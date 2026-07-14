#!/usr/bin/env bash
# bin/build.sh <arch> [--group <g>] [--pkg <name>] [--force] [--jobs N]
#
# Builds packages for <arch> in its devtools chroot, tuned with the arch's CFLAGS.
# Selection:
#   (default)      the arch's full effective set = enabled groups ∪ per-arch extras
#   --group <g>    just that group's members
#   --pkg <name>   just one package
#
# Parallelism: up to `build_concurrency` packages build at once (config/pkgmirror.toml,
# or --jobs N), each in its own named chroot copy, with make's -j split across the
# concurrent builds. Per-arch serialized via flock; a failing package is logged and
# skipped, never aborting the batch.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

arch="${1:?usage: build.sh <arch> [--group <g>] [--pkg <name>] [--force] [--jobs N]}"; shift || true
group=""; onepkg=""; force=0; jobs_override=""
while [ $# -gt 0 ]; do
  case "$1" in
    --group) group="$2"; shift 2 ;;
    --pkg)   onepkg="$2"; shift 2 ;;
    --jobs)  jobs_override="$2"; shift 2 ;;
    --force) force=1; shift ;;
    *) die "unknown arg: $1" ;;
  esac
done
conf="$(arch_conf "$arch")" || exit 1
chroot_base="$PKGMIRROR_DATA/chroots/$arch"
work="$PKGMIRROR_DATA/work/$arch"
[ -f "$chroot_base/root/.pkgmirror-ready" ] || die "chroot for '$arch' not bootstrapped"
# The chroot's makepkg.conf is tuned with this arch's CFLAGS at bootstrap time.

# al32_pin_tag <pkg> — for i686 arches, the Arch git tag matching the version
# archlinux32 currently ships for <pkg>. archlinux32 lags upstream Arch and rebuilds
# Arch's PKGBUILDs at pinned revisions, so building Arch HEAD instead resolves deps
# against a dependency graph the archlinux32 repo doesn't have yet (e.g. the
# glib2/glib2-devel split, newer sonames) AND would produce a package too new to
# install on the archlinux32 target. We therefore pin each i686 build to the tag for
# the version archlinux32 ships, read from the chroot's synced sync DB.
#   archlinux32 version -> Arch tag:  strip the archlinux32 sub-rel (trailing ".N"),
#   then map the epoch colon to a dash (git refs can't contain ':').
#   e.g. 7.1.0-1.0 -> 7.1.0-1 ;  2:5.1.2-1.0 -> 2-5.1.2-1
# Echoes the tag, or empty if the package isn't in the archlinux32 repo (DB miss).
al32_pin_tag() {
  local pkg="$1" v
  v="$(pacman --root "$chroot_base/root" --dbpath "$chroot_base/root/var/lib/pacman" \
        -Si "$pkg" 2>/dev/null | awk -F': ' '/^Version/{print $2; exit}')"
  [ -n "$v" ] || return 0
  v="${v%.*}"                 # drop archlinux32 sub-rel (.0/.1/...)
  printf '%s\n' "${v/:/-}"    # epoch ':' -> '-' to match the Arch git tag
}

# Resolve a package's build dir into $work/<pkg>; echoes the dir or fails.
resolve_src() {
  local pkg="$1" dest="$work/$1"
  rm -rf "$dest"; install -d "$work"
  local localdir="$PKGMIRROR_ROOT/pkgbuilds/$arch/$pkg"
  if [ -f "$localdir/PKGBUILD" ]; then
    cp -r "$localdir" "$dest"; printf '%s\n' "$dest"; return 0
  fi
  # Upstream: clone the packaging repo from Arch's GitLab. Packages that are
  # AUR-only or archlinux32-patched (e.g. mesa-amber) get a local override instead.
  ( cd "$work" && pkgctl repo clone --protocol https "$pkg" ) >/dev/null 2>&1 \
    || { warn "pkgctl clone failed for '$pkg' (AUR/patched? add a local PKGBUILD)"; return 1; }
  [ -f "$dest/PKGBUILD" ] || { warn "no PKGBUILD after clone for '$pkg'"; return 1; }
  # i686: pin to the archlinux32-shipped version so deps resolve and the output is
  # installable on the target. x86_64 tracks Arch HEAD (its repo IS current Arch).
  if is_i686 "$arch"; then
    local tag; tag="$(al32_pin_tag "$pkg")"
    if [ -z "$tag" ]; then
      warn "$pkg: not found in archlinux32 repo DB — building Arch HEAD (may fail)"
    elif ( cd "$dest" && git checkout -q "refs/tags/$tag" 2>/dev/null ); then
      # NB: resolve_src returns the build dir on stdout, so status goes to stderr.
      log "$pkg: pinned to archlinux32 version (tag $tag)" >&2
    else
      warn "$pkg: archlinux32 tag '$tag' missing upstream — building Arch HEAD (may fail)"
    fi
  fi
  printf '%s\n' "$dest"; return 0
}

