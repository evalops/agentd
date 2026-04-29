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
adhoc_disable_library_validation="${AGENTD_ADHOC_DISABLE_LIBRARY_VALIDATION:-1}"
sparkle_feed_url="${AGENTD_SPARKLE_FEED_URL:-}"
sparkle_public_ed_key="${AGENTD_SPARKLE_PUBLIC_ED_KEY:-}"
sparkle_download_url="${AGENTD_SPARKLE_DOWNLOAD_URL:-}"
sparkle_release_notes_url="${AGENTD_SPARKLE_RELEASE_NOTES_URL:-}"
sparkle_channel="${AGENTD_SPARKLE_CHANNEL:-}"
sparkle_phased_rollout_interval="${AGENTD_SPARKLE_PHASED_ROLLOUT_INTERVAL:-}"
sparkle_minimum_autoupdate_version="${AGENTD_SPARKLE_MINIMUM_AUTOUPDATE_VERSION:-}"
sparkle_critical_update="${AGENTD_SPARKLE_CRITICAL_UPDATE:-0}"
sparkle_appcast_path="$dist_dir/appcast.xml"
sparkle_ed_signature="${AGENTD_SPARKLE_ED_SIGNATURE:-}"
sparkle_ed_key_file="${AGENTD_SPARKLE_ED_KEY_FILE:-}"
sparkle_require_signed_feed="${AGENTD_SPARKLE_REQUIRE_SIGNED_FEED:-0}"
sparkle_bin_dir="${AGENTD_SPARKLE_BIN_DIR:-}"

mkdir -p "$dist_dir"

create_zip() {
  rm -f "$zip_path"
  ditto -c -k --keepParent "$app_path" "$zip_path"
}

plist_set_or_add() {
  local key="$1"
  local type="$2"
  local value="$3"
  local plist="$4"
  if /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist"
  else
    /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$plist"
  fi
}

require_matching_sparkle_config() {
  if [[ -n "$sparkle_feed_url" || -n "$sparkle_public_ed_key" ]]; then
    if [[ -z "$sparkle_feed_url" || -z "$sparkle_public_ed_key" ]]; then
      echo "AGENTD_SPARKLE_FEED_URL and AGENTD_SPARKLE_PUBLIC_ED_KEY must be set together." >&2
      exit 1
    fi
  fi
  if [[ -n "$sparkle_download_url" ]]; then
    if [[ -z "$sparkle_feed_url" || -z "$sparkle_public_ed_key" ]]; then
      echo "AGENTD_SPARKLE_DOWNLOAD_URL requires Sparkle feed URL and public EdDSA key." >&2
      exit 1
    fi
  fi
}

find_sparkle_framework() {
  find "$root/.build" -path "*/Sparkle.framework" -type d -print -quit 2>/dev/null || true
}

find_sparkle_sign_update() {
  if [[ -n "$sparkle_bin_dir" && -x "$sparkle_bin_dir/sign_update" ]]; then
    printf '%s\n' "$sparkle_bin_dir/sign_update"
    return
  fi
  find "$root/.build" -path "*/Sparkle/bin/sign_update" -type f -perm -111 -print -quit 2>/dev/null || true
}

