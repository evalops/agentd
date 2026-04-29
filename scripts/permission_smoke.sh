#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/permission_smoke.sh [--no-launch] [--no-install-applications]

Packages EvalOps agentd if needed, records local evidence, writes a permission
smoke report template, installs the tested app to /Applications by default, and
opens the installed app unless --no-launch is supplied.

Environment:
  AGENTD_APP_PATH               Source app bundle to test.
  AGENTD_APPLICATIONS_DIR       Applications directory, default /Applications.
  AGENTD_INSTALL_APPLICATIONS   Set to 0 to skip the Applications install.
USAGE
}

launch=1
install_applications="${AGENTD_INSTALL_APPLICATIONS:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --no-launch)
      launch=0
      shift
      ;;
    --no-install-applications)
      install_applications=0
      shift
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_app_path="${AGENTD_APP_PATH:-"$root/dist/EvalOps agentd.app"}"
applications_dir="${AGENTD_APPLICATIONS_DIR:-/Applications}"
installed_app_path="$applications_dir/EvalOps agentd.app"
app_path="$source_app_path"
report_path="${AGENTD_SMOKE_REPORT:-"$root/dist/permission-smoke-report.md"}"
batch_dir="${AGENTD_BATCH_DIR:-"$HOME/.evalops/agentd/batches"}"

if [[ ! -d "$source_app_path" && -n "${AGENTD_APP_PATH:-}" ]]; then
  echo "Missing source app bundle: $source_app_path" >&2
  exit 66
elif [[ ! -d "$source_app_path" ]]; then
  "$root/scripts/package_app.sh"
fi

if [[ "$install_applications" != "0" ]]; then
  if [[ "$installed_app_path" != "$applications_dir/"*"EvalOps agentd.app" ]]; then
    echo "Refusing unsafe Applications install path: $installed_app_path" >&2
    exit 64
  fi
  mkdir -p "$applications_dir"
  if [[ "$source_app_path" != "$installed_app_path" ]]; then
    rm -rf "$installed_app_path"
    ditto "$source_app_path" "$installed_app_path"
  fi
  app_path="$installed_app_path"
  echo "Installed $source_app_path -> $installed_app_path"
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
codesign_requirement="$(
  codesign -d -r- "$app_path" 2>&1 \
    | sed -n 's/^# designated => //p; s/^designated => //p'
)"
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
- Source app: ${source_app_path}
- App SHA-256: ${app_sha}
- Zip SHA-256: ${zip_sha:-not generated}
- Codesign authorities: ${codesign_summary:-ad-hoc}
- Codesign signature: ${codesign_signature:-unknown}
- Codesign CDHash: ${codesign_cdhash:-unknown}
- Codesign requirement: ${codesign_requirement:-unknown}
- Batch directory: ${batch_dir}

## TCC Stability

This smoke installs the tested app to a stable Applications path before launch,
because macOS TCC approvals can bind to both app identity and path. Do not move,
rebuild, or replace this exact app between granting permissions and
verification. After approving it, relaunch it with:

\`\`\`
AGENTD_APP_PATH="${app_path}" ./script/build_and_run.sh --tcc-verify
\`\`\`

If System Settings shows "EvalOps agentd.app" enabled but capture still fails
with a TCC denial, remove the existing Screen & System Audio Recording and
Accessibility rows and re-add the exact app path above. macOS can retain a
stale path/signature row with the same display name after ad-hoc or downloaded
artifact changes.

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
  echo "Grant Screen Recording and Accessibility in System Settings, then run AGENTD_APP_PATH=\"$app_path\" ./script/build_and_run.sh --tcc-verify without rebuilding or moving the app."
else
  echo "Skipped launch because --no-launch was supplied."
fi
