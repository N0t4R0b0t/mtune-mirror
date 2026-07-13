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

# Resolve a package's build dir into $work/<pkg>; echoes the dir or fails.
resolve_src() {
  local pkg="$1" dest="$work/$1"
  rm -rf "$dest"; install -d "$work"
  local localdir="$PKGMIRROR_ROOT/pkgbuilds/$arch/$pkg"
  if [ -f "$localdir/PKGBUILD" ]; then
    cp -r "$localdir" "$dest"; printf '%s\n' "$dest"; return 0
  fi
  if [ "$(toml_get "$conf" base)" = "x86_64" ]; then
    ( cd "$work" && pkgctl repo clone --protocol https "$pkg" ) >/dev/null 2>&1 \
      || { warn "pkgctl clone failed for '$pkg'"; return 1; }
    [ -f "$dest/PKGBUILD" ] && { printf '%s\n' "$dest"; return 0; }
    warn "no PKGBUILD after clone for '$pkg'"; return 1
  fi
  warn "no local PKGBUILD for i686 '$pkg' (upstream i686 fetch unimplemented)"; return 1
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

# run one package and record its result for later aggregation.
run_pkg() {
  local pkg="$1" slot="$2" rd="$3" p0 result ver
  p0="$(date +%s)"
  if build_pkg "$pkg" "build$slot"; then result="ok"; else result="failed"; fi
  ver="$(repo_version "$arch" "$pkg")"
  printf '%s\t%s\t%s\t%s\n' "$pkg" "$result" "$ver" "$(( $(date +%s) - p0 ))" > "$rd/$pkg"
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

run_build() {
  local names=(); local n
  while IFS= read -r n; do [ -n "$n" ] && names+=("$n"); done < <(selected_names)
  [ "${#names[@]}" -gt 0 ] || { warn "no packages selected for '$arch'"; return 0; }

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
    IFS=$'\t' read -r pkg result ver secs < "$rd/$n"
    if [ "$result" = "ok" ]; then ok+=("$pkg"); else failed+=("$pkg"); fi
    entries+=("{\"name\":\"$pkg\",\"result\":\"$result\",\"version\":\"${ver:-}\",\"seconds\":${secs:-0}}")
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

# Respect a global pause (see bin/control.sh) so scheduled/manual builds don't run
# when the operator has freed the box.
if [ -f "$PKGMIRROR_DATA/state/paused" ]; then
  log "builds are PAUSED — skipping $arch (resume with: bin/control.sh resume)"
  exit 0
fi

with_lock "build-$arch" run_build
