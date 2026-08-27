#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"
OUTPUT_DIR="${1:-$REPO_ROOT/app-store/screenshots/en-US}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/address-atlas-app-store-shots.XXXXXX")"
trap 'rm -rf -- "$STAGING_DIR"' EXIT
mkdir -p \
  "$STAGING_DIR/cache" \
  "$STAGING_DIR/config" \
  "$STAGING_DIR/module-cache" \
  "$STAGING_DIR/security"

EXPECTED=(
  01-portfolio.jpg
  02-wallets.jpg
  03-assets.jpg
  04-snapshots.jpg
  05-sync.jpg
)
TEST_BUILD_ARGUMENTS=()
for filename in "${EXPECTED[@]}"; do
  ADDRESS_ATLAS_APP_STORE_SCREENSHOT_DIR="$STAGING_DIR" \
  ADDRESS_ATLAS_APP_STORE_SCREENSHOT_NAME="$filename" \
  ADDRESS_ATLAS_UI_LOCALE=en_US \
  SWIFTPM_MODULECACHE_OVERRIDE="$STAGING_DIR/module-cache" \
  CLANG_MODULE_CACHE_PATH="$STAGING_DIR/module-cache" \
    swift test \
      --cache-path "$STAGING_DIR/cache" \
      --config-path "$STAGING_DIR/config" \
      --security-path "$STAGING_DIR/security" \
      "${TEST_BUILD_ARGUMENTS[@]}" \
      --filter AtlasDesignSystemTests/testGenerateRequestedAppStoreScreenshot
  TEST_BUILD_ARGUMENTS=(--skip-build)
done

for filename in "${EXPECTED[@]}"; do
  path="$STAGING_DIR/$filename"
  [[ -s "$path" ]] || {
    echo "Missing generated App Store screenshot: $filename" >&2
    exit 74
  }
  metadata="$(/usr/bin/sips -g format -g pixelWidth -g pixelHeight -g hasAlpha "$path" 2>/dev/null)"
  grep -q 'format: jpeg' <<< "$metadata"
  grep -q 'pixelWidth: 1440' <<< "$metadata"
  grep -q 'pixelHeight: 900' <<< "$metadata"
  grep -q 'hasAlpha: no' <<< "$metadata"
done

mkdir -p "$OUTPUT_DIR"
for obsolete in 04-exchanges.jpg 06-privacy-settings.jpg; do
  rm -f -- "$OUTPUT_DIR/$obsolete"
done
for filename in "${EXPECTED[@]}"; do
  cp "$STAGING_DIR/$filename" "$OUTPUT_DIR/$filename"
done

echo "Generated five fictional-data App Store screenshots in $OUTPUT_DIR"
