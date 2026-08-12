packer {
  required_plugins {
    tart = {
      version = ">= 1.12.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

# ---------------------------------------------------------------------------
# Phase 1.5 — bring the base image up to the fleet's point release
# ---------------------------------------------------------------------------
# The bare-metal signers run macOS 14.7.5 (23H527), but Apple never published a
# full restore IPSW for it. Sonoma IPSWs stop at 14.6.1 (23G93, Aug 2024) —
# once Sequoia shipped, the 14.7.x releases were security updates delivered
# through `softwareupdate`, not full restores. Confirmed absent from both
# ipsw.me's Mac14,3 index and Mr. Macintosh's IPSW database.
#
# So "match the prod OS" is two steps: restore 14.6.1, then update within the
# major. This phase is the second step.
#
# CAVEAT: `softwareupdate` generally only offers the CURRENT security update for
# a major, so this lands on whatever the latest 14.7.x is — which may be newer
# than the fleet's 14.7.5. Pin with -var target_label=... if you need a specific
# one and it is still offered. If the fleet and the image disagree, that is a
# fleet-patching question, not an image bug.

variable "vm_name" {
  type    = string
  default = "sonoma-signer-dep"
}

# Exact `softwareupdate --list` label to install, e.g.
#   "macOS Sonoma 14.7.5-23H527"
# Empty means "take the newest offered update that stays on macOS 14".
variable "target_label" {
  type    = string
  default = ""
}

source "tart-cli" "update-os" {
  vm_name      = "${var.vm_name}"
  cpu_count    = 4
  memory_gb    = 8
  disk_size_gb = 100
  ssh_password = "admin"
  ssh_username = "admin"
  ssh_timeout  = "300s"
}

build {
  name    = "update-os"
  sources = ["source.tart-cli.update-os"]

  # The update reboots the guest, so packer must expect the SSH drop.
  provisioner "shell" {
    expect_disconnect = true
    inline = [
      "set -eu",
      "echo 'Before:'; sw_vers",

      # Only ever consider updates that keep us on macOS 14. `softwareupdate -i -a`
      # can pull in a major upgrade, which would silently defeat the entire point
      # of this phase. The ansible system-updater role in this repo guards the
      # same way with its major-version `when` clause.
      "echo 'Available updates:'",
      "softwareupdate --list --all 2>&1 | tee /tmp/su-list.txt || true",

      "TARGET='${var.target_label}'",
      "if [ -z \"$TARGET\" ]; then",
      # Labels look like: * Label: macOS Sonoma 14.7.5-23H527
      # Keep only 14.x, then take the last (newest) one.
      "  TARGET=$(grep -E '^\\s*\\* Label:' /tmp/su-list.txt | sed -E 's/^[[:space:]]*\\* Label:[[:space:]]*//' | grep -E '(^|[^0-9])14\\.[0-9]' | tail -n1 || true)",
      "fi",

      "if [ -z \"$TARGET\" ]; then",
      "  echo 'No macOS 14.x update offered — already current, or Apple stopped offering one.'",
      "  echo 'NOUPDATE' | sudo tee /var/db/.signer_os_update_state >/dev/null",
      "  exit 0",
      "fi",

      "echo \"Installing: $TARGET\"",
      "echo \"$TARGET\" | sudo tee /var/db/.signer_os_update_state >/dev/null",
      # --restart is required; without it softwareupdate hangs at
      # "Downloaded: macOS [...]" (see the ansible role's comment on the same bug).
      "sudo softwareupdate --install --agree-to-license --force --restart --user admin --stdinpass <<<'admin' \"$TARGET\" || true",
      "echo 'Update issued; guest is rebooting.'",
    ]
  }

  # Reconnects after the reboot and confirms we actually moved.
  provisioner "shell" {
    pause_before = "120s"
    inline = [
      "set -eu",
      "echo 'After:'; sw_vers",
      "VER=$(sw_vers -productVersion)",
      # $$ escapes HCL interpolation so the shell gets ${VER%%.*}
      "MAJOR=$${VER%%.*}",
      "test \"$MAJOR\" = '14' || { echo \"FATAL: left macOS 14 (now $VER) — this image must stay on Sonoma\"; exit 1; }",
      "echo \"Base image is now macOS $VER (fleet reference: 14.7.5 / 23H527)\"",
      "test \"$VER\" = '14.7.5' && echo 'Exact match with the fleet.' || echo 'NOTE: differs from the fleet 14.7.5 — see the caveat in update-os.pkr.hcl.'",
      "sudo rm -f /var/db/.signer_os_update_state",
    ]
  }
}
