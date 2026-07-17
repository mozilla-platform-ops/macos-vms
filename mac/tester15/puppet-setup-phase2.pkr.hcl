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
  default = "seqoia-tester"
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

  provisioner "file" {
    source      = "vault-inject.sh"
    destination = "/tmp/vault-inject.sh"
  }

  provisioner "file" {
    source      = "com.mozilla.vault-inject.plist"
    destination = "/tmp/com.mozilla.vault-inject.plist"
  }

  provisioner "shell" {
    inline = [

      // Disable screensaver at login screen
      "sudo defaults write /Library/Preferences/com.apple.screensaver loginWindowIdleTime 0",
      // Disable screensaver for admin user
      "defaults -currentHost write com.apple.screensaver idleTime 0",
      // Prevent the VM from sleeping
      "sudo systemsetup -setsleep Off 2>/dev/null",

      "echo 'Setting up hostname auto-config at startup...'",

      // Move the script and set permissions
      "echo admin | sudo -S mv /tmp/set_hostname.sh /usr/local/bin/set_hostname.sh",
      "echo admin | sudo -S chmod +x /usr/local/bin/set_hostname.sh",

      // Move the launch daemon file and set permissions
      "echo admin | sudo -S mv /tmp/com.mozilla.sethostname.plist /Library/LaunchDaemons/com.mozilla.sethostname.plist",
      "echo admin | sudo -S chmod 644 /Library/LaunchDaemons/com.mozilla.sethostname.plist",
      "echo admin | sudo -S chown root:wheel /Library/LaunchDaemons/com.mozilla.sethostname.plist",

      // Load the daemon so it runs on startup
      "echo admin | sudo -S launchctl load /Library/LaunchDaemons/com.mozilla.sethostname.plist",

      // First-boot worker-vault injection: install the script + LaunchDaemon but
      // do NOT launchctl-load it here (it auto-loads at boot on the deployed VM;
      // loading at build would just block ~2min waiting for a vault that isn't
      // shared in during the build). At first boot it reads the host-injected
      // vault from /Volumes/My Shared Files/vault and runs puppet.
      "echo 'Installing first-boot vault-inject...'",
      "echo admin | sudo -S mv /tmp/vault-inject.sh /usr/local/bin/vault-inject.sh",
      "echo admin | sudo -S chmod +x /usr/local/bin/vault-inject.sh",
      "echo admin | sudo -S mv /tmp/com.mozilla.vault-inject.plist /Library/LaunchDaemons/com.mozilla.vault-inject.plist",
      "echo admin | sudo -S chmod 644 /Library/LaunchDaemons/com.mozilla.vault-inject.plist",
      "echo admin | sudo -S chown root:wheel /Library/LaunchDaemons/com.mozilla.vault-inject.plist",

      "echo 'Reverting temporary sed patches...'",
      "sudo sed -i '.bak' '/#.*macos_tcc_perms/s/^#//' /opt/puppet_environments/mozilla-platform-ops/ronin_puppet/modules/roles_profiles/manifests/roles/gecko_t_osx_1500_m_vms.pp",
      "sudo sed -i '.bak' '/#.*safaridriver/s/^#//' /opt/puppet_environments/mozilla-platform-ops/ronin_puppet/modules/roles_profiles/manifests/roles/gecko_t_osx_1500_m_vms.pp",
      "sudo sed -i '.bak' '/#.*pipconf/s/^#//' /opt/puppet_environments/mozilla-platform-ops/ronin_puppet/modules/roles_profiles/manifests/roles/gecko_t_osx_1500_m_vms.pp",

      "echo 'Running run-puppet.sh...'",
      "curl -o /tmp/run-puppet.sh https://ronin-puppet-package-repo.s3.us-west-2.amazonaws.com/macos/public/common/run-puppet.sh",
      "echo admin | sudo chmod +x /tmp/run-puppet.sh",
      "echo admin | sudo -S /tmp/run-puppet.sh || echo 'Puppet run completed with errors, but continuing...'",

      "sudo rm /var/root/vault.yaml",

      "sudo mkdir -p /var/tmp/semaphore",
      "sudo touch /var/tmp/semaphore/run-buildbot",

      "echo 'Finalizing setup. Ensuring clean exit...'",
      "exit 0"
    ]
  }
}