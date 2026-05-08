#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DMG_PATH="$ROOT/dist/Address Atlas.dmg"

: "${ADDRESS_ATLAS_CODESIGN_IDENTITY:?Set Developer ID Application identity.}"
: "${APPLE_ID:?Set Apple ID email.}"
: "${APPLE_TEAM_ID:?Set Apple Developer Team ID.}"
: "${APPLE_APP_SPECIFIC_PASSWORD:?Set app-specific password or notarytool keychain profile password.}"

"$ROOT/build-dmg.sh"

xcrun notarytool submit "$DMG_PATH" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD" \
  --wait

xcrun stapler staple "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"

echo "Notarized $DMG_PATH"
