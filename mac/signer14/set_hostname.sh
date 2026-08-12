#!/bin/bash
# Give a cloned signer VM its allocated identity.
#
# Runs at every boot from /Library/LaunchDaemons/com.mozilla.sethostname.plist
# (as root, RunAtLoad). Idempotent: on a VM already carrying the right name it
# changes nothing.
#
# ---------------------------------------------------------------------------
# WHY THIS IS NOT THE TESTER'S set_hostname.sh
# ---------------------------------------------------------------------------
# The tester image derives its name from the MAC address (mac-<3 octets>), which
# is fine there because the name only has to be unique. On a signer the hostname
# is *semantic*: ronin_puppet's roles_profiles::profiles::mac_signing picks the
# signer flavor from it —
#
#     /^fx-mac-v(3|4)-signing\d+/    => 'ff-prod'
#     /^tb-mac-v(3|4)-signing\d+/    => 'tb-prod'
#     /^dep-mac-v(3|4)-signing\d+/   => 'dep'
#     default                        => 'ff-prod'      <-- note
#
# and signing_worker parses the worker number out of it with
# /.*-mac-v[34]-(dep)?signing(\d+).*/, falling back to the literal 'unknown'.
#
# So a MAC-derived name like "mac-f4a3ef" matches nothing, hits the `default`
# case, and produces a machine that believes it is a PRODUCTION FIREFOX SIGNER
# with worker id gecko-signing-mac14m2-unknown. The failure is silent and it
# points at prod. That is the single worst outcome available to this image, so
# this script fails closed: no valid allocated identity, no boot-time puppet.
#
# The identity is supplied by the Tart host, the same way the vault is, through
# a read-only shared directory:
#
#     tart run --dir=identity:<dir>:ro ...
#
# with <dir>/hostname containing exactly one line, e.g. "dep-mac-v4-signing90".

set -u

LOG=/var/log/set_hostname.log
exec >> "$LOG" 2>&1
echo "=== set_hostname $(date -u +%FT%TZ) pid=$$ ==="

IDENTITY_FILE="/Volumes/My Shared Files/identity/hostname"
STAMP=/var/db/.signer_identity_ok

# Only these prefixes exist in mac_signing.pp. Anything else is a typo, and a
# typo here means "silently become a prod Firefox signer".
VALID_RE='^(fx|fx-ent|tb|vpn|adhoc|dep)-mac-v[34]-signing[0-9]+$'

# ---------------------------------------------------------------------------
# 1. Clock — everything after this needs working TLS
# ---------------------------------------------------------------------------
# A cloned VM inherits the image's RTC (nvram.bin is part of the image), so it
# boots believing it is whenever the image was captured, and every TLS call
# fails with "certificate has expired or is not yet valid" until NTP catches up
# on its own. Force it early. (Same problem, same fix, as the tester image.)
sync_clock() {
  local server
  /usr/sbin/systemsetup -setusingnetworktime on >/dev/null 2>&1 || true
  server=$(/usr/sbin/systemsetup -getnetworktimeserver 2>/dev/null \
           | awk -F': ' '{print $2}' | tr -d '[:space:]')
  [ -z "${server}" ] && server="time.apple.com"

  for _ in 1 2 3; do
    if /usr/bin/sntp -sS "${server}" >/dev/null 2>&1; then
      echo "clock: synced against ${server}, now $(date -u +%FT%TZ)"
      return 0
    fi
    sleep 5
  done
  echo "WARN clock: sntp against ${server} failed 3x; expect TLS trouble"
  return 1
}
sync_clock

# ---------------------------------------------------------------------------
# 2. Read the allocated identity — fail closed
# ---------------------------------------------------------------------------
if [ ! -f "${IDENTITY_FILE}" ]; then
  echo "FATAL identity: ${IDENTITY_FILE} not present."
  echo "      The Tart host must launch this VM with --dir=identity:<dir>:ro"
  echo "      where <dir>/hostname holds the allocated signer name."
  echo "      Refusing to guess: an unmatched hostname makes mac_signing.pp"
  echo "      fall through to its 'ff-prod' default."
  rm -f "${STAMP}"
  exit 1
