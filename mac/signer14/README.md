# 🔏 macOS Signer VM Image (dep)

Packer + Tart pipeline for a **dep** mac-v4 signer VM, mirroring the bare-metal
`dep-mac-v4-signing0*` hosts.

This is a sibling of `mac/tester15/`, not a fork of it. Several things that are
true for the tester image are **actively wrong** for a signer; those differences
are the substance of this directory and are called out below.

---

## ⚠️ The one thing to understand before touching this

**The signer flavor comes from the hostname, not from the puppet role.**

All six signer roles in `ronin_puppet`
(`mac_v4_signing_{adhoc,dep,ff_ent_prod,ff_prod,tb_prod,vpn_prod}`) have a
byte-identical profile list, and their `data/roles/*.yaml` files are identical
too. The flavor is selected in `roles_profiles::profiles::mac_signing`:

```puppet
$role = $facts['networking']['hostname'] ? {
  /^fx-mac-v(3|4)-signing\d+/    => 'ff-prod',
  /^tb-mac-v(3|4)-signing\d+/    => 'tb-prod',
  /^vpn-mac-v(3|4)-signing\d+/   => 'vpn-prod',
  /^adhoc-mac-v(3|4)-signing\d+/ => 'adhoc-prod',
  /^dep-mac-v(3|4)-signing\d+/   => 'dep',
  default                        => 'ff-prod',   # <-- the trap
}
```

and `signing_worker` parses the worker number out of the hostname with
`/.*-mac-v[34]-(dep)?signing(\d+).*/`, falling back to the literal `unknown`.

So an unmatched hostname does not error. It quietly produces a machine that
believes it is a **production Firefox signer** with worker id
`gecko-signing-mac14m2-unknown`. **The default fails toward prod.**

The tester image's MAC-derived name (`mac-f4a3ef`) matches nothing. Copying that
scheme here would hit the default case every time. Consequently:

- **Build time** — `puppet-setup-phase1.pkr.hcl` sets the hostname to
  `dep-mac-v4-signing99` *before* puppet runs, and asserts it stuck.
- **First boot** — `set_hostname.sh` reads an allocated name from a host-shared
  directory, validates it against the pattern list, checks it is a *dep* name,
  and **refuses to continue** if any of that fails. No guessing.

---

## 🆚 How this differs from `mac/tester15/`

| | tester15 | signer14 | why |
|---|---|---|---|
| macOS | Sequoia 15 | **Sonoma 14.7.x** (fleet: 14.7.5 / 23H527) | matches the fleet; `Mac14,3` / M2 mini |
| SIP | disabled (phase 2) | **left enabled** | prod signers run SIP-on; the role converges under it there |
| Phases | 4 | **3 + an OS-update step** | no SIP-disable phase; see "Getting to 14.7.x" |
| Hostname | MAC-derived, self-assigned | **host-allocated, fail-closed** | hostname is the flavor selector |
| puppet branch | `master` | **`macos-signer-latest`** | what `puppet::periodic` pins for signers |
| `profiles::hardware` | not in role | **excluded from role** | `assert_firmware` fail()s on `VirtualMac2,1` |
| `profiles::duo` | n/a | **excluded from role** | `pam_duo.so` in `/etc/pam.d/sshd` locks Packer out |
| Dev ID CA | n/a | **baked into System keychain** | arrives by MDM profile on hardware; VMs aren't enrolled |

---

## 🧬 The ronin_puppet side

This pipeline needs `roles_profiles::roles::mac_v4_signing_dep_vms`, a copy of
`mac_v4_signing_dep` minus two profiles that cannot work in a guest:

- **`profiles::hardware`** → `macos_utils::assert_firmware` `fail()`s unless
  `system_profiler.model_identifier` is a key in `apple_firmware_acceptance`.
  A Tart guest reports `VirtualMac2,1` and has no Apple boot ROM to assert.
  (`gecko_t_osx_1500_m_vms` omits it for the same reason. There is precedent for
  the other route too — the hash already contains
  `MacBookPro13,3: ['VirtualBox']` — if you would rather whitelist than exclude.)
