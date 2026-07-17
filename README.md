# 🖥️ macOS CI Virtual Machine Builder

**Automated, repeatable, credential-free macOS VM images for Firefox CI.**

Built with Packer + Tart + Puppet, orchestrated through GitHub Actions, and
distributed via an OCI registry. This system produces fully-configured macOS
VMs that mirror bare-metal hardware workers — dynamic hostnames, Taskcluster
integration, and Puppet-managed configuration — **without ever baking a worker
secret into the image or exposing one to the build runner.**

---

## 🎯 What This Does

1. **Builds golden images** from Apple IPSW files using Packer.
2. **Configures them** with Puppet (using a non-secret *fake* vault at build time).
3. **Stores them** in an OCI registry (anonymous pull, authenticated push).
4. **Deploys them** on Puppet-managed Tart worker hosts.
5. **Injects real credentials at VM boot** — the host, not the image, supplies
   the worker's Taskcluster vault.

**Key features:**
- 🔒 **Credential-free images** — no worker secret is ever baked in or present on the build runner.
- 🧩 **Host-mediated secret injection** — the MDM-enrolled Tart host fetches the per-pool vault and shares it into each VM at launch.
- 🏷️ **Dynamic hostnames** — VMs self-configure a unique identity from their MAC address.
- 📦 **OCI distribution** — images tagged `prod-latest` / `prod-{sha}`, anon-pull / auth-push.
- 🤖 **Worker automation** — Puppet-managed Tart hosts deploy and keep VMs running.

---

## 🔐 Security Model (read this first)

This repo was the subject of **Bug 2049579**: an earlier version ran fork-PR
code on a non-ephemeral self-hosted macOS runner that also held plaintext
Taskcluster worker vaults. The build has since been re-architected so that
**neither the runner nor the image ever holds a worker secret.** The controls
below are load-bearing — do not regress them:

1. **No fork-PR execution on the self-hosted runner.** The build triggers on
   `push` to `main` and `workflow_dispatch` only — never `pull_request`. A fork
   PR must not be able to run code on the build host.
2. **Credential-free images.** Every build uses the non-secret
   `mac/tester15/vault-fake.yaml`. Real worker credentials are **never** copied
   onto the runner or baked into the image.
3. **Host-mediated credential injection.** Real credentials reach a VM only at
   **first boot**, supplied by the Tart *host* (see below). The image ships with
   no usable secret.
4. **Authenticated registry push.** The OCI registry allows anonymous *pull*
   (tester hosts) but requires authentication to *push*. The build logs in with
   a `builder` credential from a GitHub Actions secret before pushing.

If you change the workflow triggers, the vault handling, or the registry auth,
you are touching the security boundary — get it reviewed as such.

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────┐
│           GitHub Actions runner (self-hosted)           │
│  push to main / workflow_dispatch                       │
│                                                         │
│  ┌──────────────────┐       ┌────────────────────────┐  │
│  │ Build            │       │ Push to OCI registry   │  │
│  │ (fake vault,     │   →   │ (auth: builder secret) │  │
│  │ credential-free) │       │                        │  │
│  └──────────────────┘       └────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│  OCI Registry        (anon pull / auth push)            │
│                                                         │
│  sequoia-tester:  prod-latest , prod-{sha}              │
└─────────────────────────────────────────────────────────┘
                            │  (host pulls image)
                            ▼
┌─────────────────────────────────────────────────────────┐
│             Tart Worker Host (MDM-enrolled)             │
│                                                         │
│  1. holds a broker client cert (via MDM)                │
│  2. fetches the per-pool vault over mTLS                │
│  3. shares it into each VM at launch:                   │
│       tart run --dir=vault:<dir>:ro                     │
│                                                         │
│  ┌─────────────────┐   ┌─────────────────┐              │
│  │ credential-free │   │ credential-free │              │
│  │ VM #1           │   │ VM #2           │              │
│  └─────────────────┘   └─────────────────┘              │
└─────────────────────────────────────────────────────────┘
                            │  (VM first boot: reads the shared vault,
                            │  runs puppet, worker registers)
                            ▼
