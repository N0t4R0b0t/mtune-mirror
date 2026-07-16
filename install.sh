#!/usr/bin/env bash
# install.sh — Proxmox VE helper (run on a PVE node as root):
#
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/<you>/mtune-mirror/main/install.sh)"
#
# Provisions — or UPDATES — an Arch LXC that builds tuned/patched packages for
# multiple target architectures and serves them as pacman repos over HTTP.
#
# One entrypoint, two modes (community-scripts style):
#   * no pkgmirror container yet  -> fresh install (create CT, toolchains, chroots)
#   * a pkgmirror container exists -> update in place (refresh tooling, re-apply
#                                     setup; user config/pkgbuilds are preserved)
# Force a mode with `install.sh install` / `install.sh update`, or MODE=env.
#
# Self-contained: does NOT depend on the community-scripts build.func.

set -euo pipefail

# --- defaults (override via env or the whiptail prompts below) --------------
REPO_URL="${REPO_URL:-https://github.com/N0t4R0b0t/mtune-mirror.git}"
REPO_REF="${REPO_REF:-main}"

CT_HOSTNAME="${CT_HOSTNAME:-pkgmirror}"
CT_CORES="${CT_CORES:-16}"
CT_RAM="${CT_RAM:-8192}"          # MB — headroom for parallel compiles; build.sh
                                  # caps make -j by RAM, so more RAM = more parallelism
CT_DISK="${CT_DISK:-32}"          # GB
CT_STORAGE="${CT_STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
CT_IP="${CT_IP:-dhcp}"
# Privileged by default: Arch devtools (mkarchroot/arch-nspawn) must bind-mount
# /dev,/proc,/sys to build in a chroot, which an unprivileged LXC denies. This is
# a dedicated build box; privileged is the standard, reliable choice here.
CT_UNPRIVILEGED="${CT_UNPRIVILEGED:-0}"
CT_TAG="pkgmirror"                # identifies our container for update detection

MODE="${MODE:-${1:-auto}}"        # auto | install | update

