#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Address Atlas"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
APP_VERSION_SOURCE="$ROOT/Sources/AddressAtlasMac/AppState.swift"
APP_VERSION="$(sed -nE 's/^[[:space:]]*static let currentAppVersion = "([0-9]+(\.[0-9]+){1,3})"$/\1/p' "$APP_VERSION_SOURCE")"

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
  echo "Could not read one valid currentAppVersion from $APP_VERSION_SOURCE" >&2
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
BINARIES=()
for architecture in "${ARCHITECTURES[@]}"; do
  case "$architecture" in
    arm64|x86_64) ;;
    *)
      echo "Unsupported architecture: $architecture" >&2
      exit 1
      ;;
  esac
  triple="${architecture}-apple-macosx14.0"
  swift build -c release --product AddressAtlasMac --triple "$triple" --sdk "$SDK_PATH"
  bin_dir="$(swift build -c release --show-bin-path --triple "$triple" --sdk "$SDK_PATH")"
  BINARIES+=("$bin_dir/AddressAtlasMac")
done

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

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
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>com.addressatlas.mac</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
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
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

SIGN_IDENTITY="${ADDRESS_ATLAS_CODESIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
fi
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
xcrun lipo -archs "$APP_DIR/Contents/MacOS/$APP_NAME"
codesign_details="$(codesign --display --verbose=4 "$APP_DIR" 2>&1)"
grep -q "flags=.*runtime" <<< "$codesign_details" \
  || { echo "Hardened runtime flag missing after signing" >&2; exit 1; }

echo "Built $APP_DIR"
