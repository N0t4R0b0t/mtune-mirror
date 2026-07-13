#!/usr/bin/env bash
# installer/bootstrap-chroot.sh <arch> — runs INSIDE the container (as root).
# Bootstraps one arch's build chroot, dispatching on the arch's `base`:
#   x86_64 -> standard devtools mkarchroot (native)
#   i686   -> archlinux32 pacman.conf + keyring, mkarchroot under `setarch i686`
#
# This is the ONLY place chroot bootstrap logic lives, so bin/add-arch.sh reuses
# it verbatim when scaffolding a brand-new arch. Idempotent: skips if the chroot
# root already exists.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/opt/pkgmirror}"
# shellcheck source=../bin/lib/common.sh
source "$REPO_ROOT/bin/lib/common.sh"

# ensure_archlinux32_keys <mirror-template>
# Imports archlinux32's master keys so the i686 chroot's packages verify. The
# keyring isn't in official Arch repos, so we pull the archlinux32-keyring package
# straight from the pool, extract its master-key material, and populate it. The
# package download is trusted over TLS (trust-on-first-use); every archlinux32
# package installed afterwards IS cryptographically verified against these keys.
# Idempotent via a marker in the gnupg home.
ensure_archlinux32_keys() {
  local mirror_tmpl="$1"

  # archlinux32's master keys cross-sign packager keys with SHA1, which modern
  # GnuPG rejects by default — leaving every packager key at 'marginal' trust so
  # all i686 packages fail verification. Permit these legacy key-signatures for
  # the pacman keyring (packages are still verified; only the WoT edge is SHA1).
  # Idempotent, and applied even when keys were populated on a prior run.
  local gpgconf=/etc/pacman.d/gnupg/gpg.conf
  if ! grep -qx 'allow-weak-key-signatures' "$gpgconf" 2>/dev/null; then
    log "Permitting archlinux32 SHA1 key-signatures (allow-weak-key-signatures)"
    echo 'allow-weak-key-signatures' >> "$gpgconf"
  fi
  # archlinux32 packager keys are cross-signed by 3 master keys, each given only
  # marginal ownertrust — but one master key is currently expired, leaving 2 valid
  # marginal introducers. GPG's default marginals-needed is 3, so packager keys
  # never reach full validity and every i686 package fails to verify. Require 2.
  if ! grep -qx 'marginals-needed 2' "$gpgconf" 2>/dev/null; then
    log "Setting marginals-needed 2 (one archlinux32 master key is expired)"
    echo 'marginals-needed 2' >> "$gpgconf"
  fi

  if [ -f /etc/pacman.d/gnupg/archlinux32-populated ]; then
    log "archlinux32 keys already populated; rebuilding trustdb"
    pacman-key --updatedb
    return 0
  fi
  command -v bsdtar >/dev/null || die "bsdtar (libarchive) required"
  command -v curl   >/dev/null || die "curl required"

  local core_url="${mirror_tmpl//\$arch/i686}"; core_url="${core_url//\$repo/core}"
  local tmp; tmp="$(mktemp -d)"
  log "Importing archlinux32 keyring from $core_url"
  curl -fsSL "$core_url/core.db" -o "$tmp/core.db" || die "fetch core.db failed"

  local fname
  fname="$(bsdtar -xOf "$tmp/core.db" --include='*/desc' 2>/dev/null \
    | awk '/^%FILENAME%$/{getline; if ($0 ~ /^archlinux32-keyring-[0-9]/) print $0}' | head -n1)"
  [ -n "$fname" ] || die "archlinux32-keyring not found in core.db"

  curl -fsSL "$core_url/$fname" -o "$tmp/keyring.pkg" || die "download $fname failed"
  bsdtar -xf "$tmp/keyring.pkg" -C "$tmp" usr/share/pacman/keyrings || die "extract keyring failed"

  install -Dm644 "$tmp"/usr/share/pacman/keyrings/archlinux32.gpg     /usr/share/pacman/keyrings/archlinux32.gpg
  install -Dm644 "$tmp"/usr/share/pacman/keyrings/archlinux32-trusted /usr/share/pacman/keyrings/archlinux32-trusted
  [ -f "$tmp"/usr/share/pacman/keyrings/archlinux32-revoked ] && \
    install -Dm644 "$tmp"/usr/share/pacman/keyrings/archlinux32-revoked /usr/share/pacman/keyrings/archlinux32-revoked

  pacman-key --populate archlinux32 || die "pacman-key --populate archlinux32 failed"
  pacman-key --updatedb
  touch /etc/pacman.d/gnupg/archlinux32-populated
  rm -rf "$tmp"
  log "archlinux32 master keys imported and populated"
}