msg()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merr\033[0m %s\n' "$*" >&2; exit 1; }
trap 'fail "aborted at line $LINENO"' ERR

command -v pct   >/dev/null || fail "pct not found — run this on a Proxmox VE node"
command -v pveam >/dev/null || fail "pveam not found — run this on a Proxmox VE node"

# --- deploy helpers (shared by install & update) ----------------------------
# Push the full tree (fresh install: seeds config + pkgbuilds defaults).
deploy_full() {
  local ctid="$1"
  pct exec "$ctid" -- mkdir -p /opt/pkgmirror
  tar -C "$HOST_REPO" -cf - . | pct exec "$ctid" -- tar -C /opt/pkgmirror -xf -
}
# Push CODE ONLY (update via host push): never touches config/ or pkgbuilds/,
# so container-side arch lists and patched PKGBUILDs survive the update.
deploy_code_only() {
  local ctid="$1"
  tar -C "$HOST_REPO" -cf - bin installer systemd nginx \
    | pct exec "$ctid" -- tar -C /opt/pkgmirror -xf -
}
run_setup() { pct exec "$1" -- env REPO_ROOT=/opt/pkgmirror bash /opt/pkgmirror/installer/container-setup.sh; }
is_git_checkout() { pct exec "$1" -- test -d /opt/pkgmirror/.git 2>/dev/null; }

# Find an existing pkgmirror container by its tag; echoes CTID or nothing.
find_existing_ct() {
  local id
  for id in $(pct list | awk 'NR>1 {print $1}'); do
    if pct config "$id" 2>/dev/null | grep -qE "^tags:.*\b${CT_TAG}\b"; then
      printf '%s\n' "$id"; return 0
    fi
  done
  return 1
}

# --- obtain this repo on the host (needed for both modes) -------------------
if [ -n "${REPO_SRC:-}" ]; then
  [ -f "$REPO_SRC/install.sh" ] || fail "REPO_SRC=$REPO_SRC is not a checkout of this repo"
  HOST_REPO="$REPO_SRC"
  msg "Using local repo source: $HOST_REPO"
else
  HOST_REPO="$(mktemp -d)"
  trap 'rm -rf "$HOST_REPO"' EXIT
  msg "Cloning $REPO_URL ($REPO_REF) to host"
  git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$HOST_REPO" 2>/dev/null \
    || fail "clone failed — set REPO_URL/REPO_REF, or pass REPO_SRC=<local checkout>"
fi
# shellcheck source=installer/create-lxc.sh
source "$HOST_REPO/installer/create-lxc.sh"

# --- resolve mode -----------------------------------------------------------
EXISTING="$(find_existing_ct || true)"
if [ "$MODE" = "auto" ]; then
  [ -n "$EXISTING" ] && MODE="update" || MODE="install"
fi

# ============================================================================
# UPDATE
# ============================================================================
if [ "$MODE" = "update" ]; then
  [ -n "$EXISTING" ] || fail "update requested but no container tagged '$CT_TAG' found"
  CTID="$EXISTING"
  msg "Updating pkgmirror container $CTID (config & pkgbuilds preserved)"
  if is_git_checkout "$CTID"; then
    msg "git checkout in container — updating via pkgmirror-update"
    pct exec "$CTID" -- pkgmirror-update
  else
    msg "pushing refreshed code (bin/ installer/ systemd/ nginx/)"
    deploy_code_only "$CTID"
    run_setup "$CTID"
  fi
  ok "Update complete for container $CTID"
  exit 0
fi

# ============================================================================
# FRESH INSTALL
# ============================================================================
[ -z "$EXISTING" ] || fail "a pkgmirror container ($EXISTING) already exists — run 'install.sh update'"

# --- optional interactive prompts (skipped if NONINTERACTIVE=1) -------------
if [ "${NONINTERACTIVE:-0}" != "1" ] && command -v whiptail >/dev/null; then
  CT_HOSTNAME=$(whiptail --inputbox "Container hostname" 8 60 "$CT_HOSTNAME" 3>&1 1>&2 2>&3) || true
  CT_CORES=$(whiptail --inputbox "CPU cores" 8 60 "$CT_CORES" 3>&1 1>&2 2>&3) || true
  CT_RAM=$(whiptail --inputbox "RAM (MB)" 8 60 "$CT_RAM" 3>&1 1>&2 2>&3) || true
  CT_DISK=$(whiptail --inputbox "Disk (GB)" 8 60 "$CT_DISK" 3>&1 1>&2 2>&3) || true
  CT_STORAGE=$(whiptail --inputbox "Rootfs storage" 8 60 "$CT_STORAGE" 3>&1 1>&2 2>&3) || true
fi

CTID="${CTID:-$(pvesh get /cluster/nextid 2>/dev/null || echo 900)}"
export CTID CT_HOSTNAME CT_CORES CT_RAM CT_DISK CT_STORAGE CT_BRIDGE CT_IP \
       CT_UNPRIVILEGED TEMPLATE_STORAGE

msg "Ensuring Arch base template is present"
TEMPLATE_VOLID="$(ensure_arch_template)"; export TEMPLATE_VOLID
ok "template: $TEMPLATE_VOLID"

msg "Creating LXC $CTID ($CT_HOSTNAME): ${CT_CORES}c / ${CT_RAM}MB / ${CT_DISK}G"
create_container
ok "container $CTID up"

msg "Pushing repo into container at /opt/pkgmirror"
deploy_full "$CTID"

msg "Running container setup (toolchains, chroots, nginx, timers)"
run_setup "$CTID"

# Arch's inetutils `hostname` has no -I; read the address from `ip` instead.
CT_IP_ADDR="$(pct exec "$CTID" -- ip -4 -o addr show scope global 2>/dev/null \
  | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
ok "Done. Repos served at: http://${CT_IP_ADDR:-<container-ip>}/repos/<arch>/"
cat <<EOF

Update later with:  install.sh update   (from the PVE host)
             or:    pkgmirror-update     (from inside the container)

Add to a client's /etc/pacman.conf (higher priority than official repos):

  [atom-local]
  Server = http://${CT_IP_ADDR:-<container-ip>}/repos/atom
  SigLevel = Optional TrustAll

  [btver1-local]
  Server = http://${CT_IP_ADDR:-<container-ip>}/repos/btver1
  SigLevel = Optional TrustAll
EOF
