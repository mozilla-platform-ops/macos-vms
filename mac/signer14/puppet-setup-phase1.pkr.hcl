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

variable "vault_file" {
  type    = string
  default = "vault-fake.yaml"
}

# Build-time hostname. See the long comment on the scutil block below — this is
# load-bearing, not cosmetic.
variable "build_hostname" {
  type    = string
  default = "dep-mac-v4-signing99"
}

# Signers track their own puppet branch, not master.
# roles_profiles::profiles::mac_signing pins puppet::periodic to this.
variable "puppet_branch" {
  type    = string
  default = "macos-signer-latest"
}

variable "puppet_role" {
  type    = string
  default = "mac_v4_signing_dep_vms"
}

source "tart-cli" "puppet-setup-phase1" {
  vm_name      = "${var.vm_name}"
  cpu_count    = 4
  memory_gb    = 8
  disk_size_gb = 100
  ssh_password = "admin"
  ssh_username = "admin"
  ssh_timeout  = "120s"
}

build {
  name    = "puppet-setup-phase1"
  sources = ["source.tart-cli.puppet-setup-phase1"]

  provisioner "file" {
    source      = "${var.vault_file}"
    destination = "/tmp/vault.yaml"
  }

  provisioner "shell" {
    inline = [

      # -----------------------------------------------------------------------
      # Build-time hostname — MUST happen before puppet runs
      # -----------------------------------------------------------------------
      # roles_profiles::profiles::mac_signing picks the signer flavor from
      # $facts['networking']['hostname'] and its `default` case is 'ff-prod'.
      # The fresh VM's name is whatever Setup Assistant left behind ("admin's
      # Virtual Machine"), which matches no pattern — so running puppet before
      # setting this would build a PRODUCTION FIREFOX SIGNER image regardless of
      # the puppet role we set two lines down. Set it first, then assert it.
      "echo 'Setting build-time hostname to ${var.build_hostname}...'",
      "echo admin | sudo -S scutil --set ComputerName  '${var.build_hostname}'",
      "echo admin | sudo -S scutil --set LocalHostName '${var.build_hostname}'",
      "echo admin | sudo -S scutil --set HostName      '${var.build_hostname}'",
      "sudo dscacheutil -flushcache || true",
      # Fail the build rather than produce a mislabelled signer image.
      "test \"$(sudo scutil --get HostName)\" = '${var.build_hostname}' || { echo 'FATAL: hostname did not stick; refusing to run puppet'; exit 1; }",
      "echo \"hostname is now $(sudo scutil --get HostName)\"",

      "echo 'Installing Rosetta 2...'",
      "echo admin | sudo -S softwareupdate --install-rosetta --agree-to-license",

      "echo 'Ensuring system paths exist...'",
      "echo admin | sudo -S mkdir -p /usr/local/bin/",
      "echo admin | sudo -S chmod 755 /usr/local/bin/",

      # run-puppet.sh expects the vault here. This is vault-fake.yaml — no real
      # signing credential is ever copied onto the runner or into the image.
      "echo admin | sudo -S mkdir -p /var/root/",
      "echo admin | sudo -S cp /tmp/vault.yaml /var/root/vault.yaml",
      "rm -f /tmp/vault.yaml",

      "echo 'Enabling passwordless sudo for admin...'",
      "echo admin | sudo -S sh -c 'mkdir -p /etc/sudoers.d/ && echo \"admin ALL=(ALL) NOPASSWD: ALL\" | tee /etc/sudoers.d/admin-nopasswd'",

      # -----------------------------------------------------------------------
      # Developer ID CA trust anchor
      # -----------------------------------------------------------------------
      # On the bare-metal signers this arrives as an MDM config profile
      # ("System Settings - Trusted Certificate - Developer ID CA"). Tart guests
      # are not MDM-enrolled and config profiles cannot be delivered by puppet,
      # so the VM equivalent is to add the (public, non-secret) Apple CA to the
      # System keychain directly.
      #
      # TODO: confirm this is the same certificate the MDM profile installs
      # before trusting the image to sign. Dump the payload from a real signer
      # with `sudo profiles -P -o stdout` and compare the SHA-256.
      "echo 'Installing Apple Developer ID CA into the System keychain...'",
      "curl -fsSL -o /tmp/DeveloperIDG2CA.cer https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer",
      "test -s /tmp/DeveloperIDG2CA.cer || { echo 'FATAL: Developer ID CA download was empty'; exit 1; }",
      "echo \"Developer ID CA sha256: $(shasum -a 256 /tmp/DeveloperIDG2CA.cer | awk '{print $1}')\"",
      "sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/DeveloperIDG2CA.cer",
      "rm -f /tmp/DeveloperIDG2CA.cer",

      # -----------------------------------------------------------------------
      # Command Line Tools
      # -----------------------------------------------------------------------
      # Pinned rather than left to the non-deterministic `softwareupdate` catalog
      # dance. Installs to /Library/Developer/CommandLineTools so the puppet
      # macos_xcode_tools exec then no-ops (its guard is
      # `unless test -d /Library/Developer/CommandLineTools/Library`).
      #
      # TODO: 16.4 is what the M4 tester fleet pins. Confirm against the real
      # signers — `pkgutil --pkg-info=com.apple.pkg.CLTools_Executables` on
      # fx-mac-v4-signing01 — because codesign/notarytool behavior is part of
      # what we are trying to reproduce here.
      "echo 'Installing pinned Command Line Tools (Xcode 16.4) from S3...'",
      "curl -o /tmp/clt.dmg https://ronin-puppet-package-repo.s3.us-west-2.amazonaws.com/macos/public/common/Command_Line_Tools_for_Xcode_16.4.dmg",
      "hdiutil attach /tmp/clt.dmg -nobrowse -mountpoint /tmp/clt",
      "echo admin | sudo -S installer -pkg '/tmp/clt/Command Line Tools.pkg' -target /",
      "hdiutil detach /tmp/clt",
      "rm -f /tmp/clt.dmg",

      "echo 'Downloading Puppet from S3...'",
      "curl -o /tmp/puppet-agent-7.28.0-1-installer.pkg https://ronin-puppet-package-repo.s3.us-west-2.amazonaws.com/macos/public/common/puppet-agent-7.28.0-1-installer.pkg",
      "echo 'Installing Puppet...'",
      "echo admin | sudo -S installer -pkg /tmp/puppet-agent-7.28.0-1-installer.pkg -target /",

      "echo '${var.puppet_role}' | sudo tee /etc/puppet_role > /dev/null",
      "sudo chmod 644 /etc/puppet_role",

      "echo 'Downloading run-puppet.sh...'",
      "curl -o /tmp/run-puppet.sh https://ronin-puppet-package-repo.s3.us-west-2.amazonaws.com/macos/public/common/run-puppet.sh",
      "chmod +x /tmp/run-puppet.sh",

      # Signers track macos-signer-latest, NOT master. The tester pipeline
      # hardcodes master; copying that here would build against code the signer
      # fleet is not running.
      "echo 'Pre-seeding Puppet repo from branch ${var.puppet_branch}...'",
      "sudo mkdir -p /opt/puppet_environments/mozilla-platform-ops",
      "sudo git clone --branch ${var.puppet_branch} https://github.com/mozilla-platform-ops/ronin_puppet.git /opt/puppet_environments/mozilla-platform-ops/ronin_puppet",

      "echo 'Running run-puppet.sh (pass 1)...'",
      "echo admin | sudo -S /tmp/run-puppet.sh || echo 'Puppet pass 1 completed with errors; phase 2 will retry.'",
    ]
  }
}
