packer {
  required_plugins {
    tart = {
      version = ">= 1.12.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

# ---------------------------------------------------------------------------
# Install full Xcode
# ---------------------------------------------------------------------------
# The signers have full Xcode, not just Command Line Tools — confirmed on
# fx-mac-v4-signing01:
#
#     $ xcodebuild -version
#     Xcode 16.2
#     Build version 16C5032a
#     $ ls -d /Applications/Xcode*.app
#     /Applications/Xcode.app
#
# Nothing in ronin_puppet installs it. `macos_xcodes_installer` exists but is
# included by NO role, and its script only drops the `xcodes` CLI helper on the
# box — it does not install Xcode. So on the hardware Xcode is hand-placed, in
# the same category as the signing keychains.
#
# 16.2 is also the newest Xcode that Sonoma can run (16.4 requires macOS 15.3),
# so the fleet is at the ceiling for its OS rather than merely behind.
#
# This is a separate phase because it is the slowest step in the pipeline by a
# wide margin — an ~8 GB download and a very slow xip expansion — and you do not
# want to repeat it every time you iterate on the puppet phases. SKIP_XCODE=1.

variable "vm_name" {
  type    = string
  default = "sonoma-signer-dep"
}

variable "xcode_xip" {
  type    = string
  default = "https://ronin-puppet-package-repo.s3.us-west-2.amazonaws.com/macos/public/common/Xcode_16.2.xip"
}

# What `xcodebuild -version` must report afterwards. Empty disables the check.
variable "expected_version" {
  type    = string
  default = "16.2"
}

source "tart-cli" "install-xcode" {
  vm_name      = "${var.vm_name}"
  cpu_count    = 4
  memory_gb    = 8
  disk_size_gb = 100
  ssh_password = "admin"
  ssh_username = "admin"
  ssh_timeout  = "300s"
}

build {
  name    = "install-xcode"
  sources = ["source.tart-cli.install-xcode"]

  provisioner "shell" {
    # The xip expansion alone routinely runs past the default timeout.
    timeout = "90m"
    inline = [
      "set -eu",

      # Runs before puppet-setup-phase1, so passwordless sudo is not set up yet.
      "echo admin | sudo -S sh -c 'mkdir -p /etc/sudoers.d && echo \"admin ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/admin-nopasswd'",

      "if [ -d /Applications/Xcode.app ]; then echo 'Xcode already present; skipping.'; exit 0; fi",

      "echo 'Free space before:'; df -h / | tail -1",

      "echo 'Downloading Xcode xip...'",
      "curl -fL --retry 3 -o /tmp/Xcode.xip '${var.xcode_xip}'",
      "test -s /tmp/Xcode.xip || { echo 'FATAL: Xcode xip download was empty'; exit 1; }",
      "ls -lh /tmp/Xcode.xip",

      # `xip --expand` verifies Apple's signature on the archive as it extracts;
      # a tampered or truncated download fails here rather than silently
      # producing a broken Xcode.
      "echo 'Expanding Xcode (slow — tens of minutes)...'",
      "cd /tmp && sudo xip --expand /tmp/Xcode.xip",
      "test -d /tmp/Xcode.app || { echo 'FATAL: xip expanded but no Xcode.app appeared'; exit 1; }",

      "sudo mv /tmp/Xcode.app /Applications/Xcode.app",
      "sudo chown -R root:wheel /Applications/Xcode.app",
      "rm -f /tmp/Xcode.xip",

      "echo 'Selecting and initialising Xcode...'",
      "sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer",
      "sudo xcodebuild -license accept",
      # Installs the bundled packages (device support, simulators runtime bits).
      # Non-fatal: it can grumble in a headless guest without leaving Xcode unusable.
      "sudo xcodebuild -runFirstLaunch || echo 'WARN: -runFirstLaunch reported an error; continuing'",

      "echo 'Verifying...'",
      "xcodebuild -version",
      "xcode-select -p",
      "VER=$(xcodebuild -version | head -1 | awk '{print $2}')",
      "if [ -n '${var.expected_version}' ] && [ \"$VER\" != '${var.expected_version}' ]; then",
      "  echo \"FATAL: expected Xcode ${var.expected_version}, got $VER\"",
      "  exit 1",
      "fi",
      "echo \"Xcode $VER installed and selected.\"",
      "echo 'Free space after:'; df -h / | tail -1",
    ]
  }
}
