#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

for script in \
  "$ROOT/altool-auth.sh" \
  "$ROOT/build-mac-app.sh" \
  "$ROOT/build-mas-pkg.sh" \
  "$ROOT/generate-app-store-screenshots.sh" \
  "$ROOT/validate-mas-artifact.sh" \
  "$ROOT/upload-mas-build.sh"
do
  bash -n "$script"
done

ENTITLEMENTS="$ROOT/Resources/AddressAtlasMac.entitlements"
PRIVACY="$ROOT/Resources/PrivacyInfo.xcprivacy"
MIGRATION="$ROOT/Resources/container-migration.plist"
for plist in "$ENTITLEMENTS" "$PRIVACY" "$MIGRATION"; do
  plutil -lint "$plist" >/dev/null
done

expected_entitlement_keys=$'com.apple.security.app-sandbox\ncom.apple.security.files.user-selected.read-write\ncom.apple.security.network.client'
actual_entitlement_keys="$(plist_top_level_keys "$ENTITLEMENTS" | LC_ALL=C sort)"
[[ "$actual_entitlement_keys" == "$expected_entitlement_keys" ]]
for entitlement in com.apple.security.app-sandbox com.apple.security.network.client \
  com.apple.security.files.user-selected.read-write; do
  [[ "$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$ENTITLEMENTS")" == "true" ]]
done
[[ "$(plutil -extract Move.0 raw "$MIGRATION")" == '${ApplicationSupport}/AddressAtlas' ]]
[[ "$(plutil -extract NSPrivacyTracking raw "$PRIVACY")" == "false" ]]
[[ "$(plist_top_level_keys "$PRIVACY" | LC_ALL=C sort)" \
  == $'NSPrivacyAccessedAPITypes\nNSPrivacyCollectedDataTypes\nNSPrivacyTracking' ]]
[[ "$(plutil -extract NSPrivacyCollectedDataTypes raw "$PRIVACY")" == "6" ]]
collected_data_types=()
for data_index in 0 1 2 3 4 5; do
  data_prefix="NSPrivacyCollectedDataTypes.$data_index"
  [[ "$(/usr/bin/xmllint --xpath \
    "count(/plist/dict/key[.='NSPrivacyCollectedDataTypes']/following-sibling::array[1]/dict[$((data_index + 1))]/key)" \
    "$PRIVACY")" == "4" ]]
  collected_data_types+=("$(plutil -extract "$data_prefix.NSPrivacyCollectedDataType" raw "$PRIVACY")")
  [[ "$(plutil -extract "$data_prefix.NSPrivacyCollectedDataTypeLinked" raw "$PRIVACY")" == "true" ]]
  [[ "$(plutil -extract "$data_prefix.NSPrivacyCollectedDataTypeTracking" raw "$PRIVACY")" == "false" ]]
  [[ "$(plutil -extract "$data_prefix.NSPrivacyCollectedDataTypePurposes" raw "$PRIVACY")" == "1" ]]
  [[ "$(plutil -extract "$data_prefix.NSPrivacyCollectedDataTypePurposes.0" raw "$PRIVACY")" \
    == "NSPrivacyCollectedDataTypePurposeAppFunctionality" ]]
done
[[ "$(printf '%s\n' "${collected_data_types[@]}" | LC_ALL=C sort)" \
  == $'NSPrivacyCollectedDataTypeOtherDataTypes\nNSPrivacyCollectedDataTypeOtherDiagnosticData\nNSPrivacyCollectedDataTypeOtherFinancialInfo\nNSPrivacyCollectedDataTypeOtherUsageData\nNSPrivacyCollectedDataTypeOtherUserContent\nNSPrivacyCollectedDataTypeUserID' ]]
[[ "$(plutil -extract NSPrivacyAccessedAPITypes raw "$PRIVACY")" == "2" ]]
accessed_api_categories=()
for api_index in 0 1; do
  api_prefix="NSPrivacyAccessedAPITypes.$api_index"
  [[ "$(/usr/bin/xmllint --xpath \
    "count(/plist/dict/key[.='NSPrivacyAccessedAPITypes']/following-sibling::array[1]/dict[$((api_index + 1))]/key)" \
    "$PRIVACY")" == "2" ]]
  api_category="$(plutil -extract "$api_prefix.NSPrivacyAccessedAPIType" raw "$PRIVACY")"
  accessed_api_categories+=("$api_category")
  api_reason_count="$(plutil -extract "$api_prefix.NSPrivacyAccessedAPITypeReasons" raw "$PRIVACY")"
  api_reasons=()
  for ((reason_index = 0; reason_index < api_reason_count; reason_index++)); do
    api_reasons+=("$(plutil -extract "$api_prefix.NSPrivacyAccessedAPITypeReasons.$reason_index" raw "$PRIVACY")")
  done
  case "$api_category" in
    NSPrivacyAccessedAPICategoryFileTimestamp)
      [[ "$(printf '%s\n' "${api_reasons[@]}" | LC_ALL=C sort)" == $'3B52.1\nC617.1' ]]
      ;;
    NSPrivacyAccessedAPICategorySystemBootTime)
      [[ "${api_reasons[*]}" == "35F9.1" ]]
      ;;
    *) exit 1 ;;
  esac
