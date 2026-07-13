#!/usr/bin/env bash
# bin/update-check.sh <arch>
#
# Reports, per configured package, the version currently in the repo vs the source
# PKGBUILD, and whether a rebuild is due. Informational: build.sh independently
# skips packages already at the current version, so this is a status view (and a
# cheap way to see drift for local-override packages without a full build).
#
# For upstream packages the source version isn't fetched here (that requires a
# clone); they show as built/missing only. Local-override packages get an exact
# up-to-date / DUE verdict.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

arch="${1:?usage: update-check.sh <arch>}"
arch_conf "$arch" >/dev/null || exit 1

printf '%-22s %-13s %-13s %-9s %s\n' PACKAGE REPO SOURCE STATUS ORIGIN
due=0
while IFS=$'\t' read -r name src origin; do
  [ -n "$name" ] || continue
  have="$(repo_version "$arch" "$name")"; have="${have:--}"
  localdir="$PKGMIRROR_ROOT/pkgbuilds/$arch/$name"
  if [ -f "$localdir/PKGBUILD" ]; then
    want="$(pkgbuild_version "$localdir")"
    if [ "$have" = "$want" ]; then status="ok";
    else status="DUE"; due=$((due + 1)); fi
  else
    want="(upstream)"
    if [ "$have" = "-" ]; then status="missing"; due=$((due + 1)); else status="built"; fi
  fi
  printf '%-22s %-13s %-13s %-9s %s\n' "$name" "$have" "$want" "$status" "$origin"
done < <(effective_packages "$arch")

log "update-check [$arch]: $due package(s) flagged (DUE/missing)"
