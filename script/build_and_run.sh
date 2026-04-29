#!/usr/bin/env bash
set -euo pipefail

mode="${1:-run}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_name="EvalOps agentd"
process_name="agentd"
bundle_id="dev.evalops.agentd"
default_app_bundle="$root/dist/$app_name.app"
app_bundle="${AGENTD_APP_PATH:-"$default_app_bundle"}"

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--reuse|--tcc-verify|--local-batch-verify|--permission-smoke]" >&2
  echo "       set AGENTD_APP_PATH to verify a downloaded/notarized app bundle without copying it into dist/" >&2
  exit 2
}

stop_running() {
  pkill -x "$process_name" >/dev/null 2>&1 || true
}

build_app() {
  "$root/scripts/package_app.sh"
}

require_existing_app() {
  if [[ ! -x "$app_bundle/Contents/MacOS/$process_name" ]]; then
    echo "Missing packaged app: $app_bundle" >&2
    echo "Run $0 once before no-rebuild verification, or set AGENTD_APP_PATH to an existing app bundle." >&2
    exit 66
  fi
}

describe_app_identity() {
  echo "App bundle: $app_bundle" >&2
  if codesign_details="$(codesign -dvvv "$app_bundle" 2>&1)"; then
    printf '%s\n' "$codesign_details" \
      | sed -n 's/^Authority=/Codesign authority: /p; s/^CDHash=/Codesign CDHash: /p; s/^TeamIdentifier=/Team identifier: /p; s/^Notarization Ticket=/Notarization ticket: /p' >&2
  else
    printf '%s\n' "$codesign_details" >&2
  fi
  codesign -d -r- "$app_bundle" 2>&1 \
    | sed -n 's/^# designated => /Designated requirement: /p; s/^designated => /Designated requirement: /p' >&2 || true
  spctl -a -vv "$app_bundle" >&2 || true
}

open_app() {
  /usr/bin/open -n "$app_bundle"
}

activate_probe_app() {
  local foreground_app="${AGENTD_SMOKE_FOREGROUND_APP:-Codex}"
  if [[ -n "$foreground_app" ]]; then
    osascript -e "tell application \"$foreground_app\" to activate" >/dev/null 2>&1 || true
  fi
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
  --reuse|reuse)
    require_existing_app
    open_app
    ;;
  --tcc-verify|tcc-verify)
    require_existing_app
    open_app
    sleep 2
    app_pid="$(pgrep -nx "$process_name" || true)"
    if [[ -z "$app_pid" ]]; then
      echo "TCC verification failed: $process_name did not stay running." >&2
      exit 76
    fi
    sleep 18
    recent_logs="$(
      /usr/bin/log show --last 45s --info --style compact --predicate "subsystem == \"$bundle_id\" && processID == $app_pid" 2>/dev/null \
        | tail -120
    )"
    printf '%s\n' "$recent_logs"
    if grep -q 'capture started' <<<"$recent_logs"; then
      echo "TCC verification passed: capture started."
    elif grep -q 'capture start failed' <<<"$recent_logs"; then
      describe_app_identity
      echo "TCC verification failed: capture did not start." >&2
      echo "Approve this exact app bundle in Screen & System Audio Recording and Accessibility, then rerun with the same AGENTD_APP_PATH without rebuilding or moving the app." >&2
      echo "If System Settings already shows EvalOps agentd.app enabled, the visible row may be a stale path/signature entry; remove it and re-add this exact app bundle before rerunning." >&2
      exit 78
    else
      echo "TCC verification inconclusive: no capture start/failure log found." >&2
      exit 75
    fi
    ;;
  --local-batch-verify|local-batch-verify)
    require_existing_app
    start_epoch="$(date +%s)"
    open_app
    activate_probe_app
    sleep 35
    latest_batch="$(
      {
        find "$HOME/.evalops/agentd/batches" -type f -name '*.json' -print0 2>/dev/null \
          | xargs -0 stat -f '%m %N' 2>/dev/null \
          | sort -rn \
          | sed -n '1s/^[0-9][0-9]* //p'
      } || true
    )"
    if [[ -z "$latest_batch" ]]; then
      echo "Local batch verification failed: no local JSON batches found." >&2
      exit 79
    fi
    batch_epoch="$(stat -f %m "$latest_batch")"
    if (( batch_epoch < start_epoch )); then
      echo "Local batch verification failed: newest batch predates this run: $latest_batch" >&2
      exit 79
    fi
    summary="$(
      jq '{
        file: input_filename,
        localOnly,
        batchId: .batch.batchId,
        frames: (.batch.frames | length),
        droppedCounts: .batch.droppedCounts,
        firstFrame: ((.batch.frames[0] // {}) | {
          bundleId,
          appName,
          windowTitleLength: (.windowTitle | length // 0),
          displayId,
          ocrTextLength: (.ocrText | length // 0),
          ocrTextTruncated
        })
      }' "$latest_batch"
    )"
    printf '%s\n' "$summary"
    frames="$(jq '.batch.frames | length' "$latest_batch")"
    denied_app="$(jq '.batch.droppedCounts.deniedApp // 0' "$latest_batch")"
    if (( frames > 0 )); then
      echo "Local batch verification passed: persisted sanitized frame metadata without printing OCR text."
    elif (( denied_app > 0 )); then
      echo "Local batch verification failed: frames were captured but denied by app policy. Check allowlist miss logs and AGENTD_SMOKE_FOREGROUND_APP." >&2
      exit 80
    else
      echo "Local batch verification failed: no frames reached the local batch." >&2
      exit 81
    fi
    ;;
  --permission-smoke|permission-smoke)
    "$root/scripts/permission_smoke.sh"
    ;;
  *)
    usage
    ;;
esac
