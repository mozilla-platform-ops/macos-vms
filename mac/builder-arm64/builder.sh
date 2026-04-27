#!/bin/bash
set -euo pipefail

# Supported roles
SUPPORTED_ROLES=("gecko_1_b_osx_arm64_vms" "gecko_3_b_osx_arm64_vms" "gecko_1_b_osx_arm64" "gecko_3_b_osx_arm64")

# Defaults
ROLE="${ROLE:-gecko_1_b_osx_arm64_vms}"
VAULT_FILE="${VAULT_FILE:-$(dirname "$0")/vault-fake.yaml}"
BASE_VM="sequoia-arm64-base"
REBUILD_BASE="${REBUILD_BASE:-false}"
PUPPET_BRANCH="${PUPPET_BRANCH:-master}"

# Map role to short VM name
case "$ROLE" in
    gecko_1_b_osx_arm64_vms) ROLE_VM="sequoia-gecko1b-vms" ;;
    gecko_3_b_osx_arm64_vms) ROLE_VM="sequoia-gecko3b-vms" ;;
    gecko_1_b_osx_arm64)     ROLE_VM="sequoia-gecko1b" ;;
    gecko_3_b_osx_arm64)     ROLE_VM="sequoia-gecko3b" ;;
    *)
        echo "Unknown ROLE: $ROLE"
        echo "Supported: ${SUPPORTED_ROLES[*]}"
        exit 1
        ;;
esac

# Resolve vault file to absolute path
VAULT_FILE="$(realpath "$VAULT_FILE")"

if [[ ! -f "$VAULT_FILE" ]]; then
    echo "Vault file not found at '$VAULT_FILE'"
    if [[ -t 0 ]]; then
        read -r -p "Enter the path to the vault file: " VAULT_FILE
        [[ -f "$VAULT_FILE" ]] || { echo "Still not found. Exiting."; exit 1; }
        VAULT_FILE="$(realpath "$VAULT_FILE")"
    else
        echo "Non-interactive mode. Exiting."
        exit 1
    fi
fi

echo "=== macOS Builder Image Build ==="
echo "  Role:          $ROLE"
echo "  VM name:       $ROLE_VM"
echo "  Vault file:    $VAULT_FILE"
echo "  Base VM:       $BASE_VM"
echo "  Puppet branch: $PUPPET_BRANCH"
echo ""

cd "$(dirname "$0")"

# Phase 1 + 2: Shared base (create from IPSW + install Xcode)
# Builders do not need SIP disabled.
# Skipped if base already exists unless REBUILD_BASE=true.
# Caching the base saves significant time when building multiple roles in one session.
BASE_EXISTS=$(tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -Fx "$BASE_VM" || true)
if [[ -n "$BASE_EXISTS" && "$REBUILD_BASE" != "true" ]]; then
    echo "Base VM '$BASE_VM' exists — skipping base rebuild (set REBUILD_BASE=true to force)"
else
    echo "--- Phase 1: Creating base image from IPSW ---"
    packer build -force -var "vm_name=${BASE_VM}" create-base.pkr.hcl

    echo "--- Phase 2: Installing Xcode 16.4 ---"
    packer build -force -var "vm_name=${BASE_VM}" install-xcode.pkr.hcl
fi

# Phase 3: Clone base into role-specific VM
echo "--- Phase 3: Cloning base into ${ROLE_VM} ---"
tart delete "$ROLE_VM" 2>/dev/null || true
tart clone "$BASE_VM" "$ROLE_VM"

# Phase 4: Puppet phase 1 (installs packages, skips pipconf)
echo "--- Phase 4: Puppet phase 1 (role: ${ROLE}) ---"

# Background net-probe: test nc from runner shell every 15s while packer tries SSH.
# Compares runner-shell vs packer-plugin-tart connectivity to same VM IP at same time.
# NOTE: must use direct & + $! pattern, NOT PID=$(func &; echo $!) — the latter hangs
# because the background process inherits and keeps open the command-substitution pipe.
(
    VM_NAME="$ROLE_VM"
    for _ in $(seq 1 60); do
        sleep 15
        vm_ip=$(tart ip "$VM_NAME" 2>/dev/null || true)
        if [[ -z "$vm_ip" ]]; then
            echo "[net-probe] VM $VM_NAME not yet running"
            continue
        fi
        if nc -zv -w5 "$vm_ip" 22 2>/dev/null; then
            echo "[net-probe] PASS: runner shell reached $vm_ip:22"
        else
            echo "[net-probe] FAIL: runner shell cannot reach $vm_ip:22"
        fi
        echo "[net-probe] ARP: $(arp -n 2>/dev/null | grep "$vm_ip" || echo 'no entry')"
    done
) &
NET_PROBE_PID=$!

# SSH proxy: forward 127.0.0.1:2222 -> VM:22 via Python (runner shell subprocess).
# packer-plugin-tart gets EHOSTUNREACH on bridge100; Python may not share that restriction.
python3 "$(dirname "$0")/ssh_proxy.py" "$ROLE_VM" 2222 &
SSH_PROXY_PID=$!
echo "Diagnostics started: net-probe=$NET_PROBE_PID, ssh-proxy=$SSH_PROXY_PID"

packer build \
    -var "vm_name=${ROLE_VM}" \
    -var "puppet_role=${ROLE}" \
    -var "vault_file=${VAULT_FILE}" \
    -var "puppet_branch=${PUPPET_BRANCH}" \
    puppet-setup-phase1.pkr.hcl
kill "$NET_PROBE_PID" "$SSH_PROXY_PID" 2>/dev/null || true
sleep 1

# Phase 5: Puppet phase 2 (enables pipconf, final apply, hostname daemon)
echo "--- Phase 5: Puppet phase 2 ---"
(
    VM_NAME="$ROLE_VM"
    for _ in $(seq 1 60); do
        sleep 15
        vm_ip=$(tart ip "$VM_NAME" 2>/dev/null || true)
        if [[ -z "$vm_ip" ]]; then
            echo "[net-probe] VM $VM_NAME not yet running"
            continue
        fi
        if nc -zv -w5 "$vm_ip" 22 2>/dev/null; then
            echo "[net-probe] PASS: runner shell reached $vm_ip:22"
        else
            echo "[net-probe] FAIL: runner shell cannot reach $vm_ip:22"
        fi
        echo "[net-probe] ARP: $(arp -n 2>/dev/null | grep "$vm_ip" || echo 'no entry')"
    done
) &
NET_PROBE_PID=$!
python3 "$(dirname "$0")/ssh_proxy.py" "$ROLE_VM" 2222 &
SSH_PROXY_PID=$!
echo "Diagnostics started: net-probe=$NET_PROBE_PID, ssh-proxy=$SSH_PROXY_PID"

packer build \
    -var "vm_name=${ROLE_VM}" \
    -var "puppet_role=${ROLE}" \
    -var "puppet_branch=${PUPPET_BRANCH}" \
    puppet-setup-phase2.pkr.hcl
kill "$NET_PROBE_PID" "$SSH_PROXY_PID" 2>/dev/null || true

echo ""
echo "Build complete: ${ROLE_VM}"
