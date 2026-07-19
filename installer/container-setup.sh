#!/usr/bin/env bash
# installer/container-setup.sh — runs INSIDE the container (as root).
# Installs toolchains, creates the service user + data tree, wires up systemd
# and nginx, and bootstraps each configured arch's build chroot.
#
# Assumes this repo is already present at /opt/pkgmirror (install.sh pushes or
# clones it before invoking this). Idempotent: safe to re-run.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/opt/pkgmirror}"
DATA_ROOT="${PKGMIRROR_DATA:-/srv/pkgmirror}"
SVC_USER="pkgmirror"
DASEL_VERSION="${DASEL_VERSION:-v2.8.1}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }

# --- 0. pacman download sandbox ---------------------------------------------
# pacman 7's download sandbox (Landlock + the 'alpm' DownloadUser) is not
# available inside an unprivileged LXC — the kernel refuses Landlock and pacman
# can't drop to the sandbox user, so every sync fails. Disable it; harmless on
# hosts where the sandbox would otherwise work (packages are still verified).
if ! grep -q '^DisableSandbox' /etc/pacman.conf; then
  log "Disabling pacman download sandbox (unprivileged LXC)"
  sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
fi

# --- 0b. pacman keyring -----------------------------------------------------
# The base template ships without an initialized keyring, so package signature
# verification fails ("Public keyring not found"). Initialize + populate it.
# Both operations are idempotent.
if [ ! -e /etc/pacman.d/gnupg/pubring.gpg ]; then
  log "Initializing pacman keyring"
  pacman-key --init
  pacman-key --populate archlinux
fi

# --- 1. base packages + toolchains ------------------------------------------
log "Updating system and installing toolchains"
pacman -Syu --noconfirm --needed \
  base-devel devtools git nginx wget sudo go

# --- 2. dasel (single static binary; TOML parser used by bin/lib/common.sh) --
# Check the file directly, not `command -v`: a non-login exec context's PATH
# (e.g. `pct exec ... bash script.sh`) may not include /usr/local/bin, which
# made this false-negative on every run and re-attempt the install — usually
# silently succeeding (harmless overwrite) but capable of colliding with a
# concurrently-running build that has the binary open (ETXTBSY, fatal under
# set -e).
if [ ! -x /usr/local/bin/dasel ]; then
  log "Installing dasel ${DASEL_VERSION}"
  wget -qO /usr/local/bin/dasel \
    "https://github.com/TomWright/dasel/releases/download/${DASEL_VERSION}/dasel_linux_amd64"
  chmod +x /usr/local/bin/dasel
fi

# --- 3. service user + data tree --------------------------------------------
if ! id "$SVC_USER" >/dev/null 2>&1; then
  log "Creating service user '$SVC_USER'"
  useradd --system --create-home --shell /usr/bin/nologin "$SVC_USER"
fi
install -d -o "$SVC_USER" -g "$SVC_USER" \
  "$DATA_ROOT" "$DATA_ROOT/chroots" "$DATA_ROOT/repos" "$DATA_ROOT/state"

# --- 3a. tmpfs for build scratch space ---------------------------------------
# $DATA_ROOT/work (source extraction + build dirs, bin/build.sh resolve_src) is
# pure scratch -- wiped and regenerated on every package build -- but the host
# storage here is spinning HDDs behind ZFS (see proxmox-test-server), and a
# compile's small-file I/O pattern (thousands of tiny object-file/header
# read/writes) is close to a worst case for that combo. Confirmed 2026-07-15:
# even tiny packages (bzip2, flac) were taking 60-250s and openssl took 55
# minutes on a 16-core/16GB container that was nowhere near CPU-saturated
# (host load 6.33 on 32 cores -- I/O wait, not compute, was the bottleneck).
# Moving this scratch space to tmpfs (RAM) removes the disk entirely from that
# path. Sized generously relative to actual usage (~2GB/arch observed) since
# multiple arches can have work dirs live at once; RAM here is otherwise idle
# (14GB+ free). Idempotent: skips if already mounted (e.g. this script re-run).
if ! mountpoint -q "$DATA_ROOT/work" 2>/dev/null; then
  log "Mounting tmpfs at $DATA_ROOT/work for build scratch space"
  install -d "$DATA_ROOT/work"
  # uid=/gid= baked into the mount options themselves (not just a one-time
  # chown after mounting here) so a plain reboot -- which remounts this from
  # /etc/fstab directly, bypassing this script entirely -- still comes back
  # owned by the service user instead of root. Bit us 2026-07-19: a reboot
  # left work/ root-owned, and every build failed with "Permission denied"
  # until this script was re-run by hand.
  svc_uid="$(id -u "$SVC_USER")" svc_gid="$(id -g "$SVC_USER")"
  mount -t tmpfs -o "size=8G,mode=0755,uid=$svc_uid,gid=$svc_gid" tmpfs "$DATA_ROOT/work"
  grep -q "^tmpfs $DATA_ROOT/work " /etc/fstab 2>/dev/null || \
    echo "tmpfs $DATA_ROOT/work tmpfs defaults,size=8G,mode=0755,uid=$svc_uid,gid=$svc_gid 0 0" >> /etc/fstab
