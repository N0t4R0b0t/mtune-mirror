#!/usr/bin/env bash
# bin/flush-cache.sh [<arch>]
#
# Clears the shared pacman package cache and force-refreshes sync DBs.
#
# The container's pacman cache dir (`pacman-conf CacheDir`) is shared across
# every arch's chroot -- makechrootpkg bind-mounts it into each build copy so
# downloads aren't repeated per arch. A stale or corrupted cached
# .pkg.tar.zst (an interrupted download, or a same-name/same-version file
# left behind by a different arch's rebuild) makes the NEXT build's dependency
# install fail with "corrupted package (checksum)" or "signature is invalid"
# -- these look like real integrity problems but are almost always just a
# stale shared cache. Cache files are deleted directly rather than via
# `pacman -Scc`: that command's own "remove ALL files from cache?" prompt
# defaults to N, and --noconfirm answers prompts with their default rather
# than forcing yes -- so `pacman -Scc --noconfirm` silently leaves every file
# in place (confirmed empirically; the cache stayed at 621M/484 files across
# a full -Scc run). A cache clear alone also doesn't reliably fix this if a
# chroot's own sync DB is stale/mismatched (see bin/build.sh's
# sync_chroot_db) -- both need refreshing together, which is what this does.
#
# With no argument: flushes the shared cache once, then force-refreshes every
# bootstrapped arch's sync DB. With <arch>: same cache flush (it's shared, so
# there's no per-arch version), but only that arch's sync DB is refreshed.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

target_arch="${1:-}"
[ -z "$target_arch" ] || arch_conf "$target_arch" >/dev/null || exit 1

cache_dir="$(pacman-conf CacheDir 2>/dev/null | head -1)"
cache_dir="${cache_dir:-/var/cache/pacman/pkg/}"

log "flushing shared pacman cache: $cache_dir"
sudo find "$cache_dir" -mindepth 1 -delete 2>&1 \
  || warn "cache flush reported errors (continuing)"

refresh_db() {
  local arch="$1" wrap=""
  local chroot_base="$PKGMIRROR_DATA/chroots/$arch"
  if [ ! -f "$chroot_base/root/.pkgmirror-ready" ]; then
    warn "skip $arch: chroot not bootstrapped"
    return 0
  fi
  is_i686 "$arch" && wrap="setarch i686"
  log "refreshing sync DB for $arch"
  $wrap sudo pacman -Syy --noconfirm \
    --config "$chroot_base/root/etc/pacman.conf" \
    --root "$chroot_base/root" \
    --dbpath "$chroot_base/root/var/lib/pacman" >/dev/null 2>&1 \
    || warn "sync DB refresh failed for '$arch'"
}

if [ -n "$target_arch" ]; then
  refresh_db "$target_arch"
else
  for_each_arch refresh_db
fi
log "cache flush complete"
