#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Address Atlas"
BUILD_DIR="$ROOT/.build/release"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"

cd "$ROOT"

"$ROOT/check-toolchain.sh"
SELECTED_DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ "$SELECTED_DEVELOPER_DIR" == *"CommandLineTools"* && -x "/opt/homebrew/opt/swift/bin/swift" && -d "/Library/Developer/CommandLineTools" ]]; then
  export PATH="/opt/homebrew/opt/swift/bin:$PATH"
  export DEVELOPER_DIR="/Library/Developer/CommandLineTools"
fi
swift build -c release --product AddressAtlasMac

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/AddressAtlasMac" "$APP_DIR/Contents/MacOS/$APP_NAME"

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
  <string>0.1.0</string>
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
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

SIGN_IDENTITY="${ADDRESS_ATLAS_CODESIGN_IDENTITY:--}"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "Built $APP_DIR"
