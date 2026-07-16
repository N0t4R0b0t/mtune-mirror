# Contributing

This started as a personal tool for rebuilding Arch packages tuned to specific
machines, and it's now public in case it's useful to anyone else running a
similar setup. Contributions are welcome — bug fixes, new arch examples,
doc fixes, anything reasonable — but keep in mind this is maintained on a
best-effort basis, not a funded project with an SLA.

## Before you start

For anything beyond a small fix (a new feature, a change to `bin/build.sh`'s
orchestration, touching `web/main.go`'s architecture), open an issue first to
talk it through. This project has already been through a few rounds of
"seemed reasonable, turned out to reintroduce a fixed bug" — see the archlinux32
pkgrel/vercmp fix and the `-mno-movbe` fix in the commit history for two real
examples. A quick issue saves both of us time versus a PR built on the wrong
assumption.

## Local development

You don't need a real Proxmox box to iterate on package/PKGBUILD fixes — see
[`docker/README.md`](docker/README.md) for a local sandbox that replicates the
build chroot environment:

```bash
docker/sandbox.sh up
docker/sandbox.sh bootstrap atom
docker/sandbox.sh build atom --pkg <pkg> --force
```

For the web UI (`web/main.go` + `web/static/`), you need Go 1.22+ and the repo
checked out somewhere `internal/pkgconfig` can find `config/*.toml` relative to
`PKGMIRROR_ROOT` (defaults to `/opt/pkgmirror`; override it when testing
locally). There's no mock data set — point it at a real `config/` tree (this
repo's own `config/` works fine for read-path testing).

## What CI actually checks

Match these locally before opening a PR — `.github/workflows/ci.yml` runs all
three on every push/PR:

```bash
# bash
shellcheck -S error bin/*.sh bin/lib/*.sh installer/*.sh docker/*.sh
find bin installer docker -name '*.sh' -print0 | xargs -0 -n1 bash -n

# go
cd web && go build ./... && go vet ./...

# toml
python3 -c "
import pathlib, sys, tomllib
bad = []
for p in pathlib.Path('config').rglob('*.toml'):
    try: tomllib.loads(p.read_text())
    except Exception as e: bad.append(f'{p}: {e}')
if bad: print('\n'.join(bad)); sys.exit(1)
"
```

## Code style

- **Bash**: `set -euo pipefail` at the top of every script; source
  `bin/lib/common.sh` for logging (`log`/`warn`/`err`/`die`), TOML access, and
  locking (`with_lock`) rather than reimplementing them.
- **Comments explain *why*, not *what*.** A comment that just restates the
  code it sits above gets deleted in review. A comment that explains a
  non-obvious constraint, a workaround for a specific confirmed bug, or a
  decision that looks wrong at a glance until you know the reason — that's
  what earns a comment here. Skim any existing file in `bin/` for the house
  style before writing new comments.
- **Real bugs over hypothetical ones.** Several fixes in this codebase exist
  because something specific and reproducible broke (see `bin/build.sh`'s
  `al32_bump_pkgrel` comment, or `config/arches/atom.toml`'s `-mno-movbe`
  comment, for two fully-documented examples). Don't add defensive code,
  fallbacks, or "just in case" complexity for a failure mode you haven't
  actually seen — if you hit a real one, fix that one and document it the
  same way.
- **Go**: no new dependencies without a clear reason (the one dependency this
  project has, `pelletier/go-toml/v2`, replaced dozens of `dasel` subprocess
  spawns per request — that's the bar). `internal/pkgconfig` is read-only by
  design; see its package doc comment before adding a write path there.

## Adding a new arch

Read [`docs/data-model.md`](docs/data-model.md) first — specifically the
`config/arches/<arch>.toml` section, which covers both the CPU-tuning case
(`atom`/`btver1`) and the different-distro case (`manjaro`, which bootstraps
against Manjaro's own repos instead of vanilla Arch). Most new arches are a
config-only change via `bin/add-arch.sh`; only a genuinely new distro/base
combination needs a change to `installer/bootstrap-chroot.sh`.

## Pull requests

- One logical change per PR. This repo's own commit history is a good model
  for scope — small, focused commits with a "why" in the message, not just a
  "what."
- Update the relevant doc (`README.md`, `docs/*.md`) in the same PR if your
  change makes something in there stale — don't leave that for later.
- No need to update `CHANGELOG`-style anything; there isn't one. Release
  notes are generated from tags, see [`docs/releasing.md`](docs/releasing.md).

## Reporting bugs

Include the arch involved (`atom`/`btver1`/`manjaro`/your own), the exact
command or dashboard action, and the actual log output — this project has
learned the hard way that "it broke" without the log is rarely enough to
diagnose (build failures here have ranged from a stale pacman sync DB to a
genuine `-march` miscompilation; the log is usually the only way to tell
which).
