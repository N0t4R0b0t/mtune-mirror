#!/usr/bin/env bash
# bin/repo-sync.sh <arch> <pkgfile ...>
#
# Copies built packages into the served repo for <arch> and updates the pacman
# repo database. The db is named "<arch>-local" to match the client pacman.conf
# blocks ([atom-local], [btver1-local], ...). Old versions are pruned by repo-add
# --remove. Signing is intentionally omitted (repos are served SigLevel=TrustAll).
#
# Not internally locked: build.sh already holds the per-arch lock when it calls
# this. Safe to run standalone too (single writer assumed).
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

arch="${1:?usage: repo-sync.sh <arch> <pkgfile ...>}"; shift || true
arch_conf "$arch" >/dev/null || exit 1
[ "$#" -gt 0 ] || { warn "repo-sync: no package files given for '$arch'"; exit 0; }

repo_dir="$PKGMIRROR_DATA/repos/$arch"
db="$repo_dir/${arch}-local.db.tar.gz"
install -d "$repo_dir"

copied=()
for f in "$@"; do
  [ -f "$f" ] || { warn "repo-sync: missing file $f"; continue; }
  install -m0644 "$f" "$repo_dir/"
  copied+=("$repo_dir/$(basename "$f")")
done
[ "${#copied[@]}" -gt 0 ] || { warn "repo-sync: nothing copied"; exit 0; }

log "repo-add: ${#copied[@]} package(s) -> ${arch}-local"
# Serialize repo-add across concurrent (parallel) builds — a shared db must not be
# rewritten by two processes at once. --remove prunes superseded package files.
exec 9>"$repo_dir/.repo.lock"
flock 9
repo-add --quiet --remove "$db" "${copied[@]}"
flock -u 9
log "repo '${arch}-local' now at: $(ls "$repo_dir"/*.pkg.tar.zst 2>/dev/null | wc -l) package file(s)"
