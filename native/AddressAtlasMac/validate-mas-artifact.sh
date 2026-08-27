#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Address Atlas"
APP_PATH="${1:-$ROOT/dist/$APP_NAME.app}"
PKG_PATH="${2:-}"
PROVENANCE_PATH="${3:-}"
EXPECTED_APP_STORE_ID="${ADDRESS_ATLAS_EXPECTED_APP_STORE_ID:-}"
EXPECTED_SOURCE_COMMIT="${ADDRESS_ATLAS_EXPECTED_SOURCE_COMMIT:-}"
VALIDATION_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/address-atlas-mas-validation.XXXXXX")"
trap 'rm -rf -- "$VALIDATION_WORK_DIR"' EXIT
expanded_package=""
package_signature=""

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

if [[ -n "$EXPECTED_APP_STORE_ID" \
  && ! "$EXPECTED_APP_STORE_ID" =~ ^[1-9][0-9]{5,14}$ ]]; then
  echo "ADDRESS_ATLAS_EXPECTED_APP_STORE_ID must be a numeric Apple ID." >&2
  exit 64
fi
if [[ -n "$EXPECTED_SOURCE_COMMIT" \
  && ! "$EXPECTED_SOURCE_COMMIT" =~ ^[0-9a-f]{40,64}$ ]]; then
  echo "ADDRESS_ATLAS_EXPECTED_SOURCE_COMMIT must be one lowercase Git commit hash." >&2
  exit 64
fi

if [[ -n "$PKG_PATH" ]]; then
  [[ -f "$PKG_PATH" && ! -L "$PKG_PATH" ]] || {
    echo "Mac App Store installer package is missing or unsafe: $PKG_PATH" >&2
    exit 66
  }
  [[ -f "$PROVENANCE_PATH" && ! -L "$PROVENANCE_PATH" ]] || {
    echo "A packaged App Store candidate requires a safe provenance record." >&2
    exit 66
  }
  package_signature="$(pkgutil --check-signature "$PKG_PATH" 2>&1)"
  grep -Eq 'Mac Installer Distribution|3rd Party Mac Developer Installer' \
    <<< "$package_signature" || {
    echo "The package is not signed by a Mac App Store installer authority." >&2
    exit 65
  }
  expanded_package="$VALIDATION_WORK_DIR/expanded-package"
  pkgutil --expand-full "$PKG_PATH" "$expanded_package"
  payload_roots="$(
    find "$expanded_package" -path '*/Payload/*' -mindepth 3 -maxdepth 3 -print
  )"
  [[ -n "$payload_roots" && "$payload_roots" != *$'\n'* \
    && -d "$payload_roots" && ! -L "$payload_roots" \
    && "$(basename "$payload_roots")" == "$APP_NAME.app" ]] || {
    echo "The installer must contain exactly one top-level Address Atlas app payload." >&2
    exit 65
  }
  if find "$expanded_package" -mindepth 2 -maxdepth 2 -type d -name Scripts \
    -print -quit | grep -q .; then
    echo "The installer contains an unreviewed package script." >&2
    exit 65
  fi
  APP_PATH="$payload_roots"
elif [[ -n "$PROVENANCE_PATH" ]]; then
  echo "A provenance record may only be validated with its installer package." >&2
  exit 64
fi

if [[ ! -d "$APP_PATH" || -L "$APP_PATH" ]]; then
  echo "Mac App Store app bundle is missing or unsafe: $APP_PATH" >&2
  exit 66
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
PRIVACY_MANIFEST="$APP_PATH/Contents/Resources/PrivacyInfo.xcprivacy"
MIGRATION_MANIFEST="$APP_PATH/Contents/Resources/container-migration.plist"
for plist in "$INFO_PLIST" "$PRIVACY_MANIFEST" "$MIGRATION_MANIFEST"; do
  [[ -f "$plist" && ! -L "$plist" ]] || {
    echo "Required property list is missing or unsafe: $plist" >&2
    exit 66
  }
  plutil -lint "$plist" >/dev/null
done

