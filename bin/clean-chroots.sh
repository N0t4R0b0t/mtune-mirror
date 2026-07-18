#!/usr/bin/env bash
# bin/clean-chroots.sh [<arch>]
#
# Reclaims build-chroot-copy space left behind by a completed or failed build.
# makechrootpkg's own -c flag (which build.sh always passes) re-syncs a copy
# from the base chroot right before its NEXT use, but a copy that fails (or
# just isn't reused soon) sits full until then. Several copies are
# individually tmpfs-mounted (installer/container-setup.sh) -- on a
# memory-limited container that's RAM held hostage indefinitely, squeezing
# every other concurrent build sharing the box. This makes reclaiming
# explicit and immediate instead of implicit and delayed.
#
# Root-caused 2026-07-18: linux-btver1 OOM-killed the whole container twice
# in a row partly because the previous failed attempt's ~9GB copy was still
# sitting there uncleaned, leaving no headroom for the next attempt.
#
# Only ever touches a copy it can acquire a non-blocking flock on -- the SAME
# "<copydir>.lock" file makechrootpkg itself holds for a build's duration
# (`lock 9 "$copydir.lock"` in makechrootpkg) -- so an in-progress build is
# always left alone. Safe to run concurrently with builds and on a timer.
# Called from build.sh at the start and end of every sweep, and independently
# on a periodic timer (systemd/pkgmirror-clean-chroots.timer) as a backstop.
#
# Empties each idle copy's CONTENTS in place -- never rmdir/unmounts the copy
# dir itself. An emptied copy is exactly equivalent to one makechrootpkg has
# never seen: `[[ ! -d $copydir ]] || (( clean_first ))` re-syncs from the
# base chroot either way, so this can never leave a copy in a state
# makechrootpkg doesn't already know how to recover from.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

target_arch="${1:-}"

# clean_copy <arch> <copy-dir> -- reclaim one copy if it's idle.
clean_copy() {
  local arch="$1" dir="$2" name lockfile before after reclaimed
  name="$(basename "$dir")"
  [ "$name" = "root" ] && return 0   # the base chroot itself -- never touched
  lockfile="$dir.lock"
  [ -e "$lockfile" ] || return 0     # no sibling .lock -- not a real copy, skip

  # `|| true` inside the substitution, not after: du exits non-zero on any
  # unreadable file under a full chroot tree (pkgmirror isn't root) even
  # though it still prints a partial total on stdout -- with pipefail active,
  # that non-zero status would otherwise kill the whole script right here.
  before="$(du -sm "$dir" 2>/dev/null | cut -f1 || true)"; before="${before:-0}"
  [ "$before" -le 1 ] && return 0    # already essentially empty -- nothing to do

  # The lock file is root-owned (makechrootpkg's own `lock 9 "$copydir.lock"`
  # runs as root), so pkgmirror can't open it directly -- sudo (pkgmirror has
  # full NOPASSWD sudo, installer/container-setup.sh) so flock's own -c
  # command mode can open+lock+run in one privileged, non-blocking step.
  # Fails cleanly (skip this copy) whether that's because a real build
  # currently holds the lock or for any other reason.
  sudo flock -n "$lockfile" -c "find '$dir' -mindepth 1 -maxdepth 1 -exec rm -rf {} +" \
    >/dev/null 2>&1 || return 0

  after="$(du -sm "$dir" 2>/dev/null | cut -f1 || true)"; after="${after:-0}"
  reclaimed=$(( before - after ))
  [ "$reclaimed" -gt 0 ] && log "clean-chroots: $arch/$name reclaimed ${reclaimed}MB"
}

# clean_arch <arch> -- sweep every copy under this arch's chroot dir.
clean_arch() {
  local arch="$1" base d
  base="$PKGMIRROR_DATA/chroots/$arch"
  [ -d "$base" ] || return 0
  for d in "$base"/*/; do
    [ -d "$d" ] || continue
    clean_copy "$arch" "${d%/}"
  done
}

if [ -n "$target_arch" ]; then
  clean_arch "$target_arch"
else
  while IFS= read -r a; do clean_arch "$a"; done < <(arch_names)
fi
