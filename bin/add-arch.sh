#!/usr/bin/env bash
# bin/add-arch.sh <name> --base <i686|x86_64> --cflags "<cflags>" [--mirror URL] [--keyring NAME]
#
# Scaffolds a new arch: writes config/arches/<name>.toml, seeds an empty
# config/packages/<name>.toml and pkgbuilds/<name>/, creates the served repo dir,
# and bootstraps the build chroot by reusing installer/bootstrap-chroot.sh.
#
# This is the low-friction "add a new arch" path — a config entry + chroot
# bootstrap, no code changes.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

name=""; base=""; cflags=""; mirror=""; keyring=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base)    base="$2";    shift 2 ;;
    --cflags)  cflags="$2";  shift 2 ;;
    --mirror)  mirror="$2";  shift 2 ;;
    --keyring) keyring="$2"; shift 2 ;;
    -*) die "unknown arg: $1" ;;
    *)  name="$1"; shift ;;
  esac
done

[ -n "$name" ]  || die "usage: add-arch.sh <name> --base <i686|x86_64> --cflags \"...\""
[ -n "$base" ]  || die "--base is required (i686 or x86_64)"
[ -n "$cflags" ] || die "--cflags is required"
conf="$PKGMIRROR_ROOT/config/arches/$name.toml"
[ -e "$conf" ] && die "arch '$name' already exists ($conf)"

# Sensible per-base defaults for mirror/keyring/toolchain.
case "$base" in
  i686)
    toolchain="devtools32"
    : "${mirror:=https://mirror.archlinux32.org/\$arch/\$repo}"
    : "${keyring:=archlinux32-keyring}"
    ;;
  x86_64)
    toolchain="devtools"
    : "${mirror:=https://geo.mirror.pkgbuild.com/\$repo/os/\$arch}"
    : "${keyring:=archlinux-keyring}"
    ;;
  *) die "unknown base '$base' (expected i686 or x86_64)" ;;
esac

log "Writing $conf"
cat >"$conf" <<EOF
name      = "$name"
base      = "$base"
toolchain = "$toolchain"
cflags    = "$cflags"
groups    = ["essentials"]

[chroot]
mirror  = "$mirror"
keyring = "$keyring"
EOF

# Seed package list + pkgbuild override dir + served repo dir.
pkglist="$PKGMIRROR_ROOT/config/packages/$name.toml"
[ -e "$pkglist" ] || cat >"$pkglist" <<EOF
# Package build list for the "$name" ($base) arch. See config/packages/atom.toml
# for field semantics (tier / source).
EOF
install -d "$PKGMIRROR_ROOT/pkgbuilds/$name"
install -d "$PKGMIRROR_DATA/repos/$name" 2>/dev/null || true

# Bootstrap the chroot now if we're inside the container (root + installer present).
bootstrap="$PKGMIRROR_ROOT/installer/bootstrap-chroot.sh"
if [ -x "$bootstrap" ] && [ "$(id -u)" -eq 0 ]; then
  log "Bootstrapping chroot for '$name'"
  REPO_ROOT="$PKGMIRROR_ROOT" "$bootstrap" "$name"
else
  warn "Skipped chroot bootstrap (not root or installer missing)."
  warn "Run as root inside the container: installer/bootstrap-chroot.sh $name"
fi

log "Arch '$name' added. Enable its timer: systemctl enable --now pkgmirror-build@${name}.timer"
