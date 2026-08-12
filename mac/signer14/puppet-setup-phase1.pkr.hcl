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
    # run-puppet.sh's retry loop is UNBOUNDED: on a failed apply it fetches,
    # finds no new commits, sleeps 60s and tries again, forever. Without a
    # timeout a broken catalog hangs the build indefinitely instead of failing
    # it — seen for real when the role was missing from the branch being used.
    timeout = "45m"
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
      # Stock macOS already trusts the ORIGINAL Developer ID Certification
      # Authority (sha256 7afc9d01...) via SystemRootCertificates.keychain. The
      # G2 CA below (sha256 f16cd3c5...) is a DIFFERENT certificate and is not
      # in the default roots — which is the likeliest reason the signers carry
      # an MDM trusted-certificate payload at all.
      #
      # TODO: confirm against the real payload. Dump it from a signer with
      # `sudo profiles -P -o stdout` and compare; if the profile ships something
      # other than G2, change the URL here.
      "echo 'Installing Apple Developer ID G2 CA into the System keychain...'",
      "curl -fsSL -o /tmp/DeveloperIDG2CA.cer https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer",
      "test -s /tmp/DeveloperIDG2CA.cer || { echo 'FATAL: Developer ID CA download was empty'; exit 1; }",
      "echo \"Developer ID G2 CA sha256: $(shasum -a 256 /tmp/DeveloperIDG2CA.cer | awk '{print $1}')\"",

      # `security add-trusted-cert` calls SecTrustSettingsSetTrustSettings, which
      # demands an authorization that cannot be granted over SSH:
      #   "The authorization was denied since no user interaction was possible."
      # Granting com.apple.trust-settings.admin for the duration is the standard
      # headless workaround. Scoped tightly and reverted immediately after, so
      # the image does not ship with trust settings writable without auth.
      "sudo security authorizationdb write com.apple.trust-settings.admin allow",
      "sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/DeveloperIDG2CA.cer; rc=$?",
      "sudo security authorizationdb remove com.apple.trust-settings.admin || true",
      "test \"$rc\" -eq 0 || { echo 'FATAL: could not add the Developer ID G2 CA to the System keychain'; exit 1; }",

      # Prove it landed rather than assuming the exit code told the truth.
      "sudo security find-certificate -c 'Developer ID Certification Authority' /Library/Keychains/System.keychain >/dev/null 2>&1 || { echo 'FATAL: Developer ID G2 CA not present in System.keychain after add'; exit 1; }",
      "echo 'Developer ID G2 CA present and trusted in System.keychain.'",
      "rm -f /tmp/DeveloperIDG2CA.cer",

      # -----------------------------------------------------------------------
      # Command Line Tools — deliberately NOT pinned here (differs from tester15)
      # -----------------------------------------------------------------------
      # tester15 installs a pinned Xcode 16.4 CLT from S3 to avoid the slow,
      # non-deterministic `softwareupdate` catalog dance. That cannot work on
      # Sonoma:
      #
      #   installer: macOS version 15.3 or later is required.
      #
      # Xcode 16.4's CLT requires macOS 15.3+, and the S3 bucket holds only two
      # CLT images — 16.4 and a 2020-era 12.2 — so there is no Sonoma-appropriate
      # pinned option to swap in. Which also means the real signers cannot be
      # using the pinned path: they get CLT from puppet's macos_xcode_tools,
      # whose exec runs `softwareupdate -i "$PROD"` and picks whatever the OS
      # is offered. Let puppet do the same here.
      #
      # If a Sonoma CLT is ever uploaded to S3, pinning it would make this build
      # faster and more reproducible. (macos/private/14/ does hold
      # Command_Line_Tools_for_Xcode_15.3.dmg, but that prefix is private and the
      # credential-free build cannot authenticate to it.)
      #
      # CLT must nevertheless be installed HERE, before the git clone below:
      # `git` on macOS is a CLT shim, so without it the clone dies with
      #   xcode-select: error: No developer tools were found and no install
      #   could be requested (possibly because there is no active GUI session)
      # and puppet — which would otherwise install CLT itself — cannot run,
      # because it is the thing we are cloning. The sentinel file is what makes
      # `softwareupdate` offer CLT headlessly; it is the same trick the
      # macos_xcode_tools module uses, so puppet's exec then no-ops on its
      # `test -d /Library/Developer/CommandLineTools/Library` guard.
      "echo 'Installing Command Line Tools via softwareupdate (headless)...'",
      "sudo touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress",
      "PROD=$(softwareupdate -l 2>/dev/null | grep '\\*.*Command Line' | tail -n1 | sed 's/^[^C]* //')",
      "test -n \"$PROD\" || { echo 'FATAL: softwareupdate offered no Command Line Tools'; exit 1; }",
      "echo \"Selected: $PROD\"",
      "sudo softwareupdate -i \"$PROD\" --verbose",
      "sudo rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress",
      "test -d /Library/Developer/CommandLineTools/Library || { echo 'FATAL: CLT did not install'; exit 1; }",
      "git --version || { echo 'FATAL: git still unusable after CLT install'; exit 1; }",

      "echo 'Downloading Puppet from S3...'",
      "curl -o /tmp/puppet-agent-7.28.0-1-installer.pkg https://ronin-puppet-package-repo.s3.us-west-2.amazonaws.com/macos/public/common/puppet-agent-7.28.0-1-installer.pkg",
      "echo 'Installing Puppet...'",
      "echo admin | sudo -S installer -pkg /tmp/puppet-agent-7.28.0-1-installer.pkg -target /",

      "echo '${var.puppet_role}' | sudo tee /etc/puppet_role > /dev/null",
      "sudo chmod 644 /etc/puppet_role",

      # -----------------------------------------------------------------------
      # Pre-install the `vault` puppet gem with a pinned connection_pool
      # -----------------------------------------------------------------------
      # vault_agent declares `package { 'vault-puppetpath-gem': name => 'vault',
      # provider => puppet_gem }` with ensure => present and NO version pin. On a
      # fresh host today that cannot succeed:
      #
      #   vault requires Ruby version >= 3.1. The current ruby version is 2.7.8.225.
      #   connection_pool requires Ruby version >= 3.2.0.
      #
      # Puppet 7.28 bundles Ruby 2.7.8. The vault gem dropped Ruby 2.7 in 0.19.0
      # (2025-12-04) and its connection_pool dependency did the same, so an
      # unpinned `gem install vault` resolves to something uninstallable. The
      # newest usable pair on Ruby 2.7.8 is vault 0.18.2 (2023-11-27) and
      # connection_pool 2.5.5. Installing those satisfies puppet's
      # `ensure => present` and the resource no-ops.
      #
      # NB this is NOT a VM problem — it is a live latent bug in ronin_puppet.
      # Existing signers have the gem from before the cutoff so they never
      # re-resolve it, but ANY signer provisioned from scratch since Dec 2025 —
      # including a replacement for a dead host — fails here. vault_agent should
      # pin these versions. Tracked separately from this image work.
      "echo 'Pre-installing vault puppet gem (pinned for Ruby 2.7.8)...'",
      "sudo /opt/puppetlabs/puppet/bin/gem install --no-document connection_pool -v 2.5.5",
      "sudo /opt/puppetlabs/puppet/bin/gem install --no-document vault -v 0.18.2",
      "sudo /opt/puppetlabs/puppet/bin/gem list | grep -E '^(vault|connection_pool) ' || { echo 'FATAL: vault gem not installed'; exit 1; }",

      # -----------------------------------------------------------------------
      # Stub out the widevine clone
      # -----------------------------------------------------------------------
      # signing_worker clones mozilla-services/widevine (a PRIVATE repo) using
      # widevine_config.user/key as a GitHub token. A credential-free build has
      # only the fake token, so the clone returns 128 — and because both
      # run-puppet.sh and bootstrap_mojave.sh retry forever on any `Error:`, that
      # single failure means the build can never converge.
      #
      # The clone exec is guarded by `unless test -d <base>/widevine/src`, so
      # pre-creating that directory makes puppet skip it.
      #
      # That alone is not the whole story. The dependent `uv pip install .` is
      # refreshonly but subscribes to BOTH the clone and
      # Exec["install <base> virtualenv"], so it still fires once — on the apply
      # where the venv is first created — and fails, because <base>/widevine
      # holds nothing but an empty src/. It then stops firing, since neither
      # subscription changes again. Convergence therefore takes three applies:
      #
      #   #1  uv venv fails (home-directory race, see README)
      #   #2  uv venv succeeds -> refreshes widevine install -> fails
      #   #3  nothing to refresh -> 0 errors -> success
      #
      # Measured end to end from a bare 14.6.1 base. Do not read the widevine
      # errors in applies #1-2 as a broken build.
      #
      # This is a genuine gap, not a fix: the image ends up WITHOUT widevine,
      # alongside the keychain / ed25519 key / signing certs it also lacks. It is
      # honest for an image that cannot sign anyway, and it must be revisited
      # when real credentials enter the picture. Only the five dep users with a
      # widevine_filename need it; vpnbld has none.
      "echo 'Stubbing widevine clone (needs a real GitHub token)...'",
      "for b in dep1 dep2 enterprisebld tb-dep adhoc-dep; do sudo mkdir -p \"/usr/local/builds/$b/widevine/src\"; done",
      "ls -d /usr/local/builds/*/widevine/src",

      "echo 'Downloading run-puppet.sh...'",
      "curl -o /tmp/run-puppet.sh https://ronin-puppet-package-repo.s3.us-west-2.amazonaws.com/macos/public/common/run-puppet.sh",
      "chmod +x /tmp/run-puppet.sh",

      # Signers track macos-signer-latest, NOT master. The tester pipeline
      # hardcodes master; copying that here would build against code the signer
      # fleet is not running.
      #
      # Pre-seeding the clone is NOT sufficient on its own. run-puppet.sh does
      # its own `git fetch origin "$GIT_BRANCH"` + `git reset --hard`, so it will
      # throw away whatever we checked out and snap the repo back to its own
      # idea of the branch — which defaults to master. Observed doing exactly
      # that: "HEAD is now at 65d8a5d8", i.e. origin/master.
      #
      # The supported override is /opt/puppet_environments/ronin_settings, which
      # run-puppet.sh sources before defaulting PUPPET_BRANCH. Write it first.
      "echo 'Setting puppet branch override to ${var.puppet_branch}...'",
      "sudo mkdir -p /opt/puppet_environments/mozilla-platform-ops",
      "sudo sh -c 'echo \"PUPPET_BRANCH=${var.puppet_branch}\" > /opt/puppet_environments/ronin_settings'",
      "sudo chmod 644 /opt/puppet_environments/ronin_settings",
      "cat /opt/puppet_environments/ronin_settings",

      # Idempotent: a bare `git clone` into an existing directory exits 128, so
      # re-running this phase on an already-provisioned VM (or a checkpoint
      # snapshot) would always fail. Fetch and hard-reset instead when the repo
      # is already there — which is also what run-puppet.sh does on every run.
      "echo 'Pre-seeding Puppet repo from branch ${var.puppet_branch}...'",
      "R=/opt/puppet_environments/mozilla-platform-ops/ronin_puppet",
      "if [ -d \"$R/.git\" ]; then",
      "  echo 'Repo already present; fetching ${var.puppet_branch} instead of cloning.'",
      "  sudo git -C \"$R\" fetch origin ${var.puppet_branch}",
      "  sudo git -C \"$R\" checkout -B ${var.puppet_branch} FETCH_HEAD",
      "else",
      "  sudo git clone --branch ${var.puppet_branch} https://github.com/mozilla-platform-ops/ronin_puppet.git \"$R\"",
      "fi",
      "sudo git -C \"$R\" log --oneline -1",

      "echo 'Running run-puppet.sh (pass 1)...'",
      "echo admin | sudo -S /tmp/run-puppet.sh || echo 'Puppet pass 1 completed with errors; phase 2 will retry.'",
    ]
  }
}
