#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$ROOT/altool-auth.sh"
APP_NAME="Address Atlas"
APP_PATH="$ROOT/dist/$APP_NAME.app"
PKG_PATH="$ROOT/dist/$APP_NAME-AppStore.pkg"
PROVENANCE_PATH="$ROOT/dist/$APP_NAME-AppStore.provenance.plist"
MODE="${1:-}"

plist_top_level_keys() {
  local plist="$1"
  local key_count
  local key_index
  key_count="$(/usr/bin/xmllint --xpath 'count(/plist/dict/key)' "$plist")"
  [[ "$key_count" =~ ^[0-9]+$ ]] || return 1
  for ((key_index = 1; key_index <= key_count; key_index++)); do
    /usr/bin/xmllint --xpath "string(/plist/dict/key[$key_index])" "$plist"
  done
}

verify_release_checkout() {
  local checkout_state
  local remote_main_line
  local remote_main_commit
  REPO_ROOT="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$REPO_ROOT" && "$(git -C "$REPO_ROOT" branch --show-current)" == "main" ]] || {
    echo "App Store Connect delivery requires the main branch of a Git checkout." >&2
    return 65
  }
  CURRENT_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  [[ "$CURRENT_COMMIT" =~ ^[0-9a-f]{40,64}$ ]] || {
    echo "The current source commit is malformed." >&2
    return 65
  }
  checkout_state="$(git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all)"
  [[ -z "$checkout_state" ]] || {
    echo "App Store Connect delivery requires a clean source checkout." >&2
    return 65
  }
  [[ "$(git -C "$REPO_ROOT" rev-parse refs/remotes/origin/main 2>/dev/null || true)" \
    == "$CURRENT_COMMIT" ]] || {
    echo "The release commit does not match the local origin/main ref." >&2
    return 65
  }
  remote_main_line="$(
    GIT_TERMINAL_PROMPT=0 git -C "$REPO_ROOT" ls-remote --exit-code \
      origin refs/heads/main 2>/dev/null || true
  )"
  remote_main_commit="$(awk 'NR == 1 { print $1 }' <<< "$remote_main_line")"
  [[ "$remote_main_commit" == "$CURRENT_COMMIT" ]] || {
    echo "The release commit is not the current live origin/main commit." >&2
    return 65
  }
}

verify_release_provenance() {
  [[ -f "$PROVENANCE_PATH" && ! -L "$PROVENANCE_PATH" ]] || {
    echo "The source-bound Mac App Store provenance record is missing or unsafe." >&2
    return 66
  }
  [[ "$(stat -f '%Lp' "$PKG_PATH")" == "444" \
    && "$(stat -f '%Lp' "$PROVENANCE_PATH")" == "444" ]] || {
    echo "The final package and provenance record must be read-only." >&2
    return 65
  }
  plutil -lint "$PROVENANCE_PATH" >/dev/null
  local expected_provenance_keys
  local actual_provenance_keys
  expected_provenance_keys=$'AppStoreID\nBuildVersion\nBundleIdentifier\nPackageSHA256\nSchemaVersion\nShortVersion\nSourceCommit\nTeamIdentifier'
  actual_provenance_keys="$(plist_top_level_keys "$PROVENANCE_PATH" | LC_ALL=C sort)"
  [[ "$actual_provenance_keys" == "$expected_provenance_keys" ]] || {
    echo "The Mac App Store provenance record has an unexpected field set." >&2
    return 65
  }
  local package_sha256
  local signature_details
  local team_identifier
  package_sha256="$(shasum -a 256 "$PKG_PATH" | awk '{print $1}')"
  signature_details="$(codesign --display --verbose=4 "$APP_PATH" 2>&1)"
  team_identifier="$(
    sed -nE 's/^TeamIdentifier=([A-Z0-9]{10})$/\1/p' <<< "$signature_details"
  )"
  [[ "$(plutil -extract SchemaVersion raw "$PROVENANCE_PATH")" == "1" \
    && "$(plutil -extract SourceCommit raw "$PROVENANCE_PATH")" == "$CURRENT_COMMIT" \
    && "$(plutil -extract SourceCommit raw "$PROVENANCE_PATH")" \
      == "$(plutil -extract AddressAtlasSourceCommit raw "$APP_PATH/Contents/Info.plist")" \
    && "$(plutil -extract PackageSHA256 raw "$PROVENANCE_PATH")" == "$package_sha256" \
    && "$(plutil -extract BundleIdentifier raw "$PROVENANCE_PATH")" \
      == "$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Contents/Info.plist")" \
    && "$(plutil -extract ShortVersion raw "$PROVENANCE_PATH")" \
      == "$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")" \
    && "$(plutil -extract BuildVersion raw "$PROVENANCE_PATH")" \
      == "$(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")" \
    && "$(plutil -extract TeamIdentifier raw "$PROVENANCE_PATH")" == "$team_identifier" \
    && "$(plutil -extract AppStoreID raw "$PROVENANCE_PATH")" == "$APP_STORE_ID" ]] || {
    echo "The package provenance does not match the current source, artifact, app, team, and App Store record." >&2
    return 65
  }
}

