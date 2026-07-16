# Local build sandbox

A privileged Docker container that replicates the Proxmox LXC's build
environment (devtools, archlinux32 keyring, dasel) for iterating on package
fixes without a remote host round-trip. Not a deployment target — see the main
[README](../README.md) for that; this is a dev tool.

Requires: Docker, a kernel that supports nested systemd-nspawn (any recent
Linux; the container runs actual systemd as PID 1, which is why it needs
`--privileged`).

```bash
docker/sandbox.sh up                    # build the image, start the container
docker/sandbox.sh bootstrap atom        # one-time chroot bootstrap (~10-15 min);
                                         # persists in the pkgmirror-chroots volume
docker/sandbox.sh build atom --pkg openssl --force
docker/sandbox.sh override atom openssl --patches i686-target.patch --notes "..."
docker/sandbox.sh shell                 # interactive shell as the pkgmirror user
docker/sandbox.sh down                  # stop + remove the container (chroots survive)
```

The repo is bind-mounted read-write at `/opt/pkgmirror` inside the container, so
`override`/`build` write straight into your working tree — patches you land
here are the same files `git add` picks up.

## How it works

`mkarchroot`/`makechrootpkg` (Arch's `devtools`) drive `systemd-nspawn`, which
needs a working `dbus`/`systemd-machined` to register containers — so the
sandbox runs real `systemd` as PID 1 (`docker run ... image /sbin/init`), not
just a `sleep infinity` placeholder. Two extra one-time fixups `up` applies
automatically:

- `mount --make-rshared /` — nspawn's own internal mount-propagation setup
  fails under Docker's default private propagation, surfacing as `Attempted to
  remove disk file system under .../propagate/..., and we can't allow that.`
- `systemd-machine-id-setup` — without `/etc/machine-id`, nspawn falls back to
  a PID-keyed path for its runtime dirs, which trips the same propagation
  safety check above (`Failed to retrieve machine ID` immediately precedes it
  in the log).

Chroots live in the `pkgmirror-chroots` named volume, independent of the
container's lifecycle — `sandbox.sh down && sandbox.sh up` doesn't lose them.
