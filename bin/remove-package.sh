#!/usr/bin/env bash
# bin/remove-package.sh <arch> <pkgname>
#
# Removes a package entry from config/packages/<arch>.toml (via dasel). Leaves any
# pkgbuilds/<arch>/<pkgname>/ override and already-built repo packages in place
# (removing those is a separate, deliberate action).
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

arch="${1:?usage: remove-package.sh <arch> <pkgname>}"
pkg="${2:?missing pkgname}"
arch_conf "$arch" >/dev/null || exit 1
case "$pkg" in *[!A-Za-z0-9._+-]*|"") die "invalid package name: $pkg" ;; esac

f="$(packages_file "$arch")"
[ -f "$f" ] || die "no package list for $arch"

idx=-1; i=0
while IFS=$'\t' read -r name t s; do
  [ "$name" = "$pkg" ] && idx="$i"
  i=$((i + 1))
done < <(pkg_records "$arch")

[ "$idx" -ge 0 ] || { warn "package '$pkg' not in $arch list"; exit 0; }
"$DASEL" delete -f "$f" -r toml ".package.[$idx]"
log "removed package '$pkg' from $arch"
