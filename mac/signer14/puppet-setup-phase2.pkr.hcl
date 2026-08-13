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

# The branch the SHIPPED image should track, regardless of what the build used.
# Phase 1 may point run-puppet.sh at a feature branch via PUPPET_BRANCH; leaving
# that baked into the image would make a deployed VM apply unreviewed code.
#
# TEMPORARY: `master`, not `macos-signer-latest`. The signer fleet tracks
# macos-signer-latest, but that branch does not yet carry
# roles_profiles::roles::mac_v4_signing_dep_vms (the role merged to master in
# ronin_puppet#1325). Pinning the image at macos-signer-latest meant puppet could
# not compile its catalog at all — so the image could never be exercised beyond
# the build. Pointing at master lets a tester actually run puppet and see how far
# it gets.
#
# REVERT TO 'macos-signer-latest' once that branch carries the role, so the image
# tracks what the fleet really runs.
variable "prod_puppet_branch" {
  type    = string
  default = "master"
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

  # Shipped so a tester can exercise puppet without real credentials. Staged to
  # /usr/local/share/, NOT /var/root/vault.yaml — the image stays credential-free
  # at rest and phase 2 still asserts that.
  provisioner "file" {
    source      = "vault-fake.yaml"
    destination = "/tmp/vault-fake.yaml"
  }

  provisioner "file" {
    source      = "puppet-dryrun.sh"
    destination = "/tmp/puppet-dryrun.sh"
  }

  provisioner "shell" {
    # See phase 1: run-puppet.sh retries a failed apply forever, so bound it.
    timeout = "45m"
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

      # -----------------------------------------------------------------------
      # Ship an opt-in puppet dry-run
      # -----------------------------------------------------------------------
      # run-puppet.sh hard-fails without /var/root/vault.yaml, so the shipped
      # image cannot be exercised beyond the build without staging one. Rather
      # than ship a vault at rest — which would undo the assertion above and
      # hand com.mozilla.periodic.plist (900s interval) a way to start applying
      # puppet unattended — ship the obviously-fake build vault somewhere inert
      # plus a wrapper that stages it, runs puppet, and removes it on exit.
      "echo 'Installing the opt-in puppet dry-run helper...'",
      "sudo mkdir -p /usr/local/share/signer14",
      "sudo install -m 0600 -o root -g wheel /tmp/vault-fake.yaml /usr/local/share/signer14/vault-fake.yaml",
      "sudo install -m 0755 -o root -g wheel /tmp/puppet-dryrun.sh /usr/local/bin/signer14-puppet-dryrun.sh",
      "rm -f /tmp/vault-fake.yaml /tmp/puppet-dryrun.sh",
      # The staged copy must not be mistaken for a live secret. NB the sudo:
      # the file is installed 0600 root:wheel (correct for anything
      # vault-shaped), and these provisioners run as `admin`, so an unprivileged
      # grep gets permission denied and the assertion fires on a perfectly good
      # file. That is exactly how this failed the first time.
      "sudo grep -q 'NON-SECRET' /usr/local/share/signer14/vault-fake.yaml || { echo 'FATAL: staged vault is not the fake one'; exit 1; }",
      "test ! -f /var/root/vault.yaml || { echo 'FATAL: staging the dry-run vault polluted /var/root'; exit 1; }",

      # -----------------------------------------------------------------------
      # Reset the puppet branch override to the production branch
      # -----------------------------------------------------------------------
      # Phase 1 may have pointed run-puppet.sh at a feature branch while the VM
      # role was still in review. Shipping that would mean a deployed signer VM
      # applies unreviewed puppet code on every run — so pin the image back to
      # the branch the signer fleet actually tracks.
      "echo 'Pinning shipped image to puppet branch ${var.prod_puppet_branch}...'",
      "sudo sh -c 'echo \"PUPPET_BRANCH=${var.prod_puppet_branch}\" > /opt/puppet_environments/ronin_settings'",
      "sudo chmod 644 /opt/puppet_environments/ronin_settings",
      "grep -q '^PUPPET_BRANCH=${var.prod_puppet_branch}$' /opt/puppet_environments/ronin_settings || { echo 'FATAL: puppet branch override not reset'; exit 1; }",
      "cat /opt/puppet_environments/ronin_settings",

      # The signing material (keychain, ed25519_privkey, widevine cert) is NOT
      # in this image and is not supposed to be — puppet only creates the empty
      # 0700 certs/ directory. Confirm nothing unexpected landed there.
      "echo 'certs directories in the image (expected: empty):'",
      "sudo find /usr/local/builds -maxdepth 3 -name certs -type d -exec ls -la {} \\; 2>/dev/null || true",

      # -----------------------------------------------------------------------
      # Stop System Settings reopening on first login
      # -----------------------------------------------------------------------
      # create-base drives System Settings over VNC to enable Screen Sharing and
      # Remote Login. macOS records that in admin's per-host relaunch list, so
      # the first GUI login on a deployed VM reopens System Settings (on the
      # Appearance pane). Confirmed in a built image:
      #
      #   $ defaults -currentHost read com.apple.loginwindow TALAppsToRelaunchAtLogin
      #   ( { BundleID = "com.apple.systempreferences"; ... }, { ... Finder ... } )
      #
      # macos_utils::clean_appstate handles exactly this for the six scriptworker
      # users — their com.apple.loginwindow domain does not even exist afterwards
      # — but nothing covers `admin`, which is the account a human logs into.
      "echo 'Clearing admin relaunch-at-login state...'",
      "sudo -u admin defaults -currentHost write com.apple.loginwindow TALAppsToRelaunchAtLogin -array",
      "sudo -u admin defaults write -g NSQuitAlwaysKeepsWindows -bool false",
      "sudo rm -rf '/Users/admin/Library/Saved Application State/'*",
      "sudo -u admin defaults -currentHost read com.apple.loginwindow TALAppsToRelaunchAtLogin 2>&1 | head -3",

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
