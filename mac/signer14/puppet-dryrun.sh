#!/bin/bash
# Run the signer puppet catalog against the NON-SECRET build vault, to see how
# far it gets without real credentials.
#
# Installed in the image as /usr/local/bin/signer14-puppet-dryrun.sh.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# The shipped image deliberately has NO /var/root/vault.yaml — that is the
# credential-free property, and phase 2 asserts it. But run-puppet.sh hard-fails
# without one:
#
#     [ -f '/var/root/vault.yaml' ] || fail "Secrets file not found"
#
# so simply invoking puppet on the image does nothing useful. This script stages
# the obviously-fake build vault, runs puppet, and then removes it again, so the
# image is credential-free at rest and only carries a vault for the duration of
# a deliberate, interactive dry run.
#
# Removing the vault afterwards is not cosmetic: com.mozilla.periodic.plist runs
# puppet every 900s, and a vault left behind would turn this one-shot dry run
# into an unattended puppet loop.
#
# ---------------------------------------------------------------------------
# WHAT TO EXPECT
# ---------------------------------------------------------------------------
# The image was built by converging this same catalog, so most of the run is a
# no-op. What you are checking is that it still compiles and applies cleanly on
# a booted VM. Expect:
#
#   * three applies before it goes green on a from-scratch host (see the README
#     section "the retry loop is load-bearing"); on this already-converged image
#     it should be clean much sooner;
#   * NO firewall rules — the image's FQDN is pinned to .invalid so
#     fw::roles::mac_signing skips, which is also what stops puppet severing
#     your SSH session;
#   * nothing signable to appear. The keychain, ed25519 key and widevine clone
#     need real credentials and are absent by design.

set -u

FAKE_VAULT=/usr/local/share/signer14/vault-fake.yaml
REAL_VAULT=/var/root/vault.yaml
BRANCH="${PUPPET_BRANCH:-master}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run me with sudo." >&2
  exit 1
fi

if [ -f "$REAL_VAULT" ]; then
  echo "REFUSING: ${REAL_VAULT} already exists."
  echo "This image is supposed to ship without one. If you placed a REAL vault"
  echo "there deliberately, run run-puppet.sh directly instead — this script"
  echo "would delete it on exit."
  exit 1
fi

if [ ! -f "$FAKE_VAULT" ]; then
  echo "FATAL: ${FAKE_VAULT} is missing; cannot dry-run." >&2
  exit 1
fi

# shellcheck disable=SC2329  # invoked via the trap below, which shellcheck does not track
cleanup() {
  rm -f "$REAL_VAULT"
  echo ""
  echo "--- removed ${REAL_VAULT}; image is credential-free again ---"
}
trap cleanup EXIT INT TERM

cat <<BANNER

=========================================================================
 signer14 puppet DRY RUN
 Staging a NON-SECRET fake vault and applying the dep signer catalog.
 Branch: ${BRANCH}
 Nothing here can sign, authenticate, or reach Taskcluster.
=========================================================================

BANNER

install -m 0600 -o root -g wheel "$FAKE_VAULT" "$REAL_VAULT"

# The templated /usr/local/bin/run-puppet.sh honours PUPPET_BRANCH from the
# environment ("${PUPPET_BRANCH:-<baked default>}"). The S3 copy does NOT — it
# sources /opt/puppet_environments/ronin_settings, which overwrites the
# environment — so prefer the templated one and pass the branch explicitly.
if [ -x /usr/local/bin/run-puppet.sh ]; then
  echo "Using /usr/local/bin/run-puppet.sh with PUPPET_BRANCH=${BRANCH}"
  PUPPET_BRANCH="${BRANCH}" /usr/local/bin/run-puppet.sh
  rc=$?
else
  echo "FATAL: /usr/local/bin/run-puppet.sh not present" >&2
  exit 1
fi

echo ""
echo "run-puppet.sh exited ${rc}"
echo "Reminder: any errors mentioning widevine, keychains, ed25519 or"
echo "Taskcluster tokens are EXPECTED — those need real credentials."
exit "$rc"
