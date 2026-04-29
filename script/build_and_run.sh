#!/usr/bin/env bash
set -euo pipefail

mode="${1:-run}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_name="EvalOps agentd"
process_name="agentd"
bundle_id="dev.evalops.agentd"
app_bundle="$root/dist/$app_name.app"

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--permission-smoke]" >&2
  exit 2
}

stop_running() {
  pkill -x "$process_name" >/dev/null 2>&1 || true
}

build_app() {
  "$root/scripts/package_app.sh"
}

open_app() {
  /usr/bin/open -n "$app_bundle"
}

stop_running

case "$mode" in
  run)
    build_app
    open_app
    ;;
  --debug|debug)
    build_app
    lldb -- "$app_bundle/Contents/MacOS/$process_name"
    ;;
  --logs|logs)
    build_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$process_name\""
    ;;
  --telemetry|telemetry)
    build_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$bundle_id\""
    ;;
  --verify|verify)
    build_app
    open_app
    sleep 2
    pgrep -x "$process_name" >/dev/null
    ;;
  --permission-smoke|permission-smoke)
    "$root/scripts/permission_smoke.sh"
    ;;
  *)
    usage
    ;;
esac