fi

HOSTNAME=$(head -n1 "${IDENTITY_FILE}" | tr -d '[:space:]')

if [ -z "${HOSTNAME}" ]; then
  echo "FATAL identity: ${IDENTITY_FILE} is empty. Refusing to guess."
  rm -f "${STAMP}"
  exit 1
fi

if ! echo "${HOSTNAME}" | grep -Eq "${VALID_RE}"; then
  echo "FATAL identity: '${HOSTNAME}' does not match ${VALID_RE}."
  echo "      mac_signing.pp would fall through to its 'ff-prod' default and"
  echo "      signing_worker would set the worker number to 'unknown'."
  echo "      Refusing to continue."
  rm -f "${STAMP}"
  exit 1
fi

# Belt and braces: this image is the dep build. If it is ever handed a
# non-dep identity, say so loudly rather than quietly becoming a prod signer.
# (Drop or widen this check when the same pipeline starts building other
# flavors — see README, "Building the other flavors".)
case "${HOSTNAME}" in
  dep-mac-v[34]-signing*) ;;
  *)
    echo "FATAL identity: '${HOSTNAME}' is not a dep name, but this is the dep"
    echo "      image (puppet role mac_v4_signing_dep_vms). Refusing to continue."
    rm -f "${STAMP}"
    exit 1
    ;;
esac

echo "identity: allocated name is ${HOSTNAME}"

# ---------------------------------------------------------------------------
# 3. Apply the names
# ---------------------------------------------------------------------------
# `scutil --set HostName` fails intermittently this early in boot, so retry.
# Unlike the tester, HostName is NOT cosmetic here — $facts['networking']['hostname']
# is what mac_signing.pp switches on — so a persistent failure is fatal.
set_name() {  # $1 = scutil key, $2 = value
  local key="$1" value="$2" i
  for i in 1 2 3; do
    if scutil --set "${key}" "${value}" 2>/dev/null; then
      [ "${i}" -gt 1 ] && echo "names: ${key} set on attempt ${i}"
      return 0
    fi
    sleep 3
  done
  echo "ERROR names: could not set ${key}=${value} after 3 attempts"
  return 1
}

CURRENT_HOSTNAME=$(scutil --get HostName 2>/dev/null || echo "")
if [ "${CURRENT_HOSTNAME}" = "${HOSTNAME}" ]; then
  echo "names: already ${HOSTNAME}"
else
  echo "names: ${CURRENT_HOSTNAME:-<unset>} -> ${HOSTNAME}"
  set_name ComputerName  "${HOSTNAME}"
  set_name LocalHostName "${HOSTNAME}"
  if ! set_name HostName "${HOSTNAME}"; then
    echo "FATAL names: HostName is the flavor selector; refusing to continue"
    echo "      with the wrong one."
    rm -f "${STAMP}"
    exit 1
  fi
  dscacheutil -flushcache 2>/dev/null || true
  killall -HUP mDNSResponder 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 4. Verify what puppet will actually see
# ---------------------------------------------------------------------------
# scutil --get HostName and the `networking.hostname` fact can disagree. Check
# the value puppet will switch on, not the one we just set.
EFFECTIVE=$(scutil --get HostName 2>/dev/null || echo "")
if [ "${EFFECTIVE}" != "${HOSTNAME}" ]; then
  echo "FATAL verify: HostName reads back as '${EFFECTIVE}', wanted '${HOSTNAME}'"
  rm -f "${STAMP}"
  exit 1
fi

touch "${STAMP}"
echo "verify: HostName=${EFFECTIVE} — safe for puppet"
echo "=== set_hostname done $(date -u +%FT%TZ) ==="
exit 0
