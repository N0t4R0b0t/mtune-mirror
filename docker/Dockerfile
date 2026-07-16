# pkgmirror local build sandbox — mirrors what installer/container-setup.sh does
# inside the Proxmox LXC, for fast local iteration on package/PKGBUILD fixes
# without round-tripping through a remote host. See docker/README.md.
FROM archlinux:latest

RUN pacman -Syu --noconfirm --needed \
      devtools archlinux-keyring base-devel git curl libarchive sudo which go \
 && pacman-key --init \
 && pacman-key --populate archlinux \
 && sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf

# dasel: the TOML parser bin/lib/common.sh depends on (see container-setup.sh)
ARG DASEL_VERSION=v2.8.1
RUN curl -fsSL -o /usr/local/bin/dasel \
      "https://github.com/TomWright/dasel/releases/download/${DASEL_VERSION}/dasel_linux_amd64" \
 && chmod +x /usr/local/bin/dasel

WORKDIR /work
CMD ["/sbin/init"]
