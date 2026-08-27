#!/usr/bin/env bash

# Resolve one supported Xcode altool authentication mode without ever accepting
# a plaintext password. The caller receives the exact arguments in
# AUTH_ARGUMENTS.
resolve_address_atlas_altool_auth() {
  local api_key="${ADDRESS_ATLAS_ASC_API_KEY:-}"
  local api_issuer="${ADDRESS_ATLAS_ASC_API_ISSUER:-}"
  local p8_path="${ADDRESS_ATLAS_ASC_P8_PATH:-}"
  local asc_username="${ADDRESS_ATLAS_ASC_USERNAME:-}"
  local password_keychain_item="${ADDRESS_ATLAS_ASC_PASSWORD_KEYCHAIN_ITEM:-}"
  local api_auth_present=0
  local password_auth_present=0
  local p8_permissions

  AUTH_ARGUMENTS=()

  if [[ -n "${ADDRESS_ATLAS_ASC_API_KEY_SUBJECT:-}" ]]; then
    echo "ADDRESS_ATLAS_ASC_API_KEY_SUBJECT is unsupported by Xcode's App Store upload commands. Use a team API key with an issuer, or an Apple ID with an app-specific password stored in Keychain." >&2
    return 64
  fi
  if [[ -n "${ADDRESS_ATLAS_ASC_PASSWORD:-}" ]]; then
    echo "Plaintext App Store Connect passwords are not accepted. Store the app-specific password in Keychain and set ADDRESS_ATLAS_ASC_PASSWORD_KEYCHAIN_ITEM." >&2
    return 64
  fi

  if [[ -n "$api_key" || -n "$api_issuer" || -n "$p8_path" ]]; then
    api_auth_present=1
  fi
  if [[ -n "$asc_username" || -n "$password_keychain_item" ]]; then
    password_auth_present=1
  fi
  if ((api_auth_present && password_auth_present)); then
    echo "Choose exactly one App Store Connect authentication method; API-key and Apple-ID credentials cannot be mixed." >&2
    return 64
  fi

  if ((api_auth_present)); then
    if [[ -z "$api_key" || -z "$api_issuer" || -z "$p8_path" ]]; then
      echo "Team API-key authentication requires ADDRESS_ATLAS_ASC_API_KEY, ADDRESS_ATLAS_ASC_API_ISSUER, and ADDRESS_ATLAS_ASC_P8_PATH." >&2
      return 78
    fi
    if [[ ! "$api_issuer" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
      echo "ADDRESS_ATLAS_ASC_API_ISSUER must be an App Store Connect issuer UUID." >&2
      return 64
    fi
    if [[ "$p8_path" != /* || ! -f "$p8_path" || -L "$p8_path" ]]; then
      echo "The App Store Connect private key path is missing or unsafe; implicit key discovery is disabled." >&2
      return 66
    fi
    p8_permissions="$(stat -f '%Lp' "$p8_path")"
    if [[ ! "$p8_permissions" =~ ^[0-7]?[0-7]00$ ]]; then
      echo "The App Store Connect private key must be private to its owner." >&2
      return 65
    fi
    AUTH_ARGUMENTS=(
      --api-key "$api_key"
      --api-issuer "$api_issuer"
      --p8-file-path "$p8_path"
    )
    return 0
  fi

  if ((password_auth_present)); then
    if [[ -z "$asc_username" || -z "$password_keychain_item" ]]; then
      echo "Apple-ID authentication requires ADDRESS_ATLAS_ASC_USERNAME and ADDRESS_ATLAS_ASC_PASSWORD_KEYCHAIN_ITEM." >&2
      return 78
    fi
    if [[ "$asc_username" == *$'\n'* || "$asc_username" == *$'\r'* ]]; then
      echo "ADDRESS_ATLAS_ASC_USERNAME contains an invalid line break." >&2
      return 64
    fi
    if [[ ! "$password_keychain_item" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
      echo "ADDRESS_ATLAS_ASC_PASSWORD_KEYCHAIN_ITEM must be a simple Keychain item name." >&2
      return 64
    fi
    AUTH_ARGUMENTS=(
      --username "$asc_username"
      --password "@keychain:$password_keychain_item"
    )
    return 0
  fi

  echo "App Store Connect authentication is required. Configure either a team API key with issuer and explicit P8 path, or an Apple ID with a Keychain-stored app-specific password." >&2
  return 78
}