done
[[ "$(printf '%s\n' "${accessed_api_categories[@]}" | LC_ALL=C sort)" \
  == $'NSPrivacyAccessedAPICategoryFileTimestamp\nNSPrivacyAccessedAPICategorySystemBootTime' ]]

grep -Fq 'PrivacyInfo.xcprivacy' "$ROOT/build-mac-app.sh"
grep -Fq 'container-migration.plist' "$ROOT/build-mac-app.sh"
grep -Fq 'Assets.car' "$ROOT/build-mac-app.sh"
grep -Fq 'CFBundleIconName' "$ROOT/build-mac-app.sh"
grep -Fq 'CFBundleSupportedPlatforms' "$ROOT/build-mac-app.sh"
grep -Fq 'ITSAppUsesNonExemptEncryption' "$ROOT/build-mac-app.sh"
grep -Fq 'AddressAtlasSourceCommit' "$ROOT/build-mac-app.sh"
grep -Fq 'https://apps.apple.com/app/id' "$ROOT/build-mac-app.sh"
grep -Fq -- '--entitlements' "$ROOT/build-mac-app.sh"
grep -Fq 'com.apple.application-identifier' "$ROOT/build-mac-app.sh"
grep -Fq 'com.apple.developer.team-identifier' "$ROOT/build-mac-app.sh"
grep -Fq 'ProvisionsAllDevices' "$ROOT/build-mac-app.sh"
grep -Fq 'ProvisionedDevices' "$ROOT/build-mac-app.sh"
grep -Fq 'ProvisionedDevices' "$ROOT/validate-mas-artifact.sh"
grep -Fq 'ExpirationDate' "$ROOT/build-mac-app.sh"
grep -Fq 'DeveloperCertificates' "$ROOT/build-mac-app.sh"
grep -Fq 'must authorize exactly one certificate' "$ROOT/build-mac-app.sh"
grep -Fq 'must authorize exactly one certificate' "$ROOT/validate-mas-artifact.sh"
grep -Fq 'ADDRESS_ATLAS_PROVISIONING_PROFILE is required' "$ROOT/build-mas-pkg.sh"
grep -Fq 'installer certificate does not belong' "$ROOT/build-mas-pkg.sh"
grep -Fq -- '--component "$APP_PATH" /Applications' "$ROOT/build-mas-pkg.sh"
grep -Fq 'PackageSHA256' "$ROOT/build-mas-pkg.sh"
grep -Fq 'SourceCommit' "$ROOT/build-mas-pkg.sh"
grep -Fq 'SIGNED_SOURCE_COMMIT' "$ROOT/build-mas-pkg.sh"
grep -Fq 'requires a clean source checkout' "$ROOT/build-mas-pkg.sh"
grep -Fq -- '--upload-package "$PKG_PATH"' "$ROOT/upload-mas-build.sh"
grep -Fq -- '--platform macos' "$ROOT/upload-mas-build.sh"
grep -Fq -- '--bundle-id "$BUNDLE_ID"' "$ROOT/upload-mas-build.sh"
grep -Fq -- '--bundle-version "$BUILD_VERSION"' "$ROOT/upload-mas-build.sh"
grep -Fq -- '--bundle-short-version-string "$SHORT_VERSION"' "$ROOT/upload-mas-build.sh"
grep -Fq -- '--wait' "$ROOT/upload-mas-build.sh"
grep -Fq "stat -f '%Lp'" "$ROOT/altool-auth.sh"
grep -Fq 'implicit key discovery is disabled' "$ROOT/altool-auth.sh"
grep -Fq -- '--api-issuer' "$ROOT/altool-auth.sh"
grep -Fq -- '@keychain:' "$ROOT/altool-auth.sh"
grep -Fq 'Plaintext App Store Connect passwords are not accepted' "$ROOT/altool-auth.sh"
grep -Fq 'verify_release_provenance' "$ROOT/upload-mas-build.sh"
grep -Fq 'ls-remote --exit-code' "$ROOT/upload-mas-build.sh"
grep -Fq -- 'pkgutil --expand-full' "$ROOT/validate-mas-artifact.sh"
grep -Fq 'signed app inside the installer package' "$ROOT/validate-mas-artifact.sh"
grep -Fq 'provenance_source_commit" == "$source_commit' "$ROOT/validate-mas-artifact.sh"
grep -Fq 'ADDRESS_ATLAS_EXPECTED_SOURCE_COMMIT' "$ROOT/validate-mas-artifact.sh"
grep -Fq 'requires a safe provenance record' "$ROOT/validate-mas-artifact.sh"
grep -Fq -- 'install-location' "$ROOT/validate-mas-artifact.sh"

