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

# makechrootpkg picks its host build-user from ${SUDO_USER:-$USER}, which is
# only reliably set in an interactive login shell — a systemd service or a
# bare `docker exec ... bash -c` invocation can leave both empty, causing
# `id: '': no such user` / `Could not download sources.`. Pin it explicitly
# via id -un, which works regardless of the calling environment.
export USER="${USER:-$(id -un)}"

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

# al32_bump_pkgrel <pkg> <epoch> <pkgver> <pkgrel> — the sub-rel to actually
# BUILD with (pkgrel becomes "<pkgrel>.<N>"), so our own i686 package wins
# pacman's vercmp against whatever archlinux32 currently publishes for the
# same pkgver-pkgrel -- even when our own repo is already listed first in
# pacman.conf. archlinux32 appends its own rebuild-iteration sub-rel (pkgrel
# "6" -> "6.2"); a bare, unmodified pkgrel can never out-vercmp that,
# regardless of repo priority (confirmed 2026-07-15: every tuned atom build
# compared as OLDER than the archlinux32 package already installed on a
# client, so none of them could ever actually be picked up by `pacman -Syu`).
# If archlinux32 currently ships this EXACT pkgver-pkgrel, go one sub-rel
# higher than theirs; otherwise (our pkgver/pkgrel already exceeds what
# archlinux32 has -- e.g. an explicit version-bump override) default to "1",
# which keeps every one of our own builds carrying a sub-rel component so
# later rebuilds always have something consistent to compare against.
al32_bump_pkgrel() {
  local pkg="$1" want_epoch="${2:-0}" want_pkgver="$3" want_pkgrel="$4"
  local raw have_epoch have_base have_subrel next=1
  raw="$(pacman --root "$chroot_base/root" --dbpath "$chroot_base/root/var/lib/pacman" \
        -Si "$pkg" 2>/dev/null | awk -F': ' '/^Version/{print $2; exit}')"
  if [ -n "$raw" ]; then
    have_epoch=0
    case "$raw" in *:*) have_epoch="${raw%%:*}"; raw="${raw#*:}" ;; esac
    have_base="${raw%.*}"      # pkgver-pkgrel, sub-rel stripped
    have_subrel="${raw##*.}"   # trailing .N
    if [ "$have_epoch" = "$want_epoch" ] && [ "$have_base" = "$want_pkgver-$want_pkgrel" ] \
       && [[ "$have_subrel" =~ ^[0-9]+$ ]]; then
      next=$((have_subrel + 1))
    fi
  fi
  printf '%s\n' "$next"
}

