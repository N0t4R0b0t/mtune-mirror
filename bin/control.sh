#!/usr/bin/env bash
# bin/control.sh <pause|resume|stop|stop-arch <arch>|status>
#
# Operator control over the build system — for shutting the server down cleanly or
# temporarily reclaiming its cores:
#   pause         set the global pause flag AND stop any running builds (frees the
#                 cores). Scheduled + manual builds then no-op until resume.
#                 Survives reboot.
#   resume        clear the pause flag.
#   stop          stop ALL running builds now, WITHOUT setting pause (they can
#                 start again).
#   stop-arch <a> stop only <a>'s running build, leaving other arches untouched.
#   status        print paused/active and any running build units.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

flag="$PKGMIRROR_DATA/state/paused"

running_units() {
  systemctl list-units --plain --no-legend --state=active \
    'pkgmirror-build@*.service' 'pkgmirror-adhoc-*.service' 2>/dev/null | awk '{print $1}'
}

# force_clear_state <arch> — drop the live-build descriptor even if the unit we
# just stopped left something behind. A build.sh process can outlive `systemctl
# stop` for its unit if a descendant (e.g. a systemd-nspawn'd compile) ends up
# outside the unit's cgroup and survives the kill — the dashboard would then show
# "still building" indefinitely with nothing left to stop it. Since the caller
# just explicitly asked to stop this arch, always clear its live state, whether
# or not every last process actually died.
force_clear_state() {
  local arch="$1" sdir="$PKGMIRROR_DATA/state/$arch"
  rm -f "$sdir/current.json"; rm -rf "$sdir/progress"
}

stop_running() {
  local u any=0
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    any=1
    log "stopping $u"
    sudo systemctl stop "$u" 2>/dev/null || true
  done < <(running_units)
  [ "$any" -eq 1 ] || log "no running builds"
  local f a
  for f in "$PKGMIRROR_ROOT"/config/arches/*.toml; do
    a="$(basename "$f" .toml)"
    force_clear_state "$a"
  done
}

# stop_arch <arch> — stop only this arch's build: its scheduled unit
# (pkgmirror-build@<arch>.service) plus whichever adhoc unit (if any) is
# currently running it, identified via state/<arch>/current.json's own "unit"
# field rather than guessing from the unit name — an ad-hoc build's unit name is
# an opaque timestamp, not tied to the arch name, so pattern-matching on it can't
# distinguish "this arch's build" from "some other arch's build" when several
# are in flight at once (the reason a global Stop only reliably kills whichever
# one it happens to match, not "the other one" a caller actually wanted stopped).
stop_arch() {
  local arch="$1" cur="$PKGMIRROR_DATA/state/$arch/current.json" u=""
  systemctl is-active --quiet "pkgmirror-build@${arch}.service" 2>/dev/null \
    && { log "stopping pkgmirror-build@${arch}.service"; sudo systemctl stop "pkgmirror-build@${arch}.service" 2>/dev/null || true; }
  if [ -f "$cur" ]; then
    u="$(toml_get_json_unit "$cur" 2>/dev/null || true)"
    if [ -n "$u" ]; then
      log "stopping $u (arch=$arch)"
      sudo systemctl stop "$u" 2>/dev/null || true
    fi
  fi
  force_clear_state "$arch"
}

# toml_get_json_unit <file> -> the "unit" field of a current.json descriptor.
# It's JSON, not TOML, but jq isn't guaranteed present on a minimal Arch image —
# a plain grep/sed is plenty for this one flat, machine-written field.
toml_get_json_unit() {
  grep -o '"unit":"[^"]*"' "$1" | head -1 | sed 's/"unit":"\(.*\)"/\1/'
}

case "${1:?usage: control.sh <pause|resume|stop|stop-arch <arch>|status>}" in
  pause)
    mkdir -p "$(dirname "$flag")"
    : > "$flag"
    log "builds PAUSED"
    stop_running
    ;;
  resume)
    rm -f "$flag"
    log "builds RESUMED"
    ;;
  stop)
    stop_running
    ;;
  stop-arch)
    arch="${2:?usage: control.sh stop-arch <arch>}"
    arch_conf "$arch" >/dev/null || exit 1
    stop_arch "$arch"
    ;;
  status)
    if [ -f "$flag" ]; then echo "paused"; else echo "active"; fi
    echo "running:"
    running_units | sed 's/^/  /'
    ;;
  *) die "usage: control.sh <pause|resume|stop|stop-arch <arch>|status>" ;;
esac