┌─────────────────────────────────────────────────────────┐
│                       Taskcluster                       │
└─────────────────────────────────────────────────────────┘
```

The **image is credential-free**; the **host** is the trust anchor (its MDM
identity authorizes the vault fetch). See `ronin_puppet`'s `profiles::tart`
(`inject_vault` / `vault_role`) for the host side, and `vault-inject.sh` for the
guest side.

---

## 📁 Repository Structure

```
macos-vms/
├── .github/workflows/
│   └── build-mac.yaml                      # CI/CD pipeline (push-to-main / dispatch)
├── scripts/                                # build-host operational tooling
│   ├── setup-build-runner.sh               #   reproducible runner (re)install
│   ├── build-runner-maintenance.sh         #   hourly tart prune + low-disk alert
│   └── com.mozilla.build-runner-maintenance.plist
└── mac/tester15/                           # the tester VM image
    ├── builder.sh                          #   4-phase build orchestrator
    ├── create-base.pkr.hcl                 #   Phase 1: base macOS from IPSW
    ├── disable-sip.pkr.hcl                 #   Phase 2: disable SIP (guest)
    ├── puppet-setup-phase1.pkr.hcl         #   Phase 3: puppet run 1
    ├── puppet-setup-phase2.pkr.hcl         #   Phase 4: puppet run 2 + first-boot hooks
    ├── set_hostname.sh                     #   dynamic hostname (LaunchDaemon)
    ├── com.mozilla.sethostname.plist
    ├── vault-inject.sh                     #   FIRST-BOOT: read host-shared vault → puppet
    ├── com.mozilla.vault-inject.plist
    └── vault-fake.yaml                     #   non-secret build-time vault (safe to commit)
