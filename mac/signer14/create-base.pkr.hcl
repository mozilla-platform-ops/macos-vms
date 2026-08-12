packer {
  required_plugins {
    tart = {
      version = ">= 1.12.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

# macOS Sonoma restore image.
#
# Deliberately has NO default. The bare-metal signers run 14.7.5 (23H527,
# Mac14,3 / M2 mini) and the point of this image is to match them, so the exact
# IPSW is a decision the operator makes, not something this file guesses at.
# Pass it via builder.sh:
#
#     IPSW_URL="https://updates.cdn-apple.com/.../UniversalMac_14.7.5_23H527_Restore.ipsw" ./builder.sh
#
# Get the URL from Apple's mesu catalog or ipsw.me for the exact build you want.
variable "ipsw_url" {
  type        = string
  description = "Full URL to the macOS Sonoma restore IPSW (must match the prod signer build)"
}

variable "vm_name" {
  type    = string
  default = "sonoma-signer-dep"
}

source "tart-cli" "create-base" {
  from_ipsw    = "${var.ipsw_url}"
  vm_name      = "${var.vm_name}"
  cpu_count    = 4
  memory_gb    = 8
  disk_size_gb = 100
  ssh_password = "admin"
  ssh_username = "admin"
  ssh_timeout  = "300s"

  # ---------------------------------------------------------------------------
  # Carried over unchanged from mac/tester15/create-base.pkr.hcl, where it was
  # written for Sequoia. It was expected to need retuning for Sonoma's Setup
  # Assistant, but it does not: verified working against 14.6.1 (23G93) on
  # 2026-08-12, reaching SSH in 15m26s with no edits.
  #
  # Still, this is blind, timed VNC keystroke automation. It is the most
  # flake-prone step in the pipeline and a macOS point release can move a pane
  # or a tab stop under it at any time. Drift surfaces as "timeout waiting for
  # SSH", not as an obvious UI error — so re-run once before digging, and watch
  # over VNC if it fails twice. See README "Phase 1 is the flaky one".
  # ---------------------------------------------------------------------------
  boot_command = [
    # hello, hola, bonjour, etc.
    "<wait60s><spacebar>",
    # Language: switch away and back so we land on "English" and not "English (UK)"
    "<wait30s>italiano<esc>english<enter>",
    # Select Your Country and Region
    "<wait30s>united states<leftShiftOn><tab><leftShiftOff><spacebar>",
    # Written and Spoken Languages
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Accessibility
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Data & Privacy
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Migration Assistant
    "<wait10s><tab><tab><tab><spacebar>",
    # Sign In with Your Apple ID
    "<wait10s><leftShiftOn><tab><leftShiftOff><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Are you sure you want to skip signing in with an Apple ID?
    "<wait10s><tab><spacebar>",
    # Terms and Conditions
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    # I have read and agree to the macOS Software License Agreement
    "<wait10s><tab><spacebar>",
    # Create a Computer Account
    "<wait10s>admin<tab><tab>admin<tab>admin<tab><tab><tab><spacebar>",
    # Enable Location Services
    "<wait120s><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Are you sure you don't want to use Location Services?
    "<wait10s><tab><spacebar>",
    # Select Your Time Zone
    "<wait10s><tab><tab>UTC<enter><leftShiftOn><tab><tab><leftShiftOff><spacebar>",
    # Analytics
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Screen Time
    "<wait10s><tab><spacebar>",
    # Siri
    "<wait10s><tab><spacebar><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Choose Your Look
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Welcome to Mac
    "<wait10s><spacebar>",
    # Enable keyboard navigation so System Settings is drivable from the keyboard
    "<wait10s><leftAltOn><spacebar><leftAltOff>Terminal<enter>",
    "<wait10s>defaults write NSGlobalDomain AppleKeyboardUIMode -int 3<enter>",
    "<wait10s><leftAltOn>q<leftAltOff>",
    # Open System Settings
    "<wait10s><leftAltOn><spacebar><leftAltOff>System Settings<enter>",
    # Navigate to "Sharing"
    "<wait10s><leftAltOn>f<leftAltOff>sharing<enter>",
    # Navigate to "Screen Sharing" and enable it
    "<wait10s><tab><tab><tab><tab><tab><spacebar>",
    # Navigate to "Remote Login" and enable it
    "<wait10s><tab><tab><tab><tab><tab><tab><tab><tab><tab><tab><tab><tab><spacebar>",
    # Quit System Settings
    "<wait10s><leftAltOn>q<leftAltOff>",
  ]

  // Workaround for Virtualization.Framework's install not fully settling in time
  create_grace_time = "30s"

  // Keep the recovery partition so `softwareupdate` still works later
  recovery_partition = "keep"
}

build {
  name    = "create-base-image"
  sources = ["source.tart-cli.create-base"]

  provisioner "shell" {
    inline = [
      # NOTE: unlike the tester pipeline there is no SIP-disable phase after
      # this one. The bare-metal signers run with SIP ENABLED (confirmed on
      # fx-mac-v4-signing01), and the signer puppet role converges under SIP on
      # that hardware, so the VM keeps SIP on to match. See README.
      "echo 'Base Sonoma image created. SIP remains ENABLED (matches prod signers).'",
      "sw_vers",
      "csrutil status || true",
    ]
  }
}
