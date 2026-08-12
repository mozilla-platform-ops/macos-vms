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

# Phase 1.5. Apple never shipped a 14.7.5 IPSW — Sonoma restore images stop at
# 14.6.1 — so reaching the fleet's point release means updating the guest after
# the restore. Set SKIP_OS_UPDATE=1 to stay on the IPSW's version.
SKIP_OS_UPDATE="${SKIP_OS_UPDATE:-0}"
TARGET_LABEL="${TARGET_LABEL:-}"

# Phase 1.6. Full Xcode (the signers run 16.2). By far the slowest step —
# ~8 GB download plus a very slow xip expansion — so it is skippable while
# iterating on the puppet phases.
SKIP_XCODE="${SKIP_XCODE:-0}"

if [[ ! -f "$VAULT_FILE" ]]; then
  echo "❌ Vault file not found at '$VAULT_FILE'"
  echo "pwd: $(pwd)"
  exit 1
fi

if [[ "$SKIP_BASE" != "1" && -z "$IPSW_URL" ]]; then
  cat <<'EOF'
❌ IPSW_URL is not set.

There is deliberately no default — the restore image is an explicit decision.

Note that you CANNOT restore straight to the fleet's version. The signers run
macOS 14.7.5 (23H527), but Apple never published a full restore IPSW for it:
Sonoma IPSWs stop at 14.6.1 (23G93, Aug 2024), because once Sequoia shipped the
14.7.x releases were security updates delivered through `softwareupdate`.

So restore 14.6.1 and let phase 1.5 update the guest within the major:

  IPSW_URL="https://updates.cdn-apple.com/2024SummerFCS/fullrestores/062-52859/932E0A8F-6644-4759-82DA-F8FA8DEA806A/UniversalMac_14.6.1_23G93_Restore.ipsw" ./builder.sh

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

# Phase 1.5: update within macOS 14 to reach the fleet's point release
if [[ "$SKIP_OS_UPDATE" == "1" ]]; then
  echo "⏭  Phase 1.5 (update-os) skipped — image stays on the IPSW's version."
else
  packer build -force \
    -var="vm_name=$VM_NAME" \
    -var="target_label=$TARGET_LABEL" \
    update-os.pkr.hcl
fi

# Phase 1.6: full Xcode, matching the signers (16.2)
if [[ "$SKIP_XCODE" == "1" ]]; then
  echo "⏭  Phase 1.6 (install-xcode) skipped — image will have CLT only, not full Xcode."
else
  packer build -force \
    -var="vm_name=$VM_NAME" \
    install-xcode.pkr.hcl
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
