#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER_BIN="${DOCKER_BIN:-docker}"
STRICT=0
case "$#:${1:-}" in
  0:) ;;
  1:--strict) STRICT=1 ;;
  *)
    echo "Usage: $0 [--strict]" >&2
    exit 64
    ;;
esac

failures=0
warnings=0

pass() {
  printf 'PASS %s\n' "$1"
}

warn() {
  warnings=$((warnings + 1))
  printf 'WARN %s\n' "$1"
}

fail() {
  failures=$((failures + 1))
  printf 'FAIL %s\n' "$1"
}

has_command() {
  command -v "$1" >/dev/null 2>&1
}

check_host_command() {
  local command_name="$1"
  local purpose="$2"
  if has_command "$command_name"; then
    pass "${command_name} found for ${purpose}"
  elif [[ "$STRICT" -eq 1 ]]; then
    fail "${command_name} missing; ${purpose} cannot be verified in strict mode"
  else
    warn "${command_name} missing; ${purpose} cannot be checked locally"
  fi
}

env_file_value() {
  local file="$1"
  local name="$2"
  local line value
  line="$(grep -E "^[[:space:]]*${name}[[:space:]]*=" "$file" | tail -n 1 || true)"
  [[ -n "$line" ]] || return 0
  value="${line#*=}"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

cd "$ROOT"
PROD_ENV_FILE="${ADDRESS_ATLAS_PROD_ENV_FILE:-server/sync/.env.production}"

has_command swift && pass "Swift toolchain found" || fail "Swift toolchain missing"
check_host_command docker "production Compose and database recovery"
check_host_command curl "bounded public deployment smoke tests"
check_host_command age "encrypted backup verification"
check_host_command age-keygen "backup identity validation"
check_host_command openssl "signed backup-manifest verification"
has_command security && pass "macOS security tool found" || warn "macOS security tool missing"

if has_command node && has_command npm \
  && npm_version="$(npm --version)" \
  && node -e '
  const [major, minor] = process.versions.node.split(".").map(Number);
  const [npmMajor, npmMinor] = process.argv[1].split(".").map(Number);
  if (major !== 22 || minor < 17 || npmMajor !== 10 || npmMinor < 9) process.exit(1);
' "$npm_version"; then
  pass "Node and npm satisfy the pinned release toolchain range"
else
  fail "Node 22.17+ and npm 10.9+ are required"
fi

ops_shell_scripts=(
  server/sync/manage-prod.sh
  server/sync/frontend-recovery.sh
  server/sync/frontend-recovery-tests.sh
  server/sync/credential-rotation-tests.sh
  scripts/check-ruleset-governance-tests.sh
  server/sync/systemd-contract-tests.sh
  server/sync/postgres-backup.sh
  server/sync/monitor-sync.sh
)
ops_posix_shell_scripts=(server/sync/provision-runtime-role.sh)
for optional_script in \
  server/sync/bootstrap-database-roles.sh \
  server/sync/migrate-restored-database.sh \
  server/sync/provision-restored-database.sh; do
  [[ ! -f "$optional_script" ]] || ops_posix_shell_scripts+=("$optional_script")
done
if bash -n "${ops_shell_scripts[@]}" \
  && sh -n "${ops_posix_shell_scripts[@]}"; then
  pass "Operations scripts pass shell syntax validation"
else
  fail "Operations script syntax validation failed"
fi

if has_command xcodebuild; then
  xcodebuild -license check >/dev/null 2>&1 && pass "Xcode license accepted" || fail "Xcode license not accepted"
else
  fail "xcodebuild missing"
fi

codesigning_identities=""
if has_command security; then
  codesigning_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
fi
if grep -q "Developer ID Application" <<< "$codesigning_identities"; then
  pass "Developer ID Application signing identity available"
else
  fail "Developer ID Application signing identity missing; public notarized release is blocked"
fi

if [[ -f "$PROD_ENV_FILE" ]]; then
  pass "Production environment file exists"
  if [[ -L "$PROD_ENV_FILE" || ! -f "$PROD_ENV_FILE" ]]; then
    fail "Production environment file must be a regular non-symlink file"
  else
    if env_file_mode="$(stat -c %a "$PROD_ENV_FILE" 2>/dev/null)" \
      && env_file_owner="$(stat -c %u "$PROD_ENV_FILE" 2>/dev/null)"; then
      :
    else
      env_file_mode="$(stat -f %Lp "$PROD_ENV_FILE" 2>/dev/null || true)"
      env_file_owner="$(stat -f %u "$PROD_ENV_FILE" 2>/dev/null || true)"
    fi
    current_uid="$(id -u)"
    if [[ "$env_file_mode" =~ ^[0-7]{3,4}$ ]] \
      && (( (8#$env_file_mode & 8#077) == 0 )) \
      && [[ "$env_file_owner" == "$current_uid" ]]; then
      pass "Production environment file is privately owned by the invoking operator"
    else
      fail "Production environment file must be operator-owned and inaccessible by group/other users"
    fi
  fi
  required_production_values=(
    POSTGRES_PASSWORD
    POSTGRES_ADMIN_PASSWORD
    POSTGRES_RUNTIME_PASSWORD
    ADDRESS_ATLAS_DATABASE_ROLE_MODE
    SYNC_SCHEMA_DATABASE_URL
    SYNC_DATABASE_URL
    SYNC_SESSION_SECRET
    SYNC_REGISTRATION_ENABLED
    ADDRESS_ATLAS_BACKUP_DIR
    ADDRESS_ATLAS_BACKUP_MAX_BYTES
    ADDRESS_ATLAS_BACKUP_AGE_RECIPIENT
    ADDRESS_ATLAS_BACKUP_AGE_IDENTITY_FILE
    ADDRESS_ATLAS_BACKUP_SIGNING_PRIVATE_KEY_FILE
    ADDRESS_ATLAS_BACKUP_SIGNATURE_PUBLIC_KEY_FILE
    ADDRESS_ATLAS_BACKUP_OFFSITE_REQUIRED
    ADDRESS_ATLAS_BACKUP_OFFSITE_HOOK
    ADDRESS_ATLAS_NATIVE_CONFIG_STATE_FILE
  )
  production_values_complete=1
  for name in "${required_production_values[@]}"; do
    if [[ -n "$(env_file_value "$PROD_ENV_FILE" "$name")" ]]; then
      pass "$name is configured in the production environment"
    else
      fail "$name is missing from the production environment"
      production_values_complete=0
    fi
  done

  owner_password="$(env_file_value "$PROD_ENV_FILE" POSTGRES_PASSWORD)"
  admin_password="$(env_file_value "$PROD_ENV_FILE" POSTGRES_ADMIN_PASSWORD)"
  runtime_password="$(env_file_value "$PROD_ENV_FILE" POSTGRES_RUNTIME_PASSWORD)"
  if [[ "$owner_password" =~ ^[A-Za-z0-9_-]{32,128}$ ]] \
    && [[ "$admin_password" =~ ^[A-Za-z0-9_-]{32,128}$ ]] \
    && [[ "$runtime_password" =~ ^[A-Za-z0-9_-]{32,128}$ ]] \
    && [[ "$owner_password" != *replace* && "$admin_password" != *replace* \
      && "$runtime_password" != *replace* ]] \
    && [[ "$owner_password" != "$admin_password" \
      && "$owner_password" != "$runtime_password" \
      && "$admin_password" != "$runtime_password" ]]; then
    pass "Admin, schema-owner, and runtime database passwords are mutually distinct"
  else
    fail "All three database passwords must be distinct, non-placeholder, URL-safe 32-128 character values"
  fi

  role_mode="$(env_file_value "$PROD_ENV_FILE" ADDRESS_ATLAS_DATABASE_ROLE_MODE)"
  if [[ "$role_mode" == "steady" ]]; then
    pass "Database roles are in steady isolated-admin mode"
  else
    fail "ADDRESS_ATLAS_DATABASE_ROLE_MODE must be steady before a release; bootstrap is one-time only"
  fi

  session_secret="$(env_file_value "$PROD_ENV_FILE" SYNC_SESSION_SECRET)"
  if [[ "$session_secret" =~ ^[A-Za-z0-9_+/=-]{43,192}$ \
     && "$session_secret" != *replace* \
      && "$session_secret" != "$owner_password" \
     && "$session_secret" != "$admin_password" \
     && "$session_secret" != "$runtime_password" ]]; then
    pass "Session secret has an independent non-placeholder 256-bit-capable shape"
  else
    fail "SYNC_SESSION_SECRET must be an independent 43-192 character random base64/base64url value"
  fi

  schema_url="$(env_file_value "$PROD_ENV_FILE" SYNC_SCHEMA_DATABASE_URL)"
  runtime_url="$(env_file_value "$PROD_ENV_FILE" SYNC_DATABASE_URL)"
  if CHECK_OWNER_PASSWORD="$owner_password" \
    CHECK_RUNTIME_PASSWORD="$runtime_password" \
    CHECK_SCHEMA_URL="$schema_url" \
    CHECK_RUNTIME_URL="$runtime_url" \
    node -e '
      try {
        const owner = new URL(process.env.CHECK_SCHEMA_URL);
        const runtime = new URL(process.env.CHECK_RUNTIME_URL);
        const postgres = new Set(["postgres:", "postgresql:"]);
        if (!postgres.has(owner.protocol) || !postgres.has(runtime.protocol)) process.exit(1);
        if (owner.username !== "address_atlas" || runtime.username !== "address_atlas_runtime") process.exit(1);
        if (decodeURIComponent(owner.password) !== process.env.CHECK_OWNER_PASSWORD) process.exit(1);
        if (decodeURIComponent(runtime.password) !== process.env.CHECK_RUNTIME_PASSWORD) process.exit(1);
        for (const url of [owner, runtime]) {
          if (url.hostname !== "postgres" || (url.port && url.port !== "5432")) process.exit(1);
          if (url.pathname !== "/address_atlas_sync" || url.search || url.hash) process.exit(1);
        }
        if (owner.host !== runtime.host || owner.pathname !== runtime.pathname) process.exit(1);
      } catch {
        process.exit(1);
      }
    '; then
    pass "Database URLs bind exact owner/runtime credentials to local postgres/address_atlas_sync without query or fragment data"
  else
    fail "Database URLs must use exact postgres:5432/address_atlas_sync owner/runtime bindings with no query or fragment"
  fi

  if [[ "$(env_file_value "$PROD_ENV_FILE" SYNC_REGISTRATION_ENABLED)" == "false" ]]; then
    pass "Public account registration is closed for release"
  else
    fail "SYNC_REGISTRATION_ENABLED must be false outside an intentional enrollment window"
  fi

  identity_file="$(env_file_value "$PROD_ENV_FILE" ADDRESS_ATLAS_BACKUP_AGE_IDENTITY_FILE)"
  if [[ -n "$identity_file" && "$identity_file" == /* && -f "$identity_file" && ! -L "$identity_file" ]]; then
    if identity_mode="$(stat -c %a "$identity_file" 2>/dev/null)"; then
      :
    else
      identity_mode="$(stat -f %Lp "$identity_file" 2>/dev/null || true)"
    fi
    if [[ "$identity_mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$identity_mode & 8#077) == 0 )); then
      pass "Backup age identity is an absolute private regular file"
    else
      fail "Backup age identity must not be accessible by group or other users"
    fi
  else
    fail "Backup age identity must be an existing absolute non-symlink file"
  fi

  signing_private_key="$(env_file_value "$PROD_ENV_FILE" ADDRESS_ATLAS_BACKUP_SIGNING_PRIVATE_KEY_FILE)"
  if [[ -n "$signing_private_key" && "$signing_private_key" == /* \
     && -f "$signing_private_key" && ! -L "$signing_private_key" ]]; then
    signing_private_mode="$(stat -c %a "$signing_private_key" 2>/dev/null \
      || stat -f %Lp "$signing_private_key" 2>/dev/null || true)"
    signing_private_owner="$(stat -c %u "$signing_private_key" 2>/dev/null \
      || stat -f %u "$signing_private_key" 2>/dev/null || true)"
    if [[ "$signing_private_mode" =~ ^[0-7]{3,4}$ \
       && "$signing_private_owner" == "$(id -u)" ]] \
      && (( (8#$signing_private_mode & 8#077) == 0 )) \
      && { ! has_command openssl \
        || openssl pkey -in "$signing_private_key" -check -noout >/dev/null 2>&1; }; then
      pass "Backup manifest signing private key is valid and private"
    else
      fail "Backup signing private key must be valid, operator-owned, and inaccessible by group/other users"
    fi
  else
    fail "Backup signing private key must be an existing absolute non-symlink file"
  fi

  signing_public_key="$(env_file_value "$PROD_ENV_FILE" ADDRESS_ATLAS_BACKUP_SIGNATURE_PUBLIC_KEY_FILE)"
  if [[ -n "$signing_public_key" && "$signing_public_key" == /* \
     && -f "$signing_public_key" && ! -L "$signing_public_key" ]]; then
    signing_public_mode="$(stat -c %a "$signing_public_key" 2>/dev/null \
      || stat -f %Lp "$signing_public_key" 2>/dev/null || true)"
    signing_public_owner="$(stat -c %u "$signing_public_key" 2>/dev/null \
      || stat -f %u "$signing_public_key" 2>/dev/null || true)"
    if [[ "$signing_public_mode" =~ ^[0-7]{3,4}$ \
       && ( "$signing_public_owner" == "0" || "$signing_public_owner" == "$(id -u)" ) ]] \
      && (( (8#$signing_public_mode & 8#022) == 0 )) \
      && { ! has_command openssl \
        || openssl pkey -pubin -in "$signing_public_key" -noout >/dev/null 2>&1; }; then
      pass "Backup manifest signature public key is trusted and non-writable"
    else
      fail "Backup signature public key must be valid, trusted-owned, and not group/other-writable"
    fi
  else
    fail "Backup signature public key must be an existing absolute non-symlink file"
  fi

  offsite_required="$(env_file_value "$PROD_ENV_FILE" ADDRESS_ATLAS_BACKUP_OFFSITE_REQUIRED)"
  offsite_hook="$(env_file_value "$PROD_ENV_FILE" ADDRESS_ATLAS_BACKUP_OFFSITE_HOOK)"
  if [[ "$offsite_required" == "true" && "$offsite_hook" == /* \
     && -f "$offsite_hook" && -x "$offsite_hook" && ! -L "$offsite_hook" ]]; then
    offsite_mode="$(stat -c %a "$offsite_hook" 2>/dev/null \
      || stat -f %Lp "$offsite_hook" 2>/dev/null || true)"
    offsite_owner="$(stat -c %u "$offsite_hook" 2>/dev/null \
      || stat -f %u "$offsite_hook" 2>/dev/null || true)"
    if [[ "$offsite_mode" =~ ^[0-7]{3,4}$ && "$offsite_owner" == "$(id -u)" ]] \
      && (( (8#$offsite_mode & 8#022) == 0 )); then
      pass "Off-host backup delivery is mandatory through a trusted executable hook"
    else
      fail "Offsite hook must be operator-owned and not group/other-writable"
    fi
  else
    fail "Production requires ADDRESS_ATLAS_BACKUP_OFFSITE_REQUIRED=true and a trusted absolute hook"
  fi

  native_config_state_file="$(env_file_value "$PROD_ENV_FILE" ADDRESS_ATLAS_NATIVE_CONFIG_STATE_FILE)"
  if has_command node \
    && node server/sync/native-config-deploy-state.mjs validate \
      "$native_config_state_file" >/dev/null 2>&1; then
    if [[ ! -e "$native_config_state_file" && ! -L "$native_config_state_file" ]] \
      || node server/sync/native-config-deploy-state.mjs read \
        "$native_config_state_file" >/dev/null 2>&1; then
      pass "Native-config deployment receipt path and existing state are trusted"
    else
      fail "Existing native-config deployment receipt is invalid or unsafe"
    fi
  else
    fail "Native-config deployment receipt path must be absolute with a prepared private owner directory"
  fi

  backup_dir="$(env_file_value "$PROD_ENV_FILE" ADDRESS_ATLAS_BACKUP_DIR)"
  [[ "$backup_dir" == /* && "$backup_dir" != "/" ]] \
    && pass "Backup directory is an explicit safe absolute path" \
    || fail "Backup directory must be an absolute path other than /"

  backup_max_bytes="$(env_file_value "$PROD_ENV_FILE" ADDRESS_ATLAS_BACKUP_MAX_BYTES)"
  if [[ "$backup_max_bytes" =~ ^[1-9][0-9]*$ ]] \
    && (( backup_max_bytes >= 1048576 && backup_max_bytes <= 1099511627776 )); then
    pass "Backup artifact size ceiling is explicit and bounded"
  else
    fail "ADDRESS_ATLAS_BACKUP_MAX_BYTES must be between 1 MiB and 1 TiB"
  fi

  backup_recipient="$(env_file_value "$PROD_ENV_FILE" ADDRESS_ATLAS_BACKUP_AGE_RECIPIENT)"
  if [[ "$backup_recipient" == age1* && "$backup_recipient" != *replace* && "$backup_recipient" != *$'\n'* ]]; then
    pass "Backup age recipient is non-placeholder and single-line"
  else
    fail "Backup age recipient is invalid or still a placeholder"
  fi

  if has_command docker; then
    bash server/sync/manage-prod.sh config >/dev/null \
      && pass "Production compose config and volume preflight pass" \
      || fail "Production compose config or volume preflight failed"

    compose_revision="$(git rev-parse HEAD 2>/dev/null || true)"
    if [[ "$compose_revision" =~ ^[0-9a-f]{40}$ ]] \
      && ADDRESS_ATLAS_BUILD_REVISION="$compose_revision" \
        "$DOCKER_BIN" compose \
          --env-file "$PROD_ENV_FILE" \
          --project-name address-atlas-sync \
          -f server/sync/compose.prod.yml \
          config --format json 2>/dev/null \
        | node -e '
            "use strict";
            let input = "";
            process.stdin.setEncoding("utf8");
            process.stdin.on("data", (chunk) => { input += chunk; });
            process.stdin.on("end", () => {
              try {
                const model = JSON.parse(input);
                const postgres = model.services?.postgres;
                const web = model.services?.web;
                if (!postgres || !web) process.exit(1);
                if (Array.isArray(postgres.ports) && postgres.ports.length > 0) process.exit(1);
                if (model.networks?.data?.internal !== true) process.exit(1);
                const postgresEnv = postgres.environment || {};
                const webEnv = web.environment || {};
                if (Object.hasOwn(postgresEnv, "POSTGRES_ADMIN_PASSWORD")) process.exit(1);
                if (Object.hasOwn(webEnv, "POSTGRES_PASSWORD") || Object.hasOwn(webEnv, "POSTGRES_ADMIN_PASSWORD")) process.exit(1);
              } catch { process.exit(1); }
            });
          '; then
      pass "PostgreSQL has no host port, the data network is internal, and admin/owner secrets stay out of long-running web"
    else
      fail "Could not prove local-only PostgreSQL binding and long-running secret isolation from rendered Compose"
    fi
  fi

  if [[ "$STRICT" -eq 1 ]]; then
    if [[ "$production_values_complete" -ne 1 ]] \
      || ! has_command docker || ! has_command age || ! has_command openssl; then
      fail "Strict backup verification and restore drill could not run because prerequisites are incomplete"
    else
      if bash server/sync/manage-prod.sh verify-backup >/dev/null; then
        pass "Newest production backup is fresh, signed, checksummed, decryptable, and readable by pg_restore"
      else
        fail "Newest production backup verification failed"
      fi
      if bash server/sync/manage-prod.sh restore-drill >/dev/null; then
        pass "Isolated production restore drill passed"
      else
        fail "Isolated production restore drill failed"
      fi
    fi
  fi
else
  if [[ -n "${ADDRESS_ATLAS_PROD_ENV_FILE:-}" ]]; then
    fail "Explicit production environment file is missing"
  elif [[ "$STRICT" -eq 1 ]]; then
    fail "Default production environment file is missing in strict mode"
  else
    warn "Production environment file missing; copy server/sync/.env.production.example before VPS deploy"
  fi
fi

if [[ "$STRICT" -eq 1 ]]; then
  current_branch="$(git branch --show-current 2>/dev/null || true)"
  [[ "$current_branch" == "main" ]] && pass "Release checkout is on main" || fail "Release checkout must be on main"
  [[ -z "$(git status --porcelain --untracked-files=normal 2>/dev/null)" ]] \
    && pass "Release checkout is clean" \
    || fail "Release checkout contains uncommitted or untracked files"
fi

if [[ -n "${ADDRESS_ATLAS_CODESIGN_IDENTITY:-}" ]]; then
  pass "ADDRESS_ATLAS_CODESIGN_IDENTITY is set"
else
  fail "ADDRESS_ATLAS_CODESIGN_IDENTITY is not set; public release is blocked"
fi

if [[ -n "${ADDRESS_ATLAS_CODESIGN_IDENTITY:-}" ]]; then
  selected_identity_found=0
  selected_identity_is_developer_id=0
  while IFS='|' read -r identity_hash identity_name; do
    if [[ "$identity_name" == "$ADDRESS_ATLAS_CODESIGN_IDENTITY" \
       || "$identity_hash" == "$ADDRESS_ATLAS_CODESIGN_IDENTITY" ]]; then
      selected_identity_found=1
      [[ "$identity_name" == "Developer ID Application: "* ]] \
        && selected_identity_is_developer_id=1
    fi
  done < <(sed -nE 's/^[[:space:]]*[0-9]+\) ([[:xdigit:]]{40}) "(.*)"$/\1|\2/p' <<< "$codesigning_identities")

  if [[ "$selected_identity_found" -eq 0 ]]; then
    fail "Selected signing identity was not found exactly in Keychain"
  elif [[ "$selected_identity_is_developer_id" -ne 1 ]]; then
    fail "Selected signing identity is not a Developer ID Application identity"
  else
    pass "Selected Developer ID Application identity exists in Keychain"
  fi
fi

notary_profile="${ADDRESS_ATLAS_NOTARY_PROFILE:-}"
notary_key_path="${ADDRESS_ATLAS_NOTARY_KEY_PATH:-}"
notary_key_id="${ADDRESS_ATLAS_NOTARY_KEY_ID:-}"
notary_issuer_id="${ADDRESS_ATLAS_NOTARY_ISSUER_ID:-}"
notary_direct_present=0
[[ -n "$notary_key_path" || -n "$notary_key_id" || -n "$notary_issuer_id" ]] \
  && notary_direct_present=1
notary_mode=""

if [[ -n "$notary_profile" && "$notary_direct_present" -eq 1 ]]; then
  fail "Choose either a notary Keychain profile or direct App Store Connect credentials, never both"
elif [[ -n "$notary_profile" ]]; then
  if [[ "$notary_profile" =~ ^[A-Za-z0-9._-]{1,128}$ ]]; then
    notary_mode="profile"
    pass "Notary Keychain profile is configured"
  else
    fail "ADDRESS_ATLAS_NOTARY_PROFILE has an invalid shape"
  fi
elif [[ "$notary_direct_present" -eq 1 ]]; then
  direct_valid=1
  [[ -n "$notary_key_path" && -n "$notary_key_id" && -n "$notary_issuer_id" ]] \
    || direct_valid=0
  [[ "$notary_key_path" == /* && -f "$notary_key_path" && ! -L "$notary_key_path" ]] \
    || direct_valid=0
  [[ "$notary_key_id" =~ ^[A-Z0-9]{10}$ ]] || direct_valid=0
  [[ "$notary_issuer_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] \
    || direct_valid=0
  if [[ -f "$notary_key_path" && ! -L "$notary_key_path" ]]; then
    if notary_key_mode="$(stat -c %a "$notary_key_path" 2>/dev/null)"; then
      :
    else
      notary_key_mode="$(stat -f %Lp "$notary_key_path" 2>/dev/null || true)"
    fi
    [[ "$notary_key_mode" =~ ^[0-7]{3,4}$ ]] \
      && (( (8#$notary_key_mode & 8#077) == 0 )) \
      || direct_valid=0
  fi
  if [[ "$direct_valid" -eq 1 ]]; then
    notary_mode="direct"
    pass "Direct App Store Connect notary credentials are configured privately"
  else
    fail "Direct notary credentials must be complete, valid, and use a private absolute key file"
  fi
else
  fail "No notary credentials are configured; public release is blocked"
fi

if [[ "$STRICT" -eq 1 && "$notary_mode" == "profile" ]]; then
  if xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1; then
    pass "Selected notary profile is valid"
  else
    fail "Selected notary profile is missing, invalid, or cannot reach Apple's notary service"
  fi
elif [[ "$STRICT" -eq 1 && "$notary_mode" == "direct" ]]; then
  if xcrun notarytool history \
    --key "$notary_key_path" \
    --key-id "$notary_key_id" \
    --issuer "$notary_issuer_id" >/dev/null 2>&1; then
    pass "Selected direct notary credentials are valid"
  else
    fail "Selected direct notary credentials are invalid or cannot reach Apple's notary service"
  fi
fi

live_exchange_missing=0
for name in \
  ADDRESS_ATLAS_BINANCE_API_KEY \
  ADDRESS_ATLAS_BINANCE_SECRET \
  ADDRESS_ATLAS_COINBASE_API_KEY \
  ADDRESS_ATLAS_COINBASE_SECRET \
  ADDRESS_ATLAS_KRAKEN_API_KEY \
  ADDRESS_ATLAS_KRAKEN_SECRET; do
  [[ -n "${!name:-}" ]] || live_exchange_missing=1
done

if [[ "$live_exchange_missing" -eq 0 ]]; then
  pass "Live exchange smoke credentials are present"
else
  warn "Live exchange smoke credentials are incomplete"
fi

printf '\nRelease doctor: %d failure(s), %d warning(s).\n' "$failures" "$warnings"

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi
