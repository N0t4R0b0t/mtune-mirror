# archlinux32 upstream reports

A running log of issues found in archlinux32's own repo — not this project's
packages — worth reporting to their [bug tracker](https://bugs.archlinux32.org/)
or as a merge request against the relevant package's own repo on
[git.archlinux32.org](https://git.archlinux32.org/archlinux32/packages). Each
entry stays here until it's actually filed, so we always know what's
outstanding vs. already sent upstream.

**Policy**: nothing goes in this doc as "report this" without a concrete,
already-verified fix attached — a bug report alone is easy for a small
volunteer project to let sit; "here's the exact fix, already tested" is much
more likely to get merged. Findings surfaced by `bin/audit-al32-deps.sh`
(see [user-guide.md](user-guide.md#cli-reference)) get triaged into this doc,
not filed directly.

Two genuinely different bug classes show up here — keep them distinct:

- **Repo drift** — a package's declared dependency has no satisfying
  provider *anywhere* in the repo. This is what `audit-al32-deps.sh` detects.
  A real metadata inconsistency archlinux32's packagers can act on directly.
- **Resolver quirk** — the dependency metadata is actually fine (a valid
  provider genuinely exists, at a version that satisfies the spec), but
  `pacman`'s own dependency resolver doesn't reliably auto-install it during
  a real `-S`/build transaction anyway. This is *not* something
  `audit-al32-deps.sh` can catch (it only checks whether a provider exists,
  not whether pacman's solver picks it), and it's arguably not even an
  archlinux32 bug — more a `pacman`/soname-`Provides` limitation their
  packagers could work around by using a hard `depends=` instead of relying
  on soname auto-resolution.

---

## netsurf: stale exact-version pins + version-too-old sibling libs

**Status:** not yet reported.
**Class:** repo drift (confirmed via `audit-al32-deps.sh`).

**What's broken:** archlinux32's `netsurf` package (Arch tag `3.10-7`) has
fallen behind its own sibling-library family in both directions:

- `depends=(... 'libhubbub=0.3.7' ... 'libnsutils=0.1.0' ...)` — exact-version
  pins that no longer match what archlinux32 currently ships (`libhubbub`
  is now `0.3.8`, `libnsutils` is now `0.1.1`) — confirmed live via
  `audit-al32-deps.sh i686 core,extra`:
  ```
  netsurf   VERSION   libhubbub=0.3.7
  netsurf   VERSION   libnsutils=0.1.0
  ```
- Separately (not caught by the metadata-only audit, found by actually
  building it): `netsurf` 3.10's C source (`content/handlers/image/bmp.c`)
  calls `bitmap_get_bpp` on `libnsbmp`'s callback vtable — a member that no
  longer exists in archlinux32's current `libnsbmp` (`0.1.7`), which moved to
  a newer API shape.

**Concrete fix (built and verified working, 2026-07-22):** bump to mainline
Arch's current `netsurf` release, tag `3.11-10`, which is written against the
current `libnsbmp` API and already pins `libhubbub=0.3.8`/`libnsutils=0.1.1`
correctly. That version's own dependency floor is ahead of archlinux32 in
three more places (`libcss>=0.9.2` vs. archlinux32's `0.9.1`,
`libnsgif>=1.0.0` vs. archlinux32's `0.2.1` — a real major-version API jump —
and `libutf8proc>=2.9.0` vs. archlinux32's `2.8.0`), so the full fix is a
**four-package bump**, not just `netsurf` alone:

| Package | archlinux32 has | Bump to (mainline tag) |
|---|---|---|
| `netsurf` | `3.10-7` | `3.11-10` |
| `libcss` | `0.9.1-6.0` | `0.9.2-2` |
| `libutf8proc` | `2.8.0-1.0` | `2.11.3-1` |
| `libnsgif` | `0.2.1-8.0` | `1.0.0-2` |

All four were built and installed successfully against a real archlinux32
`i686` chroot this session (see `pkgmirror-project` project memory / this
session's history for the build logs) — `netsurf 3.11-10.1` compiled and
linked cleanly against locally-built `libcss`/`libnsgif`/`libutf8proc`, no
source patching needed.

---

## qt6-base: `libicui18n.so=75` / `librsvg`: `libxml2.so=2`

**Status:** not yet reported — and likely shouldn't be filed as "please fix
your metadata," since the metadata is actually correct (see below).
**Class:** resolver quirk, not repo drift.

**What's broken:** building `qt6-base` (needs `libicui18n.so=75`,
satisfied by the `icu75` package) or `librsvg` (needs `libxml2.so=2`,
satisfied by `libxml2-legacy`) inside a fresh chroot fails deep in
`prepare()`/postinst hooks with `cannot open shared object file`, even
though both `icu75` and `libxml2-legacy` genuinely exist in the repo and
correctly declare the right `Provides`. Confirmed via `pacman -Sup qt6-base
librsvg`: neither `icu75` nor `libxml2-legacy` appear anywhere in the
resolved transaction, despite being valid providers of the exact soname
required.

**Root cause:** not a data problem — `pacman`'s own dependency solver isn't
reliably auto-installing a soname-`Provides` match during a real
`-S`/build-dependency-install transaction, at least not for these
packages/deps. `icu75` even sits in an explicit `Groups: build-shims`
grouping on archlinux32's side, suggesting their own packagers already treat
these as needing manual/opt-in installation rather than expecting automatic
resolution.

**Concrete fix (already shipped, our side only):** `installer/bootstrap-
chroot.sh` now installs `icu75` and `libxml2-legacy` explicitly into every
fresh i686 chroot at bootstrap time, so this never bites a build here again
— see that file's own comment for detail. This is a workaround, not a fix to
archlinux32 itself.

**What (if anything) to report:** given the metadata is correct and this is
plausibly `pacman` core behavior rather than an archlinux32 packaging bug,
the more useful thing to send upstream is probably a **documentation note**
(e.g. a forum/wiki post: "if a package needs an old SONAME shim like
`icu75`/`libxml2-legacy`, don't assume pacman auto-installs it — add it
explicitly") rather than a bug report demanding a data fix. Not yet written.

---

## `glib2-devel`: not a real package on archlinux32, ~189 packages depend on it

**Status:** not yet reported (needs a decision on scope before filing — see
below).
**Class:** repo drift, confirmed via `audit-al32-deps.sh` (189 `MISSING`
hits, 2026-07-22 run against `i686 core,extra`) and matches an
already-confirmed finding from an earlier session working on this project's
own `gdk-pixbuf2` build: **archlinux32 never split `glib2`/`glib2-devel` —
their `glib2` ships unsplit**, unlike mainline Arch, which factored the
`-devel` half (headers, `.pc` files, `glib-compile-resources` etc.) into its
own package a while back. Every package whose `makedepends`/`depends` still
literally says `glib2-devel` (inherited verbatim from mainline Arch's
PKGBUILD) can't resolve it on archlinux32 at all — not a version mismatch,
the package genuinely doesn't exist there. Examples from this run:
`at-spi2-core`, `gtk3`, `thunar`, most of `xfce4-*`, most of `telepathy-*`,
`vte3`/`vte4`, `zenity`, `xdg-desktop-portal-gtk`, and more — 189 total.

**Concrete fix:** none yet worked out generically — this project's own fix
(see `pkgmirror-project` history) was package-specific: `gdk-pixbuf2`
genuinely needs `glib2-devel`'s `glib-compile-resources` once building
against a *split* `glib2`, so the fix there was building our own split
`glib2`/`glib2-devel` locally, not something archlinux32 itself could apply
package-by-package. Filing this needs a decision first: is the real fix
"archlinux32 should split `glib2-devel` out like mainline," or "these 189
PKGBUILDs should stop requiring it since archlinux32's `glib2` already
contains everything it provides" — those are very different asks, and
picking the wrong one means it likely goes nowhere. Worth discussing before
reporting.

---

## `python2` family: fully absent, ~943 spec hits across many packages

**Status:** not yet reported.
**Class:** repo drift, confirmed via `audit-al32-deps.sh` (943 `MISSING`
hits — bare `python2` plus its `python2-*` subpackages like
`python2-pygments`/`python2-dbus`/`python2-pillow`). Matches this session's
own direct experience packaging `basilisk` for `atom`, where `python2` build
tooling turned out to be AUR-only.

**Root cause:** Python 2 is fully end-of-life and was dropped from Arch's
official repos years ago; archlinux32 never carried a replacement. Any
package (mainline Arch or archlinux32-native) still declaring `python2`/
`python2-*` as a dependency can't resolve it from `core`/`extra` at all.

**Concrete fix:** none proposed — this is a genuinely hard case, not a
metadata bug. The packages depending on `python2` are themselves stuck on
EOL tooling; the realistic fix is each of those ~943 dependency edges
getting individually modernized off Python 2 (upstream, not archlinux32's
job) or archlinux32 choosing to package `python2` from the AUR themselves as
a stopgap. Not something to file as a single actionable bug report — noting
here mainly so we don't rediscover the scope of this by surprise again.
