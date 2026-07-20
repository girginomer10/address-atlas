#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DMG_PATH="$ROOT/dist/Address Atlas.dmg"
APP_PATH="$ROOT/dist/Address Atlas.app"
XCRUN_BIN="${XCRUN_BIN:-xcrun}"
CODESIGN_BIN="${CODESIGN_BIN:-codesign}"
SPCTL_BIN="${SPCTL_BIN:-spctl}"
HDIUTIL_BIN="${HDIUTIL_BIN:-hdiutil}"
PLUTIL_BIN="${PLUTIL_BIN:-plutil}"
BUILD_DMG_SCRIPT="${BUILD_DMG_SCRIPT:-$ROOT/build-dmg.sh}"

: "${ADDRESS_ATLAS_CODESIGN_IDENTITY:?Set Developer ID Application identity.}"
if [[ "$ADDRESS_ATLAS_CODESIGN_IDENTITY" == "-" || "$ADDRESS_ATLAS_CODESIGN_IDENTITY" == *$'\n'* ]]; then
  echo "Public notarization requires one valid Developer ID Application identity." >&2
  exit 64
fi

notary_profile="${ADDRESS_ATLAS_NOTARY_PROFILE:-}"
notary_key_path="${ADDRESS_ATLAS_NOTARY_KEY_PATH:-}"
notary_key_id="${ADDRESS_ATLAS_NOTARY_KEY_ID:-}"
notary_issuer_id="${ADDRESS_ATLAS_NOTARY_ISSUER_ID:-}"
direct_notary_value_present=false
if [[ -n "$notary_key_path" || -n "$notary_key_id" || -n "$notary_issuer_id" ]]; then
  direct_notary_value_present=true
fi

notary_auth=()
if [[ -n "$notary_profile" ]]; then
  if [[ "$direct_notary_value_present" == true ]]; then
    echo "Choose either a notarytool Keychain profile or direct App Store Connect API credentials, never both." >&2
    exit 64
  fi
  if [[ ! "$notary_profile" =~ ^[A-Za-z0-9._-]{1,128}$ ]]; then
    echo "ADDRESS_ATLAS_NOTARY_PROFILE has an invalid shape." >&2
    exit 64
  fi
  notary_auth=(--keychain-profile "$notary_profile")
else
  if [[ -z "$notary_key_path" || -z "$notary_key_id" || -z "$notary_issuer_id" ]]; then
    echo "Set ADDRESS_ATLAS_NOTARY_PROFILE, or set ADDRESS_ATLAS_NOTARY_KEY_PATH, ADDRESS_ATLAS_NOTARY_KEY_ID, and ADDRESS_ATLAS_NOTARY_ISSUER_ID together." >&2
    exit 64
  fi
  if [[ "$notary_key_path" != /* || ! -f "$notary_key_path" || -L "$notary_key_path" ]]; then
    echo "ADDRESS_ATLAS_NOTARY_KEY_PATH must be an absolute, regular, non-symlink file." >&2
    exit 66
  fi
  if [[ ! "$notary_key_id" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "ADDRESS_ATLAS_NOTARY_KEY_ID has an invalid shape." >&2
    exit 64
  fi
  if [[ ! "$notary_issuer_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
    echo "ADDRESS_ATLAS_NOTARY_ISSUER_ID has an invalid shape." >&2
    exit 64
  fi
  key_mode="$(stat -f %Lp "$notary_key_path" 2>/dev/null || stat -c %a "$notary_key_path")"
  if [[ ! "$key_mode" =~ ^[0-7]{3,4}$ || $((8#$key_mode & 8#077)) -ne 0 ]]; then
    echo "The App Store Connect API key must not be accessible by group or other users." >&2
    exit 66
  fi
  notary_auth=(
    --key "$notary_key_path"
    --key-id "$notary_key_id"
    --issuer "$notary_issuer_id"
  )
fi

for command in "$XCRUN_BIN" "$CODESIGN_BIN" "$SPCTL_BIN" "$HDIUTIL_BIN" "$PLUTIL_BIN"; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Required release command is missing: $command" >&2
    exit 69
  }
done
[[ -x "$BUILD_DMG_SCRIPT" ]] || {
  echo "The DMG build script is not executable." >&2
  exit 69
}

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/address-atlas-notary.XXXXXX")"
submission_json="$work_dir/submission.json"
notary_log="$work_dir/notary-log.json"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT INT TERM

"$BUILD_DMG_SCRIPT"
[[ -d "$APP_PATH" && -s "$DMG_PATH" ]] || {
  echo "The signed app and DMG were not produced." >&2
  exit 74
}

"$CODESIGN_BIN" --verify --deep --strict --verbose=4 "$APP_PATH"
"$CODESIGN_BIN" --verify --strict --verbose=4 "$DMG_PATH"
"$HDIUTIL_BIN" verify "$DMG_PATH"

submit_status=0
"$XCRUN_BIN" notarytool submit "$DMG_PATH" \
  "${notary_auth[@]}" \
  --wait \
  --output-format json > "$submission_json" || submit_status=$?

submission_id="$($PLUTIL_BIN -extract id raw -o - "$submission_json" 2>/dev/null || true)"
notary_status="$($PLUTIL_BIN -extract status raw -o - "$submission_json" 2>/dev/null || true)"
if [[ "$submission_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
  if ! "$XCRUN_BIN" notarytool log "$submission_id" \
    "${notary_auth[@]}" \
    --output-format json > "$notary_log"; then
    : > "$notary_log"
  fi
fi
if [[ "$submit_status" -ne 0 || "$notary_status" != "Accepted" ]]; then
  echo "Apple notarization was not accepted (submission ${submission_id:-unknown}, status ${notary_status:-unknown})." >&2
  if [[ -s "$notary_log" ]]; then
    # Apple's diagnostic log contains signing/package findings, not credential
    # values. Bound it so a malformed response cannot flood CI logs.
    head -c 65536 "$notary_log" >&2
    printf '\n' >&2
  fi
  if [[ "$submit_status" -eq 0 ]]; then submit_status=1; fi
  exit "$submit_status"
fi

"$XCRUN_BIN" stapler staple "$DMG_PATH"
"$XCRUN_BIN" stapler validate "$DMG_PATH"
"$SPCTL_BIN" --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
"$HDIUTIL_BIN" verify "$DMG_PATH"

trap - EXIT INT TERM
cleanup
echo "Notarized and stapled $DMG_PATH (submission $submission_id)"
