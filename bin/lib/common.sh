#!/usr/bin/env bash
# bin/lib/common.sh — shared helpers for the pkgmirror build tooling.
#
# Source this from any bin/ or installer/ script:
#     source "$(dirname "$(readlink -f "$0")")/lib/common.sh"   # from bin/
# It sets PKGMIRROR_ROOT to the repo root and exposes logging, locking,
# TOML access (via dasel), and arch iteration helpers.
#
# This file is the single point of dependency on the TOML parser: swap dasel
# for another parser here and nothing else changes.

# --- resolve repo root ------------------------------------------------------
# common.sh lives at <root>/bin/lib/common.sh
_common_self="$(readlink -f "${BASH_SOURCE[0]}")"
PKGMIRROR_ROOT="$(cd "$(dirname "$_common_self")/../.." && pwd)"
export PKGMIRROR_ROOT

# Runtime data root (chroots + served repos). Overridable for local testing.
: "${PKGMIRROR_DATA:=/srv/pkgmirror}"
export PKGMIRROR_DATA

# Resolve dasel to an absolute path: pct exec and some systemd contexts use a
# minimal PATH that excludes /usr/local/bin, where the static binary is installed.
if [ -z "${DASEL:-}" ]; then
  if   command -v dasel >/dev/null 2>&1; then DASEL="$(command -v dasel)"
  elif [ -x /usr/local/bin/dasel ];      then DASEL=/usr/local/bin/dasel
  elif [ -x /usr/bin/dasel ];            then DASEL=/usr/bin/dasel
  else DASEL=dasel; fi
fi

# --- logging ----------------------------------------------------------------
_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log()  { printf '%s [INFO]  %s\n' "$(_ts)" "$*"; }
warn() { printf '%s [WARN]  %s\n' "$(_ts)" "$*" >&2; }
err()  { printf '%s [ERROR] %s\n' "$(_ts)" "$*" >&2; }
die()  { err "$*"; exit 1; }

# json_escape <string> -> the string with \, ", and control chars escaped for
# safe embedding in a hand-built JSON string literal. Package names can't
# contain quotes (pacman restricts them to [a-zA-Z0-9@._+-]), but --pkg/--group
# values and notes/version fields are less constrained, so every interpolated
# field in write_state/write_current should go through this rather than assume
# safety case-by-case.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# --- TOML access (dasel v2) -------------------------------------------------
# Selectors are dasel-native; a leading dot is added if omitted, so callers can
# pass either 'chroot.mirror' or '.chroot.mirror'. Surrounding double quotes are
# stripped defensively (dasel string output has varied across versions).
_dasel_sel() { case "$1" in .*) printf '%s' "$1" ;; *) printf '.%s' "$1" ;; esac; }
# dasel v2 wraps scalar output in quotes (single for TOML strings). Strip one
# surrounding pair of either kind.
_strip_q() {
  local v="$1"
  case "$v" in
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s' "$v"
}

# toml_get <file> <selector>   -> prints scalar value, empty string if absent.
toml_get() {
  local file="$1" sel; sel="$(_dasel_sel "$2")"
  [ -f "$file" ] || { err "toml_get: no such file: $file"; return 1; }
  _strip_q "$("$DASEL" -f "$file" -r toml "$sel" 2>/dev/null || true)"
}

# toml_list <file> <selector>  -> prints newline-separated list values.
# e.g. toml_list packages/atom.toml 'package.all().name'
toml_list() {
  local file="$1" sel; sel="$(_dasel_sel "$2")"
  [ -f "$file" ] || { err "toml_list: no such file: $file"; return 1; }
  "$DASEL" -f "$file" -r toml "$sel" 2>/dev/null | while IFS= read -r line; do
    _strip_q "$line"; printf '\n'
  done
}

