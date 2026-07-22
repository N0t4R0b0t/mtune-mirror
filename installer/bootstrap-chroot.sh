#!/usr/bin/env bash
# installer/bootstrap-chroot.sh <arch> — runs INSIDE the container (as root).
# Bootstraps one arch's build chroot, dispatching on the arch's `base`:
#   x86_64 -> standard devtools mkarchroot (native), OR -- if chroot.keyring
#             is "manjaro-keyring" -- against Manjaro's own repos instead of
#             the container's vanilla-Arch mirrorlist (see
#             ensure_manjaro_keys). Any other x86_64 arch's chroot.mirror/
#             keyring fields are still unused, same as before.
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

# ensure_manjaro_keys <mirror-template>
# Same trust-on-first-use import as ensure_archlinux32_keys, for Manjaro's own
# manjaro-keyring -- it isn't in official Arch repos or AUR either, so there's
# no plain `pacman-key --populate manjaro` without the key material on disk
# first. Deliberately does NOT carry over archlinux32's allow-weak-key-
# signatures/marginals-needed GPG trust relaxations -- those work around a
# specific, confirmed archlinux32 problem (an expired master key, legacy SHA1
# cross-signing); nothing found during research suggests Manjaro's keyring has
# the same issue, and weakening GPG trust with no demonstrated need would be a
# real regression, not a safe default. If a real signature failure shows up
# here, diagnose that specific problem for real -- don't pre-guess it.
# Idempotent via a marker in the gnupg home.
ensure_manjaro_keys() {
  local mirror_tmpl="$1"

  if [ -f /etc/pacman.d/gnupg/manjaro-populated ]; then
    log "manjaro keys already populated; rebuilding trustdb"
    pacman-key --updatedb
    return 0
  fi
  command -v bsdtar >/dev/null || die "bsdtar (libarchive) required"
  command -v curl   >/dev/null || die "curl required"

  local core_url="${mirror_tmpl//\$arch/x86_64}"; core_url="${core_url//\$repo/core}"
  local tmp; tmp="$(mktemp -d)"
  log "Importing manjaro keyring from $core_url"
  curl -fsSL "$core_url/core.db" -o "$tmp/core.db" || die "fetch core.db failed"

  local fname
  fname="$(bsdtar -xOf "$tmp/core.db" --include='*/desc' 2>/dev/null \
    | awk '/^%FILENAME%$/{getline; if ($0 ~ /^manjaro-keyring-[0-9]/) print $0}' | head -n1)"
  [ -n "$fname" ] || die "manjaro-keyring not found in core.db"

  curl -fsSL "$core_url/$fname" -o "$tmp/keyring.pkg" || die "download $fname failed"
  bsdtar -xf "$tmp/keyring.pkg" -C "$tmp" usr/share/pacman/keyrings || die "extract keyring failed"

  install -Dm644 "$tmp"/usr/share/pacman/keyrings/manjaro.gpg     /usr/share/pacman/keyrings/manjaro.gpg
  install -Dm644 "$tmp"/usr/share/pacman/keyrings/manjaro-trusted /usr/share/pacman/keyrings/manjaro-trusted
  [ -f "$tmp"/usr/share/pacman/keyrings/manjaro-revoked ] && \
    install -Dm644 "$tmp"/usr/share/pacman/keyrings/manjaro-revoked /usr/share/pacman/keyrings/manjaro-revoked

  pacman-key --populate manjaro || die "pacman-key --populate manjaro failed"
  pacman-key --updatedb
  touch /etc/pacman.d/gnupg/manjaro-populated
  rm -rf "$tmp"
  log "manjaro master keys imported and populated"
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
# marker is a partial/failed bootstrap — remove it and start clean. The EXPENSIVE
# step (mkarchroot + keyring import) is skipped once ready; the lightweight config
# below it (sandbox/CFLAGS/local-repo wiring) is NOT gated on this, so re-running
# bootstrap-chroot.sh (e.g. via container-setup.sh on every install.sh update)
# always re-applies config changes to an already-bootstrapped chroot too — each
# step is independently idempotent via its own grep-based check.
already_ready=0
if [ -f "$ready_marker" ]; then
  log "chroot for '$arch' already complete at $chroot_root — refreshing config only"
  already_ready=1
elif [ -d "$chroot_root" ]; then
  warn "removing incomplete chroot at $chroot_root"
  rm -rf "$chroot_root"
fi
install -d "$(dirname "$chroot_root")"

if [ "$already_ready" -eq 0 ]; then
case "$base" in
  x86_64)
    if [ "$keyring" = "manjaro-keyring" ]; then
      log "Bootstrapping x86_64 chroot for '$arch' via Manjaro (not vanilla Arch)"
      ensure_manjaro_keys "$mirror"

      # Throwaway pacman.conf pointing at Manjaro's own mirrors; deliberately
      # NOT the container's vanilla-Arch mirrorlist -- see manjaro.toml's own
      # comment for why (Manjaro holds packages back from Arch's extra for
      # stability, so building against Arch here would produce packages
      # newer than what's actually on the real target machine).
      local_conf="$(mktemp)"
      cat >"$local_conf" <<EOF
