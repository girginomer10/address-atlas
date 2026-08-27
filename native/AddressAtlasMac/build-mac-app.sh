#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Address Atlas"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
APP_VERSION_SOURCE="$ROOT/Sources/AddressAtlasMac/AppState.swift"
APP_VERSION="$(sed -nE 's/^[[:space:]]*static let currentAppVersion = "([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' "$APP_VERSION_SOURCE")"

resolve_build_version() {
  local candidate="${ADDRESS_ATLAS_BUILD_NUMBER:-}"
  if [[ -z "$candidate" ]]; then
    if [[ "$(git -C "$ROOT" rev-parse --is-shallow-repository 2>/dev/null || true)" == "true" ]]; then
      echo "A shallow clone cannot derive a unique CFBundleVersion. Set ADDRESS_ATLAS_BUILD_NUMBER from the CI/release run number." >&2
      return 1
    fi
    candidate="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || true)"
  fi
  # Apple's release CFBundleVersion grammar is one to three integer fields:
  # four digits in the first field and up to two in each remaining field.
  if [[ ! "$candidate" =~ ^[1-9][0-9]{0,3}(\.[0-9]{1,2}){0,2}$ ]]; then
    echo "Invalid CFBundleVersion '$candidate'. Set ADDRESS_ATLAS_BUILD_NUMBER to a positive value such as 42 or 42.1.3." >&2
    return 1
  fi
  printf '%s\n' "$candidate"
}

BUILD_VERSION="$(resolve_build_version)"

if [[ -z "$APP_VERSION" || "$APP_VERSION" == *$'\n'* ]]; then
  echo "Could not read one valid three-integer currentAppVersion from $APP_VERSION_SOURCE" >&2
  exit 1
fi

case "${1:-}" in
  --print-build-version)
    printf '%s\n' "$BUILD_VERSION"
    exit 0
    ;;
  "") ;;
  *)
    echo "Usage: $0 [--print-build-version]" >&2
    exit 1
    ;;
esac

cd "$ROOT"

DISTRIBUTION_CHANNEL="${ADDRESS_ATLAS_DISTRIBUTION_CHANNEL:-direct}"
case "$DISTRIBUTION_CHANNEL" in
  direct)
    UPDATE_URL="https://github.com/girginomer10/address-atlas/releases/latest"
    BASE_ENTITLEMENTS_FILE=""
    DATA_PROTECTION_KEYCHAIN_VALUE="<false/>"
    ;;
  app-store)
    APP_STORE_ID="${ADDRESS_ATLAS_APP_STORE_ID:-}"
    if [[ ! "$APP_STORE_ID" =~ ^[1-9][0-9]{5,14}$ ]]; then
      echo "ADDRESS_ATLAS_APP_STORE_ID must be the numeric Apple ID from App Store Connect." >&2
      exit 64
    fi
    UPDATE_URL="https://apps.apple.com/app/id$APP_STORE_ID"
    BASE_ENTITLEMENTS_FILE="$ROOT/Resources/AddressAtlasMac.entitlements"
    DATA_PROTECTION_KEYCHAIN_VALUE="<true/>"
    ;;
  *)
    echo "ADDRESS_ATLAS_DISTRIBUTION_CHANNEL must be 'direct' or 'app-store'." >&2
    exit 64
    ;;
esac

SOURCE_COMMIT="$(git -C "$ROOT" rev-parse --verify HEAD 2>/dev/null || true)"
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40,64}$ ]] || {
  echo "The app must be built from a Git commit so its signed source identity can be recorded." >&2
  exit 65
}

for resource in PrivacyInfo.xcprivacy container-migration.plist; do
  resource_path="$ROOT/Resources/$resource"
  if [[ ! -f "$resource_path" || -L "$resource_path" ]]; then
    echo "Required app resource is missing or unsafe: $resource_path" >&2
    exit 66
  fi
  plutil -lint "$resource_path" >/dev/null
done
if [[ -n "$BASE_ENTITLEMENTS_FILE" ]]; then
  if [[ ! -f "$BASE_ENTITLEMENTS_FILE" || -L "$BASE_ENTITLEMENTS_FILE" ]]; then
    echo "The Mac App Store entitlements file is missing or unsafe: $BASE_ENTITLEMENTS_FILE" >&2
    exit 66
  fi
  plutil -lint "$BASE_ENTITLEMENTS_FILE" >/dev/null
