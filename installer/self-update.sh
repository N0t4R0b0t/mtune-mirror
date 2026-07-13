#!/usr/bin/env bash
# installer/self-update.sh — runs INSIDE the container (as root). Updates the
# pkgmirror tooling in place, then re-applies setup. Symlinked to
# /usr/local/bin/pkgmirror-update by container-setup.sh, so from inside the CT:
#
#     pkgmirror-update
#
# If /opt/pkgmirror is a git checkout it fast-forwards from the tracked remote
# (preserving committed config/pkgbuilds and merging code). Otherwise it assumes
# code was already refreshed on disk (e.g. host pushed it) and just re-applies
# setup. Either way container-setup.sh is idempotent, so this is safe to re-run.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/opt/pkgmirror}"
cd "$REPO_ROOT"

if [ -d .git ]; then
  echo "==> Updating $REPO_ROOT via git"
  git fetch --quiet origin
  # Fast-forward only: never silently discard local commits to config/pkgbuilds.
  if ! git merge --ff-only "@{u}"; then
    echo "!! local changes prevent a fast-forward; resolve manually in $REPO_ROOT" >&2
    exit 1
  fi
else
  echo "==> $REPO_ROOT is not a git checkout; re-applying setup with on-disk code"
fi

echo "==> Re-applying container setup"
REPO_ROOT="$REPO_ROOT" bash "$REPO_ROOT/installer/container-setup.sh"

# container-setup rebuilds pkgmirror-web; make sure the running service picks it up.
if systemctl list-unit-files pkgmirror-web.service >/dev/null 2>&1; then
  systemctl restart pkgmirror-web 2>/dev/null || true
fi
echo "==> pkgmirror update complete"