- **`profiles::duo`** → installs `auth required pam_duo.so` into
  `/etc/pam.d/sshd`, confirmed present on `fx-mac-v4-signing01`. Packer
  authenticates as `admin` over SSH with a password, so enabling Duo mid-build
  locks the remaining provisioners out of the guest.

Keep that role in sync with `mac_v4_signing_dep.pp` when it changes.

---

## 🚀 Building

```bash
cd mac/signer14
IPSW_URL="https://updates.cdn-apple.com/2024SummerFCS/fullrestores/062-52859/932E0A8F-6644-4759-82DA-F8FA8DEA806A/UniversalMac_14.6.1_23G93_Restore.ipsw" ./builder.sh
```

`IPSW_URL` has no default on purpose — matching the prod build is the point, so
it is an explicit decision rather than something a file guesses at.

Iterating on the puppet phases against an already-built base:

```bash
SKIP_BASE=1 SKIP_OS_UPDATE=1 ./builder.sh
```

### Getting to 14.7.x

**You cannot restore straight to the fleet's version.** The signers run macOS
14.7.5 (23H527), but Apple never published a full restore IPSW for it. Sonoma
IPSWs stop at **14.6.1 (23G93, Aug 2024)** — once Sequoia shipped, the 14.7.x
releases were security updates delivered through `softwareupdate`, not full
restores. (Absent from both ipsw.me's `Mac14,3` index and Mr. Macintosh's IPSW
database; Apple's own mesu catalog only carries the current release.)

So the version story is two steps, and `update-os.pkr.hcl` is the second:

1. **Phase 1** restores 14.6.1 from the IPSW.
2. **Phase 1.5** runs `softwareupdate`, refusing anything that would leave
   macOS 14, and asserts the result is still a 14.x.

**The fleet's exact version is not reachable, and the gap is wider than
expected.** `softwareupdate` only offers the *current* security update for a
major. Measured on a fresh 14.6.1 guest, 2026-08-12:

```
* Label: macOS Sonoma 14.8.9-23J631     <-- what phase 1.5 installs
* Label: macOS Tahoe 26.6.1-25G76       <-- correctly refused (major bump)
* Label: Safari26.6SonomaAuto-26.6
```

So Sonoma did not stop at 14.7.x — there is a 14.8 line, and the newest is
**14.8.9**. Phase 1.5 therefore lands the image **ahead of the fleet** (14.8.9
vs 14.7.5), not level with it. 14.7.5 is not offered and cannot be reached this
way.

Both are Darwin 23, so `mac_signing.pp`'s version case treats them identically
and the puppet run does not care. Whether the divergence matters for
codesign/notarytool reproducibility is a fleet-patching decision:

- accept **14.8.9** in the image, and consider patching the fleet toward it;
- `SKIP_OS_UPDATE=1` to stay on **14.6.1** — behind the fleet rather than ahead;
- `TARGET_LABEL=...` if a specific build is ever offered again.

### Phase 1 is the flaky one

`create-base.pkr.hcl` drives Setup Assistant with blind, timed VNC keystrokes.
The sequence is carried over unchanged from tester15, where it was written for
Sequoia; it was expected to need retuning for Sonoma but does not —
**verified working against 14.6.1 (23G93) on 2026-08-12, reaching SSH in
15m26s with no edits.**

That is not a guarantee for the future. A macOS point release can move a pane or
a tab stop under it at any time, and drift surfaces as "timeout waiting for SSH"
rather than an obvious UI error. Re-run once before digging; if it fails twice,
watch over VNC and fix the tab counts.

---

## 🔐 Credentials

Same rule as the rest of this repo: **the image is credential-free and no real
secret ever reaches the build runner.** The build uses `vault-fake.yaml`, whose
values are all obvious garbage, and phase 3 deletes it and asserts the deletion.

The signer secret model is *not* the tester's, and it is worth being precise
about the difference:

| | tester | signer |
|---|---|---|
| worker vault | `vault.yaml` shared in by the host at boot | same mechanism, plus... |
| runtime secrets | — | `vault-agent` LaunchDaemon, AppRole from `/etc/vault_approle_id` + `/etc/vault_approle_secret` (both `replace => false`, placed out of band) |
| signing material | — | keychain, `ed25519_privkey`, widevine cert — **not puppet-managed at all** |

That last row is the one that surprises people. `signing_worker` creates
`${scriptworker_base}/certs` as an empty `0700` directory and only *references*
`mozilla.20240328.keychain`, `ed25519_privkey` and `widevine_prod.crt` by path
in the config it generates. On `fx-mac-v4-signing01` those files are
`-r--------  cltbld staff`, dating from 2019–2024, and they got there by hand.

**A signer VM will build green, converge green, and be unable to sign anything.**
That is expected at this stage, not a bug.

---

## ✅ What has actually been validated

Measured on a real build (2026-08-12), not inferred:

- **The dep role converges.** Both puppet phases green, zero `Error:` lines,
  `BUILDER_EXIT=0`.
- **Xcode 16.2 (16C5032a)** and **CLT for Xcode 16.2** — matching
  `fx-mac-v4-signing01` exactly. `softwareupdate` picks the matching CLT on its
  own; no pin needed.
- All six dep scriptworker users created with home directories.
- `certs/` present, empty, `0700`.
- Image seals clean: no vault on disk, branch override reset to
  `macos-signer-latest` and asserted.
- Setup Assistant automation works on Sonoma unmodified (15m26s to SSH).

### The retry loop is load-bearing

Worth internalising before reading a failed build as broken. **A clean build
from a bare 14.6.1 base takes three puppet applies to converge**, and the first
two are full of alarming errors:

| apply | `uv venv` errors | widevine errors | outcome |
|---|---|---|---|
| #1 | 12 | 15 | home-directory race |
| #2 | 0 | 20 | venv created → refreshed the widevine install → failed |
| #3 | 0 | 0 | **succeeded** |

Two independent causes stack up here. `uv venv` runs as the scriptworker user
and writes `~/.cache/uv`, but nothing orders it after `users::home_dir` creates
`/Users/<user>` — so it fails on the first pass. Then the widevine install exec
is `refreshonly` but subscribes to *both* the clone and the virtualenv exec, so
it fires exactly once (when the venv appears) against the stubbed-out widevine
directory, fails, and never fires again.

Neither is fixable from this repo, and both clear themselves. Phase 1 takes
~12 minutes as a result.

Both `run-puppet.sh` and `bootstrap_mojave.sh` retry **forever** on any
`Error:` (10-minute sleeps in the latter). That is the convergence mechanism,
not merely a safety net — but it also means a genuinely unfixable error hangs
rather than fails. Hence the 45m `timeout` on both puppet phases here.

### The build is network-sensitive — pin the FQDN

`fw::roles::mac_signing` gates on the fully-qualified domain name:

```puppet
case $::fqdn {
  /.*\.(mdc1|mdc2)\.mozilla\.com/: { ssh_from_rejh, ssh_from_mozvpn, nrpe }
  default:                        { }   # silently skip other DCs
}
```

So **where you build from changes what gets built.** On a laptop the guest's
FQDN is something like `…​.mozilla.com`, the case falls through, and no pf rules
are applied at all. On the self-hosted CI runner — which is on MDC1 — the guest
resolved an `mdc1` FQDN, puppet applied rules permitting SSH only from the
relops jump hosts and Mozilla VPN, and cut off Packer's own SSH session from the
tart bridge mid-provision:

```
Provisioning step had errors ... dial tcp 192.168.64.144:22: i/o timeout
```

Phase 1 therefore sets `HostName` to a **fully-qualified name in the reserved
`.invalid` domain** (`dep-mac-v4-signing99.vmbuild.invalid`) while leaving
`ComputerName`/`LocalHostName` bare. `facter networking.hostname` still reports
the short name — so the signer flavor still resolves to `dep` — but
`networking.fqdn` can no longer match the datacenter pattern. The build is now
identical wherever it runs, and phase 1 asserts both properties before puppet.

**Consequence:** the shipped image has **no pf rules configured**. A deployed
signer VM needs the firewall reconsidered — either its real FQDN matching on the
deployed network, or filtering at the tart host.

### The vault binary has a revoked signing certificate

Found on first GUI login of the published image, which greeted the user with:

> **"vault will damage your computer."** … *Report malware to Apple to protect
> other users* ☑

Not a false positive on Apple's part, and nothing to do with quarantine — there
is no `com.apple.quarantine` xattr on the file. Measured in the image:

```
$ spctl -a -vv /usr/local/bin/vault
/usr/local/bin/vault: CSSMERR_TP_CERT_REVOKED
$ file /usr/local/bin/vault
/usr/local/bin/vault: Mach-O 64-bit executable x86_64
-rwxr-xr-x  root wheel  201646752  Jun 15 2021  /usr/local/bin/vault
```

The **signing certificate has been revoked** on the vault 1.7.3 build in S3
(`packages::vault::version: 1.7.3`), and it is an Intel-only binary from June
2021. Consequences, all verified:

- `launchctl list` shows **no** `vault-agent` — the daemon has never started.
- `/var/log/vault-agent.log` does not exist.
- `vault version` produces no output; the binary cannot execute.

S3 holds only `vault-1.6.1.pkg` and `vault-1.7.3.pkg`, both of that vintage, so
there is no newer artifact to pin to. Phase 2 therefore disables the daemon —
this image has no approle credentials and could never have used it anyway —
rather than confront every user with a malware alert.

**This is very likely a production issue too, and it explains an earlier
oddity.** On `fx-mac-v4-signing01`, `/etc/vault_approle_secret` is **zero bytes**
and `/etc/vault_token` **does not exist** — exactly what you would see if
vault-agent had never successfully run there either. Worth checking on a real
signer:

```bash
spctl -a -vv /usr/local/bin/vault
sudo launchctl list | grep -i vault
file /usr/local/bin/vault
```

The real fix is a current, notarised, universal vault binary in S3 plus a
`packages::vault::version` bump — fleet-wide, and deliberately out of scope for
this image.

### First-login polish

`create-base` drives System Settings over VNC to enable Screen Sharing and
Remote Login, and macOS records that in `admin`'s per-host relaunch list, so the
first GUI login reopened System Settings on the Appearance pane.
`macos_utils::clean_appstate` handles precisely this for the six scriptworker
users but nothing covered `admin` — the account a human actually logs into.
Phase 2 now clears it.

### A ronin_puppet bug this surfaced

`vault_agent` declares the `vault` gem `ensure => present` with **no version
pin**. Puppet 7.28 bundles Ruby 2.7.8; `vault` dropped 2.7 in 0.19.0
(2025-12-04) and `connection_pool` did likewise. So an unpinned install now
resolves to something uninstallable:

```
vault requires Ruby version >= 3.1. The current ruby version is 2.7.8.225.
```

Existing signers are unaffected — their gems predate the cutoff and
`ensure => present` never re-resolves. But **any signer provisioned from
scratch since Dec 2025 fails here**, inside the forever-retry loop. This build
works around it by pre-installing vault 0.18.2 / connection_pool 2.5.5; the
real fix is pinning them in `vault_agent`.

---

## 🛑 Where this stops

This iteration is scoped to *"does the dep signer role converge in a VM"*. It
deliberately does **not** include:

- vault.yaml injection (no `vault-inject.sh` equivalent yet)
- the vault AppRole id/secret pair
- any signing material
- **widevine** — `signing_worker` clones a *private* repo using
  `widevine_config.user`/`key` as a GitHub token. A credential-free build only
  has the fake one, so phase 1 pre-creates `<base>/widevine/src` to trip the
  exec's own `unless` guard and skip it. A declared gap, not a fix.
- a first-boot puppet re-run

Because there is no re-run yet, the image ships with worker configs naming
`dep-mac-v4-signing99` (the build hostname). Those workers cannot authenticate —
the vault was fake — so there is no impersonation risk, but the image is a
template, not a deployable worker. Iteration 2 needs a `vault-inject`
equivalent that runs puppet again *after* `set_hostname.sh` has applied the
allocated identity.

### ⚠️ The shipped image cannot currently run puppet on boot

Phase 2 pins the image's runtime `PUPPET_BRANCH` to **`macos-signer-latest`**,
which is the branch the signer fleet tracks. As of 2026-08-12 that branch does
**not** contain `roles_profiles::roles::mac_v4_signing_dep_vms` — the role
merged to `master` (ronin_puppet#1325) and `macos-signer-latest` lags master by
several commits.

So a deployed VM that runs `run-puppet.sh` would fail to compile its catalog
("could not find class") and then **retry forever**, because the bootstrap
scripts never give up. This does not affect a smoke test — nothing re-runs
puppet unless you ask it to — but it must be resolved before the image is
deployed anywhere.

Fix is to advance `macos-signer-latest`. That is a fleet-affecting change (it
is the branch every prod signer tracks), so it is deliberately **not** bundled
with this image work.

Note also that `packages_classes` is absent from the fake vault, so
`packages_installed` is a no-op and nothing from `packages::` is installed. The
real list lives in the prod vault and is needed before the image is functional.

---

## 🧭 Building the other flavors

Once dep works, ff-prod is a small delta — the profile list is identical:

1. a `mac_v4_signing_ff_prod_vms` role (same two exclusions),
2. `puppet_role` and `build_hostname` vars in phase 1 (`fx-mac-v4-signing<NN>`),
3. an ff-prod `vault-fake.yaml` — note ff-prod has **one** scriptworker user
   (`cltbld`) against dep's six, so it is the *lighter* build,
4. widen or drop the dep-only guard in `set_hostname.sh` (marked in the file).

Do not point the dep image at an `fx-` hostname to "test ff-prod". The guard
exists precisely to stop that.

---

## 🔎 Still to confirm against the hardware

- ~~CLT version~~ — **resolved.** tester15's pinned Xcode 16.4 CLT cannot
  install on Sonoma (`installer: macOS version 15.3 or later is required`), and
  S3 holds only 16.4 and a 2020-era 12.2, so there is no Sonoma-appropriate pin.
  The real signers therefore must get CLT from puppet's `macos_xcode_tools`
  (`softwareupdate -i "$PROD"`); this image now does the same. Worth uploading a
  Sonoma CLT to S3 if build reproducibility matters later.
- `sudo profiles -P -o stdout` — full MDM profile list. The Developer ID CA
  trust payload is handled here, but the rest of the profile set has not been
  enumerated, and config profiles cannot be delivered to a non-enrolled guest.
- ~~`which uv`~~ — **resolved.** `uv` is present in the guest and works;
  the `uv venv` failures were a home-directory race, not a missing binary
  (see "the retry loop is load-bearing" above).
- ~~Xcode version~~ — **resolved.** `fx-mac-v4-signing01` runs Xcode 16.2
  (16C5032a), which is also the newest Xcode Sonoma supports, so the fleet is at
  its OS ceiling rather than lagging. `install-xcode.pkr.hcl` pulls the matching
  `Xcode_16.2.xip` already staged in S3.
- **Xcode arrives via SimpleMDM on the hardware**, auto-deployed on group
  assignment — not by hand, and not by puppet (`macos_xcodes_installer` is
  included by no role and only drops the `xcodes` CLI helper). Tart guests are
  not MDM-enrolled, hence the dedicated phase here.
- `/etc/vault_approle_secret` is **zero bytes** and `/etc/vault_token` does not
  exist on `fx-mac-v4-signing01`, which suggests the vault-agent AppRole auth is
  not actually working there. Worth checking `/var/log/vault-agent.log` on the
  hardware independently of this project.