fi

APP_ICON_SOURCE="$ROOT/Resources/AppIcon.png"
if [[ ! -f "$APP_ICON_SOURCE" || -L "$APP_ICON_SOURCE" ]]; then
  echo "The production app icon source is missing or unsafe: $APP_ICON_SOURCE" >&2
  exit 66
fi

for required_command in /usr/bin/sips /usr/bin/iconutil /usr/bin/xcrun; do
  [[ -x "$required_command" ]] || {
    echo "Required icon build tool is missing: $required_command" >&2
    exit 69
  }
done

icon_metadata="$(/usr/bin/sips -g format -g pixelWidth -g pixelHeight "$APP_ICON_SOURCE" 2>/dev/null)"
icon_format="$(sed -nE 's/^[[:space:]]*format: ([a-zA-Z0-9]+)$/\1/p' <<< "$icon_metadata")"
icon_width="$(sed -nE 's/^[[:space:]]*pixelWidth: ([0-9]+)$/\1/p' <<< "$icon_metadata")"
icon_height="$(sed -nE 's/^[[:space:]]*pixelHeight: ([0-9]+)$/\1/p' <<< "$icon_metadata")"
if [[ "$icon_format" != "png" || "$icon_width" != "1024" || "$icon_height" != "1024" ]]; then
  echo "The production app icon must be a valid, exact 1024x1024 PNG." >&2
  exit 65
fi

"$ROOT/check-toolchain.sh"
SELECTED_DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
BREW_SWIFT_PREFIX=""
if command -v brew >/dev/null 2>&1; then
  BREW_SWIFT_PREFIX="$(brew --prefix swift 2>/dev/null || true)"
fi
if [[ -z "$BREW_SWIFT_PREFIX" ]]; then
  for candidate in /opt/homebrew/opt/swift /usr/local/opt/swift; do
    if [[ -x "$candidate/bin/swift" ]]; then BREW_SWIFT_PREFIX="$candidate"; break; fi
  done
fi
if [[ "$SELECTED_DEVELOPER_DIR" == *"CommandLineTools"* && -n "$BREW_SWIFT_PREFIX" && -x "$BREW_SWIFT_PREFIX/bin/swift" && -d "/Library/Developer/CommandLineTools" ]]; then
  export PATH="$BREW_SWIFT_PREFIX/bin:$PATH"
  export DEVELOPER_DIR="/Library/Developer/CommandLineTools"
fi
SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
ARCH_LIST="${ADDRESS_ATLAS_ARCHS:-arm64,x86_64}"
IFS=',' read -r -a ARCHITECTURES <<< "$ARCH_LIST"
SIGN_IDENTITY="${ADDRESS_ATLAS_CODESIGN_IDENTITY:--}"
PROVISIONING_PROFILE="${ADDRESS_ATLAS_PROVISIONING_PROFILE:-}"
if [[ "$DISTRIBUTION_CHANNEL" == "app-store" && "$SIGN_IDENTITY" == "-" \
  && "${ADDRESS_ATLAS_ALLOW_ADHOC_APP_STORE_BUILD:-0}" != "1" ]]; then
  echo "Mac App Store builds require an Apple Distribution signing identity." >&2
  exit 78
fi
if [[ "$DISTRIBUTION_CHANNEL" == "app-store" && "$SIGN_IDENTITY" != "-" ]]; then
  if [[ -z "$PROVISIONING_PROFILE" ]]; then
    echo "Signed Mac App Store builds require ADDRESS_ATLAS_PROVISIONING_PROFILE so the App ID entitlement can authorize Data Protection Keychain." >&2
    exit 78
  fi
  if [[ ! -f "$PROVISIONING_PROFILE" || -L "$PROVISIONING_PROFILE" ]]; then
    echo "The provisioning profile is missing or unsafe: $PROVISIONING_PROFILE" >&2
    exit 66
  fi
elif [[ -n "$PROVISIONING_PROFILE" ]]; then
  echo "A provisioning profile may only be embedded in a non-ad-hoc App Store build." >&2
  exit 64
fi
BINARIES=()
for architecture in "${ARCHITECTURES[@]}"; do
  case "$architecture" in
    arm64|x86_64) ;;
    *)
      echo "Unsupported architecture: $architecture" >&2
      exit 1
      ;;
  esac