if ADDRESS_ATLAS_DISTRIBUTION_CHANNEL=app-store \
  ADDRESS_ATLAS_APP_STORE_ID=invalid \
  bash "$ROOT/build-mac-app.sh" >/dev/null 2>&1; then
  echo "The app builder accepted an invalid App Store Apple ID." >&2
  exit 1
fi
if bash "$ROOT/upload-mas-build.sh" --invalid >/dev/null 2>&1; then
  echo "The upload script accepted an unsafe mode." >&2
  exit 1
fi

TEST_P8="$(mktemp "${TMPDIR:-/tmp}/address-atlas-test-key.XXXXXX.p8")"
TEST_P8_LOOSE="$(mktemp "${TMPDIR:-/tmp}/address-atlas-test-loose-key.XXXXXX.p8")"
TEST_P8_LINK="$TEST_P8.link"
trap 'rm -f -- "$TEST_P8" "$TEST_P8_LOOSE" "$TEST_P8_LINK"' EXIT
chmod 600 "$TEST_P8"
chmod 644 "$TEST_P8_LOOSE"
ln -s "$TEST_P8" "$TEST_P8_LINK"
AUTH_LIBRARY="$ROOT/altool-auth.sh"

resolve_auth_clean() {
  /usr/bin/env -i PATH=/usr/bin:/bin "$@" /bin/bash -c \
    '. "$1"; resolve_address_atlas_altool_auth || exit $?; printf "%s\n" "${AUTH_ARGUMENTS[@]}"' \
    _ "$AUTH_LIBRARY"
}

expect_auth_failure() {
  if resolve_auth_clean "$@" >/dev/null 2>&1; then
    echo "The altool authentication contract accepted an unsafe or incomplete environment: $*" >&2
    exit 1
  fi
}

team_auth="$(resolve_auth_clean \
  ADDRESS_ATLAS_ASC_API_KEY=test-key \
  ADDRESS_ATLAS_ASC_API_ISSUER=11111111-1111-1111-1111-111111111111 \
  ADDRESS_ATLAS_ASC_P8_PATH="$TEST_P8")"