[[ "$(plutil -extract CFBundleIdentifier raw "$INFO_PLIST")" == "com.addressatlas.mac" ]]
short_version="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
[[ "$short_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "The Mac App Store CFBundleShortVersionString must contain exactly three integers: $short_version" >&2
  exit 65
}
[[ "$(plutil -extract LSApplicationCategoryType raw "$INFO_PLIST")" \
  == "public.app-category.finance" ]]
[[ "$(plutil -extract AddressAtlasDistributionChannel raw "$INFO_PLIST")" \
  == "app-store" ]]
source_commit="$(plutil -extract AddressAtlasSourceCommit raw "$INFO_PLIST")"
[[ "$source_commit" =~ ^[0-9a-f]{40,64}$ ]] || {
  echo "The signed app does not identify one valid source commit." >&2
  exit 65
}
if [[ -n "$EXPECTED_SOURCE_COMMIT" && "$source_commit" != "$EXPECTED_SOURCE_COMMIT" ]]; then
  echo "The signed app source commit does not match the expected release commit." >&2
  exit 65
fi
[[ "$(plutil -extract ITSAppUsesNonExemptEncryption raw "$INFO_PLIST")" == "false" ]]
[[ "$(plutil -extract AddressAtlasUseDataProtectionKeychain raw "$INFO_PLIST")" == "true" ]]
[[ "$(plutil -extract CFBundleIconName raw "$INFO_PLIST")" == "AppIcon" ]]
[[ "$(plutil -extract CFBundleSupportedPlatforms.0 raw "$INFO_PLIST")" == "MacOSX" ]]
if plutil -extract CFBundleSupportedPlatforms.1 raw "$INFO_PLIST" >/dev/null 2>&1; then
  echo "The Mac App Store bundle declares an unexpected second supported platform." >&2
  exit 65
fi
[[ -s "$APP_PATH/Contents/Resources/Assets.car" ]]
[[ -s "$APP_PATH/Contents/Resources/AppIcon.icns" ]]

build_version="$(plutil -extract CFBundleVersion raw "$INFO_PLIST")"
[[ "$build_version" =~ ^[1-9][0-9]{0,3}(\.[0-9]{1,2}){0,2}$ ]] || {
  echo "The Mac App Store CFBundleVersion is invalid: $build_version" >&2
  exit 65
}

update_url="$(plutil -extract AddressAtlasUpdateURL raw "$INFO_PLIST")"
[[ "$update_url" =~ ^https://apps\.apple\.com/app/id[1-9][0-9]{5,14}$ ]] || {
  echo "The Mac App Store update URL is invalid: $update_url" >&2
  exit 65
}
if [[ -n "$EXPECTED_APP_STORE_ID" \
  && "$update_url" != "https://apps.apple.com/app/id$EXPECTED_APP_STORE_ID" ]]; then
  echo "The packaged app targets a different App Store record." >&2
  exit 65
fi

[[ "$(plutil -extract Move.0 raw "$MIGRATION_MANIFEST")" \
  == '${ApplicationSupport}/AddressAtlas' ]]
if plutil -extract Move.1 raw "$MIGRATION_MANIFEST" >/dev/null 2>&1; then
  echo "The container migration manifest has an unexpected second path." >&2
  exit 65
fi

[[ "$(plutil -extract NSPrivacyTracking raw "$PRIVACY_MANIFEST")" == "false" ]]
expected_privacy_keys=$'NSPrivacyAccessedAPITypes\nNSPrivacyCollectedDataTypes\nNSPrivacyTracking'
actual_privacy_keys="$(plist_top_level_keys "$PRIVACY_MANIFEST" | LC_ALL=C sort)"
[[ "$actual_privacy_keys" == "$expected_privacy_keys" ]] || {
  echo "The privacy manifest top-level key set does not match the reviewed disclosure." >&2
  exit 65
}

collected_data_count="$(plutil -extract NSPrivacyCollectedDataTypes raw "$PRIVACY_MANIFEST")"
[[ "$collected_data_count" == "6" ]] || {
  echo "The privacy manifest must contain exactly six collected-data disclosures." >&2
  exit 65
}
collected_data_types=()
for ((data_index = 0; data_index < collected_data_count; data_index++)); do
  entry_key_count="$(
    /usr/bin/xmllint --xpath \
      "count(/plist/dict/key[.='NSPrivacyCollectedDataTypes']/following-sibling::array[1]/dict[$((data_index + 1))]/key)" \
      "$PRIVACY_MANIFEST"
  )"
  [[ "$entry_key_count" == "4" ]] || {
    echo "A collected-data privacy entry has an unexpected key set." >&2
    exit 65
  }
  data_prefix="NSPrivacyCollectedDataTypes.$data_index"
  collected_data_types+=("$(
    plutil -extract "$data_prefix.NSPrivacyCollectedDataType" raw "$PRIVACY_MANIFEST"
  )")
  [[ "$(
    plutil -extract "$data_prefix.NSPrivacyCollectedDataTypeLinked" raw "$PRIVACY_MANIFEST"
  )" == "true" ]]
  [[ "$(
    plutil -extract "$data_prefix.NSPrivacyCollectedDataTypeTracking" raw "$PRIVACY_MANIFEST"
  )" == "false" ]]
  [[ "$(
    plutil -extract "$data_prefix.NSPrivacyCollectedDataTypePurposes" raw "$PRIVACY_MANIFEST"
  )" == "1" ]]
  [[ "$(
    plutil -extract "$data_prefix.NSPrivacyCollectedDataTypePurposes.0" raw "$PRIVACY_MANIFEST"
  )" == "NSPrivacyCollectedDataTypePurposeAppFunctionality" ]]
done
actual_collected_data_types="$(printf '%s\n' "${collected_data_types[@]}" | LC_ALL=C sort)"
expected_collected_data_types=$'NSPrivacyCollectedDataTypeOtherDataTypes\nNSPrivacyCollectedDataTypeOtherDiagnosticData\nNSPrivacyCollectedDataTypeOtherFinancialInfo\nNSPrivacyCollectedDataTypeOtherUsageData\nNSPrivacyCollectedDataTypeOtherUserContent\nNSPrivacyCollectedDataTypeUserID'
[[ "$actual_collected_data_types" == "$expected_collected_data_types" ]] || {
  echo "The privacy manifest collected-data type set drifted from the reviewed label." >&2
  exit 65
}

accessed_api_count="$(plutil -extract NSPrivacyAccessedAPITypes raw "$PRIVACY_MANIFEST")"
[[ "$accessed_api_count" == "2" ]] || {
  echo "The privacy manifest must contain exactly two required-reason API categories." >&2
  exit 65
}
accessed_api_categories=()
for ((api_index = 0; api_index < accessed_api_count; api_index++)); do
  entry_key_count="$(
    /usr/bin/xmllint --xpath \
      "count(/plist/dict/key[.='NSPrivacyAccessedAPITypes']/following-sibling::array[1]/dict[$((api_index + 1))]/key)" \
      "$PRIVACY_MANIFEST"
  )"
  [[ "$entry_key_count" == "2" ]] || {
    echo "A required-reason API entry has an unexpected key set." >&2
    exit 65
  }
  api_prefix="NSPrivacyAccessedAPITypes.$api_index"
  api_category="$(
    plutil -extract "$api_prefix.NSPrivacyAccessedAPIType" raw "$PRIVACY_MANIFEST"
  )"
  accessed_api_categories+=("$api_category")
  api_reason_count="$(
    plutil -extract "$api_prefix.NSPrivacyAccessedAPITypeReasons" raw "$PRIVACY_MANIFEST"
  )"
  api_reasons=()
  for ((reason_index = 0; reason_index < api_reason_count; reason_index++)); do
    api_reasons+=("$(
      plutil -extract "$api_prefix.NSPrivacyAccessedAPITypeReasons.$reason_index" raw \
        "$PRIVACY_MANIFEST"
    )")
  done
  actual_api_reasons="$(printf '%s\n' "${api_reasons[@]}" | LC_ALL=C sort)"
  case "$api_category" in
    NSPrivacyAccessedAPICategoryFileTimestamp)
      [[ "$actual_api_reasons" == $'3B52.1\nC617.1' ]] || {
        echo "The File Timestamp required-reason set is incorrect." >&2
        exit 65
      }
      ;;
    NSPrivacyAccessedAPICategorySystemBootTime)
      [[ "$actual_api_reasons" == "35F9.1" ]] || {
        echo "The System Boot Time required-reason set is incorrect." >&2
        exit 65
      }
      ;;
    *)
      echo "The privacy manifest contains an unreviewed required-reason API category." >&2
      exit 65
      ;;
  esac