# Resolve a package's build dir into $work/<pkg>; echoes the dir or fails.
# Local PKGBUILD always wins (unchanged). Otherwise: source=aur clones from AUR;
# source=git clones an arbitrary repo (config/packages/<arch>.toml url/ref — a
# fully custom package with no Arch/AUR equivalent, e.g. your own hand-tuned
# kernel); source=url plain-HTTP-fetches a PKGBUILD (+ config's files list)
# from a directory URL instead of cloning — for a CI pipeline that publishes
# an already-substituted PKGBUILD to a static host rather than a git repo;
# everything else clones Arch's GitLab packaging repo. After fetch,
# applies (in order) a version pin, then patches, then a post_fetch hook — see
# config/overrides/<arch>.toml (bin/lib/common.sh pkg_override) and
# pkgbuilds/<arch>/<pkg>/{patches,hooks}/.
resolve_src() {
  local pkg="$1" dest="$work/$1"
  rm -rf "$dest"; install -d "$work"
  local localdir="$PKGMIRROR_ROOT/pkgbuilds/$arch/$pkg"
  if [ -f "$localdir/PKGBUILD" ]; then
    cp -r "$localdir" "$dest"; printf '%s\n' "$dest"; return 0
  fi

  local src; src="$(explicit_source "$arch" "$pkg")"
  if [ "$src" = "aur" ]; then
    ( cd "$work" && git clone -q "https://aur.archlinux.org/$pkg.git" ) >/dev/null 2>&1 \
      || { warn "AUR clone failed for '$pkg'"; return 1; }
  elif [ "$src" = "git" ]; then
    local giturl="" gitref=""
    IFS=$'\t' read -r giturl gitref < <(pkg_giturl "$arch" "$pkg") || true
    [ -n "$giturl" ] || { warn "$pkg: source=git but no url configured"; return 1; }
    ( cd "$work" && git clone -q ${gitref:+-b "$gitref"} "$giturl" "$pkg" ) >/dev/null 2>&1 \
      || { warn "git clone failed for '$pkg' ($giturl${gitref:+ @ $gitref})"; return 1; }
  elif [ "$src" = "url" ]; then
    # Plain HTTP fetch, not a clone -- for CI pipelines that publish an
    # already-substituted PKGBUILD (e.g. to a static bucket) rather than a
    # clonable git repo. $dest isn't a git working tree, so it's excluded
    # from the archlinux32 pin/checkout logic below (al32_eligible).
    local baseurl="" filelist=""
    IFS=$'\t' read -r baseurl filelist < <(pkg_urlspec "$arch" "$pkg") || true
    [ -n "$baseurl" ] || { warn "$pkg: source=url but no url configured"; return 1; }
    baseurl="${baseurl%/}"
    install -d "$dest"
    ( cd "$dest" && curl -fsSL -o PKGBUILD "$baseurl/PKGBUILD" ) >/dev/null 2>&1 \
      || { warn "url fetch failed for '$pkg' PKGBUILD ($baseurl)"; return 1; }
    if [ -n "$filelist" ]; then
      local uf furl
      IFS=',' read -ra _urlfiles <<< "$filelist"
      for uf in "${_urlfiles[@]}"; do
        [ -n "$uf" ] || continue
        furl="$baseurl/$uf"
        ( cd "$dest" && curl -fsSL -o "$uf" "$furl" ) >/dev/null 2>&1 \
          || { warn "url fetch failed for '$pkg' file '$uf' ($furl)"; return 1; }
      done
    fi
  else
    # pkgctl only clones packages it considers "active"; a package Arch has since
    # dropped from core/extra (e.g. mesa-amber, still archlinux32-maintained for
    # pre-gen4 Intel GL) keeps its packaging git repo, just orphaned — pkgctl
    # balks at it, but a plain clone of the same GitLab repo works fine.
    ( cd "$work" && pkgctl repo clone --protocol https "$pkg" ) >/dev/null 2>&1 \
      || ( cd "$work" && rm -rf "$pkg" && git clone -q \
             "https://gitlab.archlinux.org/archlinux/packaging/packages/$pkg.git" ) >/dev/null 2>&1 \
      || { warn "clone failed for '$pkg' (AUR-only? try source=aur, or add a local PKGBUILD)"; return 1; }
  fi
  [ -f "$dest/PKGBUILD" ] || { warn "no PKGBUILD after clone for '$pkg'"; return 1; }

  local ov_pin="" ov_skipcheck="" ov_margs="" ov_patches="" ov_mem="" ov_notes=""
  IFS="$pkg_override_sep" read -r ov_pin ov_skipcheck ov_margs ov_patches ov_mem ov_notes < <(pkg_override "$arch" "$pkg") || true

  # --- version pin: explicit override wins; else the automatic archlinux32 pin
  # for i686+upstream (unchanged); AUR/git sources have no archlinux32 version
  # relationship, so they're only pinned when explicitly requested.
  local al32_eligible=0
  [ "$src" != "aur" ] && [ "$src" != "git" ] && [ "$src" != "url" ] && is_i686 "$arch" && al32_eligible=1
  local tag=""
  if [ -n "$ov_pin" ]; then
    tag="$ov_pin"
  elif [ "$al32_eligible" -eq 1 ]; then
    tag="$(al32_pin_tag "$pkg")"
    [ -z "$tag" ] && warn "$pkg: not found in archlinux32 repo DB — building Arch HEAD (may fail)"
  fi
  if [ -n "$tag" ]; then
    if ( cd "$dest" && git checkout -q "refs/tags/$tag" 2>/dev/null ); then
      # NB: resolve_src returns the build dir on stdout, so status goes to stderr.
      log "$pkg: pinned to $([ -n "$ov_pin" ] && printf override || printf archlinux32) version (tag $tag)" >&2
    else
      warn "$pkg: pin tag '$tag' not found upstream — building HEAD (may fail)"
    fi
  fi

  # --- sub-rel bump: see al32_bump_pkgrel. Same eligibility as the archlinux32
  # pin above (i686, upstream-sourced) regardless of whether the pin itself
  # came from an override or the auto-pin -- either way archlinux32 may
  # already publish a same-or-lower-looking version that would otherwise win.
  if [ "$al32_eligible" -eq 1 ]; then
    local cur_epoch="" cur_pkgver="" cur_pkgrel=""
    IFS='|' read -r cur_epoch cur_pkgver cur_pkgrel < <(
      set +eu; source "$dest/PKGBUILD" >/dev/null 2>&1
      printf '%s|%s|%s\n' "${epoch:-0}" "${pkgver:-}" "${pkgrel:-}"
    )
    if [ -n "$cur_pkgver" ] && [ -n "$cur_pkgrel" ]; then
      local subrel; subrel="$(al32_bump_pkgrel "$pkg" "$cur_epoch" "$cur_pkgver" "$cur_pkgrel")"
      sed -i "s/^pkgrel=.*/pkgrel=${cur_pkgrel}.${subrel}/" "$dest/PKGBUILD"
      log "$pkg: pkgrel -> ${cur_pkgrel}.${subrel} (so this build outranks archlinux32's own sub-rel)" >&2
    fi
  fi

  # --- patches: applied in the order listed, aborting the package on failure.
  if [ -n "$ov_patches" ]; then
    local pf pdir_patches="$localdir/patches" plist
    IFS=',' read -ra plist <<< "$ov_patches"
    for pf in "${plist[@]}"; do
      [ -f "$pdir_patches/$pf" ] || { warn "$pkg: patch '$pf' not found in $pdir_patches"; return 1; }
      ( cd "$dest" && patch -p1 < "$pdir_patches/$pf" ) >&2 \
        || { warn "$pkg: patch '$pf' failed to apply"; return 1; }
      log "$pkg: applied patch $pf" >&2
    done
  fi

  # --- hook: arbitrary shell for anything the declarative fields don't cover
  # (e.g. editing a PKGBUILD's depends() array). Same trust level as PKGBUILD
  # itself. Nonzero exit aborts the package.
  local hook="$localdir/hooks/post_fetch.sh"
  if [ -x "$hook" ]; then
    ( cd "$dest" && PKG="$pkg" ARCH="$arch" SRCDIR="$dest" "$hook" ) >&2 \
      || { warn "$pkg: post_fetch hook failed"; return 1; }
    log "$pkg: ran post_fetch hook" >&2
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
  # Re-sync the base chroot's own pacman DB right before this package's build
  # copies it, not just once at the top of the sweep. A --force sweep rebuilds
  # many packages sequentially; repo-sync.sh's `repo-add --remove` deletes a
  # superseded package's OLD file the moment a newer one is published, so any
  # later package in the same sweep that depends on an earlier one (built
  # minutes ago in this very sweep) would otherwise build its copy from a
  # stale DB snapshot still pointing at that now-deleted filename -> a 404
  # mid-build. Confirmed 2026-07-15: harfbuzz failed fetching a cairo file
  # repo-add had already pruned earlier in the same --force atom sweep.
  sync_chroot_db
  local wrap=""; is_i686 "$arch" && wrap="setarch i686"
  local ov_pin="" ov_skipcheck="" ov_margs="" ov_patches="" ov_mem="" ov_notes=""
  IFS="$pkg_override_sep" read -r ov_pin ov_skipcheck ov_margs ov_patches ov_mem ov_notes < <(pkg_override "$arch" "$pkg") || true
  # makepkg args (after --): skip source-PGP checks and/or the check()/test suite.
  # Tests run tuned binaries on the build host's CPU, which may lack the target ISA.
  local mpk=()
  # i686 builds Arch's x86_64 PKGBUILDs in an i686 chroot -> skip the arch check.
  is_i686 "$arch" && mpk+=(--ignorearch)
  [ "$(config_get skip_pgp_check)" != "false" ] && mpk+=(--skippgpcheck)
  # Per-package skip_check override wins over the global default.
  local skipcheck="${ov_skipcheck:-$(config_get skip_check)}"
  [ "$skipcheck" != "false" ] && mpk+=(--nocheck)
  if [ -n "$ov_margs" ]; then
    local extra=(); IFS=',' read -ra extra <<< "$ov_margs"
    mpk+=("${extra[@]}")
  fi
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
  # Record the upstream commit actually built, for update-check.sh's git ls-remote
  # comparison (only meaningful for non-local sources; $work/$pkg is a plain copy,
  # not a git checkout, for source=local — rev-parse fails harmlessly there).
  if [ "$result" = "ok" ]; then
    local built_sha; built_sha="$(git -C "$work/$pkg" rev-parse HEAD 2>/dev/null || true)"
    if [ -n "$built_sha" ]; then
      local commits_dir="$PKGMIRROR_DATA/state/$arch/commits"
      mkdir -p "$commits_dir" 2>/dev/null && printf '%s\n' "$built_sha" > "$commits_dir/$pkg"
    fi
  fi
  # fields: name, result, version, seconds, start-epoch (start keys the log file).
  # Separator is ASCII unit separator, not tab: tab is IFS *whitespace*, so an
  # empty field (version, when a build fails before producing a package) would
  # collapse and shift every field after it left on read (see pkg_override_sep).
  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$pkg" "$result" "$ver" "$(( $(date +%s) - p0 ))" "$p0" > "$rd/$pkg"
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
  [ -n "$onepkg" ] && filt="pkg:$(json_escape "$onepkg")" || { [ -n "$group" ] && filt="group:$(json_escape "$group")"; }
  local pkgs; local IFS=,; pkgs="${_entries[*]}"
  local json="{\"arch\":\"$(json_escape "$arch")\",\"start\":$start,\"end\":$end,\"filter\":\"$filt\",\"status\":\"$(json_escape "$overall")\",\"jobs\":$jobs,\"packages\":[$pkgs]}"
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
  [ -n "$onepkg" ] && filt="pkg:$(json_escape "$onepkg")" || { [ -n "$group" ] && filt="group:$(json_escape "$group")"; }
  local list="" n
  for n in "$@"; do list="${list:+$list,}\"$(json_escape "$n")\""; done
  printf '{"unit":"%s","arch":"%s","filter":"%s","started":%s,"jobs":%s,"total":%s,"packages":[%s]}\n' \
    "$(json_escape "${PKGMIRROR_UNIT:-}")" "$(json_escape "$arch")" "$filt" "$start" "$jobs" "$#" "$list" > "$sdir/current.json"
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

  # Reclaim any idle chroot copies this arch left dirty from an earlier
  # failure (see bin/clean-chroots.sh) before this sweep needs the headroom.
  "$PKGMIRROR_ROOT/bin/clean-chroots.sh" "$arch" || true

  sync_chroot_db

  # concurrency: min(configured, #packages); split make -j across jobs.
  jobs="${jobs_override:-$(config_get build_concurrency)}"; jobs="${jobs:-1}"
  [ "$jobs" -ge 1 ] 2>/dev/null || jobs=1
  [ "$jobs" -gt "${#names[@]}" ] && jobs="${#names[@]}"
  local ncpu; ncpu="$(nproc)"
  local makej=$(( ncpu / jobs )); [ "$makej" -lt 1 ] && makej=1
  # Memory-aware cap: parallel compilers are the dominant RAM consumer, and a heavy
  # C++ TU tuned with -O2 can peak around 1.5 GB in cc1plus. On a memory-limited
  # container, ncpu/jobs compilers per build × jobs builds OOM-kills cc1plus. Cap the
  # TOTAL concurrent compile jobs (makej across all `jobs` package builds) to what
  # MemTotal supports, so builds slow down instead of dying. build_mem_per_job_mb
  # (config/pkgmirror.toml) overrides the per-job estimate; raise container RAM to lift
  # the cap. A floor of 1 keeps builds moving on very small boxes.
  local mem_mb per_job max_total cap
  mem_mb="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"; mem_mb="${mem_mb:-0}"
  per_job="$(config_get build_mem_per_job_mb)"; per_job="${per_job:-1536}"
  # A single-package build (--pkg) can override the per-job estimate — e.g. a
  # kernel build wants far more headroom than the fleet-wide default. Only applies
  # to --pkg (a batch's -j is set once for the whole sweep, so a per-package
  # estimate can't sub-cap individual packages within a mixed group/all sweep).
  if [ -n "$onepkg" ]; then
    local ov_mem; ov_mem="$(pkg_override "$arch" "$onepkg" | cut -d "$pkg_override_sep" -f5)"
    if [ -n "$ov_mem" ] && [ "$ov_mem" -gt 0 ] 2>/dev/null; then
      log "$onepkg: override mem_per_job_mb=$ov_mem (was ${per_job}MB default)"
      per_job="$ov_mem"
    fi
  fi
  if [ "$mem_mb" -gt 0 ] 2>/dev/null && [ "$per_job" -gt 0 ] 2>/dev/null; then
    max_total=$(( mem_mb / per_job )); [ "$max_total" -lt 1 ] && max_total=1
    cap=$(( max_total / jobs )); [ "$cap" -lt 1 ] && cap=1
    if [ "$makej" -gt "$cap" ]; then
      log "RAM ${mem_mb}MB (~${per_job}MB/job) caps make -j to $cap (cpu-based was $makej)"
      makej="$cap"
    fi
  fi
  # Load ceiling: make -l stops spawning new jobs once system load exceeds this. It's
  # kernel-load based, so unlike -j it's shared across every concurrent build/sweep and
  # keeps N ad-hoc builds launched at once from oversubscribing the box (and starving the
  # web UI). Defaults to core count; config max_load=0 disables it.
  local maxload; maxload="$(config_get max_load)"; maxload="${maxload:-$ncpu}"
  local makeflags="-j$makej"
  [ "$maxload" -gt 0 ] 2>/dev/null && makeflags="$makeflags -l$maxload"
  # Exported (not written into the chroot's makepkg.conf via sed): makechrootpkg
  # already passes MAKEFLAGS through its fixed --preserve-env allowlist, and an
  # env var can't go stale the way a shared config file can. A file-based value
  # is only ever (re-)read by a chroot COPY at the moment build_pkg syncs it for
  # a new package -- a long-running package (a kernel build, openssl) sits in
  # its copy for the whole build, so if anything else ever touched root's
  # makepkg.conf mid-sweep (even from an unrelated later run once this sweep's
  # lock is free), an already-assigned copy would never see it and could end up
  # silently stuck on a stale or truncated MAKEFLAGS for its entire build.
  export MAKEFLAGS="$makeflags"
  log "building ${#names[@]} package(s) for $arch — jobs=$jobs, make $makeflags"

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
    IFS=$'\x1f' read -r pkg result ver secs pstart < "$rd/$n"
    if [ "$result" = "ok" ]; then ok+=("$pkg"); else failed+=("$pkg"); fi
    entries+=("{\"name\":\"$(json_escape "$pkg")\",\"result\":\"$(json_escape "$result")\",\"version\":\"$(json_escape "${ver:-}")\",\"seconds\":${secs:-0},\"start\":${pstart:-0}}")
  done
  rm -rf "$rd"

  local overall="ok"; [ "${#failed[@]}" -gt 0 ] && overall="failed"
  write_state "$start_ts" "$(date +%s)" "$overall" entries

  log "build summary [$arch]: ${#ok[@]} ok, ${#failed[@]} failed"
  [ "${#ok[@]}"     -gt 0 ] && log "  ok:     ${ok[*]}"
  [ "${#failed[@]}" -gt 0 ] && warn "  failed: ${failed[*]}"

  # Reclaim whatever this sweep itself left dirty -- most valuable after a
  # failure, since that copy would otherwise sit full until this arch's next
  # sweep reuses it (see bin/clean-chroots.sh).
  "$PKGMIRROR_ROOT/bin/clean-chroots.sh" "$arch" || true

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