fi

# The web UI (running as the service user) edits package lists and PKGBUILDs.
chown -R "$SVC_USER":"$SVC_USER" "$REPO_ROOT/config" "$REPO_ROOT/pkgbuilds" 2>/dev/null || true
# Per-arch served repo dirs (empty for now; repo-sync.sh populates them).
while IFS= read -r arch; do
  [ -n "$arch" ] || continue
  install -d -o "$SVC_USER" -g "$SVC_USER" "$DATA_ROOT/repos/$arch"
done < <(for f in "$REPO_ROOT"/config/arches/*.toml; do basename "$f" .toml; done)

# devtools' makechrootpkg orchestrates the build via sudo (arch-nspawn, mounts,
# env passthrough like BUILDTOOL, etc.) and is designed to run as a user with full
# passwordless sudo. This is a dedicated, privileged build container — the trust
# boundary is the container itself — so grant the builder unrestricted sudo.
cat >/etc/sudoers.d/pkgmirror <<EOF
$SVC_USER ALL=(ALL) NOPASSWD: ALL
EOF
chmod 0440 /etc/sudoers.d/pkgmirror
visudo -cf /etc/sudoers.d/pkgmirror >/dev/null

# --- 3b. update command -----------------------------------------------------
# Expose the in-container updater as `pkgmirror-update`.
ln -sf "$REPO_ROOT/installer/self-update.sh" /usr/local/bin/pkgmirror-update

# --- 3c. console greeter + autologin -----------------------------------------
# This is a dedicated, LAN-internal build box (see README trust model) — root
# autologin on the console matches that trust boundary, same as the sibling
# proxmox-coder-lxc project. Override BOTH getty units this Arch CT actually
# runs: console-getty (serves /dev/console, what `pct console` normally
# attaches to) and container-getty@1 (serves /dev/pts/1) — which one Proxmox's
# console actually lands on can vary, so cover both rather than guess.
log "Configuring console autologin + greeter"
for unit in console-getty.service 'container-getty@1.service'; do
  d="/etc/systemd/system/${unit}.d"
  install -d "$d"
  cat >"$d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin root --noreset --noclear --keep-baud 115200,57600,38400,9600 - $TERM
EOF
done
systemctl daemon-reload
systemctl restart console-getty.service 'container-getty@1.service' 2>/dev/null || true

cat >/etc/profile.d/00_pkgmirror-details.sh <<PROFILE
[ -t 1 ] || return 0

_ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
_host=\$(hostname)
_arches=\$(for f in $REPO_ROOT/config/arches/*.toml; do basename "\$f" .toml; done | paste -sd, | sed 's/,/, /g')

echo ""
echo -e "\033[1;92mpkgmirror LXC Container\033[m"
echo -e "    🌐   Provided by: N0t4R0b0t | GitHub: \033[36mhttps://github.com/N0t4R0b0t/mtune-mirror\033[m"
echo ""
echo -e "    🖥️   OS: \033[1;92mArch Linux\033[m"
echo -e "    🏠   Hostname: \033[1;92m\${_host}\033[m"
echo -e "    💡   IP Address: \033[1;92m\${_ip}\033[m"
echo ""
echo -e "    📦   Dashboard: \033[36mhttp://\${_ip}/\033[m"
echo -e "    📥   Repos:     \033[36mhttp://\${_ip}/repos/<arch>/\033[m  (arches: \${_arches})"
echo ""
echo -e "    💾   Config:    $REPO_ROOT/config/"
echo -e "    📋   Logs:      journalctl -u pkgmirror-web -f  |  journalctl -u pkgmirror-build@<arch> -f"
echo -e "    🔄   Update:    pkgmirror-update"
echo ""
PROFILE
chmod +x /etc/profile.d/00_pkgmirror-details.sh

# --- 4. build the web UI (one module dependency: pelletier/go-toml/v2, for
# native config reads in internal/pkgconfig — needs network access at build
# time to resolve/download it; was previously stdlib-only) -----------------
log "Building pkgmirror-web"
( cd "$REPO_ROOT/web" && GOFLAGS=-mod=mod GOCACHE=/tmp/gocache go build -o /usr/local/bin/pkgmirror-web . ) \
  || warn "pkgmirror-web build failed — UI will be unavailable"

# --- 5. systemd units -------------------------------------------------------
log "Installing systemd units"
install -m0644 "$REPO_ROOT"/systemd/pkgmirror-build@.service          /etc/systemd/system/
install -m0644 "$REPO_ROOT"/systemd/pkgmirror-build@.timer            /etc/systemd/system/
install -m0644 "$REPO_ROOT"/systemd/pkgmirror-web.service             /etc/systemd/system/
install -m0644 "$REPO_ROOT"/systemd/pkgmirror-clean-chroots.service   /etc/systemd/system/
install -m0644 "$REPO_ROOT"/systemd/pkgmirror-clean-chroots.timer     /etc/systemd/system/
install -m0644 "$REPO_ROOT"/systemd/pkgmirror-boot-cleanup.service    /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now pkgmirror-clean-chroots.timer
# Runs once now too (not just at future boots) so re-running this script
# after a crash/reboot clears any stale "building" state immediately, same as
# an actual boot would.
systemctl enable --now pkgmirror-boot-cleanup.service
# `enable --now` only starts a not-yet-running unit; on an update run the
# service is already active, so a freshly rebuilt binary above would never
# actually get loaded without an explicit restart.
if [ -x /usr/local/bin/pkgmirror-web ]; then
  systemctl enable pkgmirror-web
  systemctl restart pkgmirror-web
fi

# --- 6. nginx ---------------------------------------------------------------
log "Configuring nginx"
install -m0644 "$REPO_ROOT"/nginx/pkgmirror.conf /etc/nginx/nginx.conf
systemctl enable nginx
systemctl reload nginx 2>/dev/null || systemctl restart nginx

# --- 6. bootstrap each arch's build chroot ----------------------------------
# Failure of one arch must not abort the rest (an i686 arch may need archlinux32
# wiring the x86_64 path doesn't). Log, continue, summarize at the end.
bootstrap_ok=(); bootstrap_failed=()
while IFS= read -r arch; do
  [ -n "$arch" ] || continue
  log "Bootstrapping chroot for arch '$arch'"
  if "$REPO_ROOT"/installer/bootstrap-chroot.sh "$arch"; then
    bootstrap_ok+=("$arch")
  else
    warn "chroot bootstrap FAILED for '$arch' — continuing with the rest"
    bootstrap_failed+=("$arch")
  fi
done < <(for f in "$REPO_ROOT"/config/arches/*.toml; do basename "$f" .toml; done)

# --- 7. enable + start per-arch build timers --------------------------------
# --now so NextElapse is populated (the UI shows each arch's next run).
while IFS= read -r arch; do
  [ -n "$arch" ] || continue
  systemctl enable --now "pkgmirror-build@${arch}.timer"
done < <(for f in "$REPO_ROOT"/config/arches/*.toml; do basename "$f" .toml; done)

log "Container setup complete."
log "chroots ok: ${bootstrap_ok[*]:-none}"
[ "${#bootstrap_failed[@]}" -gt 0 ] && warn "chroots failed: ${bootstrap_failed[*]}"
log "Repo tree served at http://<container-ip>/repos/<arch>/"
log "Monitoring & ops UI at http://<container-ip>/"