done
actual_accessed_api_categories="$(
  printf '%s\n' "${accessed_api_categories[@]}" | LC_ALL=C sort
)"
expected_accessed_api_categories=$'NSPrivacyAccessedAPICategoryFileTimestamp\nNSPrivacyAccessedAPICategorySystemBootTime'
[[ "$actual_accessed_api_categories" == "$expected_accessed_api_categories" ]] || {
  echo "The required-reason API category set drifted from the reviewed manifest." >&2
  exit 65
}

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
ENTITLEMENTS_READBACK="$VALIDATION_WORK_DIR/signed-entitlements.plist"
codesign --display --xml --entitlements - "$APP_PATH" \
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

expected_entitlement_keys=$'com.apple.security.app-sandbox\ncom.apple.security.files.user-selected.read-write\ncom.apple.security.network.client'

signature_details="$(codesign --display --verbose=4 "$APP_PATH" 2>&1)"
if grep -Eq '^Authority=(Apple Distribution|Mac App Distribution|3rd Party Mac Developer Application):' \
  <<< "$signature_details"; then
  expected_entitlement_keys+=$'\ncom.apple.application-identifier\ncom.apple.developer.team-identifier'
  PROFILE="$APP_PATH/Contents/embedded.provisionprofile"
  [[ -f "$PROFILE" && ! -L "$PROFILE" ]] || {
    echo "A distribution-signed Data Protection Keychain build requires an embedded Mac App Store provisioning profile." >&2
    exit 65
  }
  PROFILE_PLIST="$VALIDATION_WORK_DIR/provisioning-profile.plist"
  security cms -D -i "$PROFILE" -o "$PROFILE_PLIST" >/dev/null
  plutil -lint "$PROFILE_PLIST" >/dev/null
  profile_app_identifier="$(
    /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' \
      "$PROFILE_PLIST" 2>/dev/null || true
  )"
  profile_team_identifier="$(
    /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' \
      "$PROFILE_PLIST" 2>/dev/null || true
  )"
  signed_app_identifier="$(
    /usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' \
      "$ENTITLEMENTS_READBACK" 2>/dev/null || true
  )"
  signed_team_identifier="$(
    /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' \
      "$ENTITLEMENTS_READBACK" 2>/dev/null || true
  )"
  signature_team_identifier="$(
    sed -nE 's/^TeamIdentifier=([A-Z0-9]{10})$/\1/p' <<< "$signature_details"
  )"
  if /usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$PROFILE_PLIST" \
    >/dev/null 2>&1; then
    echo "The embedded profile is a Developer ID profile, not a Mac App Store profile." >&2
    exit 65
  fi
  if /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$PROFILE_PLIST" \
    >/dev/null 2>&1; then
    echo "The embedded profile is device-scoped, not a Mac App Store distribution profile." >&2
    exit 65
  fi
  profile_expiration="$(plutil -extract ExpirationDate raw "$PROFILE_PLIST" 2>/dev/null || true)"
  current_utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  if [[ ! "$profile_expiration" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ \
    || ! "$profile_expiration" > "$current_utc" ]]; then
    echo "The embedded Mac App Store provisioning profile is expired or malformed." >&2
    exit 65
  fi
  [[ "$profile_app_identifier" =~ ^[A-Z0-9]{10}\.com\.addressatlas\.mac$ \
    && "$signed_app_identifier" == "$profile_app_identifier" ]] || {
    echo "The signed App ID entitlement is absent or does not match the provisioning profile." >&2
    exit 65
  }
  [[ "$profile_team_identifier" =~ ^[A-Z0-9]{10}$ \
    && "$signed_team_identifier" == "$profile_team_identifier" \
    && "$signature_team_identifier" == "$profile_team_identifier" ]] || {
    echo "The signature, entitlement, and provisioning-profile Team identifiers do not match." >&2
    exit 65
  }
  signed_certificate_prefix="$VALIDATION_WORK_DIR/signed-certificate"
  codesign --display --extract-certificates "$signed_certificate_prefix" \
    "$APP_PATH" 2>/dev/null
  signed_certificate="$signed_certificate_prefix"0
  [[ -s "$signed_certificate" ]] || {
    echo "The application signing certificate could not be extracted." >&2
    exit 65
  }
  signed_certificate_hash="$(shasum -a 256 "$signed_certificate" | awk '{print $1}')"
  profile_certificate_count="$(
    plutil -extract DeveloperCertificates raw "$PROFILE_PLIST" 2>/dev/null || true
  )"
  [[ "$profile_certificate_count" == "1" ]] || {
    echo "A Mac App Store distribution profile must authorize exactly one certificate." >&2
    exit 65
  }
  profile_certificate="$VALIDATION_WORK_DIR/profile-certificate.der"
  plutil -extract DeveloperCertificates.0 raw "$PROFILE_PLIST" \
    | /usr/bin/base64 -D >"$profile_certificate"
  [[ "$(shasum -a 256 "$profile_certificate" | awk '{print $1}')" \
    == "$signed_certificate_hash" ]] || {
    echo "The embedded profile does not authorize the application signing certificate." >&2
    exit 65
  }
else
  if [[ "${ADDRESS_ATLAS_ALLOW_ADHOC_APP_STORE_BUILD:-0}" != "1" || -n "$PKG_PATH" ]]; then
    echo "An ad-hoc App Store candidate is permitted only for the explicit CI contract check." >&2
    exit 65
  fi
fi
actual_entitlement_keys="$(plist_top_level_keys "$ENTITLEMENTS_READBACK" | LC_ALL=C sort)"
expected_entitlement_keys="$(printf '%s\n' "$expected_entitlement_keys" | LC_ALL=C sort)"
[[ "$actual_entitlement_keys" == "$expected_entitlement_keys" ]] || {
  echo "The signed entitlement set contains a missing or unreviewed capability." >&2
  exit 65
}

if [[ -n "$PKG_PATH" ]]; then
  [[ "$(stat -f '%Lp' "$PKG_PATH")" == "444" \
    && "$(stat -f '%Lp' "$PROVENANCE_PATH")" == "444" ]] || {
    echo "The final package and provenance record must be read-only." >&2
    exit 65
  }
  plutil -lint "$PROVENANCE_PATH" >/dev/null
  expected_provenance_keys=$'AppStoreID\nBuildVersion\nBundleIdentifier\nPackageSHA256\nSchemaVersion\nShortVersion\nSourceCommit\nTeamIdentifier'
  actual_provenance_keys="$(plist_top_level_keys "$PROVENANCE_PATH" | LC_ALL=C sort)"
  [[ "$actual_provenance_keys" == "$expected_provenance_keys" ]] || {
    echo "The Mac App Store provenance record has an unexpected field set." >&2
    exit 65
  }
  provenance_app_store_id="$(plutil -extract AppStoreID raw "$PROVENANCE_PATH")"
  provenance_source_commit="$(plutil -extract SourceCommit raw "$PROVENANCE_PATH")"
  package_sha256="$(shasum -a 256 "$PKG_PATH" | awk '{print $1}')"
  artifact_team_identifier="$(
    sed -nE 's/^TeamIdentifier=([A-Z0-9]{10})$/\1/p' <<< "$signature_details"
  )"
  [[ "$provenance_app_store_id" =~ ^[1-9][0-9]{5,14}$ \
    && "$provenance_source_commit" =~ ^[0-9a-f]{40,64}$ \
    && "$(plutil -extract SchemaVersion raw "$PROVENANCE_PATH")" == "1" \
    && "$(plutil -extract PackageSHA256 raw "$PROVENANCE_PATH")" == "$package_sha256" \
    && "$(plutil -extract BundleIdentifier raw "$PROVENANCE_PATH")" \
      == "$(plutil -extract CFBundleIdentifier raw "$INFO_PLIST")" \
    && "$(plutil -extract ShortVersion raw "$PROVENANCE_PATH")" == "$short_version" \
    && "$(plutil -extract BuildVersion raw "$PROVENANCE_PATH")" == "$build_version" \
    && "$(plutil -extract TeamIdentifier raw "$PROVENANCE_PATH")" \
      == "$artifact_team_identifier" \
    && "$provenance_source_commit" == "$source_commit" \
    && "$update_url" == "https://apps.apple.com/app/id$provenance_app_store_id" ]] || {
    echo "The provenance record does not match the signed app inside the installer package." >&2
    exit 65
  }
fi

architectures="$(xcrun lipo -archs "$APP_PATH/Contents/MacOS/$APP_NAME")"
[[ "$architectures" == "arm64 x86_64" || "$architectures" == "x86_64 arm64" ]] || {
  echo "Mac App Store binary must be universal arm64 + x86_64; got: $architectures" >&2
  exit 65
}

quarantine_readback="$(/usr/bin/xattr -r -p com.apple.quarantine "$APP_PATH" 2>/dev/null || true)"
[[ -z "$quarantine_readback" ]] || {
  echo "The Mac App Store app contains a quarantined file." >&2
  exit 65
}

if [[ -n "$PKG_PATH" ]]; then
  app_team_identifier="$(
    sed -nE 's/^TeamIdentifier=([A-Z0-9]{10})$/\1/p' <<< "$signature_details"
  )"
  [[ "$app_team_identifier" =~ ^[A-Z0-9]{10}$ \
    && "$package_signature" == *"($app_team_identifier)"* ]] || {
    echo "The installer certificate does not belong to the application signing team." >&2
    exit 65
  }
  distribution_file="$expanded_package/Distribution"
  [[ -f "$distribution_file" && ! -L "$distribution_file" ]] || {
    echo "The installer package has no safe Distribution definition." >&2
    exit 65
  }
  package_info_files="$(
    find "$expanded_package" -mindepth 2 -maxdepth 2 -type f -name PackageInfo -print
  )"
  [[ -n "$package_info_files" && "$package_info_files" != *$'\n'* \
    && -f "$package_info_files" && ! -L "$package_info_files" ]] || {
    echo "The installer must contain exactly one component PackageInfo." >&2
    exit 65
  }
  [[ "$(
    /usr/bin/xmllint --xpath 'string(/pkg-info/@install-location)' "$package_info_files"
  )" == "/Applications" ]] || {
    echo "The installer component does not target /Applications." >&2
    exit 65
  }
  [[ "$(
    /usr/bin/xmllint --xpath \
      "string(/installer-gui-script/choice[@id='com.addressatlas.mac']/@customLocation)" \
      "$distribution_file"
  )" == "/Applications" ]] || {
    echo "The installer distribution does not pin Address Atlas to /Applications." >&2
    exit 65
  }
  payload_files="$(pkgutil --payload-files "$PKG_PATH")"
  if ! grep -Fxq "./$APP_NAME.app/Contents/MacOS/$APP_NAME" <<< "$payload_files" \
    && ! grep -Fxq "$APP_NAME.app/Contents/MacOS/$APP_NAME" <<< "$payload_files"; then
      echo "The installer package does not contain the expected /Applications payload." >&2
      exit 65
  fi
  quarantine_readback="$(/usr/bin/xattr -p com.apple.quarantine "$PKG_PATH" 2>/dev/null || true)"
  [[ -z "$quarantine_readback" ]] || {
    echo "The Mac App Store installer package is quarantined." >&2
    exit 65
  }
fi

echo "Mac App Store artifact validation passed."
