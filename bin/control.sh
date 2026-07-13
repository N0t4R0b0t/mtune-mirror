#!/usr/bin/env bash
# bin/control.sh <pause|resume|stop|status>
#
# Operator control over the build system — for shutting the server down cleanly or
# temporarily reclaiming its cores:
#   pause   set the global pause flag AND stop any running builds (frees the cores).
#           Scheduled + manual builds then no-op until resume. Survives reboot.
#   resume  clear the pause flag.
#   stop    stop running builds now, WITHOUT setting pause (they can start again).
#   status  print paused/active and any running build units.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

flag="$PKGMIRROR_DATA/state/paused"

running_units() {
  systemctl list-units --plain --no-legend --state=active \
    'pkgmirror-build@*.service' 'pkgmirror-adhoc-*.service' 2>/dev/null | awk '{print $1}'
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
}

case "${1:?usage: control.sh <pause|resume|stop|status>}" in
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
  status)
    if [ -f "$flag" ]; then echo "paused"; else echo "active"; fi
    echo "running:"
    running_units | sed 's/^/  /'
    ;;
  *) die "usage: control.sh <pause|resume|stop|status>" ;;
esac
