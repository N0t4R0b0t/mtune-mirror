# customArchForArch — Multi-Arch Package Mirror Builder

A Proxmox VE helper that provisions an Arch LXC which rebuilds selected packages —
tuned for a specific target CPU (`-march=…`) and/or patched with your own PKGBUILDs —
and serves them as pacman-compatible **overlay repos** over HTTP, with a web UI to
monitor and drive the whole build pipeline.

Clients keep using the official repos and only pull the rebuilt packages from a
higher-priority local repo, falling back cleanly to upstream for everything else.

Ships two targets out of the box:

| arch     | base    | tuning                          | example machine              |
|----------|---------|---------------------------------|------------------------------|
| `atom`   | i686    | `-march=atom -mtune=atom`       | Intel Atom N270 (Aspire One) |
| `btver1` | x86_64  | `-march=btver1 -mtune=btver1`   | AMD C-60 (Bobcat)            |

The build host is x86_64, so i686 builds run natively (no emulation).

## Quick start

**1. Install** — on a Proxmox VE node, as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/N0t4R0b0t/customArchForArch/main/install.sh)"
```

This provisions the container, bootstraps both build chroots, and brings up the repos
+ web UI. Re-running it later updates in place (config preserved). Override defaults
with env vars, e.g. `CT_CORES=24 CT_DISK=64 CT_STORAGE=tank`.

**2. Open the dashboard** at `http://<container-ip>/` — build packages, manage groups,
stream logs, pause/resume.

**3. Point a client at it** — add to `/etc/pacman.conf`, above the official repos:

```ini
[btver1-local]
Server = http://<container-ip>/repos/btver1
SigLevel = Optional TrustAll
```

Then `sudo pacman -Sy && sudo pacman -Syu`. (Use `atom` for i686 clients. The UI's
Help page generates these blocks for you.)

## What it does

- **Package groups** — reusable named catalogs of packages (e.g. the seeded
  `essentials`) that arches opt into; build a whole group at once.
- **Tuned rebuilds** — per-arch CFLAGS injected into the build chroot.
- **Local overrides** — drop a patched `PKGBUILD` in `pkgbuilds/<arch>/<pkg>/`; it wins
  over upstream and is never clobbered by a sync.
- **Parallel builds** — configurable concurrency per arch (each in its own chroot
  copy), plus concurrent builds across arches.
- **Web UI + API** — monitoring, one-click builds, live SSE logs, group/package
  management, PKGBUILD editing, and pause/resume — no SSH needed.
- **Auto-updates** — a daily systemd timer per arch rebuilds what changed.

## Documentation

Full docs live in [`docs/`](docs/):

- **[Architecture](docs/architecture.md)** — components, runtime layout, build & serving
  flow, parallelism, trust model (with diagrams).
- **[Data model](docs/data-model.md)** — config schema, the effective build set, state
  files, repo layout (with diagrams).
- **[User guide](docs/user-guide.md)** — installing, client setup, the UI, the CLI,
  adding an arch, patching packages, groups, pausing, and troubleshooting.

## Layout

```
install.sh              # Proxmox-host entry point (install OR update, tag-detected)
installer/              # create-lxc, container-setup, bootstrap-chroot, self-update
config/
  arches/<name>.toml    # an architecture (base, toolchain, cflags, enabled groups)
  groups/<name>.toml    # a package group catalog
  packages/<name>.toml  # per-arch extras + source overrides
  pkgmirror.toml        # global settings (concurrency, skip flags)
pkgbuilds/<arch>/<pkg>/PKGBUILD   # local overrides (win over upstream)
bin/                    # build.sh, group.sh, control.sh, update-check.sh, …
web/                    # pkgmirror-web: stdlib-only Go service + embedded SPA
systemd/                # per-arch build timers + web service
nginx/                  # /repos static, / proxied to the UI
```

## Requirements

- **Host**: Proxmox VE (`pct`, `pveam`, `git`).
- **Container** (installed automatically): `base-devel`, `devtools`, `nginx`, `go`,
  `git`, and `dasel`.

> **Security**: a dedicated, LAN-internal build box — privileged container, repos
> served `TrustAll`, web UI unauthenticated. Don't expose it to an untrusted network;
> add nginx basic-auth to lock down the UI. See
> [architecture → trust model](docs/architecture.md#trust--security-model).
