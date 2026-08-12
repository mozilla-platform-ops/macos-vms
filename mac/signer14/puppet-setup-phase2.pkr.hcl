packer {
  required_plugins {
    tart = {
      version = ">= 1.12.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

variable "vm_name" {
  type    = string
  default = "sonoma-signer-dep"
}

source "tart-cli" "puppet-setup-phase2" {
  vm_name      = "${var.vm_name}"
  cpu_count    = 4
  memory_gb    = 8
  disk_size_gb = 100
  ssh_password = "admin"
  ssh_username = "admin"
  ssh_timeout  = "120s"
}

build {
  name    = "puppet-setup-phase2"
  sources = ["source.tart-cli.puppet-setup-phase2"]

  provisioner "file" {
    source      = "set_hostname.sh"
    destination = "/tmp/set_hostname.sh"
  }

  provisioner "file" {
    source      = "com.mozilla.sethostname.plist"
    destination = "/tmp/com.mozilla.sethostname.plist"
  }

  provisioner "shell" {
    inline = [

      # Keep the VM awake and out of the screensaver, same as the tester image.
      "sudo defaults write /Library/Preferences/com.apple.screensaver loginWindowIdleTime 0",
      "defaults -currentHost write com.apple.screensaver idleTime 0",
      "sudo systemsetup -setsleep Off 2>/dev/null || true",

      # -----------------------------------------------------------------------
      # First-boot identity daemon
      # -----------------------------------------------------------------------
      # Installed but deliberately NOT launchctl-loaded here. At build time there
      # is no host-shared identity directory, so loading it now would just make
      # it fail closed and exit 1. It auto-loads at boot on the deployed VM.
      "echo 'Installing first-boot identity daemon...'",
      "sudo mv /tmp/set_hostname.sh /usr/local/bin/set_hostname.sh",
      "sudo chmod 755 /usr/local/bin/set_hostname.sh",
      "sudo chown root:wheel /usr/local/bin/set_hostname.sh",
      "sudo mv /tmp/com.mozilla.sethostname.plist /Library/LaunchDaemons/com.mozilla.sethostname.plist",
      "sudo chmod 644 /Library/LaunchDaemons/com.mozilla.sethostname.plist",
      "sudo chown root:wheel /Library/LaunchDaemons/com.mozilla.sethostname.plist",

      "echo 'Running run-puppet.sh (pass 2)...'",
      "curl -o /tmp/run-puppet.sh https://ronin-puppet-package-repo.s3.us-west-2.amazonaws.com/macos/public/common/run-puppet.sh",
      "sudo chmod +x /tmp/run-puppet.sh",
      "sudo /tmp/run-puppet.sh || echo 'Puppet pass 2 completed with errors, but continuing...'",

      # -----------------------------------------------------------------------
      # Ship credential-free
      # -----------------------------------------------------------------------
      # This was only ever vault-fake.yaml, but the image must not carry a vault
      # of any kind — a fake one left in place is indistinguishable from a real
      # one at a glance and invites someone to assume injection already works.
      "sudo rm -f /var/root/vault.yaml",
      "sudo rm -f /opt/puppet_environments/mozilla-platform-ops/ronin_puppet/data/secrets/vault.yaml",

      # Assert it. Cheap, and the whole security story rests on it.
      "test ! -f /var/root/vault.yaml || { echo 'FATAL: vault.yaml survived cleanup'; exit 1; }",

      # The signing material (keychain, ed25519_privkey, widevine cert) is NOT
      # in this image and is not supposed to be — puppet only creates the empty
      # 0700 certs/ directory. Confirm nothing unexpected landed there.
      "echo 'certs directories in the image (expected: empty):'",
      "sudo find /usr/local/builds -maxdepth 3 -name certs -type d -exec ls -la {} \\; 2>/dev/null || true",

      # -----------------------------------------------------------------------
      # Drop build-only passwordless sudo
      # -----------------------------------------------------------------------
      # Phase 1 adds this so the provisioners can work; the bare-metal signers
      # have no such file. Removing it last means everything above still had it.
      "sudo rm -f /etc/sudoers.d/admin-nopasswd",

      "echo 'Finalizing setup. Ensuring clean exit...'",
      "exit 0"
    ]
  }
}