done
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  if [[ "${#ARCHITECTURES[@]}" -ne 2 ]] ||
    ! { [[ "${ARCHITECTURES[0]}" == "arm64" && "${ARCHITECTURES[1]}" == "x86_64" ]] ||
      [[ "${ARCHITECTURES[0]}" == "x86_64" && "${ARCHITECTURES[1]}" == "arm64" ]]; }
  then
    echo "Signed distribution builds require exactly arm64 and x86_64 architectures." >&2
    exit 64
  fi
fi
for architecture in "${ARCHITECTURES[@]}"; do
  triple="${architecture}-apple-macosx14.0"
  swift build -c release --product AddressAtlasMac --triple "$triple" --sdk "$SDK_PATH"
  bin_dir="$(swift build -c release --show-bin-path --triple "$triple" --sdk "$SDK_PATH")"
  BINARIES+=("$bin_dir/AddressAtlasMac")
done

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

ICON_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/address-atlas-app-icon.XXXXXX")"
cleanup_icon_work_dir() {
  rm -rf -- "$ICON_WORK_DIR"
}
trap cleanup_icon_work_dir EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
SIGNING_ENTITLEMENTS_FILE="$BASE_ENTITLEMENTS_FILE"
ICONSET_DIR="$ICON_WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

render_icon() {
  local output_name="$1"
  local pixels="$2"
  /usr/bin/sips --resampleHeightWidth "$pixels" "$pixels" \
    "$APP_ICON_SOURCE" --out "$ICONSET_DIR/$output_name" >/dev/null
}

render_icon icon_16x16.png 16
render_icon icon_16x16@2x.png 32
render_icon icon_32x32.png 32
render_icon icon_32x32@2x.png 64
render_icon icon_128x128.png 128
render_icon icon_128x128@2x.png 256
render_icon icon_256x256.png 256
render_icon icon_256x256@2x.png 512
render_icon icon_512x512.png 512
render_icon icon_512x512@2x.png 1024
/usr/bin/iconutil --convert icns --output \
  "$APP_DIR/Contents/Resources/AppIcon.icns" "$ICONSET_DIR"
[[ -s "$APP_DIR/Contents/Resources/AppIcon.icns" ]] || {
  echo "The production AppIcon.icns was not generated." >&2
  exit 74
}