arch="${1:?usage: bootstrap-chroot.sh <arch>}"
conf="$(arch_conf "$arch")" || die "no config for arch '$arch'"

base="$(toml_get "$conf" base)"
cflags="$(toml_get "$conf" cflags)"
mirror="$(toml_get "$conf" chroot.mirror)"
keyring="$(toml_get "$conf" chroot.keyring)"

chroot_root="$PKGMIRROR_DATA/chroots/$arch/root"
ready_marker="$chroot_root/.pkgmirror-ready"
# Consider a chroot done only if it completed (marker present). A dir without the
# marker is a partial/failed bootstrap — remove it and start clean.
if [ -f "$ready_marker" ]; then
  log "chroot for '$arch' already complete at $chroot_root — skipping"
  exit 0
fi
if [ -d "$chroot_root" ]; then
  warn "removing incomplete chroot at $chroot_root"
  rm -rf "$chroot_root"
fi
install -d "$(dirname "$chroot_root")"

case "$base" in
  x86_64)
    log "Bootstrapping x86_64 chroot for '$arch' (native devtools)"
    mkarchroot "$chroot_root" base-devel
    ;;

  i686)
    log "Bootstrapping i686 chroot for '$arch' via archlinux32"
    ensure_archlinux32_keys "$mirror"

    # Throwaway pacman.conf pointing at archlinux32 mirrors; signatures are now
    # verifiable against the imported archlinux32 master keys.
    local_conf="$(mktemp)"
    cat >"$local_conf" <<EOF
[options]
Architecture = i686
SigLevel     = Required DatabaseOptional
[core]
Server = ${mirror}
[extra]
Server = ${mirror}
EOF
    setarch i686 mkarchroot -C "$local_conf" "$chroot_root" base-devel
    rm -f "$local_conf"
    ;;

  *)
    die "unknown base '$base' for arch '$arch' (expected i686 or x86_64)"
    ;;
esac

# The chroot's own pacman installs makedepends at build time; disable pacman's
# Landlock/alpm download sandbox there too (unavailable in the LXC), or dep
# installation fails. -c re-syncs copies from root, so this propagates to them.
pc="$chroot_root/etc/pacman.conf"
if [ -f "$pc" ] && ! grep -q '^DisableSandbox' "$pc"; then
  sed -i '/^\[options\]/a DisableSandbox' "$pc"
  log "disabled pacman sandbox in $arch chroot"
fi

# Tune the chroot's makepkg.conf for this arch (done as root here; builds run as
# the unprivileged pkgmirror user and can't edit the root-owned chroot). -c copies
# root/ per build, so these flags propagate to every makechrootpkg invocation.
# Append overrides rather than editing in place: makepkg.conf is sourced top-to-
# bottom so later assignments win, and the stock CFLAGS is a multi-line value that
# an in-place sed would corrupt. CARCH/CHOST are left untouched (i686 vs x86_64).
mp="$chroot_root/etc/makepkg.conf"
if [ -f "$mp" ] && [ -n "$cflags" ] && ! grep -q '# pkgmirror-tuning' "$mp"; then
  cat >>"$mp" <<EOF

# pkgmirror-tuning (overrides the defaults above; arch=$arch)
CFLAGS="$cflags"
CXXFLAGS="$cflags"
MAKEFLAGS="-j\$(nproc)"
EOF
  log "tuned makepkg.conf CFLAGS for '$arch': $cflags"
fi

touch "$ready_marker"
log "chroot for '$arch' ready at $chroot_root"
