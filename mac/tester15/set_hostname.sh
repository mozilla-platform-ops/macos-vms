#!/bin/bash
# Give a freshly cloned CI macOS VM its own identity: a stable name derived from
# the last 3 octets of the primary MAC, and a worker config that matches.
#
# Runs at every boot from /Library/LaunchDaemons/com.mozilla.sethostname.plist
# (as root, RunAtLoad). Idempotent: on a VM whose identity is already correct it
# changes nothing and does not disturb the worker.
#
# THERE IS DELIBERATELY NO `set -e` IN THIS SCRIPT. See section 3.

LOG=/var/log/set_hostname.log
exec >> "$LOG" 2>&1
echo "=== set_hostname $(date -u +%FT%TZ) pid=$$ ==="

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO=sudo

WORKER_CONFIG="/opt/worker/worker-runner-config.yaml"
GW_CONFIG="/opt/worker/generic-worker.conf.yaml"

# ---------------------------------------------------------------------------
# 1. Fix the clock first — everything after this needs working TLS
# ---------------------------------------------------------------------------
# A cloned VM inherits the image's RTC (nvram.bin is part of the image), so it
# boots believing it is whenever the image was captured. generic-worker starts
# immediately and every Taskcluster call fails TLS with
#   "certificate has expired or is not yet valid"
# because the cert was issued after that date. Measured on a fresh clone
# (macmini-m4-188, 2026-07-28): ~12 minutes of failing claim-work before NTP
# corrected the clock on its own. Force it early instead.
sync_clock() {
  local server stamp http_date
  $SUDO /usr/sbin/systemsetup -setusingnetworktime on >/dev/null 2>&1 || true
  server=$($SUDO /usr/sbin/systemsetup -getnetworktimeserver 2>/dev/null \
           | awk -F': ' '{print $2}' | tr -d '[:space:]')
  [ -z "${server}" ] && server="time.apple.com"

  for _ in 1 2 3; do
    if $SUDO /usr/bin/sntp -sS "${server}" >/dev/null 2>&1; then
      echo "clock: synced against ${server}, now $(date -u +%FT%TZ)"
      return 0
    fi
    sleep 5
  done
  echo "WARN clock: sntp against ${server} failed 3x"

  # Fallback for when UDP/123 is unreachable but HTTPS is. --insecure is correct
  # here and only here: a certificate cannot be validated while the clock is
  # wrong, and we read only the Date header, never the body.
  http_date=$(/usr/bin/curl -sSI --insecure --max-time 15 \
                https://firefox-ci-tc.services.mozilla.com/ 2>/dev/null \
              | awk -F': ' 'tolower($1)=="date"{print $2; exit}' | tr -d '\r')
  if [ -n "${http_date}" ]; then
    stamp=$(/bin/date -u -j -f "%a, %d %b %Y %H:%M:%S GMT" "${http_date}" "+%m%d%H%M%Y.%S" 2>/dev/null)
    if [ -n "${stamp}" ] && $SUDO /bin/date -u "${stamp}" >/dev/null 2>&1; then
      echo "clock: set from HTTPS Date header (${http_date}), now $(date -u +%FT%TZ)"
      return 0
    fi
  fi
  echo "WARN clock: could not correct the clock; expect TLS failures until it settles"
  return 1
}
sync_clock

# ---------------------------------------------------------------------------
# 2. Work out the identity this VM should have
# ---------------------------------------------------------------------------
PRIMARY_INTERFACE="en0"
if ! ifconfig "${PRIMARY_INTERFACE}" >/dev/null 2>&1; then
  echo "en0 not found, detecting primary interface"
  PRIMARY_INTERFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  [ -z "${PRIMARY_INTERFACE}" ] && PRIMARY_INTERFACE="en0"
fi

MAC_ADDRESS=$(ifconfig "${PRIMARY_INTERFACE}" 2>/dev/null | awk '/ether/{print $2}')
if [ -z "${MAC_ADDRESS}" ]; then
  echo "FATAL could not determine MAC address for ${PRIMARY_INTERFACE}; leaving identity alone"
  exit 1
fi

SHORT_MAC=$(echo "${MAC_ADDRESS}" | awk -F: '{print $(NF-2)$(NF-1)$NF}')
HOSTNAME="mac-${SHORT_MAC}"
echo "identity: ${PRIMARY_INTERFACE} ${MAC_ADDRESS} -> ${HOSTNAME}"