[options]
Architecture = x86_64
SigLevel     = Required DatabaseOptional
[core]
Server = ${mirror}
[extra]
Server = ${mirror}
EOF
      mkarchroot -C "$local_conf" "$chroot_root" base-devel
      rm -f "$local_conf"
    else
      log "Bootstrapping x86_64 chroot for '$arch' (native devtools)"
      mkarchroot "$chroot_root" base-devel
    fi
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

    # archlinux32 splits old SONAMEs a package still needs (e.g. a lagged
    # qt6-base built against libicui18n.so.75, or librsvg against
    # libxml2.so.2) into separate compat packages (icu75, libxml2-legacy,
    # ...) that pacman's normal dependency resolution does NOT auto-pull in
    # -- confirmed 2026-07-22: neither appears in `pacman -Sup <target>`'s
    # resolved transaction even though they're valid, available providers of
    # the exact soname required. Install them explicitly into the base chroot
    # now so every build (which syncs its working copy FROM this base) has
    # them; otherwise builds needing a lagged package's true dependency fail
    # with "cannot open shared object file" deep into prepare()/postinst
    # hooks, not a clean dependency-resolution error. Re-run whenever this
    # bites a newly-lagged package's own old SONAME shim.
    setarch i686 pacman -Syu --noconfirm \
      --config "$chroot_root/etc/pacman.conf" \
      --root "$chroot_root" --dbpath "$chroot_root/var/lib/pacman" \
      icu75 libxml2-legacy
    ;;

  *)
    die "unknown base '$base' for arch '$arch' (expected i686 or x86_64)"
    ;;
esac
fi

# Wire this arch's own served repo into the chroot's OWN pacman.conf, not just
# client machines' (see README quick-start) -- without this, a package we build
# and publish locally (e.g. a newer fontconfig than archlinux32 ships) can never
# be picked up as a build dependency by another local build (e.g. pango), since
# the chroot could only ever see archlinux32/Arch's official repos. Listed FIRST
# so it takes priority over core/extra when both provide a package. TrustAll:
# our own build output isn't gpg-signed. Loopback HTTP (not a bind-mounted
# file:// path) since the chroot doesn't have /srv/pkgmirror mounted in, but
# does share the host's network namespace (no --private-network in the
# nspawn invocation), so nginx's own served /repos/<arch>/ is reachable.
pc="$chroot_root/etc/pacman.conf"
if [ -f "$pc" ] && ! grep -q "^\[${arch}-local\]" "$pc"; then
  # Inserted before [core] (assumed to exist and come first among repo
  # sections, true for both the archlinux32 throwaway conf above and the
  # default Arch pacman.conf mkarchroot seeds x86_64 chroots with), not right
  # after [options]'s own header line -- that would swallow [options]'s
  # remaining directives (DisableSandbox, Architecture, ...) as if they
  # belonged to this new section instead, since ini-style config groups every
  # line up to the next header under the last-seen one.
  sed -i "/^\[core\]/i [${arch}-local]\nSigLevel = Optional TrustAll\nServer = http://127.0.0.1/repos/${arch}\n" "$pc"
  log "wired local repo '${arch}-local' into $arch chroot's pacman.conf"
fi

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
MAKEFLAGS="-j\$(nproc) -l\$(nproc)"
EOF
  log "tuned makepkg.conf CFLAGS for '$arch': $cflags"
fi

# tmpfs for the makechrootpkg build COPY (chroots/$arch/pkgmirror, sibling of
# root/) -- pure scratch, wiped and re-synced from root/ on every package build
# (makechrootpkg -c), but the actual compile happens here: every object file,
# header, and linker temp file this package's build touches. Host storage is
# spinning HDDs behind ZFS (see proxmox-test-server); moving this off disk
# removes it from a compile's small-file I/O path entirely -- see
# container-setup.sh's matching $DATA_ROOT/work tmpfs for the measured impact
# (even tiny packages were taking 60-250s, openssl took 55 minutes, on a
# 16-core/16GB container that wasn't CPU-saturated). root/ itself stays on
# disk -- it must survive container reboots without a full re-bootstrap.
copy_dir="$(dirname "$chroot_root")/pkgmirror"
if ! mountpoint -q "$copy_dir" 2>/dev/null; then
  # Default 10G: 8G genuinely wasn't enough for a full mesa build (many
  # gallium/vulkan driver .so targets + debug symbols) or an unstripped
  # kernel build (vmlinux.unstripped link step) -- both hit "No space left
  # on device" at 8G on real builds (2026-07-15). 10G itself then turned out
  # insufficient for linux-btver1's specific kernel config (2026-07-18) --
  # optional per-arch chroot.build_tmpfs_gb overrides the default for an
  # arch that needs more, without growing every other arch's cap too (each
  # arch's tmpfs draws from the same container RAM pool, all summed against
  # container-setup.sh's matching $DATA_ROOT/work tmpfs -- oversize this
  # without real headroom and you trade an ENOSPC for an OOM instead).
  tmpfs_gb="$(toml_get "$conf" chroot.build_tmpfs_gb)"
  case "$tmpfs_gb" in ''|*[!0-9]*) tmpfs_gb=10 ;; esac
  log "Mounting tmpfs at $copy_dir for build scratch space (${tmpfs_gb}G)"
  install -d "$copy_dir"
  mount -t tmpfs -o "size=${tmpfs_gb}G,mode=0755" tmpfs "$copy_dir"
  grep -q "^tmpfs $copy_dir " /etc/fstab 2>/dev/null || \
    echo "tmpfs $copy_dir tmpfs defaults,size=${tmpfs_gb}G,mode=0755 0 0" >> /etc/fstab
fi

touch "$ready_marker"
log "chroot for '$arch' ready at $chroot_root"
