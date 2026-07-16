#!/usr/bin/env bash
# bin/update-check.sh <arch>
#
# Reports, per configured package, the version/commit currently in the repo vs
# the source, and whether a rebuild is due. Informational: build.sh independently
# skips packages already at the current version, so this is a status view (and a
# cheap way to see drift without a full build sweep).
#
# local-override packages get an exact up-to-date / DUE verdict by diffing the
# repo's built version against the local PKGBUILD's pkgver-pkgrel.
#
# upstream/aur/git packages get a real check too: a `git ls-remote` against the
# resolved remote (Arch GitLab for upstream, aur.archlinux.org for aur, the
# configured url/ref for git — see bin/lib/common.sh upstream_remote_url_ref,
# which mirrors bin/build.sh resolve_src's clone logic) compared against the
# commit build.sh actually built last (state/<arch>/commits/<pkg>, written by
# run_pkg on a successful build). No local baseline yet (never built, or built
# before this tracking existed) or an unreachable remote falls back to the old
# built/missing verdict rather than risk a false DUE.
#
# A package with an explicit build-override pin (bin/override.sh --pin) is
# intentionally frozen to that version/tag, so upstream moving on doesn't flag
# it — it shows "pinned" instead of DUE.
#
# i686 arches are a second, implicit case of the same idea: build.sh's resolve_src
# auto-pins every upstream (non-aur/git) package to the git tag matching what
# archlinux32 currently ships (see build.sh al32_pin_tag) — archlinux32 lags Arch
# GitLab by design, so the built commit never converges on GitLab HEAD. Comparing
# against HEAD there would flag nearly the whole fleet DUE permanently, which isn't
# real drift. Those packages show "(i686 auto-pin)" instead; aur/git sources have
# no archlinux32 relationship (per build.sh) and still get the real HEAD check.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

arch="${1:?usage: update-check.sh <arch>}"
arch_conf "$arch" >/dev/null || exit 1

commits_dir="$PKGMIRROR_DATA/state/$arch/commits"

# pkg_pin <pkg> -> this package's override pin, or empty if none set.
pkg_pin() {
  local pkg="$1" pin=""
  IFS="$pkg_override_sep" read -r pin _ _ _ _ _ < <(pkg_override "$arch" "$pkg") || true
  printf '%s\n' "$pin"
}

printf '%-22s %-13s %-13s %-9s %s\n' PACKAGE REPO SOURCE STATUS ORIGIN
due=0
while IFS=$'\t' read -r name src origin; do
  [ -n "$name" ] || continue
  have="$(repo_version "$arch" "$name")"; have="${have:--}"
  localdir="$PKGMIRROR_ROOT/pkgbuilds/$arch/$name"
  if [ -f "$localdir/PKGBUILD" ]; then
    want="$(pkgbuild_version "$localdir")"
    if [ "$have" = "$want" ]; then status="ok";
    else status="DUE"; due=$((due + 1)); fi
  elif [ "$have" = "-" ]; then
    want="(upstream)"; status="missing"; due=$((due + 1))
  else
    pin="$(pkg_pin "$name")"
    auto_pin=0
    if [ -z "$pin" ] && [ "$src" != "aur" ] && [ "$src" != "git" ] && is_i686 "$arch"; then
      auto_pin=1
    fi
    if [ -n "$pin" ]; then
      want="(pinned: $pin)"; status="pinned"
    elif [ "$auto_pin" -eq 1 ]; then
      want="(i686 auto-pin)"; status="built"
    else
      IFS=$'\t' read -r rurl rref < <(upstream_remote_url_ref "$arch" "$name" "$src") || true
      remote_sha=""
      [ -n "$rurl" ] && remote_sha="$(remote_head_sha "$rurl" "$rref")"
      last_sha=""
      [ -f "$commits_dir/$name" ] && last_sha="$(<"$commits_dir/$name")"
      if [ -z "$remote_sha" ]; then
        want="(unreachable)"; status="built"
      elif [ -z "$last_sha" ]; then
        want="${remote_sha:0:8} (no baseline)"; status="built"
      elif [ "$remote_sha" = "$last_sha" ]; then
        want="${remote_sha:0:8}"; status="ok"
      else
        want="${remote_sha:0:8}"; status="DUE"; due=$((due + 1))
      fi
    fi
  fi
  printf '%-22s %-13s %-13s %-9s %s\n' "$name" "$have" "$want" "$status" "$origin"
done < <(effective_packages "$arch")

log "update-check [$arch]: $due package(s) flagged (DUE/missing)"