ASSET_CATALOG_DIR="$ICON_WORK_DIR/Assets.xcassets"
ASSET_APP_ICON_DIR="$ASSET_CATALOG_DIR/AppIcon.appiconset"
mkdir -p "$ASSET_APP_ICON_DIR"
cp "$ROOT/Resources/AppIcon.appiconset/Contents.json" "$ASSET_APP_ICON_DIR/Contents.json"
cp "$ICONSET_DIR"/*.png "$ASSET_APP_ICON_DIR/"
xcrun actool \
  --compile "$APP_DIR/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --target-device mac \
  --app-icon AppIcon \
  --standalone-icon-behavior all \
  --output-partial-info-plist "$ICON_WORK_DIR/AppIcon-Info.plist" \
  --warnings \
  --errors \
  "$ASSET_CATALOG_DIR" >"$ICON_WORK_DIR/actool-result.plist"
plutil -lint "$ICON_WORK_DIR/actool-result.plist" >/dev/null
plutil -lint "$ICON_WORK_DIR/AppIcon-Info.plist" >/dev/null
[[ -s "$APP_DIR/Contents/Resources/Assets.car" ]] || {
  echo "The production app icon asset catalog was not generated." >&2
  exit 74
}
cp "$ROOT/Resources/PrivacyInfo.xcprivacy" "$APP_DIR/Contents/Resources/PrivacyInfo.xcprivacy"
cp "$ROOT/Resources/container-migration.plist" \
  "$APP_DIR/Contents/Resources/container-migration.plist"

if [[ -n "$PROVISIONING_PROFILE" ]]; then
  PROFILE_PLIST="$ICON_WORK_DIR/provisioning-profile.plist"
  if ! security cms -D -i "$PROVISIONING_PROFILE" -o "$PROFILE_PLIST"; then
    echo "The Mac App Store provisioning profile could not be decoded." >&2
    exit 65
  fi
  plutil -lint "$PROFILE_PLIST" >/dev/null
  PROFILE_APP_IDENTIFIER="$(
    /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' \
      "$PROFILE_PLIST" 2>/dev/null || true
  )"
  PROFILE_TEAM_IDENTIFIER="$(
    /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' \
      "$PROFILE_PLIST" 2>/dev/null || true
  )"
  if [[ ! "$PROFILE_APP_IDENTIFIER" =~ ^[A-Z0-9]{10}\.com\.addressatlas\.mac$ ]]; then
    echo "The provisioning profile does not authorize com.addressatlas.mac." >&2
    exit 65
  fi
  if [[ ! "$PROFILE_TEAM_IDENTIFIER" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "The provisioning profile has no valid Apple Developer Team identifier." >&2
    exit 65
  fi
  if [[ "$(
    /usr/libexec/PlistBuddy -c 'Print :Entitlements:get-task-allow' \
      "$PROFILE_PLIST" 2>/dev/null || true
  )" == "true" ]]; then
    echo "A development provisioning profile cannot sign a Mac App Store submission." >&2
    exit 65
  fi
  if /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$PROFILE_PLIST" \
    >/dev/null 2>&1; then
    echo "A device-scoped provisioning profile cannot sign a Mac App Store submission." >&2
    exit 65
  fi
  if /usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$PROFILE_PLIST" \
    >/dev/null 2>&1; then
    echo "A Developer ID provisioning profile cannot sign a Mac App Store submission." >&2
    exit 65
  fi
  PROFILE_EXPIRATION="$(plutil -extract ExpirationDate raw "$PROFILE_PLIST" 2>/dev/null || true)"
  CURRENT_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  if [[ ! "$PROFILE_EXPIRATION" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ \
    || ! "$PROFILE_EXPIRATION" > "$CURRENT_UTC" ]]; then
    echo "The Mac App Store provisioning profile is expired or has no valid expiration date." >&2
    exit 65
  fi
  SIGNING_ENTITLEMENTS_FILE="$ICON_WORK_DIR/signed-entitlements.plist"
  cp "$BASE_ENTITLEMENTS_FILE" "$SIGNING_ENTITLEMENTS_FILE"
  /usr/libexec/PlistBuddy \
    -c "Add :com.apple.application-identifier string $PROFILE_APP_IDENTIFIER" \
    "$SIGNING_ENTITLEMENTS_FILE"
  /usr/libexec/PlistBuddy \
    -c "Add :com.apple.developer.team-identifier string $PROFILE_TEAM_IDENTIFIER" \
    "$SIGNING_ENTITLEMENTS_FILE"
  plutil -lint "$SIGNING_ENTITLEMENTS_FILE" >/dev/null
  cp "$PROVISIONING_PROFILE" "$APP_DIR/Contents/embedded.provisionprofile"
fi

if [[ "${#BINARIES[@]}" -eq 1 ]]; then
  cp "${BINARIES[0]}" "$APP_DIR/Contents/MacOS/$APP_NAME"
else
  xcrun lipo -create "${BINARIES[@]}" -output "$APP_DIR/Contents/MacOS/$APP_NAME"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>com.addressatlas.mac</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon.icns</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>MacOSX</string>
  </array>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>com.addressatlas.mac.sync-auth</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>address-atlas</string>
      </array>
    </dict>
  </array>
  <key>CFBundleVersion</key>
  <string>$BUILD_VERSION</string>
  <key>AddressAtlasDistributionChannel</key>
  <string>$DISTRIBUTION_CHANNEL</string>
  <key>AddressAtlasSourceCommit</key>
  <string>$SOURCE_COMMIT</string>
  <key>AddressAtlasUpdateURL</key>
  <string>$UPDATE_URL</string>
  <key>AddressAtlasUseDataProtectionKeychain</key>
  $DATA_PROTECTION_KEYCHAIN_VALUE
  <key>ITSAppUsesNonExemptEncryption</key>
  <false/>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.finance</string>
  <key>LSMultipleInstancesProhibited</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Ömer Girgin</string>
</dict>
</plist>
PLIST

quarantine_readback="$(/usr/bin/xattr -r -p com.apple.quarantine "$APP_DIR" 2>/dev/null || true)"
if [[ -n "$quarantine_readback" ]]; then
  echo "The app bundle contains a quarantined file and cannot be uploaded." >&2
  exit 65
fi

SIGN_ARGUMENTS=(--force --options runtime --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  SIGN_ARGUMENTS+=(--timestamp=none)
else
  SIGN_ARGUMENTS+=(--timestamp)
fi
if [[ -n "$SIGNING_ENTITLEMENTS_FILE" ]]; then
  SIGN_ARGUMENTS+=(--entitlements "$SIGNING_ENTITLEMENTS_FILE")
fi
codesign "${SIGN_ARGUMENTS[@]}" "$APP_DIR" >/dev/null
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
built_arch_list="$(xcrun lipo -archs "$APP_DIR/Contents/MacOS/$APP_NAME")"
printf '%s\n' "$built_arch_list"
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  read -r -a built_architectures <<< "$built_arch_list"
  if [[ "${#built_architectures[@]}" -ne 2 ]] ||
    ! { [[ "${built_architectures[0]}" == "arm64" && "${built_architectures[1]}" == "x86_64" ]] ||
      [[ "${built_architectures[0]}" == "x86_64" && "${built_architectures[1]}" == "arm64" ]]; }
  then
    echo "Signed distribution artifact is not an exact arm64 + x86_64 universal binary." >&2
    exit 65
  fi
fi
codesign_details="$(codesign --display --verbose=4 "$APP_DIR" 2>&1)"
grep -q "flags=.*runtime" <<< "$codesign_details" \
  || { echo "Hardened runtime flag missing after signing" >&2; exit 1; }

if [[ "$DISTRIBUTION_CHANNEL" == "app-store" ]]; then
  ENTITLEMENTS_READBACK="$ICON_WORK_DIR/signed-entitlements.plist"
  codesign --display --xml --entitlements - "$APP_DIR" \
    >"$ENTITLEMENTS_READBACK" 2>/dev/null
  plutil -lint "$ENTITLEMENTS_READBACK" >/dev/null
  for entitlement in \
    com.apple.security.app-sandbox \
    com.apple.security.network.client \
    com.apple.security.files.user-selected.read-write
  do
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$ENTITLEMENTS_READBACK")" \
      == "true" ]] || {
      echo "Required signed entitlement is missing: $entitlement" >&2
      exit 65
    }
  done
  if [[ "$SIGN_IDENTITY" != "-" ]]; then
    [[ "$(
      /usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' \
        "$ENTITLEMENTS_READBACK"
    )" == "$PROFILE_APP_IDENTIFIER" ]] || {
      echo "The signed App ID entitlement does not match the provisioning profile." >&2
      exit 65
    }
    [[ "$(
      /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' \
        "$ENTITLEMENTS_READBACK"
    )" == "$PROFILE_TEAM_IDENTIFIER" ]] || {
      echo "The signed Team identifier does not match the provisioning profile." >&2
      exit 65
    }
    SIGNED_CERTIFICATE_PREFIX="$ICON_WORK_DIR/signed-certificate"
    codesign --display --extract-certificates "$SIGNED_CERTIFICATE_PREFIX" \
      "$APP_DIR" 2>/dev/null
    SIGNED_CERTIFICATE="$SIGNED_CERTIFICATE_PREFIX"0
    [[ -s "$SIGNED_CERTIFICATE" ]] || {
      echo "The application signing certificate could not be extracted." >&2
      exit 65
    }
    SIGNED_CERTIFICATE_HASH="$(shasum -a 256 "$SIGNED_CERTIFICATE" | awk '{print $1}')"
    PROFILE_CERTIFICATE_COUNT="$(
      plutil -extract DeveloperCertificates raw "$PROFILE_PLIST" 2>/dev/null || true
    )"
    [[ "$PROFILE_CERTIFICATE_COUNT" == "1" ]] || {
      echo "A Mac App Store distribution profile must authorize exactly one certificate." >&2
      exit 65
    }
    PROFILE_CERTIFICATE="$ICON_WORK_DIR/profile-certificate.der"
    plutil -extract DeveloperCertificates.0 raw "$PROFILE_PLIST" \
      | /usr/bin/base64 -D >"$PROFILE_CERTIFICATE"
    [[ "$(shasum -a 256 "$PROFILE_CERTIFICATE" | awk '{print $1}')" \
      == "$SIGNED_CERTIFICATE_HASH" ]] || {
      echo "The embedded provisioning profile does not authorize the application signing certificate." >&2
      exit 65
    }
  fi
  [[ "$(plutil -extract AddressAtlasDistributionChannel raw "$APP_DIR/Contents/Info.plist")" \
    == "app-store" ]] || {
    echo "The signed bundle is not marked as an App Store build." >&2
    exit 65
  }
fi

echo "Built $APP_DIR"