# --- arch iteration ---------------------------------------------------------
# arch_names -> newline-separated list of configured arch names (from filenames).
arch_names() {
  local f
  for f in "$PKGMIRROR_ROOT"/config/arches/*.toml; do
    [ -e "$f" ] || continue
    basename "$f" .toml
  done
}

# arch_conf <arch> -> path to that arch's registry file (validated).
arch_conf() {
  local arch="$1" f="$PKGMIRROR_ROOT/config/arches/$1.toml"
  [ -f "$f" ] || { err "unknown arch: $arch"; return 1; }
  printf '%s\n' "$f"
}

# for_each_arch <fn> -> calls fn with each arch name (build orchestration hook).
for_each_arch() {
  local fn="$1" a
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    "$fn" "$a"
  done < <(arch_names)
}

# is_i686 <arch> -> success if the arch's base is i686 (needs linux32 wrapping).
is_i686() {
  [ "$(toml_get "$(arch_conf "$1")" base)" = "i686" ]
}

# personality_wrap <arch> -- echoes the command prefix for build/chroot ops.
# i686 arches get `setarch i686`; x86_64 arches get nothing.
personality_wrap() {
  if is_i686 "$1"; then printf 'setarch i686 '; fi
}

# --- "local override wins" rule ---------------------------------------------
# pkgbuild_source_dir <arch> <pkg> [upstream_checkout_dir]
#   -> prints the local override dir if pkgbuilds/<arch>/<pkg>/PKGBUILD exists,
#      otherwise the provided upstream checkout dir (default: empty).
# This encodes the rule that a local patched PKGBUILD is never overwritten by
# an upstream sync. Consumed by build.sh / update-check.sh in Increment 2.
pkgbuild_source_dir() {
  local arch="$1" pkg="$2" upstream="${3:-}"
  local local_dir="$PKGMIRROR_ROOT/pkgbuilds/$arch/$pkg"
  if [ -f "$local_dir/PKGBUILD" ]; then
    printf '%s\n' "$local_dir"
  else
    printf '%s\n' "$upstream"
  fi
}

# --- global settings --------------------------------------------------------
# config_get <key> -> scalar from config/pkgmirror.toml (empty if absent).
config_get() {
  local f="$PKGMIRROR_ROOT/config/pkgmirror.toml"
  [ -f "$f" ] || return 0
  toml_get "$f" "$1"
}

# --- groups -----------------------------------------------------------------
group_file() { printf '%s\n' "$PKGMIRROR_ROOT/config/groups/$1.toml"; }

# group_names -> newline-separated list of defined group names.
group_names() {
  local f
  for f in "$PKGMIRROR_ROOT"/config/groups/*.toml; do
    [ -e "$f" ] || continue
    basename "$f" .toml
  done
}
# group_members <group> -> newline-separated package names in the group.
group_members() {
  local f; f="$(group_file "$1")"
  [ -f "$f" ] || return 0
  toml_list "$f" 'packages.all()'
}
# arch_groups <arch> -> newline-separated groups the arch enables (may be empty).
arch_groups() {
  toml_list "$(arch_conf "$1")" 'groups.all()'
}

# --- package records --------------------------------------------------------
packages_file() { printf '%s\n' "$PKGMIRROR_ROOT/config/packages/$1.toml"; }

# pkg_records <arch> -> emits "name<TAB>source" per per-arch extra package.
pkg_records() {
  local f; f="$(packages_file "$1")"
  [ -f "$f" ] || return 0
  local n; n="$(toml_get "$f" 'package.all().count()')"
  [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null || return 0
  local i=0
  while [ "$i" -lt "$n" ]; do
    printf '%s\t%s\n' \
      "$(toml_get "$f" "package.[$i].name")" \
      "$(toml_get "$f" "package.[$i].source")"
    i=$((i + 1))
  done
}

# pkg_giturl <arch> <pkg> -> emits "url<TAB>ref" for a source=git package entry
# (ref empty = clone the repo's default branch), or nothing if <pkg> has no entry
# or no url set. Used by build.sh resolve_src; a separate lookup from pkg_records
# since url/ref only apply to source=git and would otherwise bloat every caller's
# tuple shape for a case that's rare.
pkg_giturl() {
  local arch="$1" pkg="$2" f; f="$(packages_file "$arch")"
  [ -f "$f" ] || return 0
  local n; n="$(toml_get "$f" 'package.all().count()')"
  [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null || return 0
  local i=0
  while [ "$i" -lt "$n" ]; do
    if [ "$(toml_get "$f" "package.[$i].name")" = "$pkg" ]; then
      printf '%s\t%s\n' \
        "$(toml_get "$f" "package.[$i].url")" \
        "$(toml_get "$f" "package.[$i].ref")"
      return 0
    fi
    i=$((i + 1))
  done
}

# pkg_giturls_all <arch> -> emits "name<TAB>url<TAB>ref" per source=git package
# entry. One-shot listing for the web UI (avoids one call per package); see
# pkg_giturl for single-package lookups.
pkg_giturls_all() {
  local arch="$1" f; f="$(packages_file "$arch")"
  [ -f "$f" ] || return 0
  local n; n="$(toml_get "$f" 'package.all().count()')"
  [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null || return 0
  local i=0 name src
  while [ "$i" -lt "$n" ]; do
    name="$(toml_get "$f" "package.[$i].name")"
    src="$(toml_get "$f" "package.[$i].source")"
    if [ "$src" = "git" ]; then
      printf '%s\t%s\t%s\n' "$name" \
        "$(toml_get "$f" "package.[$i].url")" \
        "$(toml_get "$f" "package.[$i].ref")"
    fi
    i=$((i + 1))
  done
}

# effective_packages <arch> -> emits "name<TAB>source<TAB>origin" for the arch's
# full build set: the union of its enabled groups' members and its per-arch extras
# (config/packages/<arch>.toml), deduped by name. `source` is the explicit per-arch
# override if set, else "local" when pkgbuilds/<arch>/<name>/PKGBUILD exists, else
# "upstream". `origin` is the comma-joined group name(s) and/or "individual".
effective_packages() {
  local arch="$1"
  arch_conf "$arch" >/dev/null || return 1
  declare -A _src _origin
  local g p name s
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      _origin[$p]="${_origin[$p]:+${_origin[$p]},}$g"
    done < <(group_members "$g")
  done < <(arch_groups "$arch")
  while IFS=$'\t' read -r name s; do
    [ -n "$name" ] || continue
    _src[$name]="$s"
    # Only tag "individual" a package with no prior (group) origin — a
    # packages.toml entry used just to set source=aur/local on a group member
    # shouldn't relabel it as an extra.
    [ -n "${_origin[$name]:-}" ] || _origin[$name]="individual"
  done < <(pkg_records "$arch")
  local effsrc
  for name in "${!_origin[@]}"; do
    effsrc="${_src[$name]:-}"
    if [ -z "$effsrc" ]; then
      if [ -f "$PKGMIRROR_ROOT/pkgbuilds/$arch/$name/PKGBUILD" ]; then effsrc="local"; else effsrc="upstream"; fi
    fi
    printf '%s\t%s\t%s\n' "$name" "$effsrc" "${_origin[$name]}"
  done | sort
}

# --- per-package overrides ---------------------------------------------------
# config/overrides/<arch>.toml carries HOW a package builds (pin/patches/hooks/
# skip_check/makepkg_args/mem sizing), separately from config/packages/<arch>.toml
# (WHAT gets built). Applies to any package in the arch's effective set — group
# member or extra — without affecting its origin. See bin/override.sh to edit.
override_file() { printf '%s\n' "$PKGMIRROR_ROOT/config/overrides/$1.toml"; }

# pkg_override_sep — field separator for pkg_override's output: ASCII unit
# separator (0x1F), not tab. Tab is IFS *whitespace*, so `IFS=$'\t' read` collapses
# consecutive/empty fields instead of preserving them (a real bug caught in
# testing: an empty makepkg_args field silently shifted patches/mem/notes left by
# one). 0x1F is a non-whitespace IFS char, so `read` splits strictly and keeps
# empty fields — and it can't collide with real field content (pins, patch
# filenames, notes).
pkg_override_sep=$'\x1f'

# pkg_override <arch> <pkg> -> emits pin/skip_check/makepkg_args/patches/
# mem_per_job_mb/notes joined by pkg_override_sep, for <pkg>'s override entry, or
# nothing if none exists. makepkg_args/patches are comma-joined (values are
# flags/filenames, never contain commas).
pkg_override() {
  local arch="$1" pkg="$2" f; f="$(override_file "$arch")"
  [ -f "$f" ] || return 0
  local n; n="$(toml_get "$f" 'override.all().count()')"
  [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null || return 0
  local i=0 name margs patches
  while [ "$i" -lt "$n" ]; do
    name="$(toml_get "$f" "override.[$i].name")"
    if [ "$name" = "$pkg" ]; then
      # dasel errors (exit 1) on a selector for a field that isn't set on this
      # entry (e.g. no makepkg_args at all) — under set -e that would abort the
      # whole assignment (and, since this runs in build.sh, the build). `|| true`
      # treats "field absent" as just empty, which is what it means here.
      margs="$(toml_list "$f" "override.[$i].makepkg_args.all()" | tr '\n' ',')" || true; margs="${margs%,}"
      patches="$(toml_list "$f" "override.[$i].patches.all()" | tr '\n' ',')" || true; patches="${patches%,}"
      printf "%s${pkg_override_sep}%s${pkg_override_sep}%s${pkg_override_sep}%s${pkg_override_sep}%s${pkg_override_sep}%s\n" \
        "$(toml_get "$f" "override.[$i].pin")" \
        "$(toml_get "$f" "override.[$i].skip_check")" \
        "$margs" "$patches" \
        "$(toml_get "$f" "override.[$i].mem_per_job_mb")" \
        "$(toml_get "$f" "override.[$i].notes")"
      return 0
    fi
    i=$((i + 1))
  done
}

# override_index <arch> <pkg> -> index of <pkg>'s override entry, or -1.
override_index() {
  local arch="$1" pkg="$2" f; f="$(override_file "$arch")"
  [ -f "$f" ] || { printf -- '-1\n'; return 0; }
  local n; n="$(toml_get "$f" 'override.all().count()')"
  [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null || { printf -- '-1\n'; return 0; }
  local i=0
  while [ "$i" -lt "$n" ]; do
    [ "$(toml_get "$f" "override.[$i].name")" = "$pkg" ] && { printf '%s\n' "$i"; return 0; }
    i=$((i + 1))
  done
  printf -- '-1\n'
}

# overrides_all <arch> -> emits one line per override entry: name<SEP>pin<SEP>
# skip_check<SEP>makepkg_args<SEP>patches<SEP>mem_per_job_mb<SEP>notes (SEP =
# pkg_override_sep). One-shot listing for the web UI (avoids one call per
# package); see pkg_override for single-package lookups.
overrides_all() {
  local arch="$1" f; f="$(override_file "$arch")"
  [ -f "$f" ] || return 0
  local n; n="$(toml_get "$f" 'override.all().count()')"
  [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null || return 0
  local i=0 name
  while [ "$i" -lt "$n" ]; do
    name="$(toml_get "$f" "override.[$i].name")"
    printf '%s%s%s\n' "$name" "$pkg_override_sep" "$(pkg_override "$arch" "$name")"
    i=$((i + 1))
  done
}

# --- upstream remote resolution ---------------------------------------------
# explicit_source <arch> <pkg> -> the source field from <arch>'s packages.toml
# entry for <pkg> ("upstream"/"local"/"aur"/"git"), or empty if it's only a group
# member (no explicit override — resolve_src's local-dir-then-Arch-clone default
# applies). Shared by build.sh (resolve_src) and update-check.sh (upstream check).
explicit_source() {
  local arch="$1" pkg="$2" name s
  while IFS=$'\t' read -r name s; do
    [ "$name" = "$pkg" ] && { printf '%s\n' "$s"; return 0; }
  done < <(pkg_records "$arch")
}

# upstream_remote_url_ref <arch> <pkg> <src> -> emits "url<TAB>ref" (ref empty =
# remote's default branch/HEAD) for the remote resolve_src would clone from for a
# non-local source. Mirrors resolve_src's aur/git/upstream branches in build.sh —
# kept in sync with that logic since it decides the same remote.
upstream_remote_url_ref() {
  local arch="$1" pkg="$2" src="$3"
  case "$src" in
    aur) printf '%s\t%s\n' "https://aur.archlinux.org/$pkg.git" "" ;;
    git)
      local url="" ref=""
      IFS=$'\t' read -r url ref < <(pkg_giturl "$arch" "$pkg") || true
      printf '%s\t%s\n' "$url" "$ref"
      ;;
    *) printf '%s\t%s\n' "https://gitlab.archlinux.org/archlinux/packaging/packages/$pkg.git" "" ;;
  esac
}

# remote_head_sha <url> <ref> -> the commit sha <ref> (default: remote HEAD) points
# to on <url>, or empty on failure/timeout. Read-only network probe (no clone) —
# used for cheap upstream staleness checks. Bounded by `update_check_timeout_sec`
# (config/pkgmirror.toml, default 15s) so an unreachable/slow remote can't hang a
# whole update-check sweep.
remote_head_sha() {
  local url="$1" ref="${2:-HEAD}" timeout_s
  [ -n "$url" ] || return 0
  timeout_s="$(config_get update_check_timeout_sec)"; timeout_s="${timeout_s:-15}"
  timeout "$timeout_s" git ls-remote "$url" "$ref" 2>/dev/null | awk 'NR==1{print $1}'
}

# --- version helpers --------------------------------------------------------
# pkgbuild_version <dir> -> "[epoch:]pkgver-pkgrel" by sourcing PKGBUILD in a
# subshell, matching pacman's actual filename convention (repo_version parses
# a real "<pkgname>-[epoch:]pkgver-pkgrel-<arch>.pkg.tar.zst") -- a package
# with a nonzero epoch previously never matched here (epoch was silently
# dropped), so build_pkg's up-to-date skip check never fired for it and it
# rebuilt on every single sweep regardless of whether anything had changed.
# (Adequate for static PKGBUILDs; VCS pkgver() functions are not evaluated.)
pkgbuild_version() {
  ( set +eu; source "$1/PKGBUILD" >/dev/null 2>&1
    if [ -n "${epoch:-}" ] && [ "$epoch" != 0 ]; then
      printf '%s:%s-%s\n' "$epoch" "${pkgver:-0}" "${pkgrel:-0}"
    else
      printf '%s-%s\n' "${pkgver:-0}" "${pkgrel:-0}"
    fi )
}

# repo_version <arch> <pkg> -> version of the newest built package in the repo,
# or empty if absent. Best-effort parse of the package filename.
#
# The glob requires a digit right after "<pkg>-": pacman package filenames are
# <pkgname>-<pkgver>-<pkgrel>-<arch>.pkg.tar.zst, and pkgver conventionally
# starts with a digit. Without this, "freetype2-*" also matches sibling
# split-package files that merely start with the same substring --
# freetype2-docs-*, freetype2-demos-*, freetype2-debug-* -- so e.g. freetype2
# would report freetype2-docs's version instead of its own, breaking the
# up-to-date skip check in build_pkg for any split package.
repo_version() {
  local repo_dir="$PKGMIRROR_DATA/repos/$1" pkg="$2" f v
  local newest=""
  for f in "$repo_dir/$pkg"-[0-9]*.pkg.tar.zst; do
    [ -e "$f" ] || continue
    # strip "<dir>/<pkg>-" prefix and "-<arch>.pkg.tar.zst" suffix -> pkgver-pkgrel
    v="$(basename "$f")"; v="${v#"$pkg"-}"; v="${v%-*.pkg.tar.zst}"
    newest="$v"
  done
  printf '%s\n' "$newest"
}

# --- locking ----------------------------------------------------------------
# with_lock <name> <cmd...> -> run cmd under an exclusive flock, so overlapping
# timer runs for the same arch serialize instead of colliding.
with_lock() {
  local name="$1"; shift
  local lockdir="${PKGMIRROR_LOCKDIR:-/run/pkgmirror}"
  mkdir -p "$lockdir" 2>/dev/null || lockdir="/tmp"
  local lockfile="$lockdir/$name.lock"
  exec {_lockfd}>"$lockfile" || die "cannot open lock $lockfile"
  if ! flock -n "$_lockfd"; then
    warn "another run holds lock '$name'; exiting"
    return 0
  fi
  "$@"
  local rc=$?
  flock -u "$_lockfd"
  return $rc
}