# ---------------------------------------------------------------------------
# 3. Cosmetic names — BEST EFFORT, and they must not gate section 4
# ---------------------------------------------------------------------------
# `scutil --set HostName` fails intermittently this early in boot. The original
# version of this script ran under `set -e`, so that single failure aborted the
# whole script BEFORE the worker config was rewritten -- and the clone then came
# up running the IMAGE's baked workerId, i.e. impersonating another host's live
# worker, which quarantine cannot drain.
#
# Observed on macmini-m4-188 (2026-07-28), read back from the stopped VM's disk:
#   LocalHostName = mac-2c8b88   (new, correct)
#   ComputerName  = mac-2c8b88   (new, correct)
#   HostName      = mac-fba5db   (stale -- and that is m4-185 slot 1)
# with both worker configs still saying mac-fba5db and their .bak files dated
# from the image build, proving the rewrite never ran.
#
# So: retry each name, log what fails, continue regardless. A wrong ComputerName
# is cosmetic. A wrong workerId is a production incident.
set_name() {  # $1 = scutil key, $2 = value
  local key="$1" value="$2" i
  for i in 1 2 3; do
    if $SUDO scutil --set "${key}" "${value}" 2>/dev/null; then
      [ "${i}" -gt 1 ] && echo "names: ${key} set on attempt ${i}"
      return 0
    fi
    sleep 3
  done
  echo "WARN names: could not set ${key}=${value} after 3 attempts (continuing anyway)"
  return 1
}

CURRENT_HOSTNAME=$($SUDO scutil --get HostName 2>/dev/null || echo "")
if [ "${CURRENT_HOSTNAME}" = "${HOSTNAME}" ]; then
  echo "names: already ${HOSTNAME}"
else
  echo "names: ${CURRENT_HOSTNAME:-<unset>} -> ${HOSTNAME}"
  set_name ComputerName  "${HOSTNAME}"
  set_name LocalHostName "${HOSTNAME}"
  set_name HostName      "${HOSTNAME}"
  dscacheutil -flushcache 2>/dev/null || true
  killall -HUP mDNSResponder 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 4. Worker identity — the part that actually matters
# ---------------------------------------------------------------------------
# Always runs, whatever section 3 did, and verifies itself afterwards rather than
# assuming sed worked.
CHANGED=0

rewrite_id() {  # $1 = file, $2 = sed expression
  local file="$1" expr="$2" before after
  [ -f "${file}" ] || { echo "WARN config: ${file} not present"; return 1; }
  before=$(/sbin/md5 -q "${file}" 2>/dev/null)
  $SUDO sed -i '' "${expr}" "${file}" || { echo "WARN config: sed failed on ${file}"; return 1; }
  after=$(/sbin/md5 -q "${file}" 2>/dev/null)
  [ "${before}" != "${after}" ] && CHANGED=1
  return 0
}

rewrite_id "${WORKER_CONFIG}" "s/workerID: \"[^\"]*\"/workerID: \"${HOSTNAME}\"/g"
rewrite_id "${WORKER_CONFIG}" "s/workerId: \"[^\"]*\"/workerId: \"${HOSTNAME}\"/g"
rewrite_id "${GW_CONFIG}"     "s/\"workerId\": \"[^\"]*\"/\"workerId\": \"${HOSTNAME}\"/g"

# Verify. A silent mismatch here is exactly how a clone ends up impersonating
# another worker, so say so loudly rather than exiting 0 and looking fine.
BAD=0
for f in "${WORKER_CONFIG}" "${GW_CONFIG}"; do
  [ -f "${f}" ] || continue
  if grep -oE 'mac-[0-9a-f]+' "${f}" 2>/dev/null | sort -u | grep -qv "^${HOSTNAME}$"; then
    echo "ERROR config: ${f} still references a workerId other than ${HOSTNAME}:"
    grep -oE 'mac-[0-9a-f]+' "${f}" | sort -u | sed 's/^/    /'
    BAD=1
  fi
done
[ "${BAD}" -eq 0 ] && echo "config: both configs report ${HOSTNAME}"

# ---------------------------------------------------------------------------
# 5. Converge — make a running worker pick up a corrected identity
# ---------------------------------------------------------------------------
# launchd provides no ordering between this daemon and cltbld's
# org.mozilla.worker-runner LaunchAgent, so the worker may already be running on
# the stale identity; it reads its config once at startup and will not notice the
# rewrite. Restart it, but only when we actually changed something -- on a
# steady-state boot this is a no-op and must not disturb a working worker.
if [ "${CHANGED}" -eq 1 ]; then
  uid=$(/usr/bin/id -u cltbld 2>/dev/null)
  if [ -n "${uid}" ]; then
    if $SUDO /bin/launchctl kickstart -k "gui/${uid}/org.mozilla.worker-runner" >/dev/null 2>&1; then
      echo "worker: restarted gui/${uid}/org.mozilla.worker-runner to pick up ${HOSTNAME}"
    else
      echo "WARN worker: could not restart org.mozilla.worker-runner; it may keep the"
      echo "     old identity until the next boot"
    fi
  else
    echo "WARN worker: cltbld uid unknown; cannot restart the worker"
  fi
else
  echo "worker: identity unchanged, leaving the worker alone"
fi

echo "=== set_hostname done $(date -u +%FT%TZ) (changed=${CHANGED} bad=${BAD}) ==="
exit 0
