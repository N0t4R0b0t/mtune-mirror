#!/usr/bin/env bash
# bin/flush-cache.sh
#
# Clears the shared pacman package cache and force-refreshes EVERY
# bootstrapped arch's sync DB. No per-arch mode: reproduced live
# (2026-07-20) that refreshing only one arch is actively unsafe, not just
# incomplete. A same-name/same-version package can be signed differently
# per arch (e.g. vanilla Arch's `mesa`/`libdrm`/`libpng` vs Manjaro's own
# rebuild of the identical version string) -- if one arch's build
# repopulates the shared cache with ITS trust domain's copy, the next
# build on a DIFFERENT arch that needs the same filename fails with
# "signature is invalid" / "corrupted package", because pacman is
# validating that cached file against the wrong arch's keyring. This is
# exactly what happened when a btver1 mesa rebuild (using this script's
# earlier single-arch mode) left Arch-signed libpng/libdrm/mesa in the
# shared cache, and a manjaro sunshine build picked them up next and
# failed dependency install against Manjaro's keyring. Since the cache is
# shared and any arch's build can dirty it for every other arch, the only
# safe operation is "refresh everyone, every time."
#
# Cache files are deleted directly rather than via `pacman -Scc`: that
# command's own "remove ALL files from cache?" prompt defaults to N, and
# --noconfirm answers prompts with their default rather than forcing yes --
# so `pacman -Scc --noconfirm` silently leaves every file in place
# (confirmed empirically; the cache stayed at 621M/484 files across a full
# -Scc run). A cache clear alone also doesn't reliably fix this if a
# chroot's own sync DB is stale/mismatched (see bin/build.sh's
# sync_chroot_db) -- both need refreshing together, which is what this does.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

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

for_each_arch refresh_db
log "cache flush complete"
