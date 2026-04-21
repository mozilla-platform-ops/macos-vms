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

# Phase 1 + 2: Shared base (create from IPSW + disable SIP)
# Skipped if base already exists unless REBUILD_BASE=true.
# Caching the base saves ~17 min when building multiple roles in one session.
BASE_EXISTS=$(tart list 2>/dev/null | awk '{print $1}' | grep -Fx "$BASE_VM" || true)
if [[ -n "$BASE_EXISTS" && "$REBUILD_BASE" != "true" ]]; then
    echo "Base VM '$BASE_VM' exists — skipping base rebuild (set REBUILD_BASE=true to force)"
else
    echo "--- Phase 1: Creating base image from IPSW ---"
    packer build -force -var "vm_name=${BASE_VM}" create-base.pkr.hcl

    echo "--- Phase 2: Disabling SIP ---"
    packer build -force -var "vm_name=${BASE_VM}" disable-sip.pkr.hcl
fi

# Phase 3: Clone base into role-specific VM
echo "--- Phase 3: Cloning base into ${ROLE_VM} ---"
tart delete "$ROLE_VM" 2>/dev/null || true
tart clone "$BASE_VM" "$ROLE_VM"

# Phase 4: Puppet phase 1 (installs packages, skips pipconf)
echo "--- Phase 4: Puppet phase 1 (role: ${ROLE}) ---"
packer build \
    -var "vm_name=${ROLE_VM}" \
    -var "puppet_role=${ROLE}" \
    -var "vault_file=${VAULT_FILE}" \
    -var "puppet_branch=${PUPPET_BRANCH}" \
    puppet-setup-phase1.pkr.hcl

# Phase 5: Puppet phase 2 (enables pipconf, final apply, hostname daemon)
echo "--- Phase 5: Puppet phase 2 ---"
packer build \
    -var "vm_name=${ROLE_VM}" \
    -var "puppet_role=${ROLE}" \
    puppet-setup-phase2.pkr.hcl

echo ""
echo "Build complete: ${ROLE_VM}"
