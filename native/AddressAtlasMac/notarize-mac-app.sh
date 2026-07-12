#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DMG_PATH="$ROOT/dist/Address Atlas.dmg"

: "${ADDRESS_ATLAS_CODESIGN_IDENTITY:?Set Developer ID Application identity.}"
: "${ADDRESS_ATLAS_NOTARY_PROFILE:?Set the notarytool Keychain profile name. Create it with: xcrun notarytool store-credentials <profile>.}"

"$ROOT/build-dmg.sh"

xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$ADDRESS_ATLAS_NOTARY_PROFILE" \
  --wait

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"

echo "Notarized $DMG_PATH"
