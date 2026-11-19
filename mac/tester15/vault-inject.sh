#!/bin/bash
# First-boot on the tester VM: install the host-injected worker vault and run
# puppet so the generic-worker config gets the real Taskcluster credentials.
#
# The image ships CREDENTIAL-FREE (built with vault-fake.yaml). At launch the
# HOST (ronin_puppet roles::tart_worker with tart.inject_vault=true) fetches the
# real vault over mTLS with its SCEP cert and shares it into the guest via
# `tart run --dir=vault:...`, which the guest sees at /Volumes/My Shared Files.
# The VM is not MDM-enrolled and has no broker identity of its own — the host
# mediates. See relops-bootstrap + Bug 2049579 for why creds are no longer baked.
set -uo pipefail
exec >> /var/log/vault-inject.log 2>&1
echo "=== vault-inject $(date -u +%FT%TZ) ==="

SRC="/Volumes/My Shared Files/vault/vault.yaml"

# Make sure the hostname/workerId is set first (its own daemon also runs at boot;
# call it here so puppet sees the right worker_id regardless of launchd order).
[ -x /usr/local/bin/set_hostname.sh ] && /usr/local/bin/set_hostname.sh || true

# Wait for the host to share the vault in (virtfs mount + file appears).
for _ in $(seq 1 60); do
  [ -f "$SRC" ] && break
  sleep 2
done
# Halting hands the slot back to the host: tart-run-vm.sh relaunches a fresh
# clone with a fresh vault. Staying up on the baked fake config instead leaves a
# worker that 401s forever, never finishes a task, so the host never relaunches
# it (slots sat dead like that for weeks, Nov 2026). Only do this when the host
# shared a vault directory, so packer builds and local VMs are left alone.
halt_for_relaunch() {
  echo "$1 — halting so the host relaunches a fresh clone"
  echo "=== vault-inject halt $(date -u +%FT%TZ) ==="
  /sbin/shutdown -h now
  exit 0
}

if [ ! -f "$SRC" ]; then
  if [ -d "/Volumes/My Shared Files/vault" ]; then
    halt_for_relaunch "vault share is mounted but '$SRC' never appeared"
  fi
  echo "no injected vault at '$SRC' after ~2min — leaving baked (fake) config; worker will not register"
  exit 0
fi

/bin/cp "$SRC" /var/root/vault.yaml
/bin/chmod 600 /var/root/vault.yaml
/usr/sbin/chown root:wheel /var/root/vault.yaml
echo "installed injected vault ($(/usr/bin/wc -c < /var/root/vault.yaml | /usr/bin/tr -d ' ') bytes); running puppet"

# run-puppet reads /var/root/vault.yaml and (re)generates the worker config with
# the real worker.access_token, then (re)starts the generic-worker.
/usr/bin/curl -fsSL -o /tmp/run-puppet.sh \
  https://ronin-puppet-package-repo.s3.us-west-2.amazonaws.com/macos/public/common/run-puppet.sh
/bin/chmod +x /tmp/run-puppet.sh
/tmp/run-puppet.sh || echo "run-puppet finished with errors (continuing)"

# The worker only works if puppet wrote the injected token into its config.
TOKEN=$(/usr/bin/awk '/^worker:/{f=1; next} /^[^ #]/{f=0} f && /^[[:space:]]+access_token:/{sub(/^[^:]*:[[:space:]]*/, ""); gsub(/"/, ""); print; exit}' /var/root/vault.yaml)
if [ -z "$TOKEN" ] || ! /usr/bin/grep -qsF -- "$TOKEN" /opt/worker/worker-runner-config.yaml /opt/worker/generic-worker.conf.yaml; then
  halt_for_relaunch "worker config does not have the injected token after puppet"
fi

# The generic-worker is started by cltbld's autologin session at boot, which
# happens BEFORE this daemon finishes. So on the very first boot the worker comes
# up reading the BAKED (fake-vault) credentials, and claimWork fails with
# "AuthenticationFailed: Bad mac". puppet has now (re)written the worker config
# with the REAL injected creds, but a running generic-worker doesn't re-read it.
# Reboot ONCE so the worker restarts against the correct config; guarded by a
# semaphore so we never reboot-loop (on every later boot the persisted config is
# already correct, so the worker starts clean and no reboot is needed).
REBOOT_SEM="/var/root/.vault-inject-rebooted"
if [ ! -f "${REBOOT_SEM}" ]; then
  /usr/bin/touch "${REBOOT_SEM}"
  echo "first-boot injection complete — rebooting once so generic-worker picks up the real credentials"
  echo "=== vault-inject done (pre-reboot) $(date -u +%FT%TZ) ==="
  /sbin/reboot
  exit 0
fi
echo "=== vault-inject done $(date -u +%FT%TZ) ==="
