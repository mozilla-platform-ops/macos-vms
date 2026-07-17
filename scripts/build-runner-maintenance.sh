#!/bin/bash
# build-runner-maintenance.sh — periodic disk hygiene + low-disk alerting for the
# macos-vms build host (e.g. macmini-m4-116). Installed to /usr/local/bin and run
# hourly by com.mozilla.build-runner-maintenance. The build host historically
# filled its disk (tart's OCI cache in ~/.tart grows unbounded) and silently
# started failing builds — this prunes the cache and emails when space is low.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

THRESHOLD_GIB=40                         # alert below this many GiB free
ALERT_EMAIL="releng-ci-alerts@mozilla.com"
SMTP_RELAY="smtp1.mail.mdc1.mozilla.com"
COOLDOWN=21600                           # 6h between alerts
STATE_FILE="/var/tmp/build-runner-maint.lastalert"
HN="$(hostname -f 2>/dev/null || hostname)"

log() { echo "$(date -u +%FT%TZ) $*"; }

# 1. Prune tart's OCI pull cache — but only when no build VM is running, so we
#    never yank an image out from under an in-flight build.
if tart list 2>/dev/null | awk 'NR>1 && $NF=="running"{f=1} END{exit !f}'; then
  log "a tart VM is running; skipping prune"
else
  tart prune 2>/dev/null && log "tart prune done" || log "tart prune skipped/failed"
fi

# 2. Check free space on the data volume and alert (rate-limited) if low.
avail="$(df -g /System/Volumes/Data | awk 'NR==2{print $4}')"
pct="$(df /System/Volumes/Data | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
log "disk: ${avail} GiB free (${pct}% used)"

if [ "${avail:-999}" -lt "$THRESHOLD_GIB" ]; then
  now="$(date +%s)"
  last="$(cat "$STATE_FILE" 2>/dev/null || echo 0)"
  if [ $(( now - last )) -ge "$COOLDOWN" ]; then
    echo "$now" > "$STATE_FILE"
    log "low disk (${avail} GiB < ${THRESHOLD_GIB} GiB); sending alert to ${ALERT_EMAIL}"
    ALERT_EMAIL="$ALERT_EMAIL" SMTP_RELAY="$SMTP_RELAY" HN="$HN" \
      AVAIL="$avail" PCT="$pct" THRESHOLD="$THRESHOLD_GIB" \
      /usr/bin/python3 - <<'PY'
import os, smtplib, email.utils
msg = (
    "From: ci-worker@mozilla.com\r\n"
    f"To: {os.environ['ALERT_EMAIL']}\r\n"
    f"Date: {email.utils.formatdate()}\r\n"
    f"Subject: [build-runner] low disk on {os.environ['HN']}\r\n"
    "\r\n"
    f"The macos-vms build host {os.environ['HN']} has only "
    f"{os.environ['AVAIL']} GiB free ({os.environ['PCT']}% used), below the "
    f"{os.environ['THRESHOLD']} GiB threshold. VM builds may start failing.\r\n"
    "Investigate: `tart list`, `du -sh ~/.tart`, and check for stuck builds.\r\n"
)
try:
    s = smtplib.SMTP(os.environ["SMTP_RELAY"], 25, timeout=30)
    s.sendmail("ci-worker@mozilla.com", os.environ["ALERT_EMAIL"], msg)
    s.quit()
    print("alert email sent")
except Exception as e:
    print(f"WARN: alert email failed: {e}")
PY
  else
    log "low disk but within ${COOLDOWN}s cooldown; not re-alerting"
  fi
fi
