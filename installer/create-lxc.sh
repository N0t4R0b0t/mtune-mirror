#!/usr/bin/env bash
# installer/create-lxc.sh — Proxmox HOST side: ensure the Arch template exists
# and create the LXC. Sourced by install.sh (uses the CT_* / var_* variables it
# sets) but also runnable standalone for debugging.
#
# Requires: pct, pveam (run on a Proxmox VE node as root).

set -euo pipefail

# --- ensure an Arch base template is present --------------------------------
# Prints the template volid (e.g. "local:vztmpl/archlinux-base_...tar.zst").
ensure_arch_template() {
  local storage="${TEMPLATE_STORAGE:-local}"
  pveam update >/dev/null 2>&1 || true

  # Already downloaded?
  local existing
  existing="$(pveam list "$storage" 2>/dev/null | awk '/archlinux-base/ {print $1}' | sort | tail -n1)"
  if [ -n "$existing" ]; then
    printf '%s\n' "$existing"
    return 0
  fi

  # Pick the newest archlinux-base from the available list and download it.
  local avail
  avail="$(pveam available --section system 2>/dev/null | awk '/archlinux-base/ {print $2}' | sort | tail -n1)"
  [ -n "$avail" ] || { echo "no archlinux-base template available via pveam" >&2; return 1; }
  pveam download "$storage" "$avail" >&2
  printf '%s\n' "${storage}:vztmpl/${avail}"
}

# --- create + start the container -------------------------------------------
# Expects: CTID, CT_HOSTNAME, CT_CORES, CT_RAM, CT_DISK, CT_STORAGE, CT_BRIDGE,
#          CT_UNPRIVILEGED, and TEMPLATE_VOLID (from ensure_arch_template).
create_container() {
  local template="${TEMPLATE_VOLID:?TEMPLATE_VOLID not set}"

  pct create "$CTID" "$template" \
    --hostname   "$CT_HOSTNAME" \
    --cores      "$CT_CORES" \
    --memory     "$CT_RAM" \
    --swap       "$CT_RAM" \
    --rootfs     "${CT_STORAGE}:${CT_DISK}" \
    --net0       "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP:-dhcp}" \
    --unprivileged "$CT_UNPRIVILEGED" \
    --features   "nesting=1,keyctl=1" \
    --ostype     archlinux \
    --tags       pkgmirror \
    --onboot     1

  pct start "$CTID"

  # Wait for the container's network to come up before we exec into it.
  local tries=0
  until pct exec "$CTID" -- ping -c1 -W2 geo.mirror.pkgbuild.com >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -ge 30 ] && { echo "container network did not come up" >&2; return 1; }
    sleep 2
  done
}