```

---

## 🚀 Quick Start

### Prerequisites

```bash
brew tap hashicorp/tap cirruslabs/cli
brew install hashicorp/tap/packer cirruslabs/cli/tart ansible
```

### Local development build

Always builds credential-free with the fake vault — no secrets required:

```bash
cd mac/tester15
./builder.sh
```

### CI/CD

The build runs **only** on `push` to `main` (paths under `mac/tester15/**` or
the workflow) and on manual `workflow_dispatch`. There is intentionally **no**
`pull_request` trigger (see Security Model). Every run:

- builds credential-free with `vault-fake.yaml`;
- logs in to the registry with the `builder` secret and pushes
  `sequoia-tester:prod-{sha}` + `sequoia-tester:prod-latest`.

---

## 🔨 Build Process

`builder.sh` runs four Packer phases:

### Phase 1 — Create base image
Installs macOS (Sequoia) from an IPSW and drives Setup Assistant via automated
VNC keystrokes (creates the `admin` account, enables SSH + Screen Sharing).
This phase is the slowest and, because it relies on timed blind keystrokes, the
**most flake-prone** — an SSH-timeout here is usually the Setup Assistant
automation drifting out of sync, not a real failure. Re-run first.

### Phase 2 — Disable SIP (guest)
Boots the *guest* into Recovery and runs `csrutil disable`. This affects the VM
image only, not any host.

### Phase 3 — Puppet setup, run 1
Sets the puppet role `gecko_t_osx_1500_m_vms`, installs Rosetta 2, Xcode CLT,
and the Puppet agent, temporarily disables the TCC/SafariDriver/pipconf bits
that need a reboot, and runs the first apply — all using the **fake** vault.

### Phase 4 — Puppet setup, run 2 + first-boot hooks
Re-enables the deferred bits, runs the final apply, and installs (but does not
load) the first-boot hooks: the dynamic-hostname LaunchDaemon and the
**`vault-inject` LaunchDaemon** that supplies real credentials on the deployed
VM. Any build-time vault is removed so the image ships credential-free.

---

## 🧩 Credential Injection (how a deployed VM gets its real secret)

The image contains **no** worker credential. On a deployed VM's **first boot**:

1. The Tart **host** (MDM-enrolled) fetches the per-pool vault from the RelOps
   secret broker over mTLS, using a client certificate delivered to the host by
   MDM. The host launches the VM with the vault shared in read-only:
   `tart run --dir=vault:<dir>:ro …` (see `ronin_puppet` `profiles::tart`).
2. Inside the VM, `com.mozilla.vault-inject` runs `vault-inject.sh`, which reads
   `/Volumes/My Shared Files/vault/vault.yaml`, writes it to
   `/var/root/vault.yaml`, and runs `run-puppet.sh`.
3. Puppet regenerates the worker config with the real `worker.access_token` /
   `worker.client_id`, and the worker registers with Taskcluster.

The secret exists only inside the ephemeral VM at runtime — never on the build
runner, never in the image.

---

## 📦 Deployment & Rollout

Tart worker hosts are Puppet-managed (`roles_profiles::roles::tart_worker` /
`profiles::tart`), which installs Tart, deploys the worker LaunchDaemon(s), and —
with `tart.inject_vault: true` — the launch wrapper (`tart-run-vm.sh`) that
fetches the per-pool vault over mTLS using the host's SCEP cert and shares it
into each VM (`tart run --dir=vault:…`). On macOS 15 puppet does **not**
pull/clone the image (`manage_image: false`) — `tart pull` needs a GUI/Local-
Network context — so image lifecycle is handled by the update script below.
Apple licensing caps a host at **2 VMs**.

### How a host gets a new image

`tart.oci_tag` in the host's role data selects the image — pin a specific
`prod-<sha>` for a controlled fleet, or track the moving `prod-latest`. Rolling
it out runs **`/usr/local/bin/tart-update-vms.sh`** on the host, which:

1. pulls the selected image,
2. rolls **one worker slot at a time** so the other keeps serving,
3. **drains** each slot first — waits for its worker to finish its current task
   (via the Taskcluster public API, no creds) before recreating it,
4. recreates the VM and restarts its worker unit (daemon- and agent-aware).

Each recreated VM self-configures on first boot: `set_hostname` → `vault-inject`
reads the injected vault → puppet regenerates the worker config with the **real**
credentials → a one-time **auto-reboot** so generic-worker starts on those creds
→ the worker registers and claims tasks. (Validated end-to-end on m4-235:
`mac-f4a3ef` built → injected → registered → ran a live `mochitest-chrome`.)

### Fleet rollout

Driving the per-host update across the fleet — batched to respect the MDC1
network, with TC quarantine for a true drain — is the **on-network reprovision
runner's** job, optionally triggered and observed from **Hangar** (same pattern
as the reprovision action; Hangar shows image drift + fires the roll, the runner
does the work). The per-host script above is the safe primitive that layer calls.

---

## 🏷️ Dynamic Hostname System

VMs self-configure a stable, unique hostname on first boot:

1. `set_hostname.sh` runs at boot via LaunchDaemon.
2. It derives `mac-{last-3-MAC-octets}` from the primary interface.
3. It updates the Taskcluster worker config so the worker registers under that
   unique identity.

This avoids hostname/worker-id collisions between VMs cloned from one image.

---

## 🏷️ OCI Registry Tags

- `prod-latest` → most recent `main` build
- `prod-{sha}` → a specific `main` commit

The registry is **anonymous-pull, authenticated-push**. Pulls (tester hosts)
need no credential; pushes (the build) authenticate as `builder` using the
`REGISTRY_PUSH_PASSWORD` GitHub Actions secret.

---

## 🖥️ Build-Host Operations (`scripts/`)

The build runs on a self-hosted runner (a Mac). Because that host is
long-lived, `scripts/` keeps it reproducible and healthy:

- **`setup-build-runner.sh <registration-token>`** — one command to (re)install
  the GitHub Actions runner and the maintenance daemon. The token is a runtime
  argument; nothing secret is committed.
- **`build-runner-maintenance.sh` + LaunchDaemon** — hourly `tart prune` (only
  when no build VM is running) plus a low-disk email alert. The build host's
  historical failure mode was silently filling its disk.

See `scripts/README.md` for details.

---

## 🐛 Troubleshooting

**Phase 1 (create-base) times out waiting for SSH.** Usually the Setup
Assistant VNC automation drifted; re-run the build. Persistent failures point
at host load or a macOS layout change in the boot-command tab-navigation.

**A deployed VM won't register with Taskcluster.** Check the injection chain:
on the host, confirm `inject_vault` is on and the vault fetch succeeded; in the
VM, check `/var/log/vault-inject.{out,err}` and that `/var/root/vault.yaml`
existed before the puppet run.

**VMs won't start on a worker host.**
```bash
sudo launchctl list | grep mozilla
tail -f /var/log/tartworker-1.out
```

**Can't pull from the OCI registry.**
```bash
curl http://<registry>/v2/                       # anon pull is allowed
tart pull --insecure <registry>/sequoia-tester:prod-latest
```
(Pull failures are usually connectivity; push failures are usually auth — pushes
require the `builder` credential.)

---

## 📊 Notes on Sizing

Thanks to APFS copy-on-write, a cloned VM does not immediately claim its full
provisioned disk — only writes to the clone consume new space, which also makes
cloning near-instant. Per-VM: 4 CPU / 8 GB RAM / 100 GB provisioned disk;
**max 2 VMs per physical host** (Apple license).

---

## 🤝 Contributing

1. Create a feature branch and test locally with `./builder.sh` (credential-free).
2. Open a PR for review. **PRs do not trigger a build** on the self-hosted
   runner by design (Bug 2049579) — validate locally.
3. Merge to `main` → triggers the credential-free prod build → image pushed to
   the registry → deployed to Tart hosts via Puppet.

---

## 📝 License

Mozilla Public License 2.0

---

**Built with ❤️ by Mozilla RelOps**
