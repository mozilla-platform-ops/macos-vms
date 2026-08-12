#!/bin/bash
set -euo pipefail

# Build the dep signer VM image.
#
# THREE phases, not four. The tester pipeline has a SIP-disable phase between
# create-base and puppet; the bare-metal signers run with SIP ENABLED (confirmed
# on fx-mac-v4-signing01) and the signer puppet role converges under SIP there,
# so this image keeps SIP on to match. See README.

DEFAULT_VM_NAME="sonoma-signer-dep"
DEFAULT_VAULT_FILE="vault-fake.yaml"

VM_NAME="${VM_NAME:-$DEFAULT_VM_NAME}"
VAULT_FILE="${VAULT_FILE:-$DEFAULT_VAULT_FILE}"
IPSW_URL="${IPSW_URL:-}"

# The guest clones ronin_puppet from GitHub at build time, so the role this
# image needs must exist ON THE BRANCH IT CLONES. Until
# roles_profiles::roles::mac_v4_signing_dep_vms is merged into
# macos-signer-latest, a test build has to point at the feature branch:
#
#   PUPPET_BRANCH=signer-vm-image-role ./builder.sh
#
# (That branch must be pushed to mozilla-platform-ops/ronin_puppet — the guest
# clones the public URL and cannot see a local checkout.)
PUPPET_BRANCH="${PUPPET_BRANCH:-macos-signer-latest}"
PUPPET_ROLE="${PUPPET_ROLE:-mac_v4_signing_dep_vms}"

# Phase 1 only. Set SKIP_BASE=1 to iterate on the puppet phases against a base
# image you already built — create-base is slow and the flakiest step.
SKIP_BASE="${SKIP_BASE:-0}"

if [[ ! -f "$VAULT_FILE" ]]; then
  echo "❌ Vault file not found at '$VAULT_FILE'"
  echo "pwd: $(pwd)"
  exit 1
fi

if [[ "$SKIP_BASE" != "1" && -z "$IPSW_URL" ]]; then
  cat <<'EOF'
❌ IPSW_URL is not set.

There is deliberately no default. The bare-metal signers run macOS 14.7.5
(build 23H527) and this image exists to match them, so the restore image is an
explicit decision. Get the URL for the exact build from Apple's mesu catalog or
ipsw.me, then:

  IPSW_URL="https://updates.cdn-apple.com/.../UniversalMac_14.7.5_23H527_Restore.ipsw" ./builder.sh

To skip phase 1 and reuse a base image you have already built:

  SKIP_BASE=1 ./builder.sh
EOF
  exit 1
fi

echo "⚡ Building the dep signer image..."
echo "  - VM Name:       $VM_NAME"
echo "  - VaultFile:     $VAULT_FILE  (non-secret)"
echo "  - Puppet role:   $PUPPET_ROLE"
echo "  - Puppet branch: $PUPPET_BRANCH"
echo "  - SIP:           left ENABLED (matches prod signers)"
echo "  - Skip base:     $SKIP_BASE"
echo ""

if [[ "$PUPPET_BRANCH" != "macos-signer-latest" ]]; then
  echo "⚠️  Building against a non-default puppet branch ('$PUPPET_BRANCH')."
  echo "    Expected while mac_v4_signing_dep_vms is still in review; drop the"
  echo "    override once it lands on macos-signer-latest."
  echo ""
fi

# Phase 1: base macOS from IPSW
if [[ "$SKIP_BASE" == "1" ]]; then
  echo "⏭  Phase 1 (create-base) skipped."
else
  packer build -force \
    -var="vm_name=$VM_NAME" \
    -var="ipsw_url=$IPSW_URL" \
    create-base.pkr.hcl
fi

# Phase 2: puppet run 1 (sets the build hostname first — see the file)
packer build -force \
  -var="vm_name=$VM_NAME" \
  -var="vault_file=$VAULT_FILE" \
  -var="puppet_branch=$PUPPET_BRANCH" \
  -var="puppet_role=$PUPPET_ROLE" \
  puppet-setup-phase1.pkr.hcl

# Phase 3: puppet run 2 + first-boot identity daemon + credential scrub
packer build -force \
  -var="vm_name=$VM_NAME" \
  puppet-setup-phase2.pkr.hcl

echo "✅ Build process completed successfully!"
echo ""
echo "⚠️  This image is NOT a functional signer yet:"
echo "    - no vault.yaml injection wired up (fake vault only)"
echo "    - no vault approle"
echo "    - no keychain / ed25519 key / widevine cert"
echo "    See README 'Where this stops'."
