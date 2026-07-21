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

APP_ICON_SOURCE="$ROOT/Resources/AppIcon.png"
if [[ ! -f "$APP_ICON_SOURCE" || -L "$APP_ICON_SOURCE" ]]; then
  echo "The production app icon source is missing or unsafe: $APP_ICON_SOURCE" >&2
  exit 66
fi

for required_command in /usr/bin/sips /usr/bin/iconutil; do
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
    echo "Developer ID distribution builds require exactly arm64 and x86_64 architectures." >&2
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
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.finance</string>
  <key>LSMultipleInstancesProhibited</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Omer Girgin</string>
</dict>
</plist>
PLIST

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
fi
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
built_arch_list="$(xcrun lipo -archs "$APP_DIR/Contents/MacOS/$APP_NAME")"
printf '%s\n' "$built_arch_list"
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  read -r -a built_architectures <<< "$built_arch_list"
  if [[ "${#built_architectures[@]}" -ne 2 ]] ||
    ! { [[ "${built_architectures[0]}" == "arm64" && "${built_architectures[1]}" == "x86_64" ]] ||
      [[ "${built_architectures[0]}" == "x86_64" && "${built_architectures[1]}" == "arm64" ]]; }
  then
    echo "Developer ID artifact is not an exact arm64 + x86_64 universal binary." >&2
    exit 65
  fi
fi
codesign_details="$(codesign --display --verbose=4 "$APP_DIR" 2>&1)"
grep -q "flags=.*runtime" <<< "$codesign_details" \
  || { echo "Hardened runtime flag missing after signing" >&2; exit 1; }

echo "Built $APP_DIR"