codesign_nested_sparkle() {
  local framework_path="$1"
  local timestamp_args=()
  if [[ "$identity" != "-" ]]; then
    timestamp_args+=(--timestamp)
  fi

  codesign_sparkle_component() {
    local target="$1"
    shift
    local args=(--force --sign "$identity" --options runtime "$@")
    if [[ ${#timestamp_args[@]} -gt 0 ]]; then
      args+=("${timestamp_args[@]}")
    fi
    args+=("$target")
    codesign "${args[@]}"
  }

  local nested
  for nested in \
    "$framework_path"/Versions/*/XPCServices/*.xpc \
    "$framework_path"/Versions/*/Autoupdate \
    "$framework_path"/Versions/*/Updater.app
  do
    [[ -e "$nested" ]] || continue
    if [[ "$(basename "$nested")" == "Downloader.xpc" ]]; then
      codesign_sparkle_component "$nested" --preserve-metadata=entitlements
    else
      codesign_sparkle_component "$nested"
    fi
  done

  codesign_sparkle_component "$framework_path"
}

sparkle_signature_for_zip() {
  if [[ -n "$sparkle_ed_signature" ]]; then
    printf '%s\n' "$sparkle_ed_signature"
    return
  fi

  local sign_update
  sign_update="$(find_sparkle_sign_update)"
  if [[ -z "$sign_update" ]]; then
    echo "Sparkle sign_update was not found. Set AGENTD_SPARKLE_BIN_DIR or AGENTD_SPARKLE_ED_SIGNATURE." >&2
    exit 1
  fi

  local fragment
  if [[ -n "$sparkle_ed_key_file" ]]; then
    fragment="$("$sign_update" --ed-key-file "$sparkle_ed_key_file" "$zip_path")"
  else
    fragment="$("$sign_update" "$zip_path")"
  fi
  local signature
  signature="$(printf '%s' "$fragment" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
  if [[ -z "$signature" ]]; then
    echo "Could not parse Sparkle EdDSA signature from sign_update output." >&2
    printf '%s\n' "$fragment" >&2
    exit 1
  fi
  printf '%s\n' "$signature"
}

write_sparkle_appcast() {
  if [[ -z "$sparkle_download_url" ]]; then
    rm -f "$sparkle_appcast_path"
    return
  fi
  if [[ "$notarized" != "1" && "${AGENTD_SPARKLE_ALLOW_UNNOTARIZED:-0}" != "1" ]]; then
    echo "Refusing to emit Sparkle appcast for an unnotarized archive." >&2
    echo "Set AGENTD_SPARKLE_ALLOW_UNNOTARIZED=1 only for local fixture testing." >&2
    exit 1
  fi

  local signature
  signature="$(sparkle_signature_for_zip)"
  local appcast_args=(
    write
    --archive "$zip_path" \
    --info-plist "$app_path/Contents/Info.plist" \
    --output "$sparkle_appcast_path" \
    --download-url "$sparkle_download_url" \
    --ed-signature "$signature"
  )
  if [[ -n "$sparkle_release_notes_url" ]]; then
    appcast_args+=(--release-notes-url "$sparkle_release_notes_url")
  fi
  if [[ -n "$sparkle_channel" ]]; then
    appcast_args+=(--channel "$sparkle_channel")
  fi
  if [[ -n "$sparkle_phased_rollout_interval" ]]; then
    appcast_args+=(--phased-rollout-interval "$sparkle_phased_rollout_interval")
  fi
  if [[ -n "$sparkle_minimum_autoupdate_version" ]]; then
    appcast_args+=(--minimum-autoupdate-version "$sparkle_minimum_autoupdate_version")
  fi
  if [[ "$sparkle_critical_update" == "1" ]]; then
    appcast_args+=(--critical-update)
  fi
  python3 "$root/scripts/sparkle_appcast.py" "${appcast_args[@]}"
  python3 "$root/scripts/sparkle_appcast.py" verify \
    --appcast "$sparkle_appcast_path" \
    --archive "$zip_path" \
    --download-url "$sparkle_download_url" \
    --require-https

  if [[ "$sparkle_require_signed_feed" == "1" ]]; then
    if [[ -z "$sparkle_ed_key_file" ]]; then
      echo "AGENTD_SPARKLE_REQUIRE_SIGNED_FEED=1 requires AGENTD_SPARKLE_ED_KEY_FILE." >&2
      exit 1
    fi
    local sign_update
    sign_update="$(find_sparkle_sign_update)"
    if [[ -z "$sign_update" ]]; then
      echo "Sparkle sign_update was not found. Set AGENTD_SPARKLE_BIN_DIR." >&2
      exit 1
    fi
    "$sign_update" --ed-key-file "$sparkle_ed_key_file" "$sparkle_appcast_path"
    "$sign_update" --ed-key-file "$sparkle_ed_key_file" --verify "$sparkle_appcast_path"
    python3 "$root/scripts/sparkle_appcast.py" verify \
      --appcast "$sparkle_appcast_path" \
      --archive "$zip_path" \
      --download-url "$sparkle_download_url" \
      --require-https
  fi
}

require_matching_sparkle_config

swift build -c "$configuration" --product "$product"
build_bin_dir="$(swift build -c "$configuration" --product "$product" --show-bin-path)"
binary="$build_bin_dir/$product"

rm -rf "$app_path" "$zip_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$app_path/Contents/Frameworks"
cp "$root/support/Info.plist" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $product" "$app_path/Contents/Info.plist"
if [[ -n "$sparkle_feed_url" ]]; then
  plist_set_or_add "SUFeedURL" "string" "$sparkle_feed_url" "$app_path/Contents/Info.plist"
  plist_set_or_add "SUPublicEDKey" "string" "$sparkle_public_ed_key" "$app_path/Contents/Info.plist"
  plist_set_or_add "SUVerifyUpdateBeforeExtraction" "bool" "true" "$app_path/Contents/Info.plist"
  if [[ "$sparkle_require_signed_feed" == "1" ]]; then
    plist_set_or_add "SURequireSignedFeed" "bool" "true" "$app_path/Contents/Info.plist"
  fi
fi
cp "$binary" "$app_path/Contents/MacOS/$product"
chmod 0755 "$app_path/Contents/MacOS/$product"

sparkle_framework="$(find_sparkle_framework)"
if [[ -z "$sparkle_framework" ]]; then
  echo "Sparkle.framework was not found under $root/.build after SwiftPM build." >&2
  exit 1
fi
ditto "$sparkle_framework" "$app_path/Contents/Frameworks/Sparkle.framework"
codesign_nested_sparkle "$app_path/Contents/Frameworks/Sparkle.framework"

app_entitlements="$entitlements"
if [[ "$identity" == "-" && "$adhoc_disable_library_validation" == "1" ]]; then
  app_entitlements="$dist_dir/agentd-adhoc.entitlements.plist"
  cp "$entitlements" "$app_entitlements"
  if /usr/libexec/PlistBuddy -c "Print :com.apple.security.cs.disable-library-validation" "$app_entitlements" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :com.apple.security.cs.disable-library-validation true" "$app_entitlements"
  else
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$app_entitlements"
  fi
fi

codesign_args=(
  --force
  --sign "$identity"
  --options runtime
  --entitlements "$app_entitlements"
)
if [[ "$identity" != "-" ]]; then
  codesign_args+=(--timestamp)
fi
codesign "${codesign_args[@]}" "$app_path"
codesign --verify --strict --deep --verbose=2 "$app_path"
if [[ "$identity" == "-" ]]; then
  echo "Ad-hoc signed app: macOS TCC approvals can bind to this build's cdhash."
  echo "For permission smoke, approve this exact packaged app and relaunch without rebuilding."
  if [[ "$adhoc_disable_library_validation" == "1" ]]; then
    echo "Ad-hoc local package allows embedded frameworks with disable-library-validation."
  fi
fi

create_zip

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
  create_zip
fi

write_sparkle_appcast

notarized_json=false
if [[ "$notarized" == "1" ]]; then
  notarized_json=true
fi
sparkle_enabled_json=false
sparkle_public_key_configured_json=false
sparkle_require_signed_feed_json=false
sparkle_appcast_json=""
if [[ -n "$sparkle_feed_url" ]]; then
  sparkle_enabled_json=true
  sparkle_public_key_configured_json=true
fi
if [[ "$sparkle_require_signed_feed" == "1" ]]; then
  sparkle_require_signed_feed_json=true
fi
if [[ -f "$sparkle_appcast_path" ]]; then
  sparkle_appcast_json="appcast.xml"
fi
zip_sha256="$(shasum -a 256 "$zip_path" | awk '{print $1}')"
app_binary_sha256="$(shasum -a 256 "$app_path/Contents/MacOS/$product" | awk '{print $1}')"
python3 - "$dist_dir/update-channel.json" <<PY
import json
import sys

payload = {
    "product": "$product",
    "appName": "$app_name",
    "configuration": "$configuration",
    "archive": "$(basename "$zip_path")",
    "archiveSha256": "$zip_sha256",
    "appBinarySha256": "$app_binary_sha256",
    "codesignIdentity": "$identity",
    "notarized": "$notarized_json" == "true",
    "sparkleEnabled": "$sparkle_enabled_json" == "true",
    "sparkleFeedURL": "$sparkle_feed_url",
    "sparklePublicEDKeyConfigured": "$sparkle_public_key_configured_json" == "true",
    "sparkleRequireSignedFeed": "$sparkle_require_signed_feed_json" == "true",
    "sparkleDownloadURL": "$sparkle_download_url",
    "sparkleAppcast": "$sparkle_appcast_json" or None,
    "sparkleChannel": "$sparkle_channel",
    "sparklePhasedRolloutInterval": "$sparkle_phased_rollout_interval",
    "sparkleMinimumAutoupdateVersion": "$sparkle_minimum_autoupdate_version",
    "sparkleCriticalUpdate": "$sparkle_critical_update" == "1",
}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

echo "Packaged $app_path"
echo "Archive $zip_path"
echo "Update metadata $dist_dir/update-channel.json"
if [[ -f "$sparkle_appcast_path" ]]; then
  echo "Sparkle appcast $sparkle_appcast_path"
fi
