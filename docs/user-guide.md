# User guide

- [Installing](#installing)
- [Updating](#updating)
- [Client setup](#client-setup)
- [The web UI](#the-web-ui)
- [Package groups](#package-groups)
- [Building packages](#building-packages)
- [Patching a package (local override)](#patching-a-package-local-override)
- [Per-package build overrides & AUR packages](#per-package-build-overrides--aur-packages)
- [Adding a new architecture](#adding-a-new-architecture)
- [Pausing / freeing the box](#pausing--freeing-the-box)
- [Build settings](#build-settings)
- [CLI reference](#cli-reference)
- [Security](#security)
- [Troubleshooting](#troubleshooting)

## Installing

Run on a Proxmox VE node as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/N0t4R0b0t/mtune-mirror/main/install.sh)"
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
- **Stop builds** — kill *every* arch's running build without pausing.
- **Help** — usage notes + copy-paste client `pacman.conf`.

**Currently building panel** — each in-flight arch's card has a **cancel** button
that stops only that arch's build, leaving other arches' builds running (unlike the
header's Stop builds, which stops everything). Also shows Elapsed time per sweep in
Recent builds.

**Package groups panel** — create groups, and add/remove member packages (chips with
`×`).

**Per-arch cards** — chroot status, last build result/time, next scheduled run, and:
- **Build all** — build the arch's whole effective set.
- **Groups bar** — a chip per enabled group; `▶` builds just that group, `×` disables
  it. An **Enable group** dropdown adds one.
- **Update-check** — show which packages are out of date.
- **Re-bootstrap chroot** — rebuild the chroot from scratch.
- **Package table** — repo vs source version, **origin** (which group), source, a
  `DUE` badge, and a 🔧 **override** badge (hover for a summary) when a package has
  build overrides; per-row **Details**, **Override** (pin/patches/skip_check/
  makepkg args/memory — see below), **Build**, **Edit** (local PKGBUILDs), **Remove**.
- **Add extra package** — an arch-specific package beyond the groups, sourced from
  `upstream`, `local`, or `aur`. Both this input and **add package to `<group>`**
  (Settings) offer a live search dropdown (core/extra/AUR, with descriptions) as
  you type.

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
  `update-check.sh` is a status view — a `local`-sourced package gets an exact version
  diff, and `upstream`/`aur`/`git` packages get a real (but cheap) `git ls-remote`
  against the resolved remote, compared to the commit actually built last, so `DUE`
  reflects real upstream movement, not just "was it ever built." It doesn't gate
  `build.sh`, which always runs and does its own (more expensive, full-clone)
  up-to-date check per package.

## Patching a package (local override)

To fix a broken dependency, apply a patch, or bump `pkgrel`:

1. Put a modified PKGBUILD at `pkgbuilds/<arch>/<pkgname>/PKGBUILD` — via the UI
   (**Add extra package** with `source=local`, then **Edit**) or on disk.
2. That local copy now **wins** over the upstream PKGBUILD and is never overwritten by
   a sync. Bump `pkgrel` to trigger a rebuild.
3. Build it: `bin/build.sh <arch> --pkg <pkgname> --force` (or the UI **Build** button).

The `DUE` badge appears when a local PKGBUILD's version differs from what's in the repo.
For `upstream`/`aur`/`git` packages, `DUE` instead means the resolved remote's HEAD
commit has moved past what was actually built last — an explicit override `pin`
(or, on i686 arches, the automatic archlinux32 version pin) suppresses this, since
pinning means "stay put" even as upstream moves on.

## Per-package build overrides & AUR packages

A full local override (above) replaces a package's *entire* PKGBUILD — the right
tool for a genuinely custom package. Most of the time you just need to tweak
**one thing** about an otherwise-normal upstream/AUR build: pin a version, apply
a small patch, skip its test suite, or hand it more build memory. That's what
`config/overrides/<arch>.toml` is for — see [data model → per-package
overrides](data-model.md#configoverridesarchtoml) for the full field list and
the [build resolution pipeline](data-model.md#build-resolution-pipeline)
diagram for exactly when each one applies.

**From the dashboard:** open **Packages**, click a package's **Override**
button, fill in the fields you need, **Save**. The row picks up a 🔧 badge;
**Clear override** removes the whole entry.

**From the CLI:**

```bash
# pin harfbuzz to an older tag and apply a local patch
bin/override.sh atom harfbuzz --pin 7.1.0-1 --patches icu-fix.patch
cp my-icu-fix.patch pkgbuilds/atom/harfbuzz/patches/icu-fix.patch

# a package whose build() needs more headroom than the fleet default
bin/override.sh atom linux-atom --mem-per-job-mb 4096

bin/override.sh atom list          # see every override for an arch
bin/override.sh atom harfbuzz --clear
```

For anything the declarative fields don't cover (editing a PKGBUILD's
`depends()` array, running `oldconfig` before a kernel build, …), drop an
executable `pkgbuilds/<arch>/<pkg>/hooks/post_fetch.sh` — it runs after
fetch/pin/patches, before the build, with `PKG`/`ARCH`/`SRCDIR` in its
environment. Same trust level as PKGBUILD itself (this is a LAN-trusted tool —
see [Security](#security)).

**AUR packages** get their own source, alongside `upstream` and `local`:

```bash
bin/add-package.sh atom yay --source aur      # or the UI: source=aur
```

`build.sh` then clones `https://aur.archlinux.org/<pkg>.git` instead of Arch's
official GitLab. AUR packages don't get the automatic i686/archlinux32 version
pin (AUR has no archlinux32 relationship) unless you set one explicitly via
`--pin`.

**A fully custom package** (e.g. a hand-tuned kernel like `linux-atom`) has two
options, depending on where its PKGBUILD lives:

- **`source = "git"`** — point at your *own* repo (e.g. a public GitHub repo for
  `linux-atom`) and pkgmirror clones it fresh every build. You maintain the
  PKGBUILD/config/patches in one place, not two:

  ```bash
  bin/add-package.sh atom linux-atom --source git \
    --url https://github.com/you/linux-atom.git \
    --ref stable                                    # optional: branch or tag
  bin/override.sh atom linux-atom --skip-check true --mem-per-job-mb 4096
  bin/build.sh atom --pkg linux-atom --force
  ```

  In the UI: select `git (custom repo)` as the source, which reveals a URL
  (required) and ref (optional) field.

- **`source = "local"`** — vendor the PKGBUILD directly into this repo instead,
  under `pkgbuilds/<arch>/linux-atom/`, same as `pkgmirror-hello`:

  ```bash
  bin/add-package.sh atom linux-atom --source local
  bin/override.sh atom linux-atom --skip-check true --mem-per-job-mb 4096
  bin/build.sh atom --pkg linux-atom --force
  ```

Both are treated identically by the rest of the pipeline (overrides, patches,
pinning) — `git` just fetches from elsewhere instead of reading a copy checked
in here. Prefer `git` if you already maintain the package's source externally;
prefer `local` if you'd rather keep everything in one repo.

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
bin/control.sh pause          # stop running builds + block new ones (persists across reboot)
bin/control.sh resume         # allow builds again
bin/control.sh stop           # kill EVERY arch's running build WITHOUT pausing
bin/control.sh stop-arch atom # kill only <arch>'s build, leave other arches running
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
  builds). Per-package override: see [overrides](#per-package-build-overrides--aur-packages).
- `build_mem_per_job_mb` — RAM estimate per parallel compile job, used to cap
  `make -j` so heavy builds don't get OOM-killed (default `1536`). Per-package
  override (single-package builds only): see
  [overrides](#per-package-build-overrides--aur-packages).

## CLI reference

All scripts live in `bin/` (run inside the container; the build ones as the
`pkgmirror` user, e.g. `runuser -u pkgmirror -- bin/build.sh …`).

| Command                                             | Does                                    |
|-----------------------------------------------------|-----------------------------------------|
| `build.sh <arch> [--group g\|--pkg p] [--force] [--jobs N]` | build packages for an arch        |
| `update-check.sh <arch>`                            | status table: repo vs source/upstream, origin |
| `group.sh create\|add\|remove\|enable\|disable\|list`| manage groups & arch subscriptions      |
| `add-package.sh <arch> <pkg> [--source upstream\|local\|aur\|git] [--url ..] [--ref ..]` | add a per-arch extra package (`--url` required for `git`) |
| `remove-package.sh <arch> <pkg>`                    | remove a per-arch extra                 |
| `override.sh <arch> <pkg> [--pin ..] [--skip-check ..] [--makepkg-args ..] [--patches ..] [--mem-per-job-mb ..] [--notes ..] [--clear]` | set/clear a package's build override |
| `override.sh <arch> list`                           | list all overrides for an arch          |
| `add-arch.sh <name> --base .. --cflags ".."`        | scaffold a new arch                     |
| `control.sh pause\|resume\|stop\|status`            | pause/resume/stop the build system      |
| `repo-sync.sh <arch> <pkgfile ...>`                 | add built packages to the served repo   |
| `audit-al32-deps.sh [arch] [repo,repo,...]`         | audit archlinux32's OWN repo (default `i686 core,extra`) for dependency-drift: packages whose declared `depends`/`makedepends`/`checkdepends` aren't satisfiable by anything currently published |

In-container conveniences: `pkgmirror-update` (self-update).

`audit-al32-deps.sh` is the odd one out in this table — it doesn't touch this
project's own packages at all, and doesn't need to run as the `pkgmirror`
user or even inside the container (just needs `bsdtar`, `vercmp`, `curl`,
`awk`, all standard on any Arch-family machine). It exists because we've
independently hit archlinux32's own package-graph drift more than once (a
package still declaring a dependency version its sibling packages have since
moved past, or moved beyond) — each time surfacing only as an obscure
build-time failure, never a clean error. Findings worth reporting upstream go
into [`docs/archlinux32-upstream-reports.md`](archlinux32-upstream-reports.md).

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