case "$MODE" in
  --validate-only|--upload) ;;
  *)
    echo "Usage: $0 --validate-only|--upload" >&2
    exit 64
    ;;
esac

APP_STORE_ID="${ADDRESS_ATLAS_APP_STORE_ID:-}"
[[ "$APP_STORE_ID" =~ ^[1-9][0-9]{5,14}$ ]] || {
  echo "ADDRESS_ATLAS_APP_STORE_ID must be the numeric Apple ID from App Store Connect." >&2
  exit 64
}

resolve_address_atlas_altool_auth

if ! xcrun altool --help >/dev/null 2>&1; then
  echo "Xcode's App Store delivery components are unavailable. Complete Xcode first-launch setup or reinstall Xcode before validation/upload." >&2
  exit 69
fi

verify_release_checkout
ADDRESS_ATLAS_EXPECTED_APP_STORE_ID="$APP_STORE_ID" \
ADDRESS_ATLAS_EXPECTED_SOURCE_COMMIT="$CURRENT_COMMIT" \
  "$ROOT/validate-mas-artifact.sh" "$APP_PATH" "$PKG_PATH" "$PROVENANCE_PATH"
verify_release_provenance

SHORT_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
BUILD_VERSION="$(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Contents/Info.plist")"
IDENTIFIER_ARGUMENTS=(
  --platform macos
  --apple-id "$APP_STORE_ID"
  --bundle-id "$BUNDLE_ID"
  --bundle-short-version-string "$SHORT_VERSION"
  --bundle-version "$BUILD_VERSION"
)
if [[ -n "${ADDRESS_ATLAS_ASC_PROVIDER_PUBLIC_ID:-}" ]]; then
  [[ "$ADDRESS_ATLAS_ASC_PROVIDER_PUBLIC_ID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || {
    echo "ADDRESS_ATLAS_ASC_PROVIDER_PUBLIC_ID must be a provider UUID." >&2
    exit 64
  }
  IDENTIFIER_ARGUMENTS+=(--provider-public-id "$ADDRESS_ATLAS_ASC_PROVIDER_PUBLIC_ID")
fi

xcrun altool --validate-app "$PKG_PATH" \
  "${IDENTIFIER_ARGUMENTS[@]}" \
  "${AUTH_ARGUMENTS[@]}" \
  --output-format json

if [[ "$MODE" == "--validate-only" ]]; then
  echo "App Store Connect validation passed; no upload was performed."
  exit 0
fi

verify_release_checkout
verify_release_provenance
xcrun altool --upload-package "$PKG_PATH" \
  "${IDENTIFIER_ARGUMENTS[@]}" \
  --wait \
  "${AUTH_ARGUMENTS[@]}" \
  --output-format json

echo "App Store Connect accepted the upload command for $SHORT_VERSION ($BUILD_VERSION) and returned its current import status. Re-read the processed build in App Store Connect before submission."