[[ "$team_auth" == "$(printf '%s\n' \
  --api-key test-key \
  --api-issuer 11111111-1111-1111-1111-111111111111 \
  --p8-file-path "$TEST_P8")" ]]

apple_id_auth="$(resolve_auth_clean \
  ADDRESS_ATLAS_ASC_USERNAME=reviewer@addressatlas.invalid \
  ADDRESS_ATLAS_ASC_PASSWORD_KEYCHAIN_ITEM=AddressAtlasAppStore)"
[[ "$apple_id_auth" == "$(printf '%s\n' \
  --username reviewer@addressatlas.invalid \
  --password @keychain:AddressAtlasAppStore)" ]]

expect_auth_failure
expect_auth_failure ADDRESS_ATLAS_ASC_API_KEY=test-key
expect_auth_failure ADDRESS_ATLAS_ASC_API_ISSUER=11111111-1111-1111-1111-111111111111
expect_auth_failure ADDRESS_ATLAS_ASC_P8_PATH="$TEST_P8"
expect_auth_failure ADDRESS_ATLAS_ASC_API_KEY=test-key \
  ADDRESS_ATLAS_ASC_API_ISSUER=11111111-1111-1111-1111-111111111111
expect_auth_failure ADDRESS_ATLAS_ASC_API_KEY=test-key \
  ADDRESS_ATLAS_ASC_P8_PATH="$TEST_P8"
expect_auth_failure ADDRESS_ATLAS_ASC_USERNAME=reviewer@addressatlas.invalid
expect_auth_failure ADDRESS_ATLAS_ASC_PASSWORD_KEYCHAIN_ITEM=AddressAtlasAppStore
expect_auth_failure ADDRESS_ATLAS_ASC_API_KEY=test-key \
  ADDRESS_ATLAS_ASC_API_ISSUER=11111111-1111-1111-1111-111111111111 \
  ADDRESS_ATLAS_ASC_P8_PATH="$TEST_P8" \
  ADDRESS_ATLAS_ASC_USERNAME=reviewer@addressatlas.invalid \
  ADDRESS_ATLAS_ASC_PASSWORD_KEYCHAIN_ITEM=AddressAtlasAppStore
expect_auth_failure ADDRESS_ATLAS_ASC_API_KEY_SUBJECT=user
expect_auth_failure ADDRESS_ATLAS_ASC_PASSWORD=plaintext-secret
expect_auth_failure ADDRESS_ATLAS_ASC_API_KEY=test-key \
  ADDRESS_ATLAS_ASC_API_ISSUER=11111111-1111-1111-1111-111111111111 \
  ADDRESS_ATLAS_ASC_P8_PATH=relative.p8
expect_auth_failure ADDRESS_ATLAS_ASC_API_KEY=test-key \
  ADDRESS_ATLAS_ASC_API_ISSUER=11111111-1111-1111-1111-111111111111 \
  ADDRESS_ATLAS_ASC_P8_PATH="$TEST_P8_LOOSE"
expect_auth_failure ADDRESS_ATLAS_ASC_API_KEY=test-key \
  ADDRESS_ATLAS_ASC_API_ISSUER=11111111-1111-1111-1111-111111111111 \
  ADDRESS_ATLAS_ASC_P8_PATH="$TEST_P8_LINK"
expect_auth_failure "ADDRESS_ATLAS_ASC_USERNAME=line"$'\n'"break" \
  ADDRESS_ATLAS_ASC_PASSWORD_KEYCHAIN_ITEM=AddressAtlasAppStore
expect_auth_failure ADDRESS_ATLAS_ASC_USERNAME=reviewer@addressatlas.invalid \
  ADDRESS_ATLAS_ASC_PASSWORD_KEYCHAIN_ITEM=invalid:item

echo "Mac App Store release contract checks passed."
