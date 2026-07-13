# User guide

- [Installing](#installing)
- [Updating](#updating)
- [Client setup](#client-setup)
- [The web UI](#the-web-ui)
- [Package groups](#package-groups)
- [Building packages](#building-packages)
- [Patching a package (local override)](#patching-a-package-local-override)
- [Adding a new architecture](#adding-a-new-architecture)
- [Pausing / freeing the box](#pausing--freeing-the-box)
- [Build settings](#build-settings)
- [CLI reference](#cli-reference)
- [Security](#security)
- [Troubleshooting](#troubleshooting)

## Installing

Run on a Proxmox VE node as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/N0t4R0b0t/customArchForArch/main/install.sh)"
```

The helper downloads the Arch base template if needed, creates a **privileged** LXC
(nesting on, 16 cores, 32 GB disk by default, tagged `pkgmirror`), pushes the repo to
`/opt/pkgmirror`, then runs the in-container setup: toolchains, both build chroots,
nginx, the web UI, and the per-arch build timers.

Override defaults with env vars, e.g.:

```bash
CT_CORES=24 CT_DISK=64 CT_STORAGE=tank NONINTERACTIVE=1 \
  bash -c "$(curl -fsSL .../install.sh)"
```

Useful variables (see the top of [`install.sh`](../install.sh)): `CTID`,
`CT_HOSTNAME`, `CT_CORES`, `CT_RAM`, `CT_DISK`, `CT_STORAGE`, `TEMPLATE_STORAGE`,
`CT_BRIDGE`, `CT_IP`, `CT_UNPRIVILEGED`, `NONINTERACTIVE`, and `REPO_SRC` (install from
a local checkout instead of cloning).

When done, the dashboard is at `http://<container-ip>/`.

## Updating

One entrypoint, two modes — the installer auto-detects an existing `pkgmirror`-tagged
container and **updates in place** instead of creating a new one. Your `config/` and
`pkgbuilds/` are preserved.

- **From the Proxmox host:** re-run the installer (`install.sh update` to force).
- **From inside the container:** `pkgmirror-update`. If `/opt/pkgmirror` is a git
  checkout it fast-forwards from the tracked remote; otherwise it re-applies setup with
  the on-disk code. It also rebuilds the web binary and restarts the service.

> Two independent "update" axes: **this** refreshes the *tooling*. Rebuilding
> *packages* when upstream versions change is handled by the daily per-arch timers.

## Client setup

On each client, add the block for its architecture to `/etc/pacman.conf`, **above** the
official `[core]`/`[extra]` repos so pacman prefers the tuned local builds and falls
back to official ones otherwise:

```ini
[btver1-local]
Server = http://<container-ip>/repos/btver1
SigLevel = Optional TrustAll
```

Use the block matching the client CPU — i686 machines use the `atom` repo, x86_64
machines the `btver1` repo. Then:

```bash
sudo pacman -Sy
sudo pacman -S <package>     # or: sudo pacman -Syu
```

The web UI's **Help** page generates ready-to-copy blocks with your server's address.

## The web UI

Open `http://<container-ip>/`.

**Header** — architecture/group counts, disk usage, and:
- **Pause / Resume** — halt all builds and free the box (see below).
- **Stop builds** — kill running builds without pausing.
- **Help** — usage notes + copy-paste client `pacman.conf`.

**Package groups panel** — create groups, and add/remove member packages (chips with
`×`).

**Per-arch cards** — chroot status, last build result/time, next scheduled run, and:
- **Build all** — build the arch's whole effective set.
- **Groups bar** — a chip per enabled group; `▶` builds just that group, `×` disables
  it. An **Enable group** dropdown adds one.
- **Update-check** — show which packages are out of date.
- **Re-bootstrap chroot** — rebuild the chroot from scratch.
- **Package table** — repo vs source version, **origin** (which group), source, and a
  `DUE` badge; per-row **Build**, **Edit** (local PKGBUILDs), **Remove**.
- **Add extra package** — an arch-specific package beyond the groups.

Triggering a build opens a **console** that live-streams the build log (SSE). When it
finishes, the dashboard refreshes.

## Package groups

A **group** is a reusable, named catalog of package names you define once and build
across arches. The shipped `essentials` group is the set worth recompiling with
`-march` tuning (codecs, graphics, compression, crypto).

```bash
bin/group.sh create multimedia --desc "codecs and players"
bin/group.sh add multimedia ffmpeg
bin/group.sh add multimedia mpv
bin/group.sh enable btver1 multimedia      # btver1 now builds this group
bin/group.sh disable atom essentials       # atom stops building essentials
bin/group.sh list
```

An arch's build set = members of its enabled groups + its per-arch extras (deduped).
See [data model → effective build set](data-model.md#the-effective-build-set).

## Building packages

```bash
bin/build.sh btver1                       # whole effective set
bin/build.sh btver1 --group essentials    # one group's members
bin/build.sh btver1 --pkg mesa --force    # one package, force rebuild
bin/build.sh btver1 --jobs 1              # sequential (override concurrency)
```

- Packages already at their current version are skipped unless `--force`.
- A failing package is logged and skipped; the batch continues and prints a summary.
- Within an arch, up to `build_concurrency` packages build in parallel (each in its own
  chroot copy). Different arches build concurrently.
- The daily `pkgmirror-build@<arch>.timer` runs `update-check.sh` then `build.sh <arch>`.

## Patching a package (local override)

To fix a broken dependency, apply a patch, or bump `pkgrel`:

1. Put a modified PKGBUILD at `pkgbuilds/<arch>/<pkgname>/PKGBUILD` — via the UI
   (**Add extra package** with `source=local`, then **Edit**) or on disk.
2. That local copy now **wins** over the upstream PKGBUILD and is never overwritten by
   a sync. Bump `pkgrel` to trigger a rebuild.
3. Build it: `bin/build.sh <arch> --pkg <pkgname> --force` (or the UI **Build** button).

The `DUE` badge appears when a local PKGBUILD's version differs from what's in the repo.

## Adding a new architecture

```bash
bin/add-arch.sh znver1 --base x86_64 --cflags "-march=znver1 -O2 -pipe"
# inside the container, as root, to bootstrap its chroot:
installer/bootstrap-chroot.sh znver1
systemctl enable --now pkgmirror-build@znver1.timer
```

`add-arch.sh` scaffolds `config/arches/znver1.toml` (defaulting to `groups =
["essentials"]`), seeds its package list + pkgbuild dir, and — when run as root inside
the container — bootstraps the chroot. Adding a client then just means a new
`[znver1-local]` block.

For an i686 arch, pass `--base i686`; the bootstrap imports the archlinux32 keyring and
wraps builds in `setarch i686` automatically.

## Pausing / freeing the box

To shut the server down cleanly, or temporarily reclaim its cores for something else:

```bash
bin/control.sh pause    # stop running builds + block new ones (persists across reboot)
bin/control.sh resume   # allow builds again
bin/control.sh stop     # kill running builds WITHOUT pausing
bin/control.sh status
```

Or use **Pause** / **Stop builds** in the UI header. While paused, both scheduled and
manual builds no-op until you resume. The pause flag lives at
`/srv/pkgmirror/state/paused` and survives reboot, so a paused box stays paused until
you explicitly resume.

## Build settings

Edit `config/pkgmirror.toml` (see
[data model → global settings](data-model.md#global-settings-configpkgmirrortoml)):

- `build_concurrency` — parallel builds per arch.
- `skip_pgp_check` — skip upstream source-signature verification (default `true`).
- `skip_check` — skip package test suites (default `true`; required for cross-tuned
  builds).

## CLI reference

All scripts live in `bin/` (run inside the container; the build ones as the
`pkgmirror` user, e.g. `runuser -u pkgmirror -- bin/build.sh …`).

| Command                                             | Does                                    |
|-----------------------------------------------------|-----------------------------------------|
| `build.sh <arch> [--group g\|--pkg p] [--force] [--jobs N]` | build packages for an arch        |
| `update-check.sh <arch>`                            | status table: repo vs source, origin    |
| `group.sh create\|add\|remove\|enable\|disable\|list`| manage groups & arch subscriptions      |
| `add-package.sh <arch> <pkg> [--source ..]`         | add a per-arch extra package            |
| `remove-package.sh <arch> <pkg>`                    | remove a per-arch extra                 |
| `add-arch.sh <name> --base .. --cflags ".."`        | scaffold a new arch                     |
| `control.sh pause\|resume\|stop\|status`            | pause/resume/stop the build system      |
| `repo-sync.sh <arch> <pkgfile ...>`                 | add built packages to the served repo   |

In-container conveniences: `pkgmirror-update` (self-update).

## Security

This is a dedicated, **LAN-internal** build box with a pragmatic trust model:

- The container is **privileged** and the `pkgmirror` user has **passwordless sudo**
  (devtools requires it).
- Repos are served **`SigLevel = Optional TrustAll`** (unsigned).
- The **web UI has no authentication** and can trigger builds and edit files. It binds
  `127.0.0.1` behind nginx. To lock it down, add HTTP basic-auth to the `location /`
  block in [`nginx/pkgmirror.conf`](../nginx/pkgmirror.conf) (e.g. `auth_basic` +
  `auth_basic_user_file`); keep `location /repos/` open for pacman clients.

Do not expose this container to an untrusted network.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Build fails: `unknown public key` on sources | Upstream source PGP; keep `skip_pgp_check = true`, or import the key into the chroot. |
| Build fails: test suite `check()` fails / illegal instruction | Tuned binary can't run on the build host's CPU (e.g. `btver1` SSE4A on Intel). Keep `skip_check = true`. |
| Build fails: `Landlock is not supported` / `sandbox user 'alpm'` | pacman's download sandbox in an LXC. Handled by `DisableSandbox`; if a chroot predates it, re-bootstrap it. |
| Chroot bootstrap fails for an i686 arch | archlinux32 keyring/trust — `bootstrap-chroot.sh` imports master keys and sets `marginals-needed 2` (one archlinux32 master key is expired). Re-run the bootstrap. |
| A chroot looks broken | **Re-bootstrap chroot** (UI) or `installer/bootstrap-chroot.sh <arch>` — a partial chroot (no `.pkgmirror-ready` marker) is removed and rebuilt. |
| Builds don't start | Check the pause flag: `bin/control.sh status`; `resume` if paused. |
| Client doesn't see a package | Ensure the `[<arch>-local]` block is **above** the official repos and run `pacman -Sy`. |
