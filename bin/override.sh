#!/usr/bin/env bash
# bin/override.sh <arch> <pkg> [--pin TAG] [--skip-check true|false] \
#   [--makepkg-args "a,b"] [--patches "a.patch,b.patch"] [--mem-per-job-mb N] \
#   [--notes "text"] [--clear]
# bin/override.sh <arch> list
#
# Sets/clears/lists per-package build overrides in config/overrides/<arch>.toml —
# HOW a package builds (version pin, patches, skip_check, extra makepkg args,
# memory sizing), separate from config/packages/<arch>.toml (WHAT gets built).
# Applies to any package in the arch's effective set, group member or extra, and
# never affects its origin. Patch files themselves live in
# pkgbuilds/<arch>/<pkg>/patches/; a post_fetch hook (arbitrary shell) can live in
# pkgbuilds/<arch>/<pkg>/hooks/post_fetch.sh — both are file-based, not set here.
# Used by CLI + UI. See bin/lib/common.sh pkg_override for the reader consumed by
# bin/build.sh.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

arch="${1:?usage: override.sh <arch> <pkg|list> [--pin ..] [--skip-check ..] [--makepkg-args ..] [--patches ..] [--mem-per-job-mb ..] [--notes ..] [--clear]}"
target="${2:?missing pkgname or 'list'}"; shift 2 || true
arch_conf "$arch" >/dev/null || exit 1

f="$(override_file "$arch")"

if [ "$target" = "list" ]; then
  [ -f "$f" ] || { log "no overrides for $arch"; exit 0; }
  n="$(toml_get "$f" 'override.all().count()')"
  [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null || { log "no overrides for $arch"; exit 0; }
  printf '%-20s %-12s %-6s %-20s %-24s %-8s %s\n' \
    NAME PIN SKIPCK MAKEPKG_ARGS PATCHES MEM_MB NOTES
  i=0
  while [ "$i" -lt "$n" ]; do
    name="$(toml_get "$f" "override.[$i].name")"
    IFS="$pkg_override_sep" read -r pin skipcheck margs patches mem notes < <(pkg_override "$arch" "$name") || true
    printf '%-20s %-12s %-6s %-20s %-24s %-8s %s\n' \
      "$name" "${pin:--}" "${skipcheck:--}" "${margs:--}" "${patches:--}" "${mem:--}" "${notes:-}"
    i=$((i + 1))
  done
  exit 0
fi

pkg="$target"
case "$pkg" in *[!A-Za-z0-9._+-]*|"") die "invalid package name: $pkg" ;; esac

clear=0; pin=""; skipcheck=""; margs=""; patches=""; mem=""; notes=""
set_pin=0; set_skipcheck=0; set_margs=0; set_patches=0; set_mem=0; set_notes=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pin)           pin="$2";       set_pin=1;       shift 2 ;;
    --skip-check)    skipcheck="$2"; set_skipcheck=1; shift 2 ;;
    --makepkg-args)  margs="$2";     set_margs=1;      shift 2 ;;
    --patches)       patches="$2";   set_patches=1;    shift 2 ;;
    --mem-per-job-mb) mem="$2";      set_mem=1;        shift 2 ;;
    --notes)         notes="$2";     set_notes=1;      shift 2 ;;
    --clear)         clear=1;        shift ;;
    *) die "unknown arg: $1" ;;
  esac
done

idx="$(override_index "$arch" "$pkg")"

if [ "$clear" -eq 1 ]; then
  [ "$idx" -ge 0 ] || { warn "no override for '$pkg' in $arch"; exit 0; }
  "$DASEL" delete -f "$f" -r toml ".override.[$idx]"
  log "cleared override for '$pkg' in $arch"
  exit 0
fi

if [ ! -f "$f" ]; then
  install -d "$(dirname "$f")"
  printf '# Per-package build overrides for the "%s" arch.\n' "$arch" > "$f"
fi

if [ "$idx" -lt 0 ]; then
  "$DASEL" put -f "$f" -r toml -t json -v "{\"name\":\"$pkg\"}" ".override.[]"
  idx="$(override_index "$arch" "$pkg")"
  log "created override entry for '$pkg' in $arch"
fi

[ "$set_pin" -eq 1 ] && "$DASEL" put -f "$f" -r toml -t string -v "$pin" ".override.[$idx].pin"

if [ "$set_skipcheck" -eq 1 ]; then
  case "$skipcheck" in true|false) ;; *) die "--skip-check must be true|false" ;; esac
  "$DASEL" put -f "$f" -r toml -t bool -v "$skipcheck" ".override.[$idx].skip_check"
fi

if [ "$set_mem" -eq 1 ]; then
  case "$mem" in ''|*[!0-9]*) die "--mem-per-job-mb must be a positive integer" ;; esac
  "$DASEL" put -f "$f" -r toml -t int -v "$mem" ".override.[$idx].mem_per_job_mb"
fi

[ "$set_notes" -eq 1 ] && "$DASEL" put -f "$f" -r toml -t string -v "$notes" ".override.[$idx].notes"

if [ "$set_margs" -eq 1 ]; then
  "$DASEL" delete -f "$f" -r toml ".override.[$idx].makepkg_args" 2>/dev/null || true
  if [ -n "$margs" ]; then
    IFS=',' read -ra arr <<< "$margs"
    for v in "${arr[@]}"; do "$DASEL" put -f "$f" -r toml -t string -v "$v" ".override.[$idx].makepkg_args.[]"; done
  fi
fi

if [ "$set_patches" -eq 1 ]; then
  "$DASEL" delete -f "$f" -r toml ".override.[$idx].patches" 2>/dev/null || true
  if [ -n "$patches" ]; then
    IFS=',' read -ra arr <<< "$patches"
    for v in "${arr[@]}"; do "$DASEL" put -f "$f" -r toml -t string -v "$v" ".override.[$idx].patches.[]"; done
    d="$PKGMIRROR_ROOT/pkgbuilds/$arch/$pkg/patches"
    mkdir -p "$d"
    log "ensure patch files exist under $d: ${arr[*]}"
  fi
fi

log "updated override for '$pkg' in $arch"
