packer {
  required_plugins {
    tart = {
      version = ">= 1.12.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

variable "vm_name" {
  type = string
}

variable "puppet_role" {
  type = string
}

variable "vault_file" {
  type    = string
  default = "/Users/admin/Downloads/vault.yaml"
}

variable "puppet_branch" {
  type    = string
  default = "master"
}

source "tart-cli" "puppet-setup-phase1" {
  vm_name      = var.vm_name
  cpu_count    = 8
  memory_gb    = 12
  disk_size_gb = 150
  ssh_password = "admin"
  ssh_username = "admin"
  ssh_timeout  = "120s"
}

build {
  name    = "puppet-setup-phase1"
  sources = ["source.tart-cli.puppet-setup-phase1"]

  provisioner "file" {
    source      = var.vault_file
    destination = "/tmp/vault.yaml"
  }

  provisioner "shell" {
    inline = [
      # Pin to macOS 15.3 — prevent the OS from auto-upgrading during or after the build.
      "sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false",
      "sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false",
      "sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false",
      "sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false",

      "echo 'Installing Rosetta 2...'",
      "sudo softwareupdate --install-rosetta --agree-to-license",

      "echo 'Ensuring system paths exist...'",
      "sudo mkdir -p /usr/local/bin/",
      "sudo chmod 755 /usr/local/bin/",

      "sudo mkdir -p /var/root/",
      "sudo cp /tmp/vault.yaml /var/root/vault.yaml",

      "echo 'Installing Command Line Tools...'",
      "touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress",
      "softwareupdate --list | sed -n 's/.*Label: \\(Command Line Tools for Xcode-.*\\)/\\1/p' | xargs -I {} softwareupdate --install '{}'",
      "rm /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress",

      "echo 'Downloading Puppet...'",
      "curl -o /tmp/puppet-agent-7.28.0-1-installer.pkg https://ronin-puppet-package-repo.s3.us-west-2.amazonaws.com/macos/public/common/puppet-agent-7.28.0-1-installer.pkg",
      "echo 'Installing Puppet...'",
      "sudo installer -pkg /tmp/puppet-agent-7.28.0-1-installer.pkg -target /",

      "echo '${var.puppet_role}' | sudo tee /etc/puppet_role > /dev/null",
      "sudo chmod 644 /etc/puppet_role",

      "echo 'Downloading run-puppet.sh...'",
      "curl -o /tmp/run-puppet.sh https://ronin-puppet-package-repo.s3.us-west-2.amazonaws.com/macos/public/common/run-puppet.sh",
      "chmod +x /tmp/run-puppet.sh",

      "echo 'Installing vault gems required by hiera-vault backend...'",
      "sudo /opt/puppetlabs/puppet/bin/gem install vault debouncer --no-document",

      "echo 'Cloning Puppet repo (branch: ${var.puppet_branch})...'",
      "sudo mkdir -p /opt/puppet_environments/mozilla-platform-ops",
      "sudo git clone --branch ${var.puppet_branch} https://github.com/mozilla-platform-ops/ronin_puppet.git /opt/puppet_environments/mozilla-platform-ops/ronin_puppet",

      # pipconf requires pip to already be installed, which happens during this first puppet run.
      # Disable it here so the first run can install Python/pip, then phase2 re-enables it.
      "echo 'Patching out pipconf for initial run...'",
      "sudo sed -i '.bak' '/pipconf/s/^/#/' /opt/puppet_environments/mozilla-platform-ops/ronin_puppet/modules/roles_profiles/manifests/roles/${var.puppet_role}.pp || true",

      "echo 'Running Puppet (phase 1)...'",
      "sudo env PUPPET_BRANCH=${var.puppet_branch} /tmp/run-puppet.sh",
    ]
  }
}
