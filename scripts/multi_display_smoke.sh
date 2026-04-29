#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/multi_display_smoke.sh [--phase NAME] [--require-multiple] [--no-build]

Records a bounded multi-display smoke snapshot for evalops/agentd#34.

Examples:
  scripts/multi_display_smoke.sh --phase before-attach
  scripts/multi_display_smoke.sh --phase after-attach --require-multiple
  scripts/multi_display_smoke.sh --phase after-detach

Environment:
  AGENTD_BIN                      Existing agentd binary to use.
  AGENTD_MULTI_DISPLAY_REPORT     Markdown report path.
USAGE
}

phase="snapshot"
require_multiple=0
build=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        usage >&2
        exit 64
      fi
      phase="$2"
      shift 2
      ;;
    --require-multiple)
      require_multiple=1
      shift
      ;;
    --no-build)
      build=0
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
report_path="${AGENTD_MULTI_DISPLAY_REPORT:-"$root/dist/multi-display-smoke-report.md"}"
snapshot_dir="$(dirname "$report_path")/multi-display-smoke"
bin="${AGENTD_BIN:-${AGENTD_AGENTD_BIN:-"$root/.build/debug/agentd"}}"
timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
safe_phase="$(printf '%s' "$phase" | tr -c 'A-Za-z0-9._-' '-')"
json_path="$snapshot_dir/${timestamp}-${safe_phase}.json"

if [[ "$build" == "1" && -z "${AGENTD_BIN:-}${AGENTD_AGENTD_BIN:-}" ]]; then
  (cd "$root" && swift build)
fi

if [[ ! -x "$bin" ]]; then
  echo "Missing agentd binary: $bin" >&2
  echo "Run swift build, or set AGENTD_BIN." >&2
  exit 66
fi

mkdir -p "$snapshot_dir"
"$bin" list-displays > "$json_path"

display_count="$(
  python3 - "$json_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
print(len(payload.get("displays", [])))
PY
)"

summary="$(
  python3 - "$json_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)

permissions = payload.get("permissions", {})
print(f"- Accessibility trusted: {permissions.get('accessibilityTrusted')}")
print(f"- Screen capture trusted: {permissions.get('screenCaptureTrusted')}")
print(f"- Display count: {len(payload.get('displays', []))}")
for display in payload.get("displays", []):
    bounds = display.get("bounds", {})
    print(
        "- Display {display_id}: {name}, {width}x{height}, scale={scale}, "
        "main={main}, bounds=({x},{y},{bw}x{bh})".format(
            display_id=display.get("displayId"),
            name=display.get("name", "unknown"),
            width=display.get("width"),
            height=display.get("height"),
            scale=display.get("scale"),
            main=display.get("isMain"),
            x=bounds.get("x"),
            y=bounds.get("y"),
            bw=bounds.get("width"),
            bh=bounds.get("height"),
        )
    )
PY
)"

if [[ ! -f "$report_path" ]]; then
  mkdir -p "$(dirname "$report_path")"
  cat > "$report_path" <<'REPORT'
# agentd Multi-Display Smoke Report

Use this report for evalops/agentd#34. Recommended phases:

1. `before-attach`: run with the normal desktop display setup.
2. `after-attach`: attach the external display, wait for macOS display
   arrangement to settle, then run with `--require-multiple`.
3. `capture-all`: enable `captureAllDisplays` through local config or managed
   policy, run agentd long enough to capture at least one batch, then attach
   diagnostics/batch metadata counts without raw OCR.
4. `after-detach`: detach the external display and rerun to confirm diagnostics
   return to the expected single-display shape without restarting the machine.

Do not paste raw OCR text or screenshots into this report.

REPORT
fi

cat >> "$report_path" <<REPORT
## ${phase} (${timestamp})

- Snapshot JSON: ${json_path}
- agentd binary: ${bin}
${summary}

\`\`\`json
$(cat "$json_path")
\`\`\`

REPORT

echo "Wrote $json_path"
echo "Updated $report_path"

if [[ "$require_multiple" == "1" && "$display_count" -lt 2 ]]; then
  echo "Expected at least two displays for phase '$phase', found $display_count." >&2
  exit 78
fi
