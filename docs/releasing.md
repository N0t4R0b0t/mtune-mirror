# Releasing & deploying (maintainer notes)

This covers cutting a tagged release and pushing changes to a live container —
neither is covered by the user-facing [user guide](user-guide.md).

## CI

`.github/workflows/ci.yml` runs on every push/PR to `main`: `shellcheck -S error`
on `bin/`/`installer/`/`docker/`, a `bash -n` syntax pass, `go build`/`go vet` for
`web/`, and a TOML syntax check across `config/`. Severity is capped at `error` —
the codebase isn't shellcheck-clean at `warning`/`info` (see e.g. `pkg_override_sep`
referenced-but-unassigned, SC1091 on sourced libs), and those are stylistic, not bugs.

## Cutting a release

```bash
git tag v0.1.0
git push origin v0.1.0
```

`.github/workflows/release.yml` triggers on `v*` tags:

1. Builds a static `pkgmirror-web` binary (`CGO_ENABLED=0`, linux/amd64).
2. Uploads it to R2 (**not** GitHub Releases storage — private-account space is
   limited) at `pkgmirror/<tag>/pkgmirror-web-<tag>-linux-amd64.tar.gz` (+ `.sha256`).
3. Publishes a small GitHub Release: install instructions pinned to the tag, plus
   `install.sh` as a downloadable asset. The binary is optional colour —
   `container-setup.sh` always builds its own from source; the release binary just
   saves that Go toolchain run on install.

Optional repo secrets (Settings → Secrets and variables → Actions) — the release
itself (tag + notes + `install.sh`) works without these; unset them and the R2
upload step just skips itself, no prebuilt binary link in the notes:

| Secret | |
|---|---|
| `R2_ACCESS_KEY_ID` | |
| `R2_SECRET_ACCESS_KEY` | |
| `R2_ACCOUNT_ID` | |
| `R2_BUCKET` | |

Optional repo **variable** (not secret — it's just a URL) `R2_PUBLIC_URL_BASE`
(e.g. an `r2.dev` subdomain or custom domain bound to the bucket) makes the release
notes print a direct download link. Without it, the upload still happens, just
without a linked URL in the notes.

Docker image publishing is intentionally deferred until the repo is public (no
point publishing images from a private source tree people can't build themselves).

## Pushing changes to a live container

`install.sh update` / `pkgmirror-update` (inside the container) only refresh
`bin/ installer/ systemd/ nginx/` — **not** `config/`, `pkgbuilds/`, or `web/`.
That's deliberate for normal updates (a container's live config/patches
shouldn't get clobbered by a code refresh), but it means neither path is enough
when you're pushing new package registrations, overrides, patches, or a UI
change ahead of a tag. For that, push the whole tree and re-run setup:

```bash
tar -cf - --exclude='.git' -C /path/to/checkout . \
  | ssh -i ~/.ssh/proxmox root@<host> "pct exec <ctid> -- tar -C /opt/pkgmirror -xf -"
ssh -i ~/.ssh/proxmox root@<host> \
  "pct exec <ctid> -- env REPO_ROOT=/opt/pkgmirror bash /opt/pkgmirror/installer/container-setup.sh"
```

`container-setup.sh` is idempotent — it skips already-bootstrapped chroots (checks
`.pkgmirror-ready`) and, as of the fix that shipped alongside this doc, always
`systemctl restart`s `pkgmirror-web` rather than relying on `enable --now` (a
no-op against an already-running unit — a rebuilt binary would silently never
get loaded without an explicit restart).

**Never invoke `bin/build.sh` (or anything under `bin/`) directly as root over
SSH.** The systemd units run it as `User=pkgmirror` (created by
`container-setup.sh`), and `makepkg` refuses outright to run as root
(`Running makepkg as root is not allowed`). Trigger builds via the dashboard,
`systemctl start pkgmirror-build@<arch>.service`, or `sudo -u pkgmirror
bin/build.sh <arch> ...` — never a bare root invocation. If you do this by
accident, it leaves root-owned files under `/run/pkgmirror` and
`/srv/pkgmirror/{work,state}` that then block the *correct* pkgmirror-user runs
with `Permission denied`; recover with:

```bash
chown -R pkgmirror:pkgmirror /run/pkgmirror /srv/pkgmirror/work /srv/pkgmirror/state
```