# build_pkg <pkg> <chroot-copy-name> — build one package into the repo.
build_pkg() {
  local pkg="$1" copy="$2" srcdir
  srcdir="$(resolve_src "$pkg")" || return 1
  if [ "$force" -eq 0 ]; then
    local have want
    have="$(repo_version "$arch" "$pkg")"
    want="$(pkgbuild_version "$srcdir")"
    if [ -n "$have" ] && [ "$have" = "$want" ]; then
      log "$pkg: up to date ($have) — skipping (use --force to rebuild)"
      return 0
    fi
  fi
  log "Building $pkg for $arch (copy=$copy)"
  local wrap=""; is_i686 "$arch" && wrap="setarch i686"
  # makepkg args (after --): skip source-PGP checks and/or the check()/test suite.
  # Tests run tuned binaries on the build host's CPU, which may lack the target ISA.
  local mpk=()
  # i686 builds Arch's x86_64 PKGBUILDs in an i686 chroot -> skip the arch check.
  is_i686 "$arch" && mpk+=(--ignorearch)
  [ "$(config_get skip_pgp_check)" != "false" ] && mpk+=(--skippgpcheck)
  [ "$(config_get skip_check)" != "false" ] && mpk+=(--nocheck)
  local mkargs=(); [ "${#mpk[@]}" -gt 0 ] && mkargs=(-- "${mpk[@]}")
  if [ "$jobs" -gt 1 ]; then
    ( cd "$srcdir" && $wrap makechrootpkg -c -l "$copy" -r "$chroot_base" "${mkargs[@]}" ) 2>&1 | sed -u "s/^/[$pkg] /"
    [ "${PIPESTATUS[0]}" -eq 0 ] || { err "build failed: $pkg"; return 1; }
  else
    ( cd "$srcdir" && $wrap makechrootpkg -c -r "$chroot_base" "${mkargs[@]}" ) || { err "build failed: $pkg"; return 1; }
  fi
  local built=( "$srcdir"/*.pkg.tar.zst )
  [ -e "${built[0]}" ] || { err "no package produced: $pkg"; return 1; }
  "$PKGMIRROR_ROOT/bin/repo-sync.sh" "$arch" "${built[@]}"
}

# run one package and record its result for later aggregation. Also updates the
# live progress marker (state/<arch>/progress/<pkg>: "<status>\t<epoch>") so the
# dashboard can show, mid-sweep, which packages are building/done/pending. Each
# package owns its own marker, so parallel jobs never race writing it.
run_pkg() {
  local pkg="$1" slot="$2" rd="$3" p0 result ver logf=""
  p0="$(date +%s)"
  [ -n "$pdir" ] && printf 'building\t%s\n' "$p0" > "$pdir/$pkg"
  # Persist this attempt's full output to logs/<pkg>/<start>.log so the UI can
  # show historical build logs (journald reuses the arch unit and rotates, so it
  # can't serve a specific past build). Keyed by p0, which we also record in the
  # history entry below. tee keeps the live journald stream working too.
  if [ -n "$logbase" ] && mkdir -p "$logbase/$pkg" 2>/dev/null; then
    logf="$logbase/$pkg/$p0.log"
  fi
  if [ -n "$logf" ]; then
    if build_pkg "$pkg" "build$slot" > >(tee "$logf") 2>&1; then result="ok"; else result="failed"; fi
  else
    if build_pkg "$pkg" "build$slot"; then result="ok"; else result="failed"; fi
  fi
  ver="$(repo_version "$arch" "$pkg")"
  # fields: name, result, version, seconds, start-epoch (start keys the log file)
  printf '%s\t%s\t%s\t%s\t%s\n' "$pkg" "$result" "$ver" "$(( $(date +%s) - p0 ))" "$p0" > "$rd/$pkg"
  [ -n "$pdir" ] && printf '%s\t%s\n' "$result" "$p0" > "$pdir/$pkg"
  [ -n "$logf" ] && prune_logs "$logbase/$pkg"
}

# prune_logs <dir> — keep only the newest N per-package build logs so state/<arch>/
# logs doesn't grow without bound. N = config log_retention (default 20).
prune_logs() {
  local dir="$1" keep
  keep="$(config_get log_retention)"; keep="${keep:-20}"
  [ "$keep" -ge 1 ] 2>/dev/null || keep=20
  ls -1t "$dir"/*.log 2>/dev/null | tail -n +$((keep + 1)) | while IFS= read -r f; do rm -f "$f"; done
}

# selected package names
selected_names() {
  if [ -n "$onepkg" ]; then printf '%s\n' "$onepkg"
  elif [ -n "$group" ]; then group_members "$group"
  else effective_packages "$arch" | cut -f1
  fi
}

write_state() { # <start> <end> <overall> <entries-array-name>
  local start="$1" end="$2" overall="$3"; local -n _entries="$4"
  local dir="$PKGMIRROR_DATA/state/$arch"; mkdir -p "$dir" 2>/dev/null || return 0
  local filt="all"
  [ -n "$onepkg" ] && filt="pkg:$onepkg" || { [ -n "$group" ] && filt="group:$group"; }
  local pkgs; local IFS=,; pkgs="${_entries[*]}"
  local json="{\"arch\":\"$arch\",\"start\":$start,\"end\":$end,\"filter\":\"$filt\",\"status\":\"$overall\",\"jobs\":$jobs,\"packages\":[$pkgs]}"
  printf '%s\n' "$json" > "$dir/last-build.json"
  printf '%s\n' "$json" >> "$dir/history.jsonl"
}

# --- live build descriptor --------------------------------------------------
# current.json advertises the in-flight sweep (unit, filter, selected packages)
# so the dashboard can show what's running and reattach the log console to it.
# Per-package status lives alongside in progress/<pkg>; both are cleared on exit.
write_current() { # <state-dir> <start> <names...>
  local sdir="$1" start="$2"; shift 2
  local filt="all"
  [ -n "$onepkg" ] && filt="pkg:$onepkg" || { [ -n "$group" ] && filt="group:$group"; }
  local list="" n
  for n in "$@"; do list="${list:+$list,}\"$n\""; done
  printf '{"unit":"%s","arch":"%s","filter":"%s","started":%s,"jobs":%s,"total":%s,"packages":[%s]}\n' \
    "${PKGMIRROR_UNIT:-}" "$arch" "$filt" "$start" "$jobs" "$#" "$list" > "$sdir/current.json"
}
clear_current() { rm -f "$1/current.json"; rm -rf "$1/progress"; }

# Refresh the chroot root's package databases from the arch's own mirrors (via the
# chroot's pacman.conf, NOT the container's). i686 arches need this so al32_pin_tag
# reads current archlinux32 versions; harmless to keep fresh for x86_64 too. Runs
# once per sweep, before any build copies the root. Best-effort: a stale DB only
# means a slightly out-of-date pin, so failure here doesn't abort the sweep.
sync_chroot_db() {
  local wrap=""; is_i686 "$arch" && wrap="setarch i686"
  $wrap sudo pacman -Sy --noconfirm \
    --config "$chroot_base/root/etc/pacman.conf" \
    --root "$chroot_base/root" \
    --dbpath "$chroot_base/root/var/lib/pacman" >/dev/null 2>&1 \
    || warn "chroot DB sync failed for '$arch' (pins may be stale)"
}

run_build() {
  local names=(); local n
  while IFS= read -r n; do [ -n "$n" ] && names+=("$n"); done < <(selected_names)
  [ "${#names[@]}" -gt 0 ] || { warn "no packages selected for '$arch'"; return 0; }
  sync_chroot_db

  # concurrency: min(configured, #packages); split make -j across jobs.
  jobs="${jobs_override:-$(config_get build_concurrency)}"; jobs="${jobs:-1}"
  [ "$jobs" -ge 1 ] 2>/dev/null || jobs=1
  [ "$jobs" -gt "${#names[@]}" ] && jobs="${#names[@]}"
  local ncpu; ncpu="$(nproc)"
  local makej=$(( ncpu / jobs )); [ "$makej" -lt 2 ] && makej=2
  # Set the chroot's make -j for this run (root-owned; we hold the arch lock).
  sudo sed -i -E "s|^MAKEFLAGS=.*|MAKEFLAGS=\"-j$makej\"|" "$chroot_base/root/etc/makepkg.conf" 2>/dev/null || true
  log "building ${#names[@]} package(s) for $arch — jobs=$jobs, make -j$makej"

  local start_ts; start_ts="$(date +%s)"
  local rd; rd="$(mktemp -d)"

  # publish the live descriptor: mark every package pending, advertise the run,
  # and clear it on exit (covers success, failure, and set -e aborts).
  local sdir="$PKGMIRROR_DATA/state/$arch"
  pdir="$sdir/progress"
  logbase="$sdir/logs"; mkdir -p "$logbase" 2>/dev/null || logbase=""
  if mkdir -p "$pdir" 2>/dev/null; then
    trap "clear_current '$sdir'" EXIT
    rm -f "$pdir"/* 2>/dev/null || true
    for n in "${names[@]}"; do printf 'pending\t0\n' > "$pdir/$n"; done
    write_current "$sdir" "$start_ts" "${names[@]}"
  else
    pdir=""
  fi

  if [ "$jobs" -le 1 ]; then
    for n in "${names[@]}"; do run_pkg "$n" 0 "$rd"; done
  else
    local fifo="$rd/.slots"; mkfifo "$fifo"; exec {sfd}<>"$fifo"; rm -f "$fifo"
    local i; for ((i = 0; i < jobs; i++)); do printf '%s\n' "$i" >&"$sfd"; done
    for n in "${names[@]}"; do
      local slot; read -r -u "$sfd" slot
      ( run_pkg "$n" "$slot" "$rd"; printf '%s\n' "$slot" >&"$sfd" ) &
    done
    wait
    exec {sfd}>&-
  fi

  # aggregate results
  local ok=() failed=() entries=() pkg result ver secs
  for n in "${names[@]}"; do
    [ -f "$rd/$n" ] || continue
    IFS=$'\t' read -r pkg result ver secs pstart < "$rd/$n"
    if [ "$result" = "ok" ]; then ok+=("$pkg"); else failed+=("$pkg"); fi
    entries+=("{\"name\":\"$pkg\",\"result\":\"$result\",\"version\":\"${ver:-}\",\"seconds\":${secs:-0},\"start\":${pstart:-0}}")
  done
  rm -rf "$rd"

  local overall="ok"; [ "${#failed[@]}" -gt 0 ] && overall="failed"
  write_state "$start_ts" "$(date +%s)" "$overall" entries

  log "build summary [$arch]: ${#ok[@]} ok, ${#failed[@]} failed"
  [ "${#ok[@]}"     -gt 0 ] && log "  ok:     ${ok[*]}"
  [ "${#failed[@]}" -gt 0 ] && warn "  failed: ${failed[*]}"
  [ "${#failed[@]}" -eq 0 ]
}

jobs=1  # set in run_build; declared here for build_pkg's visibility
pdir="" # progress dir; set in run_build, read by run_pkg (empty = no live state)
logbase="" # per-package log dir (state/<arch>/logs); set in run_build (empty = off)

# Respect a global pause (see bin/control.sh) so scheduled/manual builds don't run
# when the operator has freed the box.
if [ -f "$PKGMIRROR_DATA/state/paused" ]; then
  log "builds are PAUSED — skipping $arch (resume with: bin/control.sh resume)"
  exit 0
fi

with_lock "build-$arch" run_build
