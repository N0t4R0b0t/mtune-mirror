#!/usr/bin/env bash
# docker/sandbox.sh <up|down|shell|build ARCH [build.sh args...]>
#
# Local build sandbox for fast iteration on package fixes, without a remote
# Proxmox host. Runs an actual systemd (needed for archlinux32's devtools —
# mkarchroot/makechrootpkg use systemd-nspawn, which needs a working
# dbus/machined) as PID 1 in a privileged container, with the repo bind-mounted
# read-write so bin/override.sh writes land straight in your checkout.
#
# Chroots persist in a named Docker volume (pkgmirror-chroots) across restarts,
# so bootstrapping (~10-15 min) only happens once.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

IMAGE=pkgmirror-sandbox
NAME=pkgmirror-build
REPO_ROOT="$(cd .. && pwd)"

up() {
  docker build -t "$IMAGE" .
  if ! docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
    docker run -d --name "$NAME" --privileged \
      --cgroupns=host \
      -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
      -v pkgmirror-chroots:/srv/pkgmirror \
      -v "$REPO_ROOT":/opt/pkgmirror \
      --tmpfs /run --tmpfs /run/lock \
      "$IMAGE" /sbin/init
    sleep 3
  elif [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" != "true" ]; then
    docker start "$NAME"
    sleep 3
  fi
  # Idempotent one-time-per-container-instance setup.
  docker exec "$NAME" bash -c '
    mount --make-rshared /
    [ -f /etc/machine-id ] || systemd-machine-id-setup
    id pkgmirror >/dev/null 2>&1 || useradd --system --create-home --shell /usr/bin/nologin pkgmirror
    install -d -o pkgmirror -g pkgmirror /srv/pkgmirror/work /srv/pkgmirror/repos /srv/pkgmirror/state
    for a in /opt/pkgmirror/config/arches/*.toml; do
      n="$(basename "$a" .toml)"; install -d -o pkgmirror -g pkgmirror "/srv/pkgmirror/repos/$n"
    done
    printf "pkgmirror ALL=(ALL) NOPASSWD: ALL\n" > /etc/sudoers.d/pkgmirror
    chmod 0440 /etc/sudoers.d/pkgmirror
    chown -R '"$(id -u):$(id -g)"' /opt/pkgmirror/config /opt/pkgmirror/pkgbuilds
  '
  echo "sandbox up. Bootstrap a chroot with: docker/sandbox.sh bootstrap <arch>"
}

down() { docker rm -f "$NAME" 2>/dev/null || true; }

bootstrap() {
  local arch="${1:?usage: sandbox.sh bootstrap <arch>}"
  docker exec -e REPO_ROOT=/opt/pkgmirror -e PKGMIRROR_DATA=/srv/pkgmirror "$NAME" \
    bash /opt/pkgmirror/installer/bootstrap-chroot.sh "$arch"
}

shell() { docker exec -it -u pkgmirror -e PKGMIRROR_DATA=/srv/pkgmirror -e PKGMIRROR_ROOT=/opt/pkgmirror "$NAME" bash; }

build() {
  docker exec -u pkgmirror -e PKGMIRROR_DATA=/srv/pkgmirror -e PKGMIRROR_ROOT=/opt/pkgmirror "$NAME" \
    bash /opt/pkgmirror/bin/build.sh "$@"
}

override() {
  docker exec -e PKGMIRROR_DATA=/srv/pkgmirror -e PKGMIRROR_ROOT=/opt/pkgmirror "$NAME" \
    bash -c "cd /opt/pkgmirror && bin/override.sh \"\$@\"" -- "$@"
}

cmd="${1:?usage: sandbox.sh <up|down|shell|bootstrap ARCH|build ARCH...|override ARCH...>}"; shift || true
case "$cmd" in
  up)        up ;;
  down)      down ;;
  shell)     shell ;;
  bootstrap) bootstrap "$@" ;;
  build)     build "$@" ;;
  override)  override "$@" ;;
  *) echo "unknown command: $cmd" >&2; exit 1 ;;
esac
