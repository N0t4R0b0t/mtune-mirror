#!/usr/bin/env bash
# bin/group.sh <command> ...  — manage package groups and per-arch subscriptions.
#
#   create  <group> [--desc "text"]   create an empty group catalog
#   add     <group> <pkg>             add a package to a group
#   remove  <group> <pkg>             remove a package from a group
#   enable  <arch>  <group>           make an arch build a group
#   disable <arch>  <group>           stop an arch building a group
#   list                              print groups, members, and enabling arches
#
# Group catalogs live in config/groups/<group>.toml; arch subscriptions in each
# config/arches/<arch>.toml `groups` array. All edits go through dasel.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

valid_name() { case "$1" in *[!A-Za-z0-9._+-]*|"") return 1 ;; *) return 0 ;; esac; }

# index of <value> in a newline list from stdin, or -1.
index_of() {
  local want="$1" i=0 line
  while IFS= read -r line; do
    [ "$line" = "$want" ] && { printf '%s\n' "$i"; return 0; }
    i=$((i + 1))
  done
  printf '%s\n' -1
}

cmd="${1:?usage: group.sh <create|add|remove|enable|disable|list> ...}"; shift || true

case "$cmd" in
  create)
    g="${1:?group name}"; shift
    desc=""
    [ "${1:-}" = "--desc" ] && { desc="${2:-}"; }
    valid_name "$g" || die "invalid group name: $g"
    f="$(group_file "$g")"
    [ -e "$f" ] && die "group '$g' already exists"
    install -d "$(dirname "$f")"
    cat > "$f" <<EOF
name        = "$g"
description = "$desc"
packages = []
EOF
    log "created group '$g'"
    ;;

  add)
    g="${1:?group}"; pkg="${2:?pkg}"
    valid_name "$pkg" || die "invalid package name: $pkg"
    f="$(group_file "$g")"; [ -f "$f" ] || die "no such group: $g"
    if group_members "$g" | grep -qxF "$pkg"; then
      log "'$pkg' already in group '$g'"; exit 0
    fi
    "$DASEL" put -f "$f" -r toml -t string -v "$pkg" '.packages.[]'
    log "added '$pkg' to group '$g'"
    ;;

  remove)
    g="${1:?group}"; pkg="${2:?pkg}"
    f="$(group_file "$g")"; [ -f "$f" ] || die "no such group: $g"
    idx="$(group_members "$g" | index_of "$pkg")"
    [ "$idx" -ge 0 ] || { warn "'$pkg' not in group '$g'"; exit 0; }
    "$DASEL" delete -f "$f" -r toml ".packages.[$idx]"
    log "removed '$pkg' from group '$g'"
    ;;

  enable)
    arch="${1:?arch}"; g="${2:?group}"
    conf="$(arch_conf "$arch")" || exit 1
    [ -f "$(group_file "$g")" ] || die "no such group: $g"
    if arch_groups "$arch" | grep -qxF "$g"; then
      log "'$arch' already builds group '$g'"; exit 0
    fi
    "$DASEL" -f "$conf" -r toml '.groups' >/dev/null 2>&1 || \
      "$DASEL" put -f "$conf" -r toml -t json -v '[]' '.groups'
    "$DASEL" put -f "$conf" -r toml -t string -v "$g" '.groups.[]'
    log "'$arch' now builds group '$g'"
    ;;

  disable)
    arch="${1:?arch}"; g="${2:?group}"
    conf="$(arch_conf "$arch")" || exit 1
    idx="$(arch_groups "$arch" | index_of "$g")"
    [ "$idx" -ge 0 ] || { warn "'$arch' does not build group '$g'"; exit 0; }
    "$DASEL" delete -f "$conf" -r toml ".groups.[$idx]"
    log "'$arch' no longer builds group '$g'"
    ;;

  list)
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      desc="$(toml_get "$(group_file "$g")" description)"
      printf '%s — %s\n' "$g" "$desc"
      group_members "$g" | sed 's/^/    /'
    done < <(group_names)
    ;;

  *) die "unknown command: $cmd" ;;
esac
