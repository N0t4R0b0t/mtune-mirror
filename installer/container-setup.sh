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
if ! command -v dasel >/dev/null 2>&1; then
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

# --- 4. build the web UI (stdlib-only Go; no module downloads) --------------
log "Building pkgmirror-web"
( cd "$REPO_ROOT/web" && GOFLAGS=-mod=mod GOCACHE=/tmp/gocache go build -o /usr/local/bin/pkgmirror-web . ) \
  || warn "pkgmirror-web build failed — UI will be unavailable"

# --- 5. systemd units -------------------------------------------------------
log "Installing systemd units"
install -m0644 "$REPO_ROOT"/systemd/pkgmirror-build@.service /etc/systemd/system/
install -m0644 "$REPO_ROOT"/systemd/pkgmirror-build@.timer   /etc/systemd/system/
install -m0644 "$REPO_ROOT"/systemd/pkgmirror-web.service    /etc/systemd/system/
systemctl daemon-reload
[ -x /usr/local/bin/pkgmirror-web ] && systemctl enable --now pkgmirror-web

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
