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
| macOS | Sequoia 15 | **Sonoma 14.7.5 (23H527)** | matches the fleet; `Mac14,3` / M2 mini |
| SIP | disabled (phase 2) | **left enabled** | prod signers run SIP-on; the role converges under it there |
| Phases | 4 | **3** | no SIP-disable phase |
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
IPSW_URL="https://updates.cdn-apple.com/.../UniversalMac_14.7.5_23H527_Restore.ipsw" ./builder.sh
```

`IPSW_URL` has no default on purpose — matching the prod build is the point, so
it is an explicit decision rather than something a file guesses at. Get the URL
from Apple's mesu catalog or ipsw.me.

Iterating on the puppet phases against an already-built base:

```bash
SKIP_BASE=1 ./builder.sh
```

### Phase 1 is the flaky one

`create-base.pkr.hcl` drives Setup Assistant with blind, timed VNC keystrokes.
**The sequence currently in that file was written for Sequoia and copied here
verbatim as a starting point — it is not yet validated on Sonoma.** Pane order
and the tab stops in Sharing differ between releases. Watch the first run over
VNC and fix the counts. Drift shows up as "timeout waiting for SSH", not as an
obvious UI error.

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

## 🛑 Where this stops

This iteration is scoped to *"does the dep signer role converge in a VM"*. It
deliberately does **not** include:

- vault.yaml injection (no `vault-inject.sh` equivalent yet)
- the vault AppRole id/secret pair
- any signing material
- a first-boot puppet re-run

Because there is no re-run yet, the image ships with worker configs naming
`dep-mac-v4-signing99` (the build hostname). Those workers cannot authenticate —
the vault was fake — so there is no impersonation risk, but the image is a
template, not a deployable worker. Iteration 2 needs a `vault-inject`
equivalent that runs puppet again *after* `set_hostname.sh` has applied the
allocated identity.

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

- `pkgutil --pkg-info=com.apple.pkg.CLTools_Executables` — phase 1 pins Xcode
  CLT 16.4 (inherited from the M4 tester fleet); codesign/notarytool behavior is
  part of what we're reproducing, so this should match.
- `sudo profiles -P -o stdout` — full MDM profile list. The Developer ID CA
  trust payload is handled here, but the rest of the profile set has not been
  enumerated, and config profiles cannot be delivered to a non-enrolled guest.
- `which uv` — `signing_worker` runs `uv venv` / `uv sync`, but there is no
  `packages::uv` class. Where does it come from on the hardware?
- `/etc/vault_approle_secret` is **zero bytes** and `/etc/vault_token` does not
  exist on `fx-mac-v4-signing01`, which suggests the vault-agent AppRole auth is
  not actually working there. Worth checking `/var/log/vault-agent.log` on the
  hardware independently of this project.
