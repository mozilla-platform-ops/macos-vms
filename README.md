<artifact identifier="macos-vms-readme" type="text/markdown" title="macOS VM Builder README">
# 🖥️ macOS CI Virtual Machine Builder

**Automated, repeatable, production-ready macOS VM images for CI/CD workflows.**

Built with Packer + Tart + Puppet, orchestrated through GitHub Actions, and deployed to an OCI registry. This system provisions fully-configured macOS VMs that mirror bare-metal hardware workers, complete with dynamic hostnames, TaskCluster integration, and automatic configuration management.

---

## 🎯 What This Does

This repository automates the entire lifecycle of macOS CI virtual machines:

1. **Builds golden images** from Apple IPSW files using Packer
2. **Configures them** with Puppet (including secrets management via vault files)
3. **Stores them** in a local OCI registry
4. **Deploys them** automatically on Tart worker hosts
5. **Manages them** through Puppet for ongoing configuration drift prevention

**Key Features:**
- 🔄 **CI/CD Integration**: Automatic builds on PR (fake vault) and main branch (real vault)
- 🏷️ **Dynamic Hostnames**: VMs self-configure unique identities based on MAC addresses
- 🔐 **Secrets Management**: Vault-based credential injection during build
- 🎛️ **Four-Phase Build**: Base → SIP Disable → Puppet Phase 1 → Puppet Phase 2
- 📦 **OCI Distribution**: Images stored in registry with prod/PR tagging
- 🤖 **Worker Automation**: Puppet-managed Tart workers that auto-pull and deploy VMs

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    GitHub Actions (Builder)                  │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐  │
│  │  PR Build    │    │  Main Build  │    │  Push to OCI │  │
│  │ (Fake Vault) │───▶│ (Real Vault) │───▶│   Registry   │  │
│  └──────────────┘    └──────────────┘    └──────────────┘  │
└─────────────────────────────────────────────────────────────┘
                               │
                               ▼
                    ┌─────────────────────┐
                    │   OCI Registry      │
                    │  10.49.56.161:5000  │
                    │                     │
                    │  sequoia-tester:    │
                    │  - prod-latest      │
                    │  - prod-{sha}       │
                    │  - pr-{n}-latest    │
                    └─────────────────────┘
                               │
                               ▼
                    ┌─────────────────────┐
                    │  Tart Worker Hosts  │
                    │  (Puppet-managed)   │
                    │                     │
                    │  Runs 2 VMs each:   │
                    │  - sequoia-tester-1 │
                    │  - sequoia-tester-2 │
                    └─────────────────────┘
                               │
                               ▼
                    ┌─────────────────────┐
                    │   TaskCluster       │
                    │  (CI Orchestration) │
                    └─────────────────────┘
```

---

## 📁 Repository Structure

```
macos-vms/
├── .github/workflows/build.yml              # CI/CD pipeline
└── mac/tester15/
    ├── builder.sh                           # Main build orchestrator
    ├── create-base.pkr.hcl                  # Phase 1: Base macOS installation
    ├── disable-sip.pkr.hcl                  # Phase 2: Disable SIP
    ├── puppet-setup-phase1.pkr.hcl          # Phase 3: Initial Puppet run
    ├── puppet-setup-phase2.pkr.hcl          # Phase 4: Final Puppet run
    ├── set_hostname.sh                      # Dynamic hostname configuration
    ├── com.mozilla.sethostname.plist        # LaunchDaemon for hostname
    └── vault-fake.yaml                      # Test credentials (safe to commit)
```

---

## 🚀 Quick Start

### Prerequisites

```bash
# Install required tools
brew tap hashicorp/tap cirruslabs/cli
brew install hashicorp/tap/packer cirruslabs/cli/tart ansible
```

### Local Development Build

```bash
cd mac/tester15

# Use the fake vault for testing (no secrets required)
./builder.sh

