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
# CAVEAT — and it is bigger than it first looks. `softwareupdate` only offers the
# CURRENT security update for a major, and as of 2026-08-12 a fresh 14.6.1 guest
# is offered:
#
#     * Label: macOS Sonoma 14.8.9-23J631      <-- what this phase installs
#     * Label: macOS Tahoe 26.6.1-25G76        <-- correctly refused (major bump)
#     * Label: Safari26.6SonomaAuto-26.6
#
# So Sonoma did not stop at 14.7.x; there is a 14.8 line, and the newest is
# 14.8.9. This phase therefore lands the image on 14.8.9 while the signer fleet
# sits on 14.7.5 — the image ends up AHEAD of the hardware by a minor release,
# not level with it. 14.7.5 is not offered and cannot be reached this way.
#
# Both are Darwin 23, so mac_signing.pp's version case handles either
# identically. Whether the divergence is acceptable is a fleet-patching
# decision, not something this file can settle. Options:
#   - accept 14.8.9 here (and consider patching the fleet toward it);
#   - SKIP_OS_UPDATE=1 to stay on 14.6.1, i.e. behind the fleet rather than ahead;
#   - -var target_label=... if a specific build is ever offered again.

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

      # This phase runs BEFORE puppet-setup-phase1, so /etc/sudoers.d/admin-nopasswd
      # does not exist yet and a bare `sudo` has no tty to prompt on. Bootstrap it
      # here the same way phase 1 does. It cannot simply be `sudo -S` throughout:
      # `softwareupdate --stdinpass` also wants the password on stdin, and the two
      # would fight over it. Phase 3 removes this file before the image is sealed.
      "echo admin | sudo -S sh -c 'mkdir -p /etc/sudoers.d && echo \"admin ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/admin-nopasswd'",

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
      "  exit 0",
      "fi",

      "echo \"Installing: $TARGET\"",
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
    ]
  }
}
