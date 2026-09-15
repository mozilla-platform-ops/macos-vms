#!/bin/bash
set -euo pipefail

# Defaults
DEFAULT_VM_NAME="sequoia-tester"
DEFAULT_VAULT_FILE="vault-fake.yaml"  # local/dev default

# Allow overrides
VM_NAME="${VM_NAME:-$DEFAULT_VM_NAME}"
VAULT_FILE="${VAULT_FILE:-$DEFAULT_VAULT_FILE}"
# Build-time-only ronin_puppet branch to apply (default master). When set to a
# non-master branch, phase 2 bakes its engine and then removes the pin so the
# runtime guest still tracks master. See bug 2071007.
PUPPET_BRANCH="${PUPPET_BRANCH:-master}"

# Ensure the vault exists (CI is non-interactive)
if [[ ! -f "$VAULT_FILE" ]]; then
  echo "❌ Vault file not found at '$VAULT_FILE'"
  echo "pwd: $(pwd)"
  echo "VAULT_FILE: ${VAULT_FILE:-<unset>}"
  if [[ -t 0 ]]; then
    read -r -p "🔑 Enter the path to the Vault file: " VAULT_FILE
    [[ -f "$VAULT_FILE" ]] || { echo "❌ Still not found. Exiting."; exit 1; }
  else
    echo "Non-interactive mode. Exiting."
    exit 1
  fi
fi

echo "⚡ Starting macOS CI Image Build..."
echo "  - VM Name:   $VM_NAME"
echo "  - VaultFile: $VAULT_FILE"
echo ""

# Phase 1: Base (no vm_name var in this file)
packer build -force create-base.pkr.hcl

# Phase 2: Disable SIP
packer build -force \
  -var="vm_name=$VM_NAME" \
  disable-sip.pkr.hcl

# Phase 3: Puppet setup phase 1 (needs vault)
packer build -force \
  -var="vm_name=$VM_NAME" \
  -var="vault_file=$VAULT_FILE" \
  puppet-setup-phase1.pkr.hcl

# Phase 4: Puppet setup phase 2
packer build -force \
  -var="vm_name=$VM_NAME" \
  -var="puppet_branch=$PUPPET_BRANCH" \
  puppet-setup-phase2.pkr.hcl

echo "✅ Build process completed successfully!"