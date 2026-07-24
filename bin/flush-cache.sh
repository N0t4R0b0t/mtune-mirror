#!/usr/bin/env bash
# bin/flush-cache.sh
#
# Manual escape hatch: clears every bootstrapped arch's pacman package cache
# and force-refreshes its sync DB. Each arch now has its own CacheDir
# (installer/bootstrap-chroot.sh sets /var/cache/pacman/pkg-<arch>/ per
# chroot, since arch-nspawn reads CacheDir straight out of that chroot's own
# pacman.conf), so the cross-arch trust collision this script was originally
# written to clean up after -- a same-name/same-version package signed
# differently per arch (e.g. vanilla Arch's `mesa`/`libdrm`/`libpng` vs
# Manjaro's own rebuild of the identical version string) landing in one
# shared cache file and failing "signature is invalid"/"corrupted package"
# on whichever arch built second -- is now structurally impossible, not just
# handled after the fact. This script still loops over every arch (not a
# per-arch flag) purely for consistency/simplicity now that it's just
# routine cache hygiene, not a safety-critical fleet-wide operation.
#
# Cache files are deleted directly rather than via `pacman -Scc`: that
# command's own "remove ALL files from cache?" prompt defaults to N, and
# --noconfirm answers prompts with their default rather than forcing yes --
# so `pacman -Scc --noconfirm` silently leaves every file in place
# (confirmed empirically; the cache stayed at 621M/484 files across a full
# -Scc run). A cache clear alone also doesn't reliably fix a stale sync DB
# (see bin/build.sh's sync_chroot_db) -- both need refreshing together,
# which is what this does.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

flush_one() {
  local arch="$1"
  local chroot_base="$PKGMIRROR_DATA/chroots/$arch"
  if [ ! -f "$chroot_base/root/.pkgmirror-ready" ]; then
    warn "skip $arch: chroot not bootstrapped"
    return 0
  fi
  local cache_dir
  cache_dir="$(pacman-conf --config "$chroot_base/root/etc/pacman.conf" CacheDir 2>/dev/null | head -1)"
  cache_dir="${cache_dir:-/var/cache/pacman/pkg/}"
  log "flushing pacman cache for '$arch': $cache_dir"
  sudo find "$cache_dir" -mindepth 1 -delete 2>&1 \
    || warn "cache flush reported errors for '$arch' (continuing)"
}

refresh_db() {
  local arch="$1" wrap=""
  local chroot_base="$PKGMIRROR_DATA/chroots/$arch"
  if [ ! -f "$chroot_base/root/.pkgmirror-ready" ]; then
    warn "skip $arch: chroot not bootstrapped"
    return 0
  fi
  flush_one "$arch"
  is_i686 "$arch" && wrap="setarch i686"
  log "refreshing sync DB for $arch"
  $wrap sudo pacman -Syy --noconfirm \
    --config "$chroot_base/root/etc/pacman.conf" \
    --root "$chroot_base/root" \
    --dbpath "$chroot_base/root/var/lib/pacman" >/dev/null 2>&1 \
    || warn "sync DB refresh failed for '$arch'"
}

for_each_arch refresh_db
log "cache flush complete"
