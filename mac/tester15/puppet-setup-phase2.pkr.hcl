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

      # -----------------------------------------------------------------------
      # -----------------------------------------------------------------------
      # bug 2069268 -- hand the build account over to puppet, and fix ownership.
      #
      # This does NOT neutralise the account. It cannot: the tart packer plugin
      # shuts the VM down with a command baked into its binary,
      #
      #     echo %s | sudo -S -p '' shutdown -h now
      #
      # which sudos as this very account AFTER every provisioner has run. Two
      # earlier revisions tried to neutralise it here and both hung the build at
      # "Waiting for the tart process to exit..." -- once from phase 1, once as
      # the last act of phase 2. There is no point inside a packer build at which
      # this account can be disabled.
      #
      # So the image ships with it intact and the guest role does the work on the
      # first real boot instead (roles_profiles::profiles::disable_image_build_admin,
      # which is what converged the running fleet). Clearing the marker below is
      # what re-arms that.
      #
      # Residual: a freshly cloned guest carries the account live from boot until
      # that first puppet run completes -- order minutes. Tracked in the bug. A
      # first-boot LaunchDaemon would narrow it further if that is ever judged
      # worth the extra machinery.
      #
      # The ownership fix DOES belong here: /usr/local/bin/set_hostname.sh and
      # vault-inject.sh are executed by root LaunchDaemons at boot and ship owned
      # by this account, because the file provisioner uploads as it and sudo mv
      # preserves ownership. Root-executed scripts should be root-owned whatever
      # else is true of the account.
      "echo 'Reassigning build-account ownership and re-arming puppet (bug 2069268)...'",
      <<-EOT
        echo admin | sudo -S sh -c '
          set -u

          find /usr/local /opt /Library /etc -xdev -user admin -exec chown root:wheel {} + 2>/dev/null || true

          # Provisioning is done -- let the guest role manage this account again
          # on the next (runtime) puppet run. Cleared last so nothing above it can
          # trip the role mid-build, and so the marker never ships in the image.
          rm -f /var/root/.image-build-in-progress

          # Verify in this same root shell: a non-zero exit fails the build.
          leftover=$(find /usr/local /opt /Library /etc -xdev -user admin 2>/dev/null | head -5)
          if [ -n "$leftover" ]; then
            echo "FAIL: files still owned by the build account:"; echo "$leftover"; exit 1
          fi
          if [ -f /var/root/.image-build-in-progress ]; then
            echo "FAIL: build marker still present; the guest role would stay disarmed"; exit 1
          fi
          echo "OK: ownership reassigned, build marker cleared"
        '
      EOT
      ,

      "echo 'Finalizing setup. Ensuring clean exit...'",
      "exit 0"
    ]
  }
}