# Or specify a custom vault
export VAULT_FILE="/path/to/your/vault.yaml"
./builder.sh
```

### CI/CD Pipeline

**Pull Requests** → Builds with `vault-fake.yaml`, pushes to `pr-{number}-latest`

**Main Branch** → Builds with real vault from `/etc/ronin/vault-real.yaml`, pushes to `prod-latest` and `prod-{sha}`

---

## 🔨 Build Process

### Phase 1: Create Base Image (~12-15 min)

Fully automated macOS installation from IPSW:
- Downloads and installs macOS 15.3 (Sequoia)
- Creates admin user with password `admin`
- Enables SSH and Screen Sharing
- Automated keyboard navigation through setup wizard

**Key Innovation:** Uses Tart's `boot_command` to simulate keyboard input through the entire macOS setup assistant without human intervention.

### Phase 2: Disable SIP (~2 min)

- Boots into macOS Recovery
- Disables System Integrity Protection via `csrutil disable`
- Required for certain CI tools and Puppet configurations

### Phase 3: Puppet Setup Phase 1 (~7 min)

Initial system configuration:
- **Vault injection:** Copies vault file to `/var/root/vault.yaml`
- Installs Rosetta 2, Xcode Command Line Tools, Puppet Agent
- Sets puppet role: `gecko_t_osx_1500_m_vms`
- **Temporarily disables** TCC permissions, SafariDriver, and pipconf (requires reboot)
- Runs initial Puppet apply

**Why two phases?** Some Puppet modules (TCC, SafariDriver) require a reboot to apply correctly.

### Phase 4: Puppet Setup Phase 2 (~2-3 min)

Final configuration:
- Sets up dynamic hostname script and LaunchDaemon
- **Re-enables** TCC permissions, SafariDriver, and pipconf
- Runs final Puppet apply with full configuration
- Removes vault file for security

**Total Build Time:** ~25-30 minutes

---

## 🏷️ Dynamic Hostname System

VMs automatically configure unique, stable hostnames on first boot:

```bash
# Example: mac-eb3740 (derived from MAC address 12:5d:17:eb:37:40)
```

**How it works:**
1. `set_hostname.sh` runs at boot via LaunchDaemon
2. Extracts last 3 octets of primary interface MAC address
3. Sets hostname to `mac-{MAC}`
4. Updates TaskCluster worker configuration files with new hostname
5. Worker registers with TaskCluster using unique identity

**Benefits:**
- No hostname collisions between VMs
- Stable identity across reboots
- Automatic TaskCluster integration
- Easy identification in logs and monitoring

---

## 📦 Deployment

### Worker Host Configuration (Puppet-Managed)

Tart worker hosts are configured via Puppet (`roles_profiles::roles::tart_worker`):

```yaml
# data/roles/tart_worker.yaml
tart:
  version: '2.30.0'
  registry_host: '10.49.56.161'
  registry_port: 5000
  oci_image: 'sequoia-tester:prod-latest'
  worker_count: 2
  insecure: true
```

**Puppet automatically:**
- Installs Tart 2.30.0
- Pulls `sequoia-tester:prod-latest` from OCI registry
- Clones 2 VMs per host (Apple licensing limit)
- Configures LaunchDaemons to keep VMs running
- Creates manual update script at `/usr/local/bin/tart-update-vms.sh`

### Manual VM Updates

When you want to deploy a new image to running workers:

```bash
# On the Tart worker host
sudo /usr/local/bin/tart-update-vms.sh
```

This script:
1. Stops all worker VMs gracefully (30s wait)
2. Deletes old VMs
3. Pulls latest image from OCI registry
4. Clones fresh VMs
5. Restarts LaunchDaemons

**Downtime:** ~2-3 minutes per worker host

---

## 🔐 Secrets Management

### Fake Vault (Development/PR)

`vault-fake.yaml` contains non-sensitive placeholder data for testing. Safe to commit to the repository.

### Real Vault (Production)

Located at `/etc/ronin/vault-real.yaml` on GitHub Actions runners. Contains:
- Puppet Hiera secrets
- API keys
- Certificates
- Service credentials

**Security:**
- Never committed to repository
- Injected during build via GitHub Actions
- Copied to `/var/root/vault.yaml` in VM during Phase 3
- **Deleted** in Phase 4 after Puppet consumes it
- Not present in final OCI image

---

## 🎛️ Configuration

### OCI Registry Tags

- `prod-latest` → Most recent main branch build
- `prod-{sha}` → Specific commit from main branch
- `pr-{number}-latest` → Most recent build from PR #{number}
- `pr-{number}-{sha}` → Specific commit from PR #{number}

### Environment Variables

```bash
VM_NAME="sequoia-tester"           # Base VM name
VAULT_FILE="vault-fake.yaml"       # Path to vault file
REGISTRY_HOST="10.49.56.161"       # OCI registry host
REGISTRY_PORT="5000"               # OCI registry port
REGISTRY_IMAGE="sequoia-tester"    # Image name in registry
```

---

## 🐛 Troubleshooting

### Build fails during Puppet Phase 1

**Check:** Vault file exists and is readable
```bash
ls -la /var/root/vault.yaml  # Inside VM
```

### VMs won't start on worker host

**Check LaunchDaemons:**
```bash
sudo launchctl list | grep mozilla
tail -f /var/log/tartworker-1.out
```

### Wrong hostname after boot

**Manually run hostname script:**
```bash
sudo /usr/local/bin/set_hostname.sh
```

### Can't pull from OCI registry

**Verify connectivity:**
```bash
curl http://10.49.56.161:5000/v2/
tart pull --insecure 10.49.56.161:5000/sequoia-tester:prod-latest
```

---

## 📊 Metrics

**Build Times:**
- Phase 1 (Base): ~12-15 min
- Phase 2 (SIP): ~2 min
- Phase 3 (Puppet 1): ~7 min
- Phase 4 (Puppet 2): ~2-3 min
- **Total:** ~25-30 minutes

**Image Sizes:**
- Base macOS: ~20 GB
- After Puppet: ~40 GB
- Compressed in OCI: ~17 GB

**Resource Requirements:**
- CPU: 4 cores per VM
- Memory: 8 GB per VM
- Disk: 100 GB per VM
- Maximum: 2 VMs per physical host (Apple license)

---

## 🤝 Contributing

1. Create a feature branch
2. Test locally with `./builder.sh`
3. Open a PR (triggers PR build with fake vault)
4. Merge to main (triggers prod build with real vault)
5. VMs automatically deployed via Puppet

---

## 📝 License

Mozilla Public License 2.0

---

**Built with ❤️ by Mozilla RelOps**
