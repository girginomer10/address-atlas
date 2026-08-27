#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Address Atlas"
APP_PATH="$ROOT/dist/$APP_NAME.app"
PKG_PATH="$ROOT/dist/$APP_NAME-AppStore.pkg"
PROVENANCE_PATH="$ROOT/dist/$APP_NAME-AppStore.provenance.plist"

APP_SIGN_IDENTITY="${ADDRESS_ATLAS_MAS_CODESIGN_IDENTITY:-}"
INSTALLER_SIGN_IDENTITY="${ADDRESS_ATLAS_MAS_INSTALLER_IDENTITY:-}"
APP_STORE_ID="${ADDRESS_ATLAS_APP_STORE_ID:-}"
PROVISIONING_PROFILE="${ADDRESS_ATLAS_PROVISIONING_PROFILE:-}"

REPO_ROOT="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_ROOT" ]] || {
  echo "The Mac App Store package must be built from a Git checkout." >&2
  exit 65
}
[[ "$(git -C "$REPO_ROOT" branch --show-current)" == "main" ]] || {
  echo "The Mac App Store package must be built from the main branch." >&2
  exit 65
}
SOURCE_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40,64}$ ]] || {
  echo "The current source commit is malformed." >&2
  exit 65
}
[[ "$(git -C "$REPO_ROOT" rev-parse refs/remotes/origin/main 2>/dev/null || true)" \
  == "$SOURCE_COMMIT" ]] || {
  echo "The release commit must match the locally verified origin/main ref." >&2
  exit 65
}
[[ -z "$(git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all)" ]] || {
  echo "The Mac App Store package requires a clean source checkout." >&2
  exit 65
}

[[ -n "$APP_SIGN_IDENTITY" ]] || {
  echo "ADDRESS_ATLAS_MAS_CODESIGN_IDENTITY is required (Apple Distribution or Mac App Distribution)." >&2
  exit 78
}
[[ -n "$INSTALLER_SIGN_IDENTITY" ]] || {
  echo "ADDRESS_ATLAS_MAS_INSTALLER_IDENTITY is required (Mac Installer Distribution)." >&2
  exit 78
}
[[ "$APP_STORE_ID" =~ ^[1-9][0-9]{5,14}$ ]] || {
  echo "ADDRESS_ATLAS_APP_STORE_ID must be the numeric Apple ID from App Store Connect." >&2
  exit 64
}
[[ -n "$PROVISIONING_PROFILE" ]] || {
  echo "ADDRESS_ATLAS_PROVISIONING_PROFILE is required for the App ID and Data Protection Keychain entitlement." >&2
  exit 78
}
[[ -f "$PROVISIONING_PROFILE" && ! -L "$PROVISIONING_PROFILE" ]] || {
  echo "The Mac App Store provisioning profile is missing or unsafe." >&2
  exit 66
}

for command in security productbuild pkgutil codesign git shasum plutil; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Required Mac App Store packaging command is missing: $command" >&2
    exit 69
  }
done

security find-identity -v -p codesigning \
  | grep -Fq "\"$APP_SIGN_IDENTITY\"" || {
    echo "The requested App Store application signing identity is unavailable." >&2
    exit 78
  }

ADDRESS_ATLAS_DISTRIBUTION_CHANNEL=app-store \
ADDRESS_ATLAS_CODESIGN_IDENTITY="$APP_SIGN_IDENTITY" \
ADDRESS_ATLAS_APP_STORE_ID="$APP_STORE_ID" \
ADDRESS_ATLAS_PROVISIONING_PROFILE="$PROVISIONING_PROFILE" \
  "$ROOT/build-mac-app.sh"

signature_details="$(codesign --display --verbose=4 "$APP_PATH" 2>&1)"
grep -Eq '^Authority=(Apple Distribution|Mac App Distribution|3rd Party Mac Developer Application):' \
  <<< "$signature_details" || {
    echo "The app is not signed by an App Store distribution authority." >&2
    exit 65
  }
grep -Eq '^TeamIdentifier=[A-Z0-9]{10}$' <<< "$signature_details" || {
  echo "The app signature has no valid Apple Developer TeamIdentifier." >&2
  exit 65
}
APP_TEAM_IDENTIFIER="$(
  sed -nE 's/^TeamIdentifier=([A-Z0-9]{10})$/\1/p' <<< "$signature_details"
)"

rm -f "$PKG_PATH" "$PROVENANCE_PATH"
productbuild \
  --sign "$INSTALLER_SIGN_IDENTITY" \
  --component "$APP_PATH" /Applications \
  "$PKG_PATH"

package_signature="$(pkgutil --check-signature "$PKG_PATH" 2>&1)"
grep -Eq 'Mac Installer Distribution|3rd Party Mac Developer Installer' \
  <<< "$package_signature" || {
  echo "The package is not signed by a Mac App Store installer authority." >&2
  exit 65
}
grep -Fq "($APP_TEAM_IDENTIFIER)" <<< "$package_signature" || {
  echo "The installer certificate does not belong to the application signing team." >&2
  exit 65
}

[[ "$(git -C "$REPO_ROOT" rev-parse HEAD)" == "$SOURCE_COMMIT" \
  && -z "$(git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all)" ]] || {
  echo "The source checkout changed while the Mac App Store package was built." >&2
  exit 65
}

SHORT_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
BUILD_VERSION="$(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")"
BUNDLE_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Contents/Info.plist")"
SIGNED_SOURCE_COMMIT="$(plutil -extract AddressAtlasSourceCommit raw "$APP_PATH/Contents/Info.plist")"
PACKAGE_SHA256="$(shasum -a 256 "$PKG_PATH" | awk '{print $1}')"
[[ "$PACKAGE_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "The package SHA-256 digest could not be computed." >&2
  exit 65
}
[[ "$SIGNED_SOURCE_COMMIT" == "$SOURCE_COMMIT" ]] || {
  echo "The signed application does not identify the source commit being packaged." >&2
  exit 65
}

plutil -create xml1 "$PROVENANCE_PATH"
plutil -insert SchemaVersion -integer 1 "$PROVENANCE_PATH"
plutil -insert SourceCommit -string "$SOURCE_COMMIT" "$PROVENANCE_PATH"
plutil -insert PackageSHA256 -string "$PACKAGE_SHA256" "$PROVENANCE_PATH"
plutil -insert BundleIdentifier -string "$BUNDLE_IDENTIFIER" "$PROVENANCE_PATH"
plutil -insert ShortVersion -string "$SHORT_VERSION" "$PROVENANCE_PATH"
plutil -insert BuildVersion -string "$BUILD_VERSION" "$PROVENANCE_PATH"
plutil -insert TeamIdentifier -string "$APP_TEAM_IDENTIFIER" "$PROVENANCE_PATH"
plutil -insert AppStoreID -string "$APP_STORE_ID" "$PROVENANCE_PATH"
plutil -lint "$PROVENANCE_PATH" >/dev/null
chmod 444 "$PKG_PATH" "$PROVENANCE_PATH"

ADDRESS_ATLAS_EXPECTED_APP_STORE_ID="$APP_STORE_ID" \
ADDRESS_ATLAS_EXPECTED_SOURCE_COMMIT="$SOURCE_COMMIT" \
  "$ROOT/validate-mas-artifact.sh" "$APP_PATH" "$PKG_PATH" "$PROVENANCE_PATH"

echo "Built Mac App Store package: $PKG_PATH"
echo "Recorded release provenance: $PROVENANCE_PATH"
