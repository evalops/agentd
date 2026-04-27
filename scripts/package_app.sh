#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
product="${AGENTD_PRODUCT:-agentd}"
configuration="${CONFIGURATION:-release}"
dist_dir="${DIST_DIR:-"$root/dist"}"
app_name="${AGENTD_APP_NAME:-EvalOps agentd}"
app_path="$dist_dir/$app_name.app"
zip_path="$dist_dir/$product.zip"
identity="${AGENTD_CODESIGN_IDENTITY:--}"
entitlements="${AGENTD_ENTITLEMENTS:-"$root/support/agentd.entitlements"}"

mkdir -p "$dist_dir"

swift build -c "$configuration" --product "$product"
build_bin_dir="$(swift build -c "$configuration" --product "$product" --show-bin-path)"
binary="$build_bin_dir/$product"

rm -rf "$app_path" "$zip_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$root/support/Info.plist" "$app_path/Contents/Info.plist"
cp "$binary" "$app_path/Contents/MacOS/$product"
chmod 0755 "$app_path/Contents/MacOS/$product"

codesign_args=(
  --force
  --sign "$identity"
  --options runtime
  --entitlements "$entitlements"
)
if [[ "$identity" != "-" ]]; then
  codesign_args+=(--timestamp)
fi
codesign "${codesign_args[@]}" "$app_path"
codesign --verify --strict --deep --verbose=2 "$app_path"

ditto -c -k --keepParent "$app_path" "$zip_path"

notarized=0
if [[ -n "${AGENTD_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$zip_path" --keychain-profile "$AGENTD_NOTARY_PROFILE" --wait
  xcrun stapler staple "$app_path"
  notarized=1
elif [[ -n "${AGENTD_NOTARY_APPLE_ID:-}" && -n "${AGENTD_NOTARY_TEAM_ID:-}" && -n "${AGENTD_NOTARY_PASSWORD:-}" ]]; then
  xcrun notarytool submit "$zip_path" \
    --apple-id "$AGENTD_NOTARY_APPLE_ID" \
    --team-id "$AGENTD_NOTARY_TEAM_ID" \
    --password "$AGENTD_NOTARY_PASSWORD" \
    --wait
  xcrun stapler staple "$app_path"
  notarized=1
else
  echo "Skipping notarization: set AGENTD_NOTARY_PROFILE or AGENTD_NOTARY_APPLE_ID/TEAM_ID/PASSWORD."
fi

if [[ "$notarized" == "1" ]] && command -v spctl >/dev/null 2>&1; then
  spctl -a -t exec -vv "$app_path"
fi

echo "Packaged $app_path"
echo "Archive $zip_path"
