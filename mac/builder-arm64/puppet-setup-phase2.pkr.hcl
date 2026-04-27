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

variable "puppet_branch" {
  type    = string
  default = "master"
}

source "tart-cli" "puppet-setup-phase2" {
  vm_name      = var.vm_name
  cpu_count    = 6
  memory_gb    = 8
  disk_size_gb = 150
  ssh_password = "admin"
  ssh_username = "admin"
  ssh_timeout  = "600s"
  headless     = true
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
      "sudo defaults write /Library/Preferences/com.apple.screensaver loginWindowIdleTime 0",
      "defaults -currentHost write com.apple.screensaver idleTime 0",
      "sudo systemsetup -setsleep Off 2>/dev/null",
      "sudo pmset -a sleep 0 displaysleep 0 disksleep 0 womp 0",

      "echo 'Installing caffeinate LaunchDaemon...'",
      "sudo tee /Library/LaunchDaemons/org.mozilla.caffeinate.plist > /dev/null << 'EOF'\n<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n    <key>Label</key>\n    <string>org.mozilla.caffeinate</string>\n    <key>ProgramArguments</key>\n    <array>\n        <string>/usr/bin/caffeinate</string>\n        <string>-i</string>\n        <string>-m</string>\n        <string>-s</string>\n    </array>\n    <key>RunAtLoad</key>\n    <true/>\n    <key>KeepAlive</key>\n    <true/>\n    <key>UserName</key>\n    <string>root</string>\n</dict>\n</plist>\nEOF",
      "sudo chmod 644 /Library/LaunchDaemons/org.mozilla.caffeinate.plist",
      "sudo chown root:wheel /Library/LaunchDaemons/org.mozilla.caffeinate.plist",
      "sudo launchctl load /Library/LaunchDaemons/org.mozilla.caffeinate.plist",

      "echo 'Installing hostname LaunchDaemon...'",
      "sudo mv /tmp/set_hostname.sh /usr/local/bin/set_hostname.sh",
      "sudo chmod +x /usr/local/bin/set_hostname.sh",
      "sudo mv /tmp/com.mozilla.sethostname.plist /Library/LaunchDaemons/com.mozilla.sethostname.plist",
      "sudo chmod 644 /Library/LaunchDaemons/com.mozilla.sethostname.plist",
      "sudo chown root:wheel /Library/LaunchDaemons/com.mozilla.sethostname.plist",
      "sudo launchctl load /Library/LaunchDaemons/com.mozilla.sethostname.plist",

      "echo 'Re-enabling pipconf...'",
      "sudo sed -i '.bak' '/#.*pipconf/s/^#//' /opt/puppet_environments/mozilla-platform-ops/ronin_puppet/modules/roles_profiles/manifests/roles/${var.puppet_role}.pp",

      # run-puppet.sh does git reset --hard which restores vault_secrets/hiera.yaml from master,
      # re-introducing the vault gem requirement. Disable it again before phase 2 runs.
      "sudo mv /opt/puppet_environments/mozilla-platform-ops/ronin_puppet/modules/vault_secrets/hiera.yaml /opt/puppet_environments/mozilla-platform-ops/ronin_puppet/modules/vault_secrets/hiera.yaml.disabled || true",

      "echo 'Running Puppet (phase 2)...'",
      "curl -o /tmp/run-puppet.sh https://ronin-puppet-package-repo.s3.us-west-2.amazonaws.com/macos/public/common/run-puppet.sh",
      "sudo chmod +x /tmp/run-puppet.sh",
      "sudo env PUPPET_BRANCH=${var.puppet_branch} /tmp/run-puppet.sh || echo 'Puppet phase 2 completed with non-fatal errors, continuing...'",

      "sudo rm -f /var/root/vault.yaml",

      "echo 'Finalizing image...'",
      "exit 0"
    ]
  }
}
