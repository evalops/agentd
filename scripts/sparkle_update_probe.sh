#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="${DIST_DIR:-"$root/dist"}"
app_name="${AGENTD_APP_NAME:-EvalOps agentd}"
app_path="${AGENTD_APP_PATH:-"$dist_dir/$app_name.app"}"
feed_url="${AGENTD_SPARKLE_PROBE_FEED_URL:-${AGENTD_SPARKLE_FEED_URL:-}}"
appcast_path="${AGENTD_SPARKLE_APPCAST_PATH:-"$dist_dir/appcast.xml"}"
channels="${AGENTD_SPARKLE_PROBE_CHANNELS:-}"
user_agent="${AGENTD_SPARKLE_PROBE_USER_AGENT:-EvalOps agentd update probe}"

find_sparkle_cli() {
  if [[ -n "${AGENTD_SPARKLE_BIN_DIR:-}" ]]; then
    if [[ -x "$AGENTD_SPARKLE_BIN_DIR/sparkle" ]]; then
      printf '%s\n' "$AGENTD_SPARKLE_BIN_DIR/sparkle"
      return
    fi
    if [[ -x "$AGENTD_SPARKLE_BIN_DIR/sparkle.app/Contents/MacOS/sparkle" ]]; then
      printf '%s\n' "$AGENTD_SPARKLE_BIN_DIR/sparkle.app/Contents/MacOS/sparkle"
      return
    fi
  fi
  find "$root/.build" \( \
    -path "*/Sparkle/bin/sparkle" -o \
    -path "*/Sparkle/bin/sparkle.app/Contents/MacOS/sparkle" \
  \) -type f -perm -111 -print -quit 2>/dev/null || true
}

if [[ ! -d "$app_path" ]]; then
  echo "App bundle not found: $app_path" >&2
  echo "Run scripts/package_app.sh first or set AGENTD_APP_PATH." >&2
  exit 1
fi

sparkle_cli="$(find_sparkle_cli)"
if [[ -z "$sparkle_cli" ]]; then
  echo "Sparkle CLI was not found. Set AGENTD_SPARKLE_BIN_DIR or build/resolve Sparkle first." >&2
  exit 1
fi

if [[ -z "$feed_url" && -f "$appcast_path" ]]; then
  feed_url="$(python3 - "$appcast_path" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve().as_uri())
PY
)"
fi

args=(--probe --user-agent-name "$user_agent")
if [[ -n "$feed_url" ]]; then
  args+=(--feed-url "$feed_url")
fi
if [[ -n "$channels" ]]; then
  args+=(--channels "$channels")
fi
if [[ "${AGENTD_SPARKLE_ALLOW_MAJOR_UPGRADES:-0}" == "1" ]]; then
  args+=(--allow-major-upgrades)
fi

echo "Probing Sparkle updates for $app_path"
if [[ -n "$feed_url" ]]; then
  echo "Using feed $feed_url"
fi
exec "$sparkle_cli" "${args[@]}" "$app_path"
