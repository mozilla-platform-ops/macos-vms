#!/bin/bash
# setup-build-runner.sh — reproducibly (re)install the macos-vms GitHub Actions
# self-hosted build runner on a build host (e.g. macmini-m4-116), plus the disk
# prune/monitor LaunchDaemon. Turns "manual scramble after the runner is
# wiped/de-registered" into one command.
#
# Run ON the build host as the `admin` user (the runner + tart builds need the
# admin GUI session; ensure that user autologs in). Usage:
#
#   ./setup-build-runner.sh <registration-token>
#
# Get a fresh registration token (repo admin, expires ~1h):
#   gh api -X POST repos/mozilla-platform-ops/macos-vms/actions/runners/registration-token --jq .token
#
# Notes:
#   * Idempotent: re-running re-registers the runner and reinstalls the service.
#   * The runner runs as a LaunchAgent in the admin session (tart/VZ needs it);
#     keep admin autologin enabled so it survives reboots.
set -euo pipefail

TOKEN="${1:?usage: setup-build-runner.sh <registration-token>}"
REPO_URL="https://github.com/mozilla-platform-ops/macos-vms"
RUNNER_VERSION="2.335.1"
RUNNER_DIR="${HOME}/actions-runner"
RUNNER_NAME="$(/usr/sbin/scutil --get LocalHostName 2>/dev/null || hostname -s)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== 1. GitHub Actions runner (${RUNNER_VERSION}) ==="
mkdir -p "${RUNNER_DIR}"
cd "${RUNNER_DIR}"
if [ ! -x ./config.sh ]; then
  echo "downloading runner..."
  curl -fsSLo runner.tar.gz \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
  tar xzf runner.tar.gz && rm -f runner.tar.gz
fi

# Clear any stale local registration, then register fresh. (config.sh remove
# needs a token too; if it fails because GitHub no longer has the runner, just
# drop the local config files — they're invalid anyway.)
if [ -f .runner ]; then
  ./config.sh remove --token "${TOKEN}" 2>/dev/null || rm -f .runner .credentials .credentials_rsaparams
fi
./config.sh --url "${REPO_URL}" --token "${TOKEN}" \
  --labels self-hosted --unattended --name "${RUNNER_NAME}" --replace

./svc.sh install
./svc.sh start
echo "runner service:"; ./svc.sh status || true

echo "=== 2. disk prune/monitor LaunchDaemon ==="
sudo install -m 0755 "${SCRIPT_DIR}/build-runner-maintenance.sh" /usr/local/bin/build-runner-maintenance.sh
sudo install -m 0644 "${SCRIPT_DIR}/com.mozilla.build-runner-maintenance.plist" \
  /Library/LaunchDaemons/com.mozilla.build-runner-maintenance.plist
sudo chown root:wheel /Library/LaunchDaemons/com.mozilla.build-runner-maintenance.plist
sudo launchctl bootout system /Library/LaunchDaemons/com.mozilla.build-runner-maintenance.plist 2>/dev/null || true
sudo launchctl bootstrap system /Library/LaunchDaemons/com.mozilla.build-runner-maintenance.plist
echo "maintenance daemon loaded (hourly prune + low-disk alert)"

echo "=== done. Confirm the runner shows online:"
echo "   gh api repos/mozilla-platform-ops/macos-vms/actions/runners --jq '.runners[].name'"
