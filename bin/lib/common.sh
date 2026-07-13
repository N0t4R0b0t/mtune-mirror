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
    _origin[$name]="${_origin[$name]:+${_origin[$name]},}individual"
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

# --- version helpers --------------------------------------------------------
# pkgbuild_version <dir> -> "pkgver-pkgrel" by sourcing PKGBUILD in a subshell.
# (Adequate for static PKGBUILDs; VCS pkgver() functions are not evaluated.)
pkgbuild_version() {
  ( set +eu; source "$1/PKGBUILD" >/dev/null 2>&1
    printf '%s-%s\n' "${pkgver:-0}" "${pkgrel:-0}" )
}

# repo_version <arch> <pkg> -> version of the newest built package in the repo,
# or empty if absent. Best-effort parse of the package filename.
repo_version() {
  local repo_dir="$PKGMIRROR_DATA/repos/$1" pkg="$2" f v
  local newest=""
  for f in "$repo_dir/$pkg"-*.pkg.tar.zst; do
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
