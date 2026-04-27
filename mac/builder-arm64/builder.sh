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

# Tart wrapper: packer-plugin-tart overrides ssh_host by calling 'tart ip' and using the
# result directly, ignoring ssh_host in the packer HCL. The bridge100 VM IP is unreachable
# from packer-plugin-tart's process context (EHOSTUNREACH), but reachable from the runner
# shell. This wrapper intercepts 'tart ip' to return 127.0.0.1 — routing packer's SSH
# through our Python proxy (127.0.0.1:2222 -> VM:22) which runs in the shell context.
TART_WRAPPER_DIR=$(mktemp -d)
cat > "$TART_WRAPPER_DIR/tart" << 'TART_WRAPPER_EOF'
#!/bin/bash
REAL_TART=/opt/homebrew/bin/tart
if [[ "$1" == "ip" ]]; then
    # packer-plugin-tart calls: tart ip --wait 120 <vm_name>
    # Pass ALL args to real tart unchanged; replace the returned IP with 127.0.0.1
    # so packer connects through our proxy instead of the unreachable bridge100 address.
    real_ip=$("$REAL_TART" "$@" 2>/dev/null || true)
    if [[ -n "$real_ip" && "$real_ip" == *.* ]]; then
        echo "127.0.0.1"
        exit 0
    fi
    exit 1
fi
exec "$REAL_TART" "$@"
TART_WRAPPER_EOF
chmod +x "$TART_WRAPPER_DIR/tart"
export PATH="$TART_WRAPPER_DIR:$PATH"
echo "Tart wrapper installed at $TART_WRAPPER_DIR/tart (tart ip -> 127.0.0.1)"

# Pre-packer network diagnostics: verify what is reachable from the runner subprocess.
# Uses the REAL tart (not the wrapper) to get the VM's actual IP.
# These run in the same process context as the proxy and packer.
echo "--- Pre-packer network diagnostics ---"
_diag_ip=$(/opt/homebrew/bin/tart ip --wait 90 "$ROLE_VM" 2>/dev/null || echo "")
echo "[diag] VM IP (real tart):  ${_diag_ip:-NONE}"
echo "[diag] bridge100:"
ifconfig bridge100 2>/dev/null | grep -E '(flags|inet )' | head -3 || echo "(no bridge100)"
echo "[diag] route to 192.168.64.x:"
netstat -rn 2>/dev/null | grep -E '(192\.168\.64|bridge100)' || echo "(no route)"
echo "[diag] ARP table:"
arp -n 2>/dev/null | grep '192\.168\.64' || echo "(no entries)"
if [[ -n "$_diag_ip" ]]; then
    echo "[diag] nc -z to $_diag_ip:22 (5s timeout):"
    nc -zv -w5 "$_diag_ip" 22 2>&1 && echo "[diag] nc: PASS" || echo "[diag] nc: FAIL"
    echo "[diag] ping -c1 $_diag_ip:"
    ping -c 1 -W 2000 "$_diag_ip" 2>&1 | tail -2 || true
fi
echo "--- End diagnostics ---"

# Phase 4: Puppet phase 1 (installs packages, skips pipconf)
echo "--- Phase 4: Puppet phase 1 (role: ${ROLE}) ---"

# Background net-probe: use REAL tart (not wrapper) to get the VM's actual IP,
# then test nc from runner shell every 15s while packer tries SSH.
# NOTE: must use direct & + $! pattern, NOT PID=$(func &; echo $!) — the latter hangs
# because the background process inherits and keeps open the command-substitution pipe.
(
    VM_NAME="$ROLE_VM"
    REAL_TART=/opt/homebrew/bin/tart
    for _ in $(seq 1 60); do
        sleep 15
        vm_ip=$("$REAL_TART" ip "$VM_NAME" 2>/dev/null || true)
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
    REAL_TART=/opt/homebrew/bin/tart
    for _ in $(seq 1 60); do
        sleep 15
        vm_ip=$("$REAL_TART" ip "$VM_NAME" 2>/dev/null || true)
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

rm -rf "$TART_WRAPPER_DIR"
echo ""
echo "Build complete: ${ROLE_VM}"
