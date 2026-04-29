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
codesign_details="$(codesign -dvvv "$app_path" 2>&1)"
codesign_summary="$(
  printf '%s\n' "$codesign_details" \
    | sed -n 's/^Authority=//p' \
    | awk 'NF { if (seen++) printf ", "; printf "%s", $0 } END { if (seen) print "" }'
)"
codesign_requirement="$(codesign -d -r- "$app_path" 2>&1 | sed -n 's/^# designated => //p')"
codesign_cdhash="$(
  printf '%s\n' "$codesign_details" \
    | sed -n 's/^CDHash=//p; s/^CandidateCDHash sha256=//p' \
    | head -1
)"
codesign_signature="$(printf '%s\n' "$codesign_details" | sed -n 's/^Signature=//p')"

cat > "$report_path" <<REPORT
# agentd Permission Smoke Report

- Date: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
- macOS: ${macos_version} (${build_version})
- App: ${app_path}
- App SHA-256: ${app_sha}
- Zip SHA-256: ${zip_sha:-not generated}
- Codesign authorities: ${codesign_summary:-ad-hoc}
- Codesign signature: ${codesign_signature:-unknown}
- Codesign CDHash: ${codesign_cdhash:-unknown}
- Codesign requirement: ${codesign_requirement:-unknown}
- Batch directory: ${batch_dir}

## TCC Stability

If the app is ad-hoc signed, macOS can bind Screen Recording and Accessibility
approval to the exact CDHash above. Do not rebuild between granting permissions
and verification. After approving this exact packaged app, relaunch it with:

\`\`\`
./script/build_and_run.sh --tcc-verify
\`\`\`

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
  echo "Grant Screen Recording and Accessibility in System Settings, then run ./script/build_and_run.sh --tcc-verify without rebuilding."
else
  echo "Skipped launch because --no-launch was supplied."
fi
