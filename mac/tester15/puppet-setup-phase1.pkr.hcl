packer {
  required_plugins {
    tart = {
      version = ">= 1.12.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

# Define a variable for VM name (allows dynamic selection)
variable "vm_name" {
  type    = string
  default = "sequoia-tester"
}

# Define a variable for the Vault file path
variable "vault_file" {
  type    = string
  default = "/Users/admin/Downloads/vault.yaml" # Default path
}

source "tart-cli" "puppet-setup-phase1" {
  vm_name   = "${var.vm_name}"  # Use dynamic variable
  cpu_count = 4
  memory_gb = 8
  disk_size_gb = 100
  ssh_password = "admin"
  ssh_username = "admin"
  ssh_timeout  = "120s"
}

build {
  name    = "puppet-setup-phase1"
  sources = ["source.tart-cli.puppet-setup-phase1"]

  # Copy Vault file dynamically
  provisioner "file" {
    source      = "${var.vault_file}" # Uses the variable
    destination = "/tmp/vault.yaml"
  }

  provisioner "shell" {
    inline = [

      "echo 'Installing Rosetta 2...'",
      "echo admin | sudo -S softwareupdate --install-rosetta --agree-to-license",

      "echo 'Ensuring system paths exist...'",
      "echo admin | sudo -S mkdir -p /usr/local/bin/",
      "echo admin | sudo -S chmod 755 /usr/local/bin/",

      // Ensure vault.yaml is where run-puppet.sh expects it..
      "echo admin | sudo -S mkdir -p /var/root/",
      "echo admin | sudo -S cp /tmp/vault.yaml /var/root/vault.yaml",

      "echo 'Enabling passwordless sudo for admin...'",
      "echo admin | sudo -S sh -c 'mkdir -p /etc/sudoers.d/ && echo \"admin ALL=(ALL) NOPASSWD: ALL\" | tee /etc/sudoers.d/admin-nopasswd'",

      # Install a PINNED Command Line Tools (Xcode 16.4, matching the M4 fleet)
      # straight from S3 instead of the slow, non-deterministic `softwareupdate`
      # catalog dance. Installs to /Library/Developer/CommandLineTools, so the
      # puppet macos_xcode_tools softwareupdate exec then no-ops (its guard is
      # `unless test -d /Library/Developer/CommandLineTools/Library`).
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

      "echo 'gecko_t_osx_1500_m_vms' | sudo tee /etc/puppet_role > /dev/null",
      "sudo chmod 644 /etc/puppet_role",

      "echo 'Downloading run-puppet.sh...'",
      "curl -o /tmp/run-puppet.sh https://ronin-puppet-package-repo.s3.us-west-2.amazonaws.com/macos/public/common/run-puppet.sh",
      "chmod +x /tmp/run-puppet.sh",

      "echo 'Pre-seeding Puppet repo....'",
      "sudo mkdir -p /opt/puppet_environments/mozilla-platform-ops",
      "sudo git clone --branch master https://github.com/mozilla-platform-ops/ronin_puppet.git /opt/puppet_environments/mozilla-platform-ops/ronin_puppet",

      "echo 'Applying temporary sed patches...'",
      "sudo sed -i '.bak' '/macos_tcc_perms/s/^/#/' /opt/puppet_environments/mozilla-platform-ops/ronin_puppet/modules/roles_profiles/manifests/roles/gecko_t_osx_1500_m_vms.pp",
      "sudo sed -i '.bak' '/safaridriver/s/^/#/' /opt/puppet_environments/mozilla-platform-ops/ronin_puppet/modules/roles_profiles/manifests/roles/gecko_t_osx_1500_m_vms.pp",
      "sudo sed -i '.bak' '/pipconf/s/^/#/' /opt/puppet_environments/mozilla-platform-ops/ronin_puppet/modules/roles_profiles/manifests/roles/gecko_t_osx_1500_m_vms.pp",

      "echo 'Running run-puppet.sh...'",
      "echo admin | sudo -S /tmp/run-puppet.sh",
    ]
  }
}