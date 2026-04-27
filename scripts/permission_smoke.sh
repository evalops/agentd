#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/permission_smoke.sh [--no-launch]

Packages EvalOps agentd if needed, records local evidence, writes a permission
smoke report template, and opens the app unless --no-launch is supplied.
USAGE
}

launch=1
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
elif [[ "${1:-}" == "--no-launch" ]]; then
  launch=0
elif [[ $# -gt 0 ]]; then
  usage >&2
  exit 64
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="${AGENTD_APP_PATH:-"$root/dist/EvalOps agentd.app"}"
report_path="${AGENTD_SMOKE_REPORT:-"$root/dist/permission-smoke-report.md"}"
batch_dir="${AGENTD_BATCH_DIR:-"$HOME/.evalops/agentd/batches"}"

if [[ ! -d "$app_path" ]]; then
  "$root/scripts/package_app.sh"
fi

binary="$app_path/Contents/MacOS/agentd"
if [[ ! -x "$binary" ]]; then
  echo "Missing executable: $binary" >&2
  exit 66
fi

mkdir -p "$(dirname "$report_path")"
app_sha="$(shasum -a 256 "$binary" | awk '{print $1}')"
zip_sha=""
if [[ -f "$root/dist/agentd.zip" ]]; then
  zip_sha="$(shasum -a 256 "$root/dist/agentd.zip" | awk '{print $1}')"
fi
macos_version="$(sw_vers -productVersion)"
build_version="$(sw_vers -buildVersion)"
codesign_summary="$(codesign -dv "$app_path" 2>&1 | sed -n 's/^Authority=//p' | paste -sd ', ' -)"

cat > "$report_path" <<REPORT
# agentd Permission Smoke Report

- Date: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
- macOS: ${macos_version} (${build_version})
- App: ${app_path}
- App SHA-256: ${app_sha}
- Zip SHA-256: ${zip_sha:-not generated}
- Codesign authorities: ${codesign_summary:-ad-hoc}
- Batch directory: ${batch_dir}

## Checks

- [ ] Launch shows menu-bar item as "EvalOps agentd" / "agentd".
- [ ] Screen Recording prompt appears for the app bundle identity.
- [ ] Accessibility prompt appears for the app bundle identity.
- [ ] After granting permissions and relaunching, pause/resume works.
- [ ] Flush now creates a local-only batch under the batch directory.
- [ ] Denied app/path/secret smoke fixtures drop frames before persistence.

## Notes

Add concise pass/fail notes here before closing evalops/agentd#25.
REPORT

echo "Wrote $report_path"

if [[ "$launch" == "1" ]]; then
  open "$app_path"
  echo "Opened $app_path"
  echo "Grant Screen Recording and Accessibility in System Settings, relaunch, then complete $report_path."
else
  echo "Skipped launch because --no-launch was supplied."
fi
