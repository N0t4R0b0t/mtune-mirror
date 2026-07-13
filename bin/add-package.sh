#!/usr/bin/env bash
# bin/add-package.sh <arch> <pkgname> [--source upstream|local]
#
# Adds or updates a per-arch EXTRA package entry in config/packages/<arch>.toml
# (packages built for this arch beyond its enabled groups). For source=local it
# scaffolds pkgbuilds/<arch>/<pkgname>/ with a starter PKGBUILD. Used by CLI + UI.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

arch="${1:?usage: add-package.sh <arch> <pkgname> [--source ..]}"
pkg="${2:?missing pkgname}"; shift 2
src="upstream"
while [ $# -gt 0 ]; do
  case "$1" in
    --source) src="$2";  shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done
arch_conf "$arch" >/dev/null || exit 1
case "$src"  in upstream|local) ;; *) die "invalid source: $src" ;; esac
case "$pkg"  in *[!A-Za-z0-9._+-]*|"") die "invalid package name: $pkg" ;; esac

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
  log "added package '$pkg' to $arch (source=$src)"
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
