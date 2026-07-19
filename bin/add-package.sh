#!/usr/bin/env bash
# bin/add-package.sh <arch> <pkgname> [--source upstream|local|aur|git|url] [--url URL] \
#                     [--ref REF] [--files a,b,c]
#
# Adds or updates a per-arch EXTRA package entry in config/packages/<arch>.toml
# (packages built for this arch beyond its enabled groups). For source=local it
# scaffolds pkgbuilds/<arch>/<pkgname>/ with a starter PKGBUILD. source=aur builds
# from https://aur.archlinux.org/<pkgname>.git instead of Arch's official repo.
# source=git clones an arbitrary --url (e.g. your own repo hosting a fully custom
# package's PKGBUILD, like a hand-tuned kernel) — optionally pinned to --ref
# (branch or tag; omit to track the repo's default branch). source=url plain-HTTP
# GETs a PKGBUILD (plus any --files, comma-separated) from a directory --url —
# for CI pipelines that publish an already-substituted PKGBUILD (e.g. to a
# static bucket) rather than hosting a clonable git repo. All handled in
# bin/build.sh resolve_src. Used by CLI + UI.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

arch="${1:?usage: add-package.sh <arch> <pkgname> [--source ..] [--url ..] [--ref ..] [--files ..]}"
pkg="${2:?missing pkgname}"; shift 2
src="upstream"; url=""; ref=""; files=""
while [ $# -gt 0 ]; do
  case "$1" in
    --source) src="$2"; shift 2 ;;
    --url)    url="$2"; shift 2 ;;
    --ref)    ref="$2"; shift 2 ;;
    --files)  files="$2"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done
arch_conf "$arch" >/dev/null || exit 1
case "$src"  in upstream|local|aur|git|url) ;; *) die "invalid source: $src" ;; esac
case "$pkg"  in *[!A-Za-z0-9._+-]*|"") die "invalid package name: $pkg" ;; esac
if [ "$src" = "git" ]; then
  [ -n "$url" ] || die "source=git requires --url"
  case "$url" in
    https://*|git://*|ssh://*|git@*) ;;
    *) die "invalid --url: $url (expected https://, git://, ssh://, or git@... )" ;;
  esac
fi
if [ "$src" = "url" ]; then
  [ -n "$url" ] || die "source=url requires --url"
  case "$url" in
    https://*|http://*) ;;
    *) die "invalid --url: $url (expected http:// or https://)" ;;
  esac
fi

f="$(packages_file "$arch")"
[ -f "$f" ] || printf '# Package build list for the "%s" arch.\n' "$arch" > "$f"

# Locate an existing entry (update in place) or append a new table.
idx=-1; i=0
while IFS=$'\t' read -r name t s; do
  [ "$name" = "$pkg" ] && idx="$i"
  i=$((i + 1))
done < <(pkg_records "$arch")

if [ "$idx" -ge 0 ]; then
  "$DASEL" put -f "$f" -r toml -t string -v "$src"  ".package.[$idx].source"
  log "updated package '$pkg' in $arch (source=$src)"
else
  "$DASEL" put -f "$f" -r toml -t json \
    -v "{\"name\":\"$pkg\",\"source\":\"$src\"}" ".package.[]"
  idx=$(( $(toml_get "$f" 'package.all().count()') - 1 ))
  log "added package '$pkg' to $arch (source=$src)"
fi
if [ "$src" = "git" ]; then
  "$DASEL" put -f "$f" -r toml -t string -v "$url" ".package.[$idx].url"
  if [ -n "$ref" ]; then
    "$DASEL" put -f "$f" -r toml -t string -v "$ref" ".package.[$idx].ref"
  else
    "$DASEL" delete -f "$f" -r toml ".package.[$idx].ref" 2>/dev/null || true
  fi
fi
if [ "$src" = "url" ]; then
  "$DASEL" put -f "$f" -r toml -t string -v "$url" ".package.[$idx].url"
  "$DASEL" delete -f "$f" -r toml ".package.[$idx].files" 2>/dev/null || true
  if [ -n "$files" ]; then
    IFS=',' read -ra arr <<< "$files"
    for v in "${arr[@]}"; do
      v="$(printf '%s' "$v" | xargs)"
      [ -n "$v" ] && "$DASEL" put -f "$f" -r toml -t string -v "$v" ".package.[$idx].files.[]"
    done
  fi
fi

if [ "$src" = "local" ]; then
  d="$PKGMIRROR_ROOT/pkgbuilds/$arch/$pkg"
  mkdir -p "$d"
  if [ ! -f "$d/PKGBUILD" ]; then
    cat > "$d/PKGBUILD" <<EOF
# Local override PKGBUILD for $pkg ($arch).
# Fork the upstream PKGBUILD here, patch deps / bump pkgrel as needed; this local
# copy wins over upstream and is never overwritten by a sync.
EOF
    log "scaffolded pkgbuilds/$arch/$pkg/PKGBUILD"
  fi
fi
