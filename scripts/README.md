# macos-vms build-host scripts

Operational scripts for the **build host** — the Mac that runs the self-hosted
GitHub Actions runner and produces the `sequoia-tester` VM image
(currently `macmini-m4-116`).

## `setup-build-runner.sh`

Reproducibly (re)installs the GitHub Actions self-hosted runner **and** the disk
prune/monitor daemon. Run it whenever the runner needs to be rebuilt (host
reimaged, runner de-registered, or config wiped) instead of reassembling the
steps by hand.

```bash
# on the build host, as the `admin` user:
TOKEN=$(gh api -X POST \
  repos/mozilla-platform-ops/macos-vms/actions/runners/registration-token \
  --jq .token)
./setup-build-runner.sh "$TOKEN"
```

The registration token is short-lived and is passed at runtime — nothing secret
is committed. The runner runs as a LaunchAgent in the `admin` GUI session
(tart/Virtualization needs it), so keep `admin` autologin enabled for
reboot-persistence.

## `build-runner-maintenance.sh` + `com.mozilla.build-runner-maintenance.plist`

Installed by `setup-build-runner.sh` to `/usr/local/bin` and
`/Library/LaunchDaemons`. Runs hourly:

- prunes tart's OCI pull cache (`~/.tart`, which grows unbounded) — but only
  when no build VM is running, so it never disturbs an in-flight build;
- emails `releng-ci-alerts@mozilla.com` (rate-limited, 6h) when free space on
  the data volume drops below 40 GiB.

This addresses the build host's historical failure mode: silently running out
of disk and failing builds with no signal.

Logs: `/var/log/build-runner-maintenance.{out,err}`.
