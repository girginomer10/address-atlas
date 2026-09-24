#!/usr/bin/env bash
# Builds the iOS app for the simulator (default) or a generic iOS device.
# Simulator builds are ad-hoc signed by Xcode so the app carries its
# entitlements: without an application-identifier the iOS Keychain refuses
# every request with errSecMissingEntitlement and the vault cannot unlock.
# Usage: ./build-ios-app.sh [--simulator|--device] [--configuration Debug|Release] [--install-booted] [--unsigned]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$ROOT/AddressAtlasiOS.xcodeproj"
SCHEME="AddressAtlasiOS"
DERIVED="$ROOT/build/DerivedData"
DESTINATION="generic/platform=iOS Simulator"
CONFIGURATION="Debug"
INSTALL_BOOTED=0
SIGNING_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --simulator) DESTINATION="generic/platform=iOS Simulator" ;;
    --device) DESTINATION="generic/platform=iOS" ;;
    # Compile-only check for environments without any signing identity.
    --unsigned) SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=) ;;
    --configuration) CONFIGURATION="$2"; shift ;;
    --install-booted) INSTALL_BOOTED=1 ;;
    *) echo "Usage: $0 [--simulator|--device] [--configuration Debug|Release] [--install-booted] [--unsigned]" >&2; exit 64 ;;
  esac
  shift
done

if [[ "$(xcode-select -p 2>/dev/null)" != *"/Xcode"*".app/Contents/Developer" ]]; then
  echo "Full Xcode must be selected with xcode-select; Command Line Tools cannot build iOS apps." >&2
  exit 69
fi
xcrun --sdk iphonesimulator --show-sdk-path >/dev/null

"$ROOT/scripts/write-version-xcconfig.sh"
[[ -d "$PROJECT" ]] || { echo "Missing $PROJECT. Run ./generate-project.sh first." >&2; exit 66; }

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  ${SIGNING_ARGS[@]+"${SIGNING_ARGS[@]}"} \
  build

if [[ "$INSTALL_BOOTED" == 1 ]]; then
  APP_PATH="$DERIVED/Build/Products/$CONFIGURATION-iphonesimulator/Address Atlas.app"
  [[ -d "$APP_PATH" ]] || { echo "Built app not found at $APP_PATH" >&2; exit 66; }
  xcrun simctl install booted "$APP_PATH"
  xcrun simctl launch booted com.addressatlas.ios
fi
