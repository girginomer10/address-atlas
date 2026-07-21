#!/usr/bin/env bash
set -uo pipefail

# Hermetic executable tests for the standalone production operations scripts.
# Docker, age, curl, date, and psql are replaced with per-test fakes; no live
# service, database, key, network endpoint, or host backup directory is used.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_SCRIPT="${SCRIPT_DIR}/monitor-sync.sh"
BACKUP_SCRIPT="${SCRIPT_DIR}/postgres-backup.sh"
PROVISION_SCRIPT="${SCRIPT_DIR}/provision-runtime-role.sh"
BOOTSTRAP_ROLE_SCRIPT="${SCRIPT_DIR}/bootstrap-database-roles.sh"
REAL_OPENSSL_BIN="$(command -v openssl || true)"
REAL_NODE_BIN="$(command -v node || true)"
OPS_TEST_BASH_BIN="${OPS_TEST_BASH_BIN:-/bin/bash}"
[[ "$OPS_TEST_BASH_BIN" == /* && -x "$OPS_TEST_BASH_BIN" ]] || {
  printf 'OPS_TEST_BASH_BIN must be an absolute executable Bash path.\n' >&2
  exit 64
}

TEST_ROOT="$(mktemp -d "${SCRIPT_DIR}/.ops-tests.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
PASSED=0
FAILED=0

cleanup() {
  if [[ "${OPS_TEST_KEEP_TMP:-0}" == '1' ]]; then
    printf 'preserved test workspace: %s\n' "$TEST_ROOT" >&2
    return 0
  fi
  find "$TEST_ROOT" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf 'assertion failed: %s\n' "$1" >&2
  return 1
}

assert_status() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  [[ "$actual" -eq "$expected" ]] || fail "${label} (expected ${expected}, got ${actual})"
}

assert_path_exists() {
  [[ -e "$1" ]] || fail "$2"
}

assert_path_absent() {
  [[ ! -e "$1" ]] || fail "$2"
}

assert_file_contains() {
  local path="$1"
  local needle="$2"
  local label="$3"
  [[ -f "$path" ]] || fail "${label} (file is missing)"
  grep -F -- "$needle" "$path" >/dev/null || fail "$label"
}

assert_file_not_contains() {
  local path="$1"
  local needle="$2"
  local label="$3"
  [[ ! -f "$path" ]] && return 0
  ! grep -F -- "$needle" "$path" >/dev/null || fail "$label"
}

assert_file_equals() {
  local path="$1"
  local expected="$2"
  local label="$3"
  local actual
  [[ -f "$path" ]] || fail "${label} (file is missing)"
  actual="$(<"$path")"
  [[ "$actual" == "$expected" ]] || fail "$label"
}

new_case() {
  CASE_DIR="$(mktemp -d "${TEST_ROOT}/case.XXXXXX")"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/log" "$CASE_DIR/home"
  if [[ "$OPS_TEST_BASH_BIN" != '/bin/bash' ]]; then
    ln -s "$OPS_TEST_BASH_BIN" "$CASE_DIR/bin/bash"
  fi
}

install_date_fake() {
  cat > "$CASE_DIR/bin/date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  +%s)
    printf '%s\n' "${MOCK_NOW_EPOCH:-1784563200}"
    ;;
  -u)
    case "${2:-}" in
      +%Y%m%dT%H%M%SZ) printf '%s\n' '20260720T160000Z' ;;
      +%Y-%m-%dT%H:%M:%SZ)
        if [[ -n "${MOCK_LOG_DIR:-}" && -n "${MOCK_SNAPSHOT_STARTED_AT:-}" ]]; then
          if [[ ! -e "$MOCK_LOG_DIR/date.snapshot-returned" ]]; then
            : > "$MOCK_LOG_DIR/date.snapshot-returned"
            printf '%s\n' "$MOCK_SNAPSHOT_STARTED_AT"
          else
            printf '%s\n' "${MOCK_COMPLETED_AT:-$MOCK_SNAPSHOT_STARTED_AT}"
          fi
        else
          printf '%s\n' '2026-07-20T16:00:00Z'
        fi
        ;;
      +%Y%m%d%H%M%S) printf '%s\n' '20260720160000' ;;
      *) exec /bin/date "$@" ;;
    esac
    ;;
  *) exec /bin/date "$@" ;;
esac
EOF
  chmod 0700 "$CASE_DIR/bin/date"
}

install_monitor_fakes() {
  install_date_fake
  cat > "$CASE_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${!#}"
printf '%s\n' "$url" >> "${MOCK_CURL_CALL_LOG:-/dev/null}"
case "${MOCK_MONITOR_MODE:-healthy}" in
  healthy)
    printf '%s\n%s\n' '{"ok":true,"service":"address-atlas-sync"}' '200'
    ;;
  not_ready)
    if [[ "$url" == */livez ]]; then
      printf '%s\n%s\n' '{"ok":true,"service":"address-atlas-sync"}' '200'
    else
      printf '%s\n%s\n' '{"ok":false}' '503'
    fi
    ;;
  unhealthy)
    printf '%s\n%s\n' '{"ok":false}' '503'
    ;;
  secret_failure)
    printf '{"detail":"%s"}\n500\n' "${MOCK_RESPONSE_SECRET:-RESPONSE_SECRET}"
    printf 'curl diagnostic contains %s\n' "${MOCK_STDERR_SECRET:-STDERR_SECRET}" >&2
    exit 22
    ;;
  *)
    exit 70
    ;;
esac
EOF
  chmod 0700 "$CASE_DIR/bin/curl"
}

run_monitor_capture() {
  local mode="$1"
  local base_url="$2"
  local response_secret="${3:-RESPONSE_SECRET}"
  local stderr_secret="${4:-STDERR_SECRET}"
  set +e
  env -i \
    PATH="$CASE_DIR/bin:/usr/bin:/bin" \
    HOME="$CASE_DIR/home" \
    CURL_BIN="$CASE_DIR/bin/curl" \
    ADDRESS_ATLAS_MONITOR_BASE_URL="$base_url" \
    ADDRESS_ATLAS_MONITOR_TIMEOUT_SECONDS=5 \
    MOCK_MONITOR_MODE="$mode" \
    MOCK_RESPONSE_SECRET="$response_secret" \
    MOCK_STDERR_SECRET="$stderr_secret" \
    MOCK_CURL_CALL_LOG="$CASE_DIR/log/curl.calls" \
    MOCK_NOW_EPOCH=1784563200 \
    "$OPS_TEST_BASH_BIN" "$MONITOR_SCRIPT" \
      > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr"
  CAPTURE_STATUS=$?
  set -e
}

test_monitor_healthy() {
  new_case
  install_monitor_fakes
  run_monitor_capture healthy 'https://monitor.example.test'
  assert_status "$CAPTURE_STATUS" 0 'healthy monitor exit status'
  assert_file_equals "$CASE_DIR/stdout" \
    '{"timestamp":"2026-07-20T16:00:00Z","service":"address-atlas-sync","status":"healthy","live":true,"ready":true,"durationMs":0}' \
    'healthy monitor JSON'
  assert_file_equals "$CASE_DIR/stderr" '' 'healthy monitor stderr'
}

test_monitor_not_ready() {
  new_case
  install_monitor_fakes
  run_monitor_capture not_ready 'https://monitor.example.test'
  assert_status "$CAPTURE_STATUS" 1 'not-ready monitor exit status'
  assert_file_contains "$CASE_DIR/stdout" '"status":"not_ready"' 'not-ready status field'
  assert_file_contains "$CASE_DIR/stdout" '"live":true,"ready":false' 'not-ready probe fields'
  assert_file_equals "$CASE_DIR/stderr" '' 'not-ready monitor stderr'
}

test_monitor_unhealthy() {
  new_case
  install_monitor_fakes
  run_monitor_capture unhealthy 'https://monitor.example.test'
  assert_status "$CAPTURE_STATUS" 2 'unhealthy monitor exit status'
  assert_file_contains "$CASE_DIR/stdout" '"status":"unhealthy"' 'unhealthy status field'
  assert_file_contains "$CASE_DIR/stdout" '"live":false,"ready":false' 'unhealthy probe fields'
  assert_file_equals "$CASE_DIR/stderr" '' 'unhealthy monitor stderr'
}

test_monitor_rejects_non_origin_urls_before_curl() {
  local invalid_url
  local -a invalid_urls=(
    'http://monitor.example.test'
    'https://user:password@monitor.example.test'
    'https://monitor.example.test/'
    'https://monitor.example.test/probe'
    'https://monitor.example.test?token=URL_QUERY_SECRET_c731'
    'https://monitor.example.test#fragment'
    'https://monitor.example.test:0'
    'https://monitor.example.test:65536'
  )

  for invalid_url in "${invalid_urls[@]}"; do
    new_case
    install_monitor_fakes
    run_monitor_capture secret_failure "$invalid_url"
    assert_status "$CAPTURE_STATUS" 64 "invalid monitor origin rejected: ${invalid_url}"
    assert_path_absent "$CASE_DIR/log/curl.calls" "curl invoked for invalid origin: ${invalid_url}"
    assert_file_not_contains "$CASE_DIR/stdout" 'URL_QUERY_SECRET_c731' 'URL secret leaked to stdout'
    assert_file_not_contains "$CASE_DIR/stderr" 'URL_QUERY_SECRET_c731' 'URL secret leaked to stderr'
  done
}

ensure_backup_signing_keys() {
  [[ -n "$REAL_OPENSSL_BIN" ]] || fail 'openssl is required for backup signature tests'
  TEST_SIGNING_PRIVATE_KEY="$TEST_ROOT/backup-signing-private.pem"
  TEST_SIGNATURE_PUBLIC_KEY="$TEST_ROOT/backup-signing-public.pem"
  if [[ ! -f "$TEST_SIGNING_PRIVATE_KEY" ]]; then
    "$REAL_OPENSSL_BIN" genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
      -out "$TEST_SIGNING_PRIVATE_KEY" >/dev/null 2>&1
    "$REAL_OPENSSL_BIN" pkey -in "$TEST_SIGNING_PRIVATE_KEY" -pubout \
      -out "$TEST_SIGNATURE_PUBLIC_KEY" >/dev/null 2>&1
    chmod 0600 "$TEST_SIGNING_PRIVATE_KEY"
    chmod 0644 "$TEST_SIGNATURE_PUBLIC_KEY"
  fi
}

install_backup_fakes() {
  install_date_fake
  ensure_backup_signing_keys
  cat > "$CASE_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_LOG_DIR:?}"
{
  printf 'docker '
  printf '%q ' "$@"
  printf '\n'
} >> "$MOCK_LOG_DIR/docker.argv"

joined="$*"
case "${1:-}" in
  image)
    if [[ "${2:-}" == 'inspect' ]]; then
      if [[ "$joined" == *'org.opencontainers.image.revision'* ]]; then
        printf '%s\n' "${MOCK_RESTORE_IMAGE_REVISION:-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee}"
      else
        printf 'sha256:%s\n' 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
      fi
    else
      exit 70
    fi
    ;;
  inspect)
    if [[ "$joined" == *'.Mounts'* ]]; then
      printf '%s\n' 'volume|address-atlas-sync_postgres-data|/var/lib/docker/volumes/address-atlas-sync_postgres-data/_data'
    elif [[ "$joined" == *'org.opencontainers.image.revision'* ]]; then
      printf '%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    elif [[ "$joined" == *'{{.Image}}'* ]]; then
      last="${!#}"
      if [[ "$last" == 'web-test' ]]; then
        printf 'sha256:%s\n' 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
      else
        printf 'sha256:%s\n' 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
      fi
    fi
    ;;
  ps)
    if [[ "$joined" == *'service=web'* ]]; then
      if [[ "$joined" == *'-aq'* && "${MOCK_WEB_EXISTS:-1}" == '1' ]]; then
        printf '%s\n' 'web-test'
      elif [[ "${MOCK_WEB_RUNNING:-1}" == '1' ]]; then
        printf '%s\n' 'web-test'
      fi
    elif [[ "$joined" == *'service=postgres'* ]]; then
      printf '%s\n' 'postgres-test'
    fi
    ;;
  exec)
    if [[ "$joined" == *'ADDRESS_ATLAS_SCHEMA_LOCK_SESSION=1'* ]]; then
      while IFS= read -r line; do
        if [[ "$line" == *'pg_advisory_lock(1094992973)'* ]]; then
          printf '%s\n' 'ADDRESS_ATLAS_SCHEMA_LOCK_ACQUIRED'
          printf '%s\n' 'acquired' >> "$MOCK_LOG_DIR/schema-lock.events"
        elif [[ "$line" == *'ADDRESS_ATLAS_SCHEMA_LOCK_STILL_HELD'* ]]; then
          if [[ "${MOCK_SCHEMA_LOCK_MODE:-normal}" == 'remote-loss' ]]; then
            printf '%s\n' 'ADDRESS_ATLAS_SCHEMA_LOCK_LOST'
            printf '%s\n' 'lost' >> "$MOCK_LOG_DIR/schema-lock.events"
          else
            printf '%s\n' 'ADDRESS_ATLAS_SCHEMA_LOCK_STILL_HELD'
            printf '%s\n' 'proved' >> "$MOCK_LOG_DIR/schema-lock.events"
          fi
        elif [[ "$line" == '\q' ]]; then
          printf '%s\n' 'released' >> "$MOCK_LOG_DIR/schema-lock.events"
          exit 0
        fi
      done
      exit 0
    fi
    input=''
    input_file=''
    if [[ " ${joined} " == *' -i '* ]]; then
      input_file="$MOCK_LOG_DIR/docker.stdin.$$"
      /bin/cat > "$input_file"
      input="$(<"$input_file")"
    fi
    if [[ "$joined" == *'printenv POSTGRES_DB'* ]]; then
      printf '%s\n' 'address_atlas_sync'
    elif [[ "$joined" == *'printenv POSTGRES_USER'* ]]; then
      printf '%s\n' 'address_atlas'
    elif [[ "$joined" == *'pg_dump'* ]]; then
      printf '%s\n' 'PLAINTEXT_PGDUMP_FIXTURE'
    elif [[ "$joined" == *'address_atlas_source_classification_v2'* ]]; then
      case "${MOCK_SOURCE_CLASSIFICATION:-existing-or-ambiguous}" in
        query-error) exit 55 ;;
        unexpected) printf '%s\n' 'unsafe-unknown-result' ;;
        *) printf '%s\n' "$MOCK_SOURCE_CLASSIFICATION" ;;
      esac
    elif [[ "$joined" == *'required_table'* ]]; then
      if [[ "${MOCK_PRE_CUTOVER_CHECK_FAIL:-0}" == '1' \
          && "$joined" == *'atlas_restore_'* ]]; then
        exit 30
      elif [[ "${MOCK_POST_CUTOVER_CHECK_FAIL:-0}" == '1' \
          && -f "$MOCK_LOG_DIR/cutover.done" \
          && ! -f "$MOCK_LOG_DIR/rollback.done" \
          && "$joined" == *'address_atlas_sync'* ]]; then
        exit 31
      fi
    elif [[ "$joined" == *'SELECT version, name, checksum FROM public.sync_schema_migrations'* ]]; then
      case "${MOCK_LEDGER_HEAD:-3}" in
        1)
          printf '%s\n' \
            '1|core-schema-ledger|95334a9cc097e1f3ee3a6dcd21b65720c359235a0737531938837799df71fe46'
          ;;
        2)
          printf '%s\n' \
            '1|core-schema-ledger|95334a9cc097e1f3ee3a6dcd21b65720c359235a0737531938837799df71fe46' \
            '2|vault-accounting-trigger|370460a2d8e85eb9a1471ac300e7d82efcc16bf9b7f6339e2559507ce2c8d518'
          ;;
        3)
          printf '%s\n' \
            '1|core-schema-ledger|95334a9cc097e1f3ee3a6dcd21b65720c359235a0737531938837799df71fe46' \
            '2|vault-accounting-trigger|370460a2d8e85eb9a1471ac300e7d82efcc16bf9b7f6339e2559507ce2c8d518' \
            '3|account-deletion-receipts|1a7393b31cfcfd3135532e911a2e824385cb25b7d9f6611e48ad4cda91db0555'
          ;;
        altered)
          printf '%s\n' \
            '1|core-schema-ledger|dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
          ;;
        skipped)
          printf '%s\n' \
            '1|core-schema-ledger|95334a9cc097e1f3ee3a6dcd21b65720c359235a0737531938837799df71fe46' \
            '3|account-deletion-receipts|1a7393b31cfcfd3135532e911a2e824385cb25b7d9f6611e48ad4cda91db0555'
          ;;
      esac
    elif [[ "$joined" == *'pg_restore'* ]]; then
      [[ -n "$input_file" ]] && cp "$input_file" "$MOCK_LOG_DIR/restore.$$.stdin"
      exit "${MOCK_PG_RESTORE_EXIT:-0}"
    elif [[ "$joined" == *'createdb'* ]]; then
      exit "${MOCK_CREATEDB_EXIT:-0}"
    elif [[ "$joined" == *'dropdb'* ]]; then
      exit "${MOCK_DROPDB_EXIT:-0}"
    elif [[ "$joined" == *'exec psql'* ]]; then
      sql="${input#*$'\n'}"
      printf '%s\n-- statement --\n' "$sql" >> "$MOCK_LOG_DIR/admin.sql"
      if [[ "$sql" == *'pg_control_system()'* ]]; then
        printf '%s\n' '7567890123456789012'
      elif [[ "$sql" == *'address_atlas_bootstrap_pristine_v1'* ]]; then
        if [[ -f "$MOCK_LOG_DIR/bootstrap.provisioned" \
            || -f "$MOCK_LOG_DIR/bootstrap.bridge-post-split" \
            || -f "$MOCK_LOG_DIR/bootstrap.cutover" \
            || "${MOCK_BOOTSTRAP_PRISTINE_RESULT:-ok}" != 'ok' ]]; then
          printf '%s\n' 'invalid'
        else
          printf '%s\n' 'ok'
        fi
        exit 0
      elif [[ "$sql" == *'address_atlas_bootstrap_pristine_database_v1'* ]]; then
        if [[ -f "$MOCK_LOG_DIR/bootstrap.contaminated-staging" \
            && "$joined" == *'atlas_bootstrap_'* ]]; then
          printf '%s\n' 'invalid'
        else
          printf '%s\n' "${MOCK_BOOTSTRAP_SYSTEM_DATABASE_RESULT:-ok}"
        fi
        exit 0
      elif [[ "$sql" == *'address_atlas_bootstrap_pre_split_recovery_v1'* ]]; then
        if [[ ! -f "$MOCK_LOG_DIR/bootstrap.provisioned" \
            && ! -f "$MOCK_LOG_DIR/bootstrap.cutover" ]]; then
          printf '%s\n' "${MOCK_BOOTSTRAP_PRE_SPLIT_RESULT:-ok}"
        else
          printf '%s\n' 'invalid'
        fi
        exit 0
      elif [[ "$sql" == *'address_atlas_bootstrap_pre_cutover_v1'* ]]; then
        if [[ -f "$MOCK_LOG_DIR/bootstrap.provisioned" \
            && ! -f "$MOCK_LOG_DIR/bootstrap.cutover" ]]; then
          printf '%s\n' 'ok'
        else
          printf '%s\n' 'invalid'
        fi
        exit 0
      elif [[ "$sql" == *'address_atlas_bootstrap_post_split_bridge_v1'* ]]; then
        if [[ -f "$MOCK_LOG_DIR/bootstrap.bridge-post-split" \
            && ! -f "$MOCK_LOG_DIR/bootstrap.cutover" ]]; then
          printf '%s\n' 'ok'
        else
          printf '%s\n' 'invalid'
        fi
        exit 0
      elif [[ "$sql" == *'address_atlas_bootstrap_post_cutover_v1'* ]]; then
        if [[ -f "$MOCK_LOG_DIR/bootstrap.cutover" ]]; then
          printf '%s\n' 'ok'
        else
          printf '%s\n' 'invalid'
        fi
        exit 0
      elif [[ "$sql" == *'ALTER ROLE "address_atlas_runtime" NOLOGIN'* \
          && -f "$MOCK_LOG_DIR/provision.attempted" \
          && "${MOCK_RUNTIME_RELOCK_EXIT:-0}" != '0' ]]; then
        exit "$MOCK_RUNTIME_RELOCK_EXIT"
      elif [[ "$sql" == *'ALTER ROLE "address_atlas_runtime" NOLOGIN'* ]]; then
        : > "$MOCK_LOG_DIR/runtime.nologin"
      fi
      if [[ "$sql" == *'address_atlas_restore_cutover_state_v1'* ]]; then
        if [[ -n "${MOCK_CUTOVER_STATE:-}" ]]; then
          printf '%s\n' "$MOCK_CUTOVER_STATE"
        elif [[ -f "$MOCK_LOG_DIR/cutover.done" \
            && ! -f "$MOCK_LOG_DIR/rollback.done" ]]; then
          printf '%s\n' 'cut-over'
        else
          printf '%s\n' 'not-cut-over'
        fi
      elif [[ "$sql" == *'SELECT CASE WHEN'* ]]; then
        if [[ "$sql" == *"CURRENT_USER = 'address_atlas_runtime'"* \
            && -f "$MOCK_LOG_DIR/runtime.nologin" ]]; then
          exit 28
        elif [[ "$sql" == *'pg_auth_members'* \
            && "$sql" == *"r.rolname = 'address_atlas_runtime' AND r.rolcanlogin"* \
            && -f "$MOCK_LOG_DIR/runtime.nologin" ]]; then
          printf '%s\n' 'invalid'
        elif [[ "$sql" == *'pg_auth_members'* ]]; then
          printf '%s\n' "${MOCK_CONTROL_CONTEXT_RESULT:-ok}"
        else
          printf '%s\n' 'ok'
        fi
      elif [[ "$sql" == *'ALTER DATABASE'* ]]; then
        if [[ "$sql" == *'atlas_bootstrap_'* ]]; then
          : > "$MOCK_LOG_DIR/bootstrap.cutover"
          [[ ! -f "$MOCK_LOG_DIR/bootstrap.fail-after-cutover" ]] || exit 74
        elif [[ "$sql" == *'atlas_failed_'* ]]; then
          [[ "${MOCK_ROLLBACK_EXIT:-0}" == '0' ]] || exit "$MOCK_ROLLBACK_EXIT"
          : > "$MOCK_LOG_DIR/rollback.done"
        elif [[ "$sql" == *'atlas_restore_'* && "$sql" == *'atlas_quarantine_'* ]]; then
          [[ "${MOCK_CUTOVER_EXIT:-0}" == '0' ]] || exit "$MOCK_CUTOVER_EXIT"
          : > "$MOCK_LOG_DIR/cutover.done"
          [[ "${MOCK_CUTOVER_COMMIT_THEN_EXIT:-0}" == '0' ]] \
            || exit "$MOCK_CUTOVER_COMMIT_THEN_EXIT"
        fi
      fi
    fi
    ;;
  *)
    exit 70
    ;;
esac
EOF

  cat > "$CASE_DIR/bin/age" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_LOG_DIR:?}"
mode=''
output=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --encrypt)
      mode='encrypt'
      shift
      ;;
    --decrypt)
      mode='decrypt'
      shift
      ;;
    --output)
      output="$2"
      shift 2
      ;;
    --recipient|--identity)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
case "$mode" in
  encrypt)
    printf '%s\n' 'encrypt' >> "$MOCK_LOG_DIR/age.events"
    /bin/cat >/dev/null
    [[ -n "$output" ]]
    printf '%s\n' 'AGE_ENCRYPTED_FIXTURE' > "$output"
    ;;
  decrypt)
    printf '%s\n' 'decrypt' >> "$MOCK_LOG_DIR/age.events"
    [[ "${MOCK_AGE_DECRYPT_EXIT:-0}" == '0' ]] || exit "$MOCK_AGE_DECRYPT_EXIT"
    printf '%s\n' 'PGDUMP_CUSTOM_FIXTURE'
    ;;
  *)
    exit 64
    ;;
esac
EOF
  chmod 0700 "$CASE_DIR/bin/docker" "$CASE_DIR/bin/age"

  BACKUP_DIR="$CASE_DIR/backups"
  IDENTITY_FILE="$CASE_DIR/identity.txt"
  printf '%s\n' 'AGE-SECRET-KEY-TEST-ONLY' > "$IDENTITY_FILE"
  chmod 0600 "$IDENTITY_FILE"
  SIGNING_PRIVATE_KEY="$TEST_SIGNING_PRIVATE_KEY"
  SIGNATURE_PUBLIC_KEY="$TEST_SIGNATURE_PUBLIC_KEY"
  MOCK_NOW_EPOCH="$(/bin/date +%s)"
  ALLOW_RESTORE=''
  ALLOW_BOOTSTRAP_RESTORE=''
  ALLOW_BOOTSTRAP_LOCK_RECLAIM=''
  EXPECTED_BACKUP_SHA=''
  BOOTSTRAP_FINALIZE_ACK=''
  MOCK_WEB_RUNNING=1
  MOCK_WEB_EXISTS=1
  MOCK_POST_CUTOVER_CHECK_FAIL=0
  MOCK_PRE_CUTOVER_CHECK_FAIL=0
  MOCK_CUTOVER_EXIT=0
  MOCK_CUTOVER_COMMIT_THEN_EXIT=0
  MOCK_CUTOVER_STATE=''
  MOCK_CONTROL_CONTEXT_RESULT=ok
  MOCK_RUNTIME_RELOCK_EXIT=0
  MOCK_ROLLBACK_EXIT=0
  MOCK_DROPDB_EXIT=0
  MOCK_SOURCE_CLASSIFICATION='existing-or-ambiguous'
  MOCK_LEDGER_HEAD=3
  MOCK_AGE_DECRYPT_EXIT=0
  MOCK_SCHEMA_LOCK_MODE=normal
  MOCK_BOOTSTRAP_PRISTINE_RESULT=ok
  MOCK_BOOTSTRAP_SYSTEM_DATABASE_RESULT=ok
  MOCK_BOOTSTRAP_PRE_SPLIT_RESULT=ok
  MOCK_RESTORE_IMAGE_REVISION='eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
  NATIVE_CONFIG_VERSION=5
  NATIVE_CONFIG_DIGEST='ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
  NATIVE_CONFIG_UPDATED_AT_EPOCH_MS=1784505600000
  NATIVE_CONFIG_SERVING_REVISION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  ADMIN_PASSWORD='ADMIN_PASSWORD_SECRET_72cd_ADMIN_PASSWORD_SECRET'
  OFFSITE_HOOK=''
  OFFSITE_REQUIRED=false
  RESTORE_MIGRATION_HOOK="$CASE_DIR/restore-validate"
  RESTORE_PROVISION_HOOK="$CASE_DIR/restore-provision"
  RESTORE_BUILD_REVISION='eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
  RESTORE_IMAGE="address-atlas-sync:${RESTORE_BUILD_REVISION}"
  RESTORE_PROVISION_IMAGE='postgres:16.14-alpine3.24@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777'
  BACKUP_OWNER_PASSWORD='OwnerBootstrapSecret_7Gm2Qv9Lx4Np8Yk6'
  RUNTIME_PASSWORD='RuntimeServiceSecret_3Ld8Qw5Nz7Rx2Km9'
  MOCK_SNAPSHOT_STARTED_AT='2026-07-20T16:00:00Z'
  MOCK_COMPLETED_AT='2026-07-20T16:00:00Z'
  cat > "$RESTORE_MIGRATION_HOOK" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 4 ]]
[[ "$3" =~ ^[1-3]$ && "$4" == '3' ]]
[[ "$ADDRESS_ATLAS_RESTORE_IMAGE" == *":${ADDRESS_ATLAS_RESTORE_BUILD_REVISION}" ]]
[[ -n "$POSTGRES_PASSWORD" ]]
[[ -z "${POSTGRES_ADMIN_PASSWORD:-}" ]]
hook_dir="$(cd "$(dirname "$0")" && pwd)"
[[ ! -f "$hook_dir/log/bootstrap.fail-migration" ]] || exit 74
printf '%s\n' "$@" >> "$hook_dir/log/restore-validation.args"
EOF
  chmod 0700 "$RESTORE_MIGRATION_HOOK"
  cat > "$RESTORE_PROVISION_HOOK" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 2 ]]
[[ "$1" == 'postgres-test' ]]
[[ "$2" == 'address_atlas_sync' || "$2" == atlas_drill_* \
    || "$2" == atlas_bootstrap_* ]]
[[ "$POSTGRES_ADMIN_PASSWORD" == 'ADMIN_PASSWORD_SECRET_72cd_ADMIN_PASSWORD_SECRET' ]]
[[ "$POSTGRES_RUNTIME_PASSWORD" == 'RuntimeServiceSecret_3Ld8Qw5Nz7Rx2Km9' ]]
[[ "$ADDRESS_ATLAS_RESTORE_PROVISION_IMAGE" == postgres:16.14-alpine3.24@sha256:* ]]
[[ "$ADDRESS_ATLAS_RESTORE_PROVISION_MODE" == 'bootstrap' \
    || "$ADDRESS_ATLAS_RESTORE_PROVISION_MODE" == 'drill' \
    || "$ADDRESS_ATLAS_RESTORE_PROVISION_MODE" == 'restore' ]]
[[ "$ADDRESS_ATLAS_RESTORE_STAGING_ROOT" == */backups ]]
hook_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ "$ADDRESS_ATLAS_RESTORE_PROVISION_MODE" == 'bootstrap' ]]; then
  [[ "$POSTGRES_PASSWORD" == 'OwnerBootstrapSecret_7Gm2Qv9Lx4Np8Yk6' ]]
  [[ ! -f "$hook_dir/log/bootstrap.fail-before-provision" ]] || exit 74
  : > "$hook_dir/log/bootstrap.provisioned"
  [[ ! -f "$hook_dir/log/bootstrap.fail-after-provision" ]] || exit 74
else
  [[ -z "${POSTGRES_PASSWORD:-}" ]]
  if [[ "$ADDRESS_ATLAS_RESTORE_PROVISION_MODE" == 'restore' \
      && "$2" == atlas_bootstrap_* ]]; then
    : > "$hook_dir/log/bootstrap.provisioned"
  fi
fi
find "$hook_dir/log/runtime.nologin" -maxdepth 0 -type f -delete 2>/dev/null || true
find "$hook_dir/log/bootstrap.bridge-post-split" -maxdepth 0 -type f -delete 2>/dev/null || true
printf '%s\n' "$@" >> "$hook_dir/log/restore-provision.args"
printf '%s:%s\n' "$2" "$ADDRESS_ATLAS_RESTORE_PROVISION_MODE" \
  >> "$hook_dir/log/restore-provision.modes"
EOF
  chmod 0700 "$RESTORE_PROVISION_HOOK"
  cat > "$CASE_DIR/provision-runtime-role.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod 0700 "$CASE_DIR/provision-runtime-role.sh"
  cat > "$CASE_DIR/bootstrap-database-roles.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod 0700 "$CASE_DIR/bootstrap-database-roles.sh"
}

sha256_for_test() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

ledger_digest_for_test() {
  local head="${1:-3}"
  {
    printf '%s\n' \
      '1|core-schema-ledger|95334a9cc097e1f3ee3a6dcd21b65720c359235a0737531938837799df71fe46'
    if [[ "$head" -ge 2 ]]; then
      printf '%s\n' \
        '2|vault-accounting-trigger|370460a2d8e85eb9a1471ac300e7d82efcc16bf9b7f6339e2559507ce2c8d518'
    fi
    if [[ "$head" -ge 3 ]]; then
      printf '%s\n' \
        '3|account-deletion-receipts|1a7393b31cfcfd3135532e911a2e824385cb25b7d9f6611e48ad4cda91db0555'
    fi
  } \
    | if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
      else
        shasum -a 256 | awk '{print $1}'
      fi
}

mtime_for_test() {
  if stat -c %Y "$1" >/dev/null 2>&1; then
    stat -c %Y "$1"
  else
    stat -f %m "$1"
  fi
}

iso8601_epoch_for_test() {
  if /bin/date -u -d "$1" +%s >/dev/null 2>&1; then
    /bin/date -u -d "$1" +%s
  else
    /bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s
  fi
}

sign_fixture_manifest() {
  local backup="$1"
  "$REAL_OPENSSL_BIN" dgst -sha256 -sign "$SIGNING_PRIVATE_KEY" \
    -out "${backup}.manifest.sig" "${backup}.manifest.json" >/dev/null 2>&1
}

make_backup_fixture() {
  local path="$1"
  local head="${2:-3}"
  local schema="${3:-4}"
  local digest size ledger_digest created_at compact base_name
  local completed_epoch native_updated_at_epoch_ms=1784505600000
  mkdir -p "$(dirname "$path")"
  printf '%s\n' 'AGE_ENCRYPTED_SOURCE_FIXTURE' > "$path"
  digest="$(sha256_for_test "$path")"
  size="$(wc -c < "$path" | tr -d '[:space:]')"
  ledger_digest="$(ledger_digest_for_test "$head")"
  created_at='2026-07-20T16:00:00Z'
  base_name="$(basename "$path")"
  if [[ "$base_name" =~ ^address-atlas-([0-9]{8}T[0-9]{6}Z)\.dump\.age$ ]]; then
    compact="${BASH_REMATCH[1]}"
    created_at="${compact:0:4}-${compact:4:2}-${compact:6:2}T${compact:9:2}:${compact:11:2}:${compact:13:2}Z"
  fi
  printf '%s  %s\n' "$digest" "$(basename "$path")" > "${path}.sha256"
  if [[ "$schema" == 3 ]]; then
    printf '{\n  "schemaVersion": 3,\n  "snapshotStartedAt": "%s",\n  "completedAt": "%s",\n  "database": "address_atlas_sync",\n  "encryptedBytes": %s,\n  "sha256": "%s",\n  "sourceWebRevision": "%s",\n  "sourceWebImageId": "sha256:%s",\n  "sourcePostgresImageId": "sha256:%s",\n  "migrationHeadVersion": %s,\n  "migrationLedgerSha256": "%s"\n}\n' \
      "$created_at" "$created_at" "$size" "$digest" \
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
      'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
      "$head" "$ledger_digest" > "${path}.manifest.json"
  else
    [[ "$schema" == 4 ]] || return 64
    completed_epoch="$(iso8601_epoch_for_test "$created_at")"
    if (( native_updated_at_epoch_ms > completed_epoch * 1000 + 300000 )); then
      native_updated_at_epoch_ms=$((completed_epoch * 1000))
    fi
    printf '{\n  "schemaVersion": 4,\n  "snapshotStartedAt": "%s",\n  "completedAt": "%s",\n  "database": "address_atlas_sync",\n  "encryptedBytes": %s,\n  "sha256": "%s",\n  "sourceWebRevision": "%s",\n  "sourceWebImageId": "sha256:%s",\n  "sourcePostgresImageId": "sha256:%s",\n  "nativeConfigVersion": 5,\n  "nativeConfigSha256": "%s",\n  "nativeConfigUpdatedAtEpochMs": %s,\n  "nativeConfigServingRevision": "%s",\n  "migrationHeadVersion": %s,\n  "migrationLedgerSha256": "%s"\n}\n' \
      "$created_at" "$created_at" "$size" "$digest" \
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
      'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
      'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' \
      "$native_updated_at_epoch_ms" \
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
      "$head" "$ledger_digest" > "${path}.manifest.json"
  fi
  sign_fixture_manifest "$path"
}

rewrite_and_resign_manifest() {
  local backup="$1"
  local expression="$2"
  sed "$expression" "${backup}.manifest.json" > "${backup}.manifest.tmp"
  mv "${backup}.manifest.tmp" "${backup}.manifest.json"
  sign_fixture_manifest "$backup"
}

run_backup_capture() {
  set +e
  env -i \
    PATH="$CASE_DIR/bin:/usr/bin:/bin" \
    HOME="$CASE_DIR/home" \
    DOCKER_BIN="$CASE_DIR/bin/docker" \
    BACKUP_SCRIPT_PATH="$BACKUP_SCRIPT" \
    BACKUP_BASH_BIN="$OPS_TEST_BASH_BIN" \
    AGE_BIN="$CASE_DIR/bin/age" \
    OPENSSL_BIN="$REAL_OPENSSL_BIN" \
    NODE_BIN="$REAL_NODE_BIN" \
    MOCK_LOG_DIR="$CASE_DIR/log" \
    MOCK_NOW_EPOCH="$MOCK_NOW_EPOCH" \
    MOCK_WEB_RUNNING="$MOCK_WEB_RUNNING" \
    MOCK_WEB_EXISTS="$MOCK_WEB_EXISTS" \
    MOCK_POST_CUTOVER_CHECK_FAIL="$MOCK_POST_CUTOVER_CHECK_FAIL" \
    MOCK_PRE_CUTOVER_CHECK_FAIL="$MOCK_PRE_CUTOVER_CHECK_FAIL" \
    MOCK_CUTOVER_EXIT="$MOCK_CUTOVER_EXIT" \
    MOCK_CUTOVER_COMMIT_THEN_EXIT="$MOCK_CUTOVER_COMMIT_THEN_EXIT" \
    MOCK_CUTOVER_STATE="$MOCK_CUTOVER_STATE" \
    MOCK_CONTROL_CONTEXT_RESULT="$MOCK_CONTROL_CONTEXT_RESULT" \
    MOCK_RUNTIME_RELOCK_EXIT="$MOCK_RUNTIME_RELOCK_EXIT" \
    MOCK_ROLLBACK_EXIT="$MOCK_ROLLBACK_EXIT" \
    MOCK_DROPDB_EXIT="$MOCK_DROPDB_EXIT" \
    MOCK_SOURCE_CLASSIFICATION="$MOCK_SOURCE_CLASSIFICATION" \
    MOCK_LEDGER_HEAD="$MOCK_LEDGER_HEAD" \
    MOCK_AGE_DECRYPT_EXIT="$MOCK_AGE_DECRYPT_EXIT" \
    MOCK_SCHEMA_LOCK_MODE="$MOCK_SCHEMA_LOCK_MODE" \
    MOCK_BOOTSTRAP_PRISTINE_RESULT="$MOCK_BOOTSTRAP_PRISTINE_RESULT" \
    MOCK_BOOTSTRAP_SYSTEM_DATABASE_RESULT="$MOCK_BOOTSTRAP_SYSTEM_DATABASE_RESULT" \
    MOCK_BOOTSTRAP_PRE_SPLIT_RESULT="$MOCK_BOOTSTRAP_PRE_SPLIT_RESULT" \
    MOCK_RESTORE_IMAGE_REVISION="$MOCK_RESTORE_IMAGE_REVISION" \
    MOCK_SNAPSHOT_STARTED_AT="$MOCK_SNAPSHOT_STARTED_AT" \
    MOCK_COMPLETED_AT="$MOCK_COMPLETED_AT" \
    ADDRESS_ATLAS_BACKUP_DIR="$BACKUP_DIR" \
    ADDRESS_ATLAS_BACKUP_RETENTION_DAYS=30 \
    ADDRESS_ATLAS_BACKUP_MAX_AGE_HOURS=26 \
    ADDRESS_ATLAS_BACKUP_MAX_BYTES=1048576 \
    ADDRESS_ATLAS_BACKUP_AGE_RECIPIENT='age1testrecipientpublicvalue' \
    ADDRESS_ATLAS_BACKUP_AGE_IDENTITY_FILE="$IDENTITY_FILE" \
    ADDRESS_ATLAS_BACKUP_SIGNING_PRIVATE_KEY_FILE="$SIGNING_PRIVATE_KEY" \
    ADDRESS_ATLAS_BACKUP_SIGNATURE_PUBLIC_KEY_FILE="$SIGNATURE_PUBLIC_KEY" \
    ADDRESS_ATLAS_BACKUP_OFFSITE_HOOK="$OFFSITE_HOOK" \
    ADDRESS_ATLAS_BACKUP_OFFSITE_REQUIRED="$OFFSITE_REQUIRED" \
    ADDRESS_ATLAS_BACKUP_RESTORE_MIGRATION_HOOK="$RESTORE_MIGRATION_HOOK" \
    ADDRESS_ATLAS_BACKUP_RESTORE_PROVISION_HOOK="$RESTORE_PROVISION_HOOK" \
    ADDRESS_ATLAS_RESTORE_BUILD_REVISION="$RESTORE_BUILD_REVISION" \
    ADDRESS_ATLAS_RESTORE_IMAGE="$RESTORE_IMAGE" \
    ADDRESS_ATLAS_RESTORE_PROVISION_IMAGE="$RESTORE_PROVISION_IMAGE" \
    ADDRESS_ATLAS_POSTGRES_CONTAINER='postgres-test' \
    ADDRESS_ATLAS_POSTGRES_DB='address_atlas_sync' \
    ADDRESS_ATLAS_POSTGRES_USER='address_atlas' \
    ADDRESS_ATLAS_BUILD_REVISION='1111111111111111111111111111111111111111' \
    ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_VERSION="$NATIVE_CONFIG_VERSION" \
    ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_SHA256="$NATIVE_CONFIG_DIGEST" \
    ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_UPDATED_AT_EPOCH_MS="$NATIVE_CONFIG_UPDATED_AT_EPOCH_MS" \
    ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_SERVING_REVISION="$NATIVE_CONFIG_SERVING_REVISION" \
    ADDRESS_ATLAS_ALLOW_PRODUCTION_RESTORE="$ALLOW_RESTORE" \
    ADDRESS_ATLAS_ALLOW_BOOTSTRAP_RESTORE="$ALLOW_BOOTSTRAP_RESTORE" \
    ADDRESS_ATLAS_EXPECTED_BACKUP_SHA256="$EXPECTED_BACKUP_SHA" \
    ADDRESS_ATLAS_BOOTSTRAP_FINALIZE_ACK="$BOOTSTRAP_FINALIZE_ACK" \
    ADDRESS_ATLAS_ALLOW_BOOTSTRAP_LOCK_RECLAIM="${ALLOW_BOOTSTRAP_LOCK_RECLAIM:-}" \
    POSTGRES_PASSWORD="$BACKUP_OWNER_PASSWORD" \
    POSTGRES_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
    POSTGRES_RUNTIME_PASSWORD="$RUNTIME_PASSWORD" \
    "$OPS_TEST_BASH_BIN" "$BACKUP_SCRIPT" "$@" \
      > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr"
  CAPTURE_STATUS=$?
  set -e
}

test_backup_classify_source() {
  new_case
  install_backup_fakes
  MOCK_SOURCE_CLASSIFICATION='brand-new-empty'
  run_backup_capture classify-source
  assert_status "$CAPTURE_STATUS" 0 'brand-new source classification status'
  assert_file_equals "$CASE_DIR/stdout" 'brand-new-empty' 'brand-new source classification'
  assert_file_equals "$CASE_DIR/stderr" '' 'brand-new source classification stderr'
  assert_path_absent "$CASE_DIR/log/age.events" 'source classification invoked age'
  assert_file_not_contains "$CASE_DIR/log/docker.argv" 'service=web' 'source classification required web provenance'
  assert_file_contains "$CASE_DIR/log/docker.argv" 'search_path=pg_catalog' \
    'source classification did not pin the trusted catalog search path'
  assert_file_contains "$CASE_DIR/log/docker.argv" 'pg_catalog.pg_subscription' \
    'source classification omitted subscription state'
  assert_file_contains "$CASE_DIR/log/docker.argv" 'pg_catalog.pg_ts_config' \
    'source classification omitted text-search state'
  assert_file_contains "$CASE_DIR/log/docker.argv" 'pg_catalog.pg_shseclabel' \
    'source classification omitted database security labels'
  assert_file_contains "$CASE_DIR/log/docker.argv" 'pg_catalog.aclexplode' \
    'source classification omitted the exact PostgreSQL 16 public-schema ACL contract'

  new_case
  install_backup_fakes
  MOCK_SOURCE_CLASSIFICATION='existing-or-ambiguous'
  run_backup_capture classify-source
  assert_status "$CAPTURE_STATUS" 0 'existing source classification status'
  assert_file_equals "$CASE_DIR/stdout" 'existing-or-ambiguous' 'existing source classification'
  assert_file_equals "$CASE_DIR/stderr" '' 'existing source classification stderr'

  new_case
  install_backup_fakes
  MOCK_SOURCE_CLASSIFICATION='query-error'
  run_backup_capture classify-source
  [[ "$CAPTURE_STATUS" -ne 0 ]] || fail 'classification query error was treated as empty'
  assert_file_equals "$CASE_DIR/stdout" '' 'classification query error stdout'
  assert_file_contains "$CASE_DIR/stderr" 'Unable to classify the source database safely.' 'classification query error'

  new_case
  install_backup_fakes
  MOCK_SOURCE_CLASSIFICATION='unexpected'
  run_backup_capture classify-source
  assert_status "$CAPTURE_STATUS" 65 'unexpected source classification status'
  assert_file_equals "$CASE_DIR/stdout" '' 'unexpected classification stdout'
  assert_file_contains "$CASE_DIR/stderr" 'unexpected result' 'unexpected classification error'
}

test_backup_schema_lock_constant_contract() {
  local shell_value typescript_value schema_source provision_image
  schema_source="${SCRIPT_DIR}/../../src/lib/sync/postgres-schema.ts"
  shell_value="$(sed -n 's/^SCHEMA_MIGRATION_ADVISORY_LOCK=//p' "$BACKUP_SCRIPT")"
  typescript_value="$(sed -nE \
    's/^const SCHEMA_MIGRATION_ADVISORY_LOCK = ([0-9_]+);$/\1/p' \
    "$schema_source" | tr -d '_')"
  [[ "$shell_value" =~ ^[0-9]+$ ]] \
    || fail 'backup schema advisory-lock constant is malformed'
  [[ "$typescript_value" =~ ^[0-9]+$ ]] \
    || fail 'TypeScript schema advisory-lock constant is malformed'
  [[ "$shell_value" == "$typescript_value" ]] \
    || fail 'backup and migration code use different schema advisory locks'
  provision_image="$(sed -n \
    "s/^EXPECTED_RESTORE_PROVISION_IMAGE='\([^']*\)'$/\1/p" "$BACKUP_SCRIPT")"
  [[ -n "$provision_image" ]] || fail 'backup provision image contract is missing'
  assert_file_contains "${SCRIPT_DIR}/compose.prod.yml" "$provision_image" \
    'backup provision image differs from the production PostgreSQL image'
  assert_file_contains "${SCRIPT_DIR}/provision-restored-database.sh" "$provision_image" \
    'backup provision image differs from the restore hook allowlist'
  assert_file_not_contains "$BACKUP_SCRIPT" 'pg_catalog.current_user' \
    'runtime validation schema-qualified the CURRENT_USER special form'
  assert_file_not_contains "$BACKUP_SCRIPT" "'"'"'pg_catalog.pg_database'"'"'" \
    'database description lookup uses an invalid schema-qualified catalog argument'
  assert_file_not_contains "$BACKUP_SCRIPT" "'"'"'pg_catalog.pg_namespace'"'"'" \
    'namespace description lookup uses an invalid schema-qualified catalog argument'
}

test_backup_rejects_symlink_destination() {
  local target backup
  new_case
  install_backup_fakes
  target="$CASE_DIR/real-backups"
  mkdir -p "$target"
  ln -s "$target" "$CASE_DIR/backup-link"
  BACKUP_DIR="$CASE_DIR/backup-link"
  backup="$target/address-atlas-20260720T160000Z.dump.age"
  run_backup_capture create
  assert_status "$CAPTURE_STATUS" 65 'symlink backup directory status'
  assert_file_contains "$CASE_DIR/stderr" 'symlink component' 'symlink backup directory rejection'
  assert_path_absent "$backup" 'symlink destination received a backup'

  new_case
  install_backup_fakes
  target="$CASE_DIR/real-parent"
  mkdir -p "$target"
  ln -s "$target" "$CASE_DIR/parent-link"
  BACKUP_DIR="$CASE_DIR/parent-link/backups"
  run_backup_capture create
  assert_status "$CAPTURE_STATUS" 65 'symlink backup parent status'
  assert_file_contains "$CASE_DIR/stderr" 'symlink component' 'symlink backup parent rejection'
  assert_path_absent "$target/backups" 'symlink parent received a backup directory'

  new_case
  install_backup_fakes
  target="$CASE_DIR/writable-parent"
  mkdir -p "$target"
  chmod 0777 "$target"
  BACKUP_DIR="$target/backups"
  backup="$BACKUP_DIR/address-atlas-20260720T160000Z.dump.age"
  run_backup_capture create
  assert_status "$CAPTURE_STATUS" 65 'writable backup parent status'
  assert_file_contains "$CASE_DIR/stderr" 'must not be writable by group or other users' \
    'writable backup parent rejection'
  assert_path_absent "$backup" 'writable parent received a backup payload'
}

test_backup_create() {
  local backup digest
  new_case
  install_backup_fakes
  backup="$BACKUP_DIR/address-atlas-20260720T160000Z.dump.age"
  run_backup_capture create
  assert_status "$CAPTURE_STATUS" 0 'backup create exit status'
  assert_file_equals "$CASE_DIR/stdout" "$backup" 'backup create output path'
  assert_file_equals "$CASE_DIR/stderr" '' 'backup create stderr'
  assert_path_exists "$backup" 'encrypted backup was not created'
  assert_path_exists "${backup}.sha256" 'checksum sidecar was not created'
  assert_path_exists "${backup}.manifest.json" 'manifest sidecar was not created'
  assert_path_exists "${backup}.manifest.sig" 'signature sidecar was not created'
  assert_file_not_contains "$backup" 'PLAINTEXT_PGDUMP_FIXTURE' 'plaintext dump reached backup file'
  digest="$(sha256_for_test "$backup")"
  assert_file_contains "${backup}.sha256" "$digest" 'checksum sidecar digest'
  assert_file_contains "${backup}.manifest.json" '"database": "address_atlas_sync"' 'manifest database'
  assert_file_contains "${backup}.manifest.json" '"sourceWebRevision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' 'manifest live revision'
  assert_file_contains "${backup}.manifest.json" '"sourceWebImageId": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' 'manifest web image'
  assert_file_contains "${backup}.manifest.json" '"sourcePostgresImageId": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"' 'manifest PostgreSQL image'
  assert_file_contains "${backup}.manifest.json" '"schemaVersion": 4' \
    'manifest schema version'
  assert_file_contains "${backup}.manifest.json" '"nativeConfigVersion": 5' \
    'manifest native-config version'
  assert_file_contains "${backup}.manifest.json" '"nativeConfigSha256": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
    'manifest native-config digest'
  assert_file_contains "${backup}.manifest.json" '"nativeConfigUpdatedAtEpochMs": 1784505600000' \
    'manifest native-config timestamp'
  assert_file_contains "${backup}.manifest.json" '"nativeConfigServingRevision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
    'manifest native-config serving revision'
  assert_file_contains "${backup}.manifest.json" "\"migrationLedgerSha256\": \"$(ledger_digest_for_test)\"" 'manifest ledger digest'
  assert_file_not_contains "${backup}.manifest.json" '1111111111111111111111111111111111111111' 'target checkout revision mislabeled source data'
  "$REAL_OPENSSL_BIN" dgst -sha256 -verify "$SIGNATURE_PUBLIC_KEY" \
    -signature "${backup}.manifest.sig" "${backup}.manifest.json" >/dev/null 2>&1 \
    || fail 'created manifest signature does not verify'
  assert_file_contains "$CASE_DIR/log/docker.argv" 'pg_dump' 'create did not invoke pg_dump'
  assert_file_contains "$CASE_DIR/log/docker.argv" 'org.opencontainers.image.revision' 'create did not resolve deployed revision'
  assert_file_equals "$CASE_DIR/log/schema-lock.events" $'acquired\nproved\nreleased' \
    'create did not hold and re-prove the schema advisory lock across pg_dump'
  assert_file_equals "$CASE_DIR/log/age.events" $'encrypt\ndecrypt' 'create encrypt/self-verify sequence'
  assert_path_absent "$BACKUP_DIR/.backup-operation.lock" 'backup operation lock was not removed'
}

test_backup_rejects_future_native_config_receipt() {
  local backup
  new_case
  install_backup_fakes
  backup="$BACKUP_DIR/address-atlas-20260720T160000Z.dump.age"
  NATIVE_CONFIG_UPDATED_AT_EPOCH_MS=$((MOCK_NOW_EPOCH * 1000 + 300001))
  run_backup_capture create
  assert_status "$CAPTURE_STATUS" 65 'future native-config receipt status'
  assert_file_contains "$CASE_DIR/stderr" 'implausibly in the future' \
    'future native-config receipt rejection message'
  assert_file_not_contains "$CASE_DIR/log/docker.argv" 'pg_dump' \
    'future native-config receipt reached pg_dump'
  assert_path_absent "$backup" \
    'future native-config receipt published a backup'
}

test_backup_rejects_lost_remote_schema_lock() {
  local backup
  new_case
  install_backup_fakes
  MOCK_SCHEMA_LOCK_MODE=remote-loss
  backup="$BACKUP_DIR/address-atlas-20260720T160000Z.dump.age"
  run_backup_capture create
  assert_status "$CAPTURE_STATUS" 74 'lost remote schema lock status'
  assert_file_contains "$CASE_DIR/stderr" 'no longer held the schema advisory lock' \
    'lost remote schema lock failure was not explicit'
  assert_file_contains "$CASE_DIR/log/docker.argv" 'pg_dump' \
    'remote-lock loss test did not cross the dump boundary'
  assert_file_equals "$CASE_DIR/log/schema-lock.events" $'acquired\nlost\nreleased' \
    'remote schema-lock loss was not detected through the live session'
  assert_path_absent "$backup" 'backup was published after its remote schema lock was lost'
}

test_backup_create_predeploy() {
  local backup
  new_case
  install_backup_fakes
  MOCK_WEB_RUNNING=1
  run_backup_capture create-predeploy
  assert_status "$CAPTURE_STATUS" 77 'running-web predeploy backup gate status'
  assert_file_not_contains "$CASE_DIR/log/docker.argv" 'pg_dump' \
    'predeploy backup dumped while web was running'

  new_case
  install_backup_fakes
  MOCK_WEB_RUNNING=0
  MOCK_WEB_EXISTS=1
  backup="$BACKUP_DIR/address-atlas-20260720T160000Z.dump.age"
  run_backup_capture create-predeploy
  assert_status "$CAPTURE_STATUS" 0 'stopped-web predeploy backup status'
  assert_file_equals "$CASE_DIR/stdout" "$backup" 'predeploy backup output path'
  assert_file_contains "$CASE_DIR/log/docker.argv" 'ps -aq' \
    'predeploy backup did not resolve the stopped web provenance container'
}

test_backup_lock_run_reentrant_contract() {
  local backup
  new_case
  install_backup_fakes
  cat > "$CASE_DIR/reentrant-predeploy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$BACKUP_BASH_BIN" "$BACKUP_SCRIPT_PATH" assert-lock >/dev/null
exec "$BACKUP_BASH_BIN" "$BACKUP_SCRIPT_PATH" create-predeploy
EOF
  chmod 0700 "$CASE_DIR/reentrant-predeploy"
  MOCK_WEB_RUNNING=0
  backup="$BACKUP_DIR/address-atlas-20260720T160000Z.dump.age"
  run_backup_capture lock-run -- "$CASE_DIR/reentrant-predeploy"
  assert_status "$CAPTURE_STATUS" 0 'lock-run reentrant backup status'
  assert_file_equals "$CASE_DIR/stdout" "$backup" 'lock-run child backup output'
  assert_path_absent "$BACKUP_DIR/.backup-operation.lock" 'lock-run did not release its operation lock'

  new_case
  install_backup_fakes
  mkdir -p "$BACKUP_DIR"
  printf 'pid=999999999\nboot=stale\nstart=stale\n' > "$BACKUP_DIR/.backup-operation.lock"
  run_backup_capture create
  assert_status "$CAPTURE_STATUS" 75 'stale operation lock status'
  assert_file_contains "$CASE_DIR/stderr" 'remove it explicitly' 'stale lock was not fail-closed'
  assert_file_not_contains "$CASE_DIR/log/docker.argv" 'pg_dump' 'stale lock reached pg_dump'
}

test_backup_lock_run_fast_children() {
  new_case
  install_backup_fakes
  run_backup_capture lock-run -- /usr/bin/true
  assert_status "$CAPTURE_STATUS" 0 'fast successful lock-run child status'
  assert_path_absent "$BACKUP_DIR/.backup-operation.lock" \
    'fast successful child left the operation lock behind'
  assert_file_equals "$CASE_DIR/stderr" '' 'fast successful lock-run stderr'

  new_case
  install_backup_fakes
  run_backup_capture lock-run -- /usr/bin/false
  assert_status "$CAPTURE_STATUS" 1 'fast failing lock-run child status'
  assert_path_absent "$BACKUP_DIR/.backup-operation.lock" \
    'fast failing child left the operation lock behind'
  assert_file_equals "$CASE_DIR/stderr" '' 'fast failing lock-run stderr'
}

test_backup_lock_run_honors_startup_cancellation() {
  local wrapper_pid status attempt
  new_case
  install_backup_fakes
  cat > "$CASE_DIR/bin/ps" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *'pgid='* ]]; then
  : > "$MOCK_LOG_DIR/pgid.handshake"
  sleep 1
fi
exec /bin/ps "$@"
EOF
  chmod 0700 "$CASE_DIR/bin/ps"
  cat > "$CASE_DIR/must-not-start" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
operation_dir="$(cd "$(dirname "$0")" && pwd)"
: > "$operation_dir/log/target.started"
sleep 10
EOF
  chmod 0700 "$CASE_DIR/must-not-start"
  env -i \
    PATH="$CASE_DIR/bin:/usr/bin:/bin" \
    HOME="$CASE_DIR/home" \
    MOCK_LOG_DIR="$CASE_DIR/log" \
    ADDRESS_ATLAS_BACKUP_DIR="$BACKUP_DIR" \
    "$OPS_TEST_BASH_BIN" "$BACKUP_SCRIPT" lock-run -- "$CASE_DIR/must-not-start" \
      > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr" &
  wrapper_pid=$!
  for attempt in {1..100}; do
    [[ -f "$CASE_DIR/log/pgid.handshake" ]] && break
    sleep 0.05
  done
  assert_path_exists "$CASE_DIR/log/pgid.handshake" \
    'lock-run did not enter the startup handshake'
  kill -TERM "$wrapper_pid"
  set +e
  wait "$wrapper_pid"
  status=$?
  set -e
  assert_status "$status" 143 'lock-run startup cancellation status'
  assert_path_absent "$CASE_DIR/log/target.started" \
    'target started after cancellation during PGID handshake'
  assert_path_exists "$BACKUP_DIR/.backup-operation.lock" \
    'startup cancellation did not preserve the operation lock'
}

test_backup_lock_run_cancels_process_group() {
  local wrapper_pid status attempt
  new_case
  install_backup_fakes
  cat > "$CASE_DIR/long-operation" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
operation_dir="$(cd "$(dirname "$0")" && pwd)"
(
  trap ': > "$operation_dir/log/grandchild.term"; exit 0' TERM INT
  : > "$operation_dir/log/grandchild.ready"
  while :; do sleep 1; done
) &
wait "$!"
EOF
  chmod 0700 "$CASE_DIR/long-operation"
  env -i \
    PATH="$CASE_DIR/bin:/usr/bin:/bin" \
    HOME="$CASE_DIR/home" \
    ADDRESS_ATLAS_BACKUP_DIR="$BACKUP_DIR" \
    "$OPS_TEST_BASH_BIN" "$BACKUP_SCRIPT" lock-run -- "$CASE_DIR/long-operation" \
      > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr" &
  wrapper_pid=$!
  for attempt in {1..100}; do
    [[ -f "$CASE_DIR/log/grandchild.ready" ]] && break
    sleep 0.05
  done
  assert_path_exists "$CASE_DIR/log/grandchild.ready" 'lock-run descendant did not start'
  kill -TERM "$wrapper_pid"
  set +e
  wait "$wrapper_pid"
  status=$?
  set -e
  assert_status "$status" 143 'lock-run cancellation status'
  assert_path_exists "$CASE_DIR/log/grandchild.term" 'lock-run did not signal the descendant process group'
  assert_path_exists "$BACKUP_DIR/.backup-operation.lock" 'cancelled lock-run did not preserve its stale operation lock'
  assert_file_contains "$CASE_DIR/stderr" 'verified manually' 'cancelled lock-run did not explain stale-lock recovery'
}

test_backup_lock_run_kills_term_ignoring_group() {
  local wrapper_pid status attempt direct_pid grandchild_pid
  new_case
  install_backup_fakes
  cat > "$CASE_DIR/term-ignoring-operation" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
operation_dir="$(cd "$(dirname "$0")" && pwd)"
trap '' TERM INT
printf '%s\n' "$$" > "$operation_dir/log/direct.pid"
/bin/sh -c 'trap "" TERM INT; printf "%s\n" "$$" > "$1"; : > "$2"; while :; do sleep 1; done' \
  sh "$operation_dir/log/grandchild.pid" "$operation_dir/log/ignoring.ready" &
wait "$!"
EOF
  chmod 0700 "$CASE_DIR/term-ignoring-operation"
  env -i \
    PATH="$CASE_DIR/bin:/usr/bin:/bin" \
    HOME="$CASE_DIR/home" \
    ADDRESS_ATLAS_BACKUP_DIR="$BACKUP_DIR" \
    "$OPS_TEST_BASH_BIN" "$BACKUP_SCRIPT" lock-run -- \
      "$CASE_DIR/term-ignoring-operation" \
      > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr" &
  wrapper_pid=$!
  for attempt in {1..100}; do
    [[ -f "$CASE_DIR/log/ignoring.ready" ]] && break
    sleep 0.05
  done
  assert_path_exists "$CASE_DIR/log/ignoring.ready" 'TERM-ignoring process group did not start'
  direct_pid="$(< "$CASE_DIR/log/direct.pid")"
  grandchild_pid="$(< "$CASE_DIR/log/grandchild.pid")"
  kill -TERM "$wrapper_pid"
  set +e
  wait "$wrapper_pid"
  status=$?
  set -e
  assert_status "$status" 143 'TERM-ignoring lock-run cancellation status'
  for attempt in {1..50}; do
    if ! kill -0 "$direct_pid" 2>/dev/null && ! kill -0 "$grandchild_pid" 2>/dev/null; then
      break
    fi
    sleep 0.05
  done
  ! kill -0 "$direct_pid" 2>/dev/null || fail 'TERM-ignoring direct child survived lock release'
  ! kill -0 "$grandchild_pid" 2>/dev/null || fail 'TERM-ignoring grandchild survived lock release'
  assert_path_exists "$BACKUP_DIR/.backup-operation.lock" \
    'cancelled TERM-ignoring lock-run did not preserve its stale lock'
}

test_backup_snapshot_start_freshness() {
  local backup
  new_case
  install_backup_fakes
  MOCK_SNAPSHOT_STARTED_AT='2026-07-20T16:00:00Z'
  MOCK_COMPLETED_AT='2026-07-20T16:07:30Z'
  backup="$BACKUP_DIR/address-atlas-20260720T160000Z.dump.age"
  run_backup_capture create
  assert_status "$CAPTURE_STATUS" 0 'long-running backup create status'
  assert_path_exists "$backup" 'backup filename did not use snapshot start'
  assert_file_contains "${backup}.manifest.json" \
    '"snapshotStartedAt": "2026-07-20T16:00:00Z"' \
    'signed snapshot start was not recorded'
  assert_file_contains "${backup}.manifest.json" \
    '"completedAt": "2026-07-20T16:07:30Z"' \
    'signed backup completion was not recorded'
  assert_path_absent "$BACKUP_DIR/address-atlas-20260720T160730Z.dump.age" \
    'backup freshness was mislabeled with completion time'
}

test_backup_verify() {
  local backup restore_stream
  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  make_backup_fixture "$backup"
  run_backup_capture verify "$backup"
  assert_status "$CAPTURE_STATUS" 0 'backup verify exit status'
  assert_file_equals "$CASE_DIR/stdout" "Verified encrypted and signed backup: ${backup}" 'backup verify output'
  assert_file_equals "$CASE_DIR/stderr" '' 'backup verify stderr'
  assert_file_equals "$CASE_DIR/log/age.events" 'decrypt' 'verify age operation'
  assert_file_contains "$CASE_DIR/log/docker.argv" 'pg_restore' 'verify did not invoke pg_restore'
  assert_file_contains "$CASE_DIR/log/docker.argv" '--list' 'verify did not request pg_restore list'
  restore_stream="$(find "$CASE_DIR/log" -maxdepth 1 -type f -name 'restore.*.stdin' -print -quit)"
  [[ -n "$restore_stream" ]] || fail 'decrypted pg_restore stream capture is missing'
  assert_file_contains "$restore_stream" 'PGDUMP_CUSTOM_FIXTURE' 'decrypted stream was not piped to pg_restore'
}

test_backup_rejects_unsafe_external_sources() {
  local backup source_parent

  new_case
  install_backup_fakes
  source_parent="$CASE_DIR/writable-source"
  mkdir -p "$source_parent"
  chmod 0777 "$source_parent"
  backup="$source_parent/source.dump.age"
  make_backup_fixture "$backup"
  run_backup_capture verify "$backup"
  assert_status "$CAPTURE_STATUS" 65 'writable external source parent status'
  assert_file_contains "$CASE_DIR/stderr" 'must not be writable by group or other users' \
    'writable external source parent rejection'
  assert_path_absent "$CASE_DIR/log/age.events" \
    'writable external source reached decryption'

  new_case
  install_backup_fakes
  backup="$CASE_DIR/fifo.dump.age"
  make_backup_fixture "$backup"
  find "$backup" -maxdepth 0 -type f -delete
  mkfifo "$backup"
  run_backup_capture verify "$backup"
  assert_status "$CAPTURE_STATUS" 66 'FIFO external source status'
  assert_path_absent "$CASE_DIR/log/age.events" 'FIFO external source reached decryption'

  new_case
  install_backup_fakes
  backup="$CASE_DIR/oversized-control.dump.age"
  make_backup_fixture "$backup"
  printf '%0300d' 0 >> "${backup}.sha256"
  run_backup_capture verify "$backup"
  assert_status "$CAPTURE_STATUS" 65 'oversized external control artifact status'
  assert_file_contains "$CASE_DIR/stderr" 'safe staging size limits' \
    'oversized external control artifact rejection'
  assert_path_absent "$CASE_DIR/log/age.events" \
    'oversized external control artifact reached decryption'
}

test_backup_rejects_missing_or_tampered_authenticated_set() {
  local backup scenario
  for scenario in missing_manifest missing_signature tampered_manifest tampered_signature; do
    new_case
    install_backup_fakes
    backup="$CASE_DIR/${scenario}.dump.age"
    make_backup_fixture "$backup"
    case "$scenario" in
      missing_manifest)
        find "${backup}.manifest.json" -maxdepth 0 -type f -delete
        ;;
      missing_signature)
        find "${backup}.manifest.sig" -maxdepth 0 -type f -delete
        ;;
      tampered_manifest)
        printf ' ' >> "${backup}.manifest.json"
        ;;
      tampered_signature)
        printf '%s\n' 'NOT_A_VALID_SIGNATURE' > "${backup}.manifest.sig"
        ;;
    esac
    run_backup_capture verify "$backup"
    [[ "$CAPTURE_STATUS" -ne 0 ]] || fail "${scenario} unexpectedly verified"
    assert_path_absent "$CASE_DIR/log/age.events" "${scenario} reached age decryption"
  done
}

test_backup_rejects_signed_metadata_mismatches() {
  local backup scenario digest
  digest="$(printf 'd%.0s' {1..64})"
  for scenario in wrong_provenance wrong_size wrong_digest wrong_ledger; do
    new_case
    install_backup_fakes
    backup="$CASE_DIR/${scenario}.dump.age"
    make_backup_fixture "$backup"
    case "$scenario" in
      wrong_provenance)
        rewrite_and_resign_manifest "$backup" \
          's/"sourceWebRevision": "[0-9a-f]*"/"sourceWebRevision": "unknown"/'
        ;;
      wrong_size)
        rewrite_and_resign_manifest "$backup" \
          's/"encryptedBytes": [0-9]\{1,\}/"encryptedBytes": 999999/'
        ;;
      wrong_digest)
        rewrite_and_resign_manifest "$backup" \
          "s/\"sha256\": \"[0-9a-f]*\"/\"sha256\": \"${digest}\"/"
        ;;
      wrong_ledger)
        rewrite_and_resign_manifest "$backup" \
          "s/\"migrationLedgerSha256\": \"[0-9a-f]*\"/\"migrationLedgerSha256\": \"${digest}\"/"
        ;;
    esac
    run_backup_capture verify "$backup"
    assert_status "$CAPTURE_STATUS" 65 "${scenario} verification status"
    assert_path_absent "$CASE_DIR/log/age.events" "${scenario} reached age decryption"
  done
}

test_backup_latest() {
  local older newer
  new_case
  install_backup_fakes
  older="$BACKUP_DIR/address-atlas-20260720T140000Z.dump.age"
  newer="$BACKUP_DIR/address-atlas-20260720T150000Z.dump.age"
  make_backup_fixture "$older"
  make_backup_fixture "$newer"
  touch -t 202607201400.00 "$older"
  touch -t 202607201500.00 "$newer"
  MOCK_NOW_EPOCH="$(iso8601_epoch_for_test '2026-07-20T15:00:00Z')"
  run_backup_capture latest
  assert_status "$CAPTURE_STATUS" 0 'backup latest exit status'
  assert_file_equals "$CASE_DIR/stdout" "$newer" 'latest selected wrong backup'
  assert_file_equals "$CASE_DIR/stderr" '' 'backup latest stderr'
  assert_file_equals "$CASE_DIR/log/age.events" 'decrypt' 'latest did not verify selected backup'
}

test_backup_latest_uses_signed_freshness() {
  local backup
  new_case
  install_backup_fakes
  backup="$BACKUP_DIR/address-atlas-20200101T000000Z.dump.age"
  make_backup_fixture "$backup"
  touch "$backup"
  MOCK_NOW_EPOCH="$(/bin/date +%s)"
  run_backup_capture latest
  assert_status "$CAPTURE_STATUS" 66 'signed stale backup status'
  assert_file_contains "$CASE_DIR/stderr" 'older than' 'signed stale backup rejection'

  new_case
  install_backup_fakes
  backup="$BACKUP_DIR/address-atlas-20260720T150000Z.dump.age"
  make_backup_fixture "$backup"
  rewrite_and_resign_manifest "$backup" \
    's/2026-07-20T15:00:00Z/2026-07-20T14:00:00Z/'
  MOCK_NOW_EPOCH="$(mtime_for_test "$backup")"
  run_backup_capture latest
  assert_status "$CAPTURE_STATUS" 65 'signed filename timestamp mismatch status'
  assert_file_contains "$CASE_DIR/stderr" 'filename does not match' 'signed filename timestamp mismatch'
}

test_backup_canonical_prefix_upgrade() {
  local backup
  new_case
  install_backup_fakes
  MOCK_LEDGER_HEAD=1
  backup="$BACKUP_DIR/address-atlas-20260720T160000Z.dump.age"
  run_backup_capture create
  assert_status "$CAPTURE_STATUS" 0 'canonical v1 prefix create status'
  assert_file_contains "${backup}.manifest.json" '"migrationHeadVersion": 1' 'v1 manifest head'
  assert_file_contains "${backup}.manifest.json" "\"migrationLedgerSha256\": \"$(ledger_digest_for_test 1)\"" 'v1 manifest ledger digest'
  run_backup_capture verify "$backup"
  assert_status "$CAPTURE_STATUS" 0 'canonical v1 prefix verify status'

  new_case
  install_backup_fakes
  MOCK_LEDGER_HEAD=altered
  run_backup_capture create
  assert_status "$CAPTURE_STATUS" 65 'altered migration ledger create status'
  assert_file_not_contains "$CASE_DIR/log/docker.argv" 'pg_dump' 'altered ledger reached pg_dump'

  new_case
  install_backup_fakes
  MOCK_LEDGER_HEAD=skipped
  run_backup_capture create
  assert_status "$CAPTURE_STATUS" 65 'skipped migration ledger create status'
  assert_file_not_contains "$CASE_DIR/log/docker.argv" 'pg_dump' 'skipped ledger reached pg_dump'

  new_case
  install_backup_fakes
  backup="$CASE_DIR/v1-no-hook.dump.age"
  make_backup_fixture "$backup" 1
  RESTORE_MIGRATION_HOOK=''
  run_backup_capture drill "$backup"
  assert_status "$CAPTURE_STATUS" 66 'older prefix missing migration hook status'
  assert_file_contains "$CASE_DIR/stderr" 'requires an absolute non-symlink migration/readiness hook' 'older prefix missing migration hook'

  new_case
  install_backup_fakes
  backup="$CASE_DIR/v1-hook-failure.dump.age"
  make_backup_fixture "$backup" 1
  cat > "$CASE_DIR/migrate-fail" <<'EOF'
#!/usr/bin/env bash
exit 19
EOF
  chmod 0700 "$CASE_DIR/migrate-fail"
  RESTORE_MIGRATION_HOOK="$CASE_DIR/migrate-fail"
  run_backup_capture drill "$backup"
  assert_status "$CAPTURE_STATUS" 74 'older prefix failed migration hook status'
  assert_file_contains "$CASE_DIR/stderr" 'fresh database was not cut over' 'failed migration hook result'

  new_case
  install_backup_fakes
  backup="$CASE_DIR/v1-hook-success.dump.age"
  make_backup_fixture "$backup" 1
  cat > "$CASE_DIR/migrate-success" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 4 ]]
[[ "$1" == 'postgres-test' ]]
[[ "$2" == atlas_drill_* ]]
[[ "$3" == '1' && "$4" == '3' ]]
[[ "$DOCKER_BIN" == /* && -x "$DOCKER_BIN" ]]
[[ "$POSTGRES_PASSWORD" == 'OwnerBootstrapSecret_7Gm2Qv9Lx4Np8Yk6' ]]
[[ "$ADDRESS_ATLAS_RESTORE_IMAGE" == "address-atlas-sync:${ADDRESS_ATLAS_RESTORE_BUILD_REVISION}" ]]
[[ -z "${POSTGRES_ADMIN_PASSWORD:-}" ]]
[[ -z "${ADDRESS_ATLAS_BACKUP_SIGNING_PRIVATE_KEY_FILE:-}" ]]
hook_dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$@" > "$hook_dir/log/migration.args"
printf '%s\n' "$ADDRESS_ATLAS_RESTORE_IMAGE" > "$hook_dir/log/migration.image"
EOF
  chmod 0700 "$CASE_DIR/migrate-success"
  RESTORE_MIGRATION_HOOK="$CASE_DIR/migrate-success"
  run_backup_capture drill "$backup"
  assert_status "$CAPTURE_STATUS" 0 'older prefix successful migration hook status'
  assert_file_contains "$CASE_DIR/log/migration.args" 'postgres-test' 'migration hook container argument'
  assert_file_contains "$CASE_DIR/log/migration.args" 'atlas_drill_' 'migration hook staging database argument'
  assert_file_contains "$CASE_DIR/log/migration.image" "$RESTORE_IMAGE" 'migration hook restore image allowlist'

  new_case
  install_backup_fakes
  backup="$CASE_DIR/v3-production-hook-failure.dump.age"
  make_backup_fixture "$backup" 3
  cat > "$CASE_DIR/validate-current-fail" <<'EOF'
#!/usr/bin/env bash
exit 20
EOF
  chmod 0700 "$CASE_DIR/validate-current-fail"
  RESTORE_MIGRATION_HOOK="$CASE_DIR/validate-current-fail"
  ALLOW_RESTORE='YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED'
  MOCK_WEB_RUNNING=0
  run_backup_capture restore "$backup" --confirm 'RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 74 'production current-head readiness hook failure status'
  assert_path_absent "$CASE_DIR/log/cutover.done" 'failed current-head readiness hook reached cutover'

  new_case
  install_backup_fakes
  backup="$CASE_DIR/v1-production-hook-failure.dump.age"
  make_backup_fixture "$backup" 1
  cat > "$CASE_DIR/migrate-prod-fail" <<'EOF'
#!/usr/bin/env bash
exit 21
EOF
  chmod 0700 "$CASE_DIR/migrate-prod-fail"
  RESTORE_MIGRATION_HOOK="$CASE_DIR/migrate-prod-fail"
  ALLOW_RESTORE='YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED'
  MOCK_WEB_RUNNING=0
  run_backup_capture restore "$backup" --confirm 'RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 74 'production older prefix migration failure status'
  assert_path_absent "$CASE_DIR/log/cutover.done" 'failed restore migration hook reached cutover'
}

test_backup_offsite_contract() {
  local backup
  new_case
  install_backup_fakes
  backup="$BACKUP_DIR/address-atlas-20260720T160000Z.dump.age"
  OFFSITE_REQUIRED=true
  run_backup_capture create
  assert_status "$CAPTURE_STATUS" 66 'missing required offsite hook status'
  assert_path_absent "$backup" 'backup should not begin with missing required hook'

  new_case
  install_backup_fakes
  backup="$BACKUP_DIR/address-atlas-20260720T160000Z.dump.age"
  cat > "$CASE_DIR/offsite-fail" <<'EOF'
#!/usr/bin/env bash
exit 23
EOF
  chmod 0700 "$CASE_DIR/offsite-fail"
  OFFSITE_HOOK="$CASE_DIR/offsite-fail"
  OFFSITE_REQUIRED=true
  run_backup_capture create
  assert_status "$CAPTURE_STATUS" 74 'failed required offsite hook status'
  assert_path_exists "$backup" 'failed offsite delivery deleted local dump'
  assert_path_exists "${backup}.sha256" 'failed offsite delivery deleted checksum'
  assert_path_exists "${backup}.manifest.json" 'failed offsite delivery deleted manifest'
  assert_path_exists "${backup}.manifest.sig" 'failed offsite delivery deleted signature'
  assert_file_contains "$CASE_DIR/stderr" 'completed local artifact set was retained' 'offsite failure retention message'

  new_case
  install_backup_fakes
  backup="$BACKUP_DIR/address-atlas-20260720T160000Z.dump.age"
  cat > "$CASE_DIR/offsite-success" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 4 ]]
for artifact in "$@"; do
  [[ -f "$artifact" ]]
done
hook_dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$@" > "$hook_dir/log/offsite.args"
EOF
  chmod 0700 "$CASE_DIR/offsite-success"
  OFFSITE_HOOK="$CASE_DIR/offsite-success"
  OFFSITE_REQUIRED=true
  run_backup_capture create
  assert_status "$CAPTURE_STATUS" 0 'successful required offsite hook status'
  assert_file_equals "$CASE_DIR/stdout" "$backup" 'offsite create output path'
  assert_file_contains "$CASE_DIR/log/offsite.args" "${backup}.manifest.sig" 'offsite hook did not receive signature'
  [[ "$(wc -l < "$CASE_DIR/log/offsite.args" | tr -d '[:space:]')" == '4' ]] \
    || fail 'offsite hook did not receive exactly four artifact paths'
}

test_backup_self_verifies_before_delivery_and_retention() {
  local expired backup
  new_case
  install_backup_fakes
  expired="$BACKUP_DIR/address-atlas-20200101T000000Z.dump.age"
  make_backup_fixture "$expired"
  touch -t 202001010000.00 "$expired" "${expired}.sha256" \
    "${expired}.manifest.json" "${expired}.manifest.sig"
  cat > "$CASE_DIR/offsite-must-not-run" <<'EOF'
#!/usr/bin/env bash
hook_dir="$(cd "$(dirname "$0")" && pwd)"
: > "$hook_dir/log/offsite-ran"
EOF
  chmod 0700 "$CASE_DIR/offsite-must-not-run"
  OFFSITE_HOOK="$CASE_DIR/offsite-must-not-run"
  OFFSITE_REQUIRED=true
  MOCK_AGE_DECRYPT_EXIT=47
  backup="$BACKUP_DIR/address-atlas-20260720T160000Z.dump.age"
  run_backup_capture create
  assert_status "$CAPTURE_STATUS" 74 'unreadable new backup status'
  assert_path_exists "$backup" 'unreadable local artifact was not retained for diagnosis'
  assert_path_exists "$expired" 'unreadable new backup pruned the last known recovery point'
  assert_path_exists "${expired}.manifest.sig" 'unreadable new backup pruned old authenticated sidecars'
  assert_path_absent "$CASE_DIR/log/offsite-ran" 'unreadable backup reached offsite delivery'
  assert_file_contains "$CASE_DIR/stderr" 'could not be decrypted and inspected' \
    'unreadable backup failure was not explicit'
}

test_backup_drill() {
  local backup
  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  make_backup_fixture "$backup"
  run_backup_capture drill "$backup"
  assert_status "$CAPTURE_STATUS" 0 'backup drill exit status'
  assert_file_contains "$CASE_DIR/stdout" 'Restore drill passed in fresh template0 database atlas_drill_20260720160000_' 'drill success output'
  assert_file_equals "$CASE_DIR/stderr" '' 'backup drill stderr'
  assert_file_equals "$CASE_DIR/log/age.events" $'decrypt\ndecrypt' 'drill verify/restore age sequence'
  assert_file_contains "$CASE_DIR/log/docker.argv" 'createdb' 'drill database was not created'
  assert_file_contains "$CASE_DIR/log/docker.argv" '--template=template0' 'drill database did not use template0'
  assert_file_contains "$CASE_DIR/log/docker.argv" '--owner=' 'drill database owner flag'
  assert_file_contains "$CASE_DIR/log/docker.argv" 'address_atlas' 'drill database owner argument'
  assert_file_contains "$CASE_DIR/log/docker.argv" 'address_atlas_admin' 'drill did not use the admin role'
  assert_file_contains "$CASE_DIR/log/docker.argv" 'account_deletion_receipts' 'drill did not check all 11 tables'
  assert_file_contains "$CASE_DIR/log/docker.argv" 'dropdb' 'drill database was not cleaned up'
  assert_file_contains "$CASE_DIR/log/restore-validation.args" '3' 'current-head drill skipped immutable-image validation hook'
  assert_file_contains "$CASE_DIR/log/restore-provision.args" 'atlas_drill_' \
    'drill skipped exact restore privilege provisioning'
  assert_file_contains "$CASE_DIR/log/restore-provision.modes" ':drill' \
    'drill provisioning did not require steady credential preflight mode'
  assert_file_contains "$CASE_DIR/log/admin.sql" 'pg_catalog.pg_auth_members' \
    'drill skipped post-provision protected-role validation'
  assert_file_contains "$CASE_DIR/log/docker.argv" 'address_atlas_runtime' \
    'drill skipped runtime access-contract authentication'
  assert_path_absent "$BACKUP_DIR/.backup-operation.lock" 'drill operation lock was not removed'
  assert_file_not_contains "$CASE_DIR/log/docker.argv" "$ADMIN_PASSWORD" 'admin password leaked to docker argv'
  assert_file_not_contains "$CASE_DIR/log/docker.argv" "$RUNTIME_PASSWORD" 'runtime password leaked to docker argv'
  assert_file_not_contains "$CASE_DIR/stdout" "$ADMIN_PASSWORD" 'admin password leaked to stdout'
  assert_file_not_contains "$CASE_DIR/stderr" "$ADMIN_PASSWORD" 'admin password leaked to stderr'
}

test_backup_drill_preserves_lock_on_cleanup_failure() {
  local backup
  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  make_backup_fixture "$backup"
  MOCK_DROPDB_EXIT=44
  run_backup_capture drill "$backup"
  assert_status "$CAPTURE_STATUS" 74 'drill drop failure status'
  assert_path_exists "$BACKUP_DIR/.backup-operation.lock" \
    'failed drill database cleanup released the operation lock'
  assert_path_exists "$BACKUP_DIR/.backup-operation.lock.preserve" \
    'failed drill database cleanup omitted the recovery marker'
  assert_file_contains "$CASE_DIR/stderr" 'sensitive production data' \
    'failed drill database cleanup lacked a critical warning'
}

test_backup_rejects_control_plane_role_drift() {
  local backup
  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  make_backup_fixture "$backup"
  MOCK_CONTROL_CONTEXT_RESULT=invalid
  run_backup_capture drill "$backup"
  assert_status "$CAPTURE_STATUS" 65 'control-plane role drift status'
  assert_file_contains "$CASE_DIR/stderr" 'membership, setting' 'control-plane drift message'
  assert_file_not_contains "$CASE_DIR/log/docker.argv" 'createdb' 'control-plane drift reached database creation'
  assert_file_contains "$CASE_DIR/log/docker.argv" 'search_path=pg_catalog' \
    'admin session did not pin a trusted search path'
  assert_file_contains "$CASE_DIR/log/admin.sql" 'pg_catalog.pg_auth_members' \
    'exact role-membership contract was not queried'
  assert_file_contains "$CASE_DIR/log/admin.sql" 'pg_catalog.pg_db_role_setting' \
    'exact role/database-setting contract was not queried'
}

test_restore_confirmation_gate() {
  local backup
  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  make_backup_fixture "$backup"
  run_backup_capture restore "$backup" --confirm 'RESTORE:wrong_database'
  assert_status "$CAPTURE_STATUS" 64 'restore confirmation gate status'
  assert_file_contains "$CASE_DIR/stderr" 'Confirmation must exactly equal RESTORE:address_atlas_sync.' 'restore confirmation gate message'
  assert_path_absent "$CASE_DIR/log/age.events" 'restore read backup before confirmation gate'
  assert_file_not_contains "$CASE_DIR/log/docker.argv" 'pg_restore' 'restore invoked pg_restore before confirmation gate'
}

test_restore_authorization_gate() {
  local backup
  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  make_backup_fixture "$backup"
  run_backup_capture restore "$backup" --confirm 'RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 77 'restore authorization gate status'
  assert_file_contains "$CASE_DIR/stderr" 'Production restore authorization environment value is missing.' 'restore authorization gate message'
  assert_path_absent "$CASE_DIR/log/age.events" 'restore read backup before authorization gate'
  assert_file_not_contains "$CASE_DIR/log/docker.argv" 'pg_restore' 'restore invoked pg_restore before authorization gate'
}

test_restore_rejects_future_native_config_manifest_before_mutation() {
  local backup completed_epoch future_timestamp
  new_case
  install_backup_fakes
  backup="$CASE_DIR/future-native-config.dump.age"
  make_backup_fixture "$backup"
  completed_epoch="$(iso8601_epoch_for_test '2026-07-20T16:00:00Z')"
  future_timestamp=$((completed_epoch * 1000 + 300001))
  rewrite_and_resign_manifest "$backup" \
    "s/\"nativeConfigUpdatedAtEpochMs\": 1784505600000/\"nativeConfigUpdatedAtEpochMs\": ${future_timestamp}/"
  ALLOW_RESTORE='YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED'
  MOCK_WEB_RUNNING=0
  run_backup_capture restore "$backup" --confirm 'RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 65 'future native-config restore status'
  assert_file_contains "$CASE_DIR/stderr" 'exceeds snapshot completion plus allowed clock skew' \
    'future native-config restore rejection message'
  assert_file_not_contains "$CASE_DIR/log/admin.sql" 'NOLOGIN' \
    'future native-config restore quiesced the runtime role'
  assert_file_not_contains "$CASE_DIR/log/docker.argv" 'pg_dump' \
    'future native-config restore created a safety backup'
  assert_file_not_contains "$CASE_DIR/log/docker.argv" 'pg_restore' \
    'future native-config restore reached database restore'
  assert_path_absent "$CASE_DIR/log/cutover.done" \
    'future native-config restore reached cutover'
}

test_restore_web_service_gate() {
  local backup
  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  make_backup_fixture "$backup"
  ALLOW_RESTORE='YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED'
  MOCK_WEB_RUNNING=1
  run_backup_capture restore "$backup" --confirm 'RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 77 'restore running-web gate status'
  assert_file_contains "$CASE_DIR/stderr" 'Stop the production web service before restoring PostgreSQL.' 'restore running-web gate message'
  assert_path_absent "$CASE_DIR/log/age.events" 'restore read backup while web service was running'
  assert_file_not_contains "$CASE_DIR/log/docker.argv" 'pg_restore' 'restore invoked pg_restore while web service was running'
}

test_restore_preflights_provisioning_before_quiesce() {
  local backup
  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  make_backup_fixture "$backup"
  ALLOW_RESTORE='YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED'
  MOCK_WEB_RUNNING=0
  RESTORE_PROVISION_IMAGE='postgres:16.14-alpine3.24'
  run_backup_capture restore "$backup" --confirm 'RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 65 'invalid provision image preflight status'
  assert_path_absent "$CASE_DIR/log/cutover.done" \
    'invalid provision configuration reached cutover'
  assert_file_not_contains "$CASE_DIR/log/admin.sql" 'NOLOGIN' \
    'invalid provision configuration quiesced the runtime role'
  assert_file_contains "$CASE_DIR/stderr" 'reviewed immutable PostgreSQL image' \
    'invalid provision configuration lacked a preflight error'

  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  make_backup_fixture "$backup"
  ALLOW_RESTORE='YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED'
  MOCK_WEB_RUNNING=0
  ADMIN_PASSWORD='AdminSecretWithDisallowedPunctuation_123!'
  run_backup_capture restore "$backup" --confirm 'RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 65 'invalid provision admin secret preflight status'
  assert_file_not_contains "$CASE_DIR/log/admin.sql" 'NOLOGIN' \
    'invalid provision admin secret quiesced the runtime role'

  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  make_backup_fixture "$backup"
  ALLOW_RESTORE='YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED'
  MOCK_WEB_RUNNING=0
  find "$CASE_DIR/provision-runtime-role.sh" -maxdepth 0 -type f -delete
  run_backup_capture restore "$backup" --confirm 'RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 66 'missing canonical provision source preflight status'
  assert_file_not_contains "$CASE_DIR/log/admin.sql" 'NOLOGIN' \
    'missing canonical provision source quiesced the runtime role'
}

test_restore_preflights_migration_before_quiesce() {
  local backup
  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  make_backup_fixture "$backup"
  ALLOW_RESTORE='YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED'
  MOCK_WEB_RUNNING=0
  RESTORE_MIGRATION_HOOK=''
  run_backup_capture restore "$backup" --confirm 'RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 66 'missing migration hook preflight status'
  assert_path_absent "$CASE_DIR/log/cutover.done" \
    'missing migration contract reached cutover'
  assert_file_not_contains "$CASE_DIR/log/admin.sql" 'NOLOGIN' \
    'missing migration contract quiesced the runtime role'
  assert_file_contains "$CASE_DIR/stderr" 'migration/readiness hook' \
    'missing migration contract lacked a preflight error'

  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  make_backup_fixture "$backup"
  ALLOW_RESTORE='YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED'
  MOCK_WEB_RUNNING=0
  MOCK_RESTORE_IMAGE_REVISION='ffffffffffffffffffffffffffffffffffffffff'
  run_backup_capture restore "$backup" --confirm 'RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 65 'restore image label mismatch preflight status'
  assert_file_not_contains "$CASE_DIR/log/admin.sql" 'NOLOGIN' \
    'restore image label mismatch quiesced the runtime role'
  assert_file_contains "$CASE_DIR/stderr" 'revision label does not match' \
    'restore image label mismatch lacked a preflight error'
}

test_restore_distinguishes_atomic_cutover_outcomes() {
  local backup
  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  make_backup_fixture "$backup"
  ALLOW_RESTORE='YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED'
  MOCK_WEB_RUNNING=0
  MOCK_CUTOVER_EXIT=45
  run_backup_capture restore "$backup" --confirm 'RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 45 'pre-commit cutover failure status'
  assert_path_absent "$CASE_DIR/log/cutover.done" \
    'pre-commit cutover failure was recorded as committed'
  assert_path_absent "$CASE_DIR/log/rollback.done" \
    'pre-commit cutover failure attempted a false reverse rename'
  assert_path_absent "$BACKUP_DIR/.backup-operation.lock" \
    'known pre-commit cutover failure preserved a false recovery lock'
  assert_file_not_contains "$CASE_DIR/stderr" 'Automatic restore rollback failed' \
    'known pre-commit failure emitted a false rollback critical'

  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  make_backup_fixture "$backup"
  ALLOW_RESTORE='YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED'
  MOCK_WEB_RUNNING=0
  MOCK_CUTOVER_COMMIT_THEN_EXIT=46
  run_backup_capture restore "$backup" --confirm 'RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 46 'committed cutover client-failure status'
  assert_path_exists "$CASE_DIR/log/cutover.done" \
    'committed cutover client failure did not record cutover'
  assert_path_exists "$CASE_DIR/log/rollback.done" \
    'committed cutover client failure was not rolled back'
  assert_path_absent "$BACKUP_DIR/.backup-operation.lock" \
    'verified committed-cutover rollback left a stale operation lock'
  assert_file_not_contains "$CASE_DIR/stderr" 'Automatic restore rollback failed' \
    'verified committed-cutover rollback emitted a false critical'
}

test_restore_fresh_stage_cutover() {
  local backup safety_backup
  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  safety_backup="$BACKUP_DIR/address-atlas-20260720T160000Z.dump.age"
  make_backup_fixture "$backup"
  ALLOW_RESTORE='YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED'
  MOCK_WEB_RUNNING=0
  run_backup_capture restore "$backup" --confirm 'RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 0 'authorized restore exit status'
  assert_file_contains "$CASE_DIR/stdout" "Created and verified pre-restore safety backup: ${safety_backup}" 'restore safety-backup output'
  assert_file_contains "$CASE_DIR/stdout" 'Production restore completed for address_atlas_sync; previous database quarantined as atlas_quarantine_' 'restore completion output'
  assert_file_contains "$CASE_DIR/stdout" 'Exact database privileges were provisioned' 'restore privilege-provisioning handoff'
  assert_file_equals "$CASE_DIR/stderr" '' 'authorized restore stderr'
  assert_path_exists "$safety_backup" 'pre-restore encrypted safety backup was not created'
  assert_path_exists "${safety_backup}.manifest.sig" 'pre-restore safety signature was not created'
  assert_file_equals "$CASE_DIR/log/age.events" $'decrypt\nencrypt\ndecrypt\ndecrypt' 'verify/safety/restore sequence'
  assert_file_contains "$CASE_DIR/log/docker.argv" 'pg_dump' 'safety backup did not invoke pg_dump'
  assert_file_contains "$CASE_DIR/log/docker.argv" '--template=template0' 'production staging database did not use template0'
  assert_file_contains "$CASE_DIR/log/docker.argv" '--single-transaction' 'database rename cutover was not transactional'
  assert_file_contains "$CASE_DIR/log/admin.sql" 'ALTER ROLE "address_atlas_runtime" NOLOGIN' 'runtime role was not quiesced before safety backup'
  assert_file_contains "$CASE_DIR/log/restore-provision.args" 'address_atlas_sync' 'restore privilege-provisioning hook did not run'
  assert_file_contains "$CASE_DIR/log/restore-provision.modes" 'address_atlas_sync:restore' \
    'production restore provisioning did not use restore credential mode'
  assert_file_contains "$CASE_DIR/log/admin.sql" 'ALLOW_CONNECTIONS false' 'quarantined database still accepts connections'
  assert_file_contains "$CASE_DIR/log/restore-validation.args" 'atlas_restore_' 'current-head production restore skipped immutable-image readiness hook'
  assert_file_not_contains "$CASE_DIR/log/docker.argv" '--clean' 'production restore still cleans the live database'
  assert_path_exists "$CASE_DIR/log/cutover.done" 'production cutover SQL did not execute'
  assert_path_absent "$BACKUP_DIR/.backup-operation.lock" 'restore operation lock was not removed'
  assert_file_not_contains "$CASE_DIR/log/docker.argv" "$ADMIN_PASSWORD" 'admin password leaked to docker argv'
  assert_file_not_contains "$CASE_DIR/stdout" "$ADMIN_PASSWORD" 'admin password leaked to stdout'
  assert_file_not_contains "$CASE_DIR/stderr" "$ADMIN_PASSWORD" 'admin password leaked to stderr'
}

test_restore_preserves_selected_expired_backup() {
  local backup
  new_case
  install_backup_fakes
  backup="$BACKUP_DIR/address-atlas-20200101T000000Z.dump.age"
  make_backup_fixture "$backup"
  touch -t 202001010000.00 "$backup" "${backup}.sha256" \
    "${backup}.manifest.json" "${backup}.manifest.sig"
  ALLOW_RESTORE='YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED'
  MOCK_WEB_RUNNING=0
  run_backup_capture restore "$backup" --confirm 'RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 0 'expired recovery-point restore status'
  assert_path_exists "$backup" 'safety backup retention deleted the selected restore dump'
  assert_path_exists "${backup}.sha256" 'safety backup retention deleted selected checksum'
  assert_path_exists "${backup}.manifest.json" 'safety backup retention deleted selected manifest'
  assert_path_exists "${backup}.manifest.sig" 'safety backup retention deleted selected signature'
}

test_restore_rolls_back_failed_post_cutover_validation() {
  local backup
  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  make_backup_fixture "$backup"
  ALLOW_RESTORE='YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED'
  MOCK_WEB_RUNNING=0
  MOCK_POST_CUTOVER_CHECK_FAIL=1
  run_backup_capture restore "$backup" --confirm 'RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 74 'post-cutover validation failure status'
  assert_path_exists "$CASE_DIR/log/cutover.done" 'failed validation did not follow cutover'
  assert_path_exists "$CASE_DIR/log/rollback.done" 'failed validation did not trigger rollback rename'
  assert_file_contains "$CASE_DIR/log/admin.sql" 'ALLOW_CONNECTIONS false' 'failed restore candidate was not isolated'
  assert_file_contains "$CASE_DIR/log/admin.sql" 'ALLOW_CONNECTIONS true' 'rolled-back production database was not re-enabled'
  assert_file_contains "$CASE_DIR/stderr" 'previous production database was restored' 'rollback result message'
  assert_file_contains "$CASE_DIR/stderr" 'atlas_failed_' 'failed candidate quarantine message'
  assert_file_not_contains "$CASE_DIR/log/docker.argv" "$ADMIN_PASSWORD" 'admin password leaked during rollback'
}

test_restore_rejects_failed_pre_cutover_readiness() {
  local backup
  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  make_backup_fixture "$backup"
  ALLOW_RESTORE='YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED'
  MOCK_WEB_RUNNING=0
  MOCK_PRE_CUTOVER_CHECK_FAIL=1
  run_backup_capture restore "$backup" --confirm 'RESTORE:address_atlas_sync'
  [[ "$CAPTURE_STATUS" -ne 0 ]] || fail 'pre-cutover readiness failure unexpectedly restored production'
  assert_path_absent "$CASE_DIR/log/cutover.done" 'failed pre-cutover readiness reached cutover'
  assert_file_contains "$CASE_DIR/log/docker.argv" 'dropdb' 'failed staging database was not cleaned up'
  assert_file_contains "$CASE_DIR/stderr" 'runtime database role remains NOLOGIN' \
    'failed restore did not preserve fail-closed runtime quiescence'
}

test_restore_preserves_lock_on_staging_cleanup_failure() {
  local backup
  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  make_backup_fixture "$backup"
  ALLOW_RESTORE='YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED'
  MOCK_WEB_RUNNING=0
  MOCK_PRE_CUTOVER_CHECK_FAIL=1
  MOCK_DROPDB_EXIT=44
  run_backup_capture restore "$backup" --confirm 'RESTORE:address_atlas_sync'
  [[ "$CAPTURE_STATUS" -ne 0 ]] || fail 'staging cleanup failure unexpectedly succeeded'
  assert_path_exists "$BACKUP_DIR/.backup-operation.lock" \
    'failed staging database cleanup released the operation lock'
  assert_path_exists "$BACKUP_DIR/.backup-operation.lock.preserve" \
    'failed staging database cleanup omitted the recovery marker'
  assert_file_contains "$CASE_DIR/stderr" 'restore staging database' \
    'failed staging database cleanup lacked a critical warning'
}

test_restore_rolls_back_failed_privilege_provisioning() {
  local backup
  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  make_backup_fixture "$backup"
  cat > "$CASE_DIR/restore-provision-fail" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'hook stdout secret: RuntimeServiceSecret_3Ld8Qw5Nz7Rx2Km9'
printf '%s\n' 'ROLE_PROVISION_FAILED mode=restore stage=convergence-transaction' >&2
exit 29
EOF
  chmod 0700 "$CASE_DIR/restore-provision-fail"
  RESTORE_PROVISION_HOOK="$CASE_DIR/restore-provision-fail"
  ALLOW_RESTORE='YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED'
  MOCK_WEB_RUNNING=0
  run_backup_capture restore "$backup" --confirm 'RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 74 'restore privilege-provisioning failure status'
  assert_path_exists "$CASE_DIR/log/cutover.done" 'privilege-provisioning failure did not reach validated cutover'
  assert_path_exists "$CASE_DIR/log/rollback.done" 'privilege-provisioning failure did not restore previous database'
  assert_file_contains "$CASE_DIR/stderr" 'privilege provisioning failed' 'restore privilege-provisioning failure message'
  assert_file_contains "$CASE_DIR/stderr" \
    'ROLE_PROVISION_FAILED mode=restore stage=convergence-transaction' \
    'restore wrapper suppressed the fixed privilege-provisioning diagnostic'
  assert_file_not_contains "$CASE_DIR/stdout" \
    'hook stdout secret: RuntimeServiceSecret_3Ld8Qw5Nz7Rx2Km9' \
    'restore wrapper exposed privilege-provisioning hook stdout'
  assert_file_not_contains "$CASE_DIR/stderr" \
    'hook stdout secret: RuntimeServiceSecret_3Ld8Qw5Nz7Rx2Km9' \
    'restore wrapper redirected privilege-provisioning hook stdout to stderr'
  assert_file_contains "$CASE_DIR/log/admin.sql" 'ALTER ROLE "address_atlas_runtime" NOLOGIN' \
    'failed privilege provisioning did not force runtime back to NOLOGIN'
}

test_restore_preserves_lock_when_runtime_relock_is_uncertain() {
  local backup
  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  make_backup_fixture "$backup"
  cat > "$CASE_DIR/restore-provision-partial-fail" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
hook_dir="$(cd "$(dirname "$0")" && pwd)"
: > "$hook_dir/log/provision.attempted"
exit 29
EOF
  chmod 0700 "$CASE_DIR/restore-provision-partial-fail"
  RESTORE_PROVISION_HOOK="$CASE_DIR/restore-provision-partial-fail"
  MOCK_RUNTIME_RELOCK_EXIT=42
  ALLOW_RESTORE='YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED'
  MOCK_WEB_RUNNING=0
  run_backup_capture restore "$backup" --confirm 'RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 74 'uncertain runtime relock restore status'
  assert_path_exists "$BACKUP_DIR/.backup-operation.lock" \
    'uncertain runtime relock released the operation lock'
  assert_path_exists "$BACKUP_DIR/.backup-operation.lock.preserve" \
    'uncertain runtime relock omitted the manual-recovery marker'
  assert_file_contains "$CASE_DIR/stderr" 'could not be proven NOLOGIN' \
    'uncertain runtime relock lacked a critical operator warning'
  assert_file_not_contains "$CASE_DIR/stderr" 'role remains NOLOGIN' \
    'uncertain runtime relock falsely claimed NOLOGIN'
}

test_restore_preserves_lock_when_rollback_is_uncertain() {
  local backup
  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  make_backup_fixture "$backup"
  ALLOW_RESTORE='YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED'
  MOCK_WEB_RUNNING=0
  MOCK_POST_CUTOVER_CHECK_FAIL=1
  MOCK_ROLLBACK_EXIT=43
  run_backup_capture restore "$backup" --confirm 'RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 74 'uncertain rollback restore status'
  assert_path_exists "$BACKUP_DIR/.backup-operation.lock" \
    'uncertain rollback released the operation lock'
  assert_path_exists "$BACKUP_DIR/.backup-operation.lock.preserve" \
    'uncertain rollback omitted the manual-recovery marker'
  assert_file_contains "$CASE_DIR/stderr" 'Automatic restore rollback failed' \
    'uncertain rollback lacked a critical operator warning'
  [[ "$(grep -c 'atlas_failed_' "$CASE_DIR/log/admin.sql" || true)" -ge 2 ]] \
    || fail 'cleanup did not retry the failed automatic rollback'
}

test_lock_run_preserves_lock_when_recovery_marker_write_fails() {
  local backup
  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  make_backup_fixture "$backup"
  cat > "$CASE_DIR/restore-provision-partial-fail" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
hook_dir="$(cd "$(dirname "$0")" && pwd)"
: > "$hook_dir/log/provision.attempted"
exit 29
EOF
  chmod 0700 "$CASE_DIR/restore-provision-partial-fail"
  RESTORE_PROVISION_HOOK="$CASE_DIR/restore-provision-partial-fail"
  cat > "$CASE_DIR/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
joined="$*"
if [[ -f "$MOCK_LOG_DIR/provision.attempted" \
    && "$joined" == *'.backup-operation.lock.preserve'* ]]; then
  exit 51
fi
exec /bin/mv "$@"
EOF
  chmod 0700 "$CASE_DIR/bin/mv"
  cat > "$CASE_DIR/locked-restore" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "\$BACKUP_BASH_BIN" "\$BACKUP_SCRIPT_PATH" restore "$backup" \
  --confirm 'RESTORE:address_atlas_sync'
EOF
  chmod 0700 "$CASE_DIR/locked-restore"
  MOCK_RUNTIME_RELOCK_EXIT=42
  ALLOW_RESTORE='YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED'
  MOCK_WEB_RUNNING=0
  run_backup_capture lock-run -- "$CASE_DIR/locked-restore"
  assert_status "$CAPTURE_STATUS" 75 'failed recovery-marker parent signal status'
  assert_path_exists "$BACKUP_DIR/.backup-operation.lock" \
    'outer lock-run released lock after recovery-marker persistence failed'
  assert_path_absent "$BACKUP_DIR/.backup-operation.lock.preserve" \
    'recovery-marker failure test unexpectedly persisted the marker'
  assert_file_contains "$CASE_DIR/stderr" 'could not persist its recovery marker' \
    'outer lock-run did not explain reserved child recovery status'
}

prepare_bootstrap_fixture() {
  install_backup_fakes
  BOOTSTRAP_BACKUP="$CASE_DIR/bootstrap-source.dump.age"
  make_backup_fixture "$BOOTSTRAP_BACKUP"
  EXPECTED_BACKUP_SHA="$(sha256_for_test "$BOOTSTRAP_BACKUP")"
  ALLOW_BOOTSTRAP_RESTORE='YES_I_UNDERSTAND_FRESH_CLUSTER_ONLY'
  ALLOW_BOOTSTRAP_LOCK_RECLAIM='YES_I_VERIFIED_STALE_OWNER'
  BOOTSTRAP_FINALIZE_ACK='PUBLIC_SMOKE_AND_RECEIPT_PERSISTED'
  MOCK_WEB_RUNNING=0
  MOCK_SOURCE_CLASSIFICATION='brand-new-empty'
}

write_bootstrap_manager() {
  BOOTSTRAP_MANAGER="$CASE_DIR/bootstrap-manager"
  cat > "$BOOTSTRAP_MANAGER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
backup="$1"
if [[ -n "${ADDRESS_ATLAS_BOOTSTRAP_TARGET_REVISION:-}" ]]; then
  [[ "$ADDRESS_ATLAS_BOOTSTRAP_TARGET_REVISION" \
      == 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' ]]
  helper_dir="$(cd "$(dirname "$0")" && pwd)"
  printf '%s\n' "$ADDRESS_ATLAS_BOOTSTRAP_TARGET_REVISION" \
    > "$helper_dir/log/bootstrap.resume-revision"
fi
"$BACKUP_BASH_BIN" "$BACKUP_SCRIPT_PATH" bootstrap-restore "$backup" \
  --confirm 'BOOTSTRAP-RESTORE:address_atlas_sync'
"$BACKUP_BASH_BIN" "$BACKUP_SCRIPT_PATH" bootstrap-finalize \
  --confirm 'BOOTSTRAP-FINALIZE:address_atlas_sync'
EOF
  chmod 0700 "$BOOTSTRAP_MANAGER"
}

write_bootstrap_finalize_manager() {
  BOOTSTRAP_FINALIZE_MANAGER="$CASE_DIR/bootstrap-finalize-manager"
  cat > "$BOOTSTRAP_FINALIZE_MANAGER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$ADDRESS_ATLAS_BOOTSTRAP_TARGET_REVISION" \
    == 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' ]]
exec "$BACKUP_BASH_BIN" "$BACKUP_SCRIPT_PATH" bootstrap-finalize \
  --confirm 'BOOTSTRAP-FINALIZE:address_atlas_sync'
EOF
  chmod 0700 "$BOOTSTRAP_FINALIZE_MANAGER"
}

test_backup_inspect_contract_and_native_boundaries() {
  local backup completed_epoch digest expected_line future_timestamp version
  new_case
  install_backup_fakes
  backup="$CASE_DIR/source.dump.age"
  make_backup_fixture "$backup"
  digest="$(sha256_for_test "$backup")"
  expected_line="BACKUP_METADATA|4|${digest}|address_atlas_sync|5|ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff|1784505600000|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc|3|2026-07-20T16:00:00Z"
  run_backup_capture inspect "$backup"
  assert_status "$CAPTURE_STATUS" 0 'schema-v4 inspect status'
  assert_file_equals "$CASE_DIR/stdout" "$expected_line" \
    'schema-v4 inspect machine contract'
  assert_file_equals "$CASE_DIR/stderr" '' 'schema-v4 inspect stderr'

  new_case
  install_backup_fakes
  backup="$CASE_DIR/source-v3.dump.age"
  make_backup_fixture "$backup" 3 3
  digest="$(sha256_for_test "$backup")"
  run_backup_capture inspect "$backup"
  assert_status "$CAPTURE_STATUS" 0 'schema-v3 inspect compatibility status'
  assert_file_equals "$CASE_DIR/stdout" \
    "BACKUP_METADATA|3|${digest}|address_atlas_sync|-|-|-|-|sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc|3|2026-07-20T16:00:00Z" \
    'schema-v3 inspect compatibility contract'

  for version in 4 2000000001; do
    new_case
    install_backup_fakes
    backup="$CASE_DIR/native-${version}.dump.age"
    make_backup_fixture "$backup"
    rewrite_and_resign_manifest "$backup" \
      "s/\"nativeConfigVersion\": 5/\"nativeConfigVersion\": ${version}/"
    run_backup_capture inspect "$backup"
    assert_status "$CAPTURE_STATUS" 65 \
      "out-of-domain native-config version ${version} status"
  done

  new_case
  install_backup_fakes
  backup="$CASE_DIR/native-max.dump.age"
  make_backup_fixture "$backup"
  rewrite_and_resign_manifest "$backup" \
    's/"nativeConfigVersion": 5/"nativeConfigVersion": 2000000000/'
  run_backup_capture inspect "$backup"
  assert_status "$CAPTURE_STATUS" 0 'maximum native-config version status'
  assert_file_contains "$CASE_DIR/stdout" '|2000000000|' \
    'maximum native-config version inspect output'

  new_case
  install_backup_fakes
  backup="$CASE_DIR/native-future.dump.age"
  make_backup_fixture "$backup"
  completed_epoch="$(iso8601_epoch_for_test '2026-07-20T16:00:00Z')"
  future_timestamp=$((completed_epoch * 1000 + 300001))
  rewrite_and_resign_manifest "$backup" \
    "s/\"nativeConfigUpdatedAtEpochMs\": 1784505600000/\"nativeConfigUpdatedAtEpochMs\": ${future_timestamp}/"
  run_backup_capture inspect "$backup"
  assert_status "$CAPTURE_STATUS" 65 \
    'future native-config manifest inspect status'
  assert_file_contains "$CASE_DIR/stderr" \
    'exceeds snapshot completion plus allowed clock skew' \
    'future native-config manifest inspect rejection message'
}

test_bootstrap_restore_gates_and_managed_success() {
  local backup receipt bootstrap_digest
  new_case
  prepare_bootstrap_fixture
  write_bootstrap_manager
  bootstrap_digest="$(sha256_for_test "$CASE_DIR/bootstrap-database-roles.sh")"
  run_backup_capture lock-run -- "$BOOTSTRAP_MANAGER" "$BOOTSTRAP_BACKUP"
  assert_status "$CAPTURE_STATUS" 0 'managed bootstrap restore status'
  receipt="$(grep '^BOOTSTRAP_RESTORE_RECEIPT|' "$CASE_DIR/stdout" || true)"
  [[ -n "$receipt" && "$(awk -F '|' '{print NF}' <<< "$receipt")" -eq 18 ]] \
    || fail 'managed bootstrap receipt field count'
  [[ "$receipt" == *"|${bootstrap_digest}" ]] \
    || fail 'managed bootstrap receipt omitted the bound bootstrap source digest'
  assert_file_contains "$CASE_DIR/stdout" \
    "Bootstrap restore finalized for address_atlas_sync at artifact ${EXPECTED_BACKUP_SHA}." \
    'managed bootstrap finalize output'
  assert_file_contains "$CASE_DIR/log/restore-provision.modes" ':bootstrap' \
    'managed bootstrap did not use bootstrap role provisioning'
  assert_path_exists "$CASE_DIR/log/bootstrap.cutover" \
    'managed bootstrap did not atomically cut over'
  assert_path_absent "$BACKUP_DIR/.bootstrap-restore.state" \
    'managed bootstrap left finalized state'
  assert_path_absent "$BACKUP_DIR/.backup-operation.lock" \
    'managed bootstrap released state before its operation lock'

  new_case
  prepare_bootstrap_fixture
  backup="$CASE_DIR/schema-v3.dump.age"
  make_backup_fixture "$backup" 3 3
  EXPECTED_BACKUP_SHA="$(sha256_for_test "$backup")"
  run_backup_capture bootstrap-restore "$backup" \
    --confirm 'BOOTSTRAP-RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 65 'schema-v3 bootstrap rejection status'
  assert_file_contains "$CASE_DIR/stderr" 'requires a signed schema-v4' \
    'schema-v3 bootstrap rejection message'
  assert_path_absent "$BACKUP_DIR/.bootstrap-restore.state" \
    'schema-v3 bootstrap mutated recovery state'

  new_case
  prepare_bootstrap_fixture
  EXPECTED_BACKUP_SHA='dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
  run_backup_capture bootstrap-restore "$BOOTSTRAP_BACKUP" \
    --confirm 'BOOTSTRAP-RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 65 'bootstrap digest pin mismatch status'
  assert_path_absent "$BACKUP_DIR/.bootstrap-restore.state" \
    'bootstrap digest mismatch mutated recovery state'

  new_case
  prepare_bootstrap_fixture
  MOCK_BOOTSTRAP_SYSTEM_DATABASE_RESULT=invalid
  run_backup_capture bootstrap-restore "$BOOTSTRAP_BACKUP" \
    --confirm 'BOOTSTRAP-RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 65 'non-pristine system database rejection status'
  assert_file_contains "$CASE_DIR/stderr" 'exact pristine dedicated PostgreSQL cluster' \
    'non-pristine system database rejection message'
  assert_path_absent "$BACKUP_DIR/.bootstrap-restore.state" \
    'non-pristine system database mutated recovery state'
}

test_bootstrap_rejects_contaminated_template_staging() {
  new_case
  prepare_bootstrap_fixture
  : > "$CASE_DIR/log/bootstrap.contaminated-staging"
  run_backup_capture bootstrap-restore "$BOOTSTRAP_BACKUP" \
    --confirm 'BOOTSTRAP-RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 65 'contaminated template staging rejection status'
  assert_file_contains "$CASE_DIR/stderr" \
    'inherited non-pristine template content' \
    'contaminated template staging rejection message'
  assert_path_absent "$CASE_DIR/log/restore-validation.args" \
    'contaminated template staging reached restore migration/readiness'
  assert_file_contains "$BACKUP_DIR/.bootstrap-restore.state" 'phase=staging' \
    'contaminated template staging lost resumable state'
  assert_path_exists "$BACKUP_DIR/.backup-operation.lock" \
    'contaminated template staging released its recovery lock'

  find "$BACKUP_DIR/.backup-operation.lock" \
    "$BACKUP_DIR/.backup-operation.lock.preserve" -maxdepth 0 -type f -delete
  run_backup_capture create
  assert_status "$CAPTURE_STATUS" 75 'unfinished bootstrap blocks create status'
  assert_file_contains "$CASE_DIR/stderr" 'unfinished bootstrap restore blocks' \
    'unfinished bootstrap create block message'
}

test_bootstrap_fault_recovery_boundaries() {
  new_case
  prepare_bootstrap_fixture
  write_bootstrap_manager
  : > "$CASE_DIR/log/bootstrap.fail-migration"
  run_backup_capture bootstrap-restore "$BOOTSTRAP_BACKUP" \
    --confirm 'BOOTSTRAP-RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 74 'pre-role migration fault status'
  assert_file_contains "$BACKUP_DIR/.bootstrap-restore.state" 'phase=staging' \
    'pre-role migration fault phase'
  assert_path_absent "$CASE_DIR/log/bootstrap.provisioned" \
    'pre-role migration fault reached role split'
  find "$CASE_DIR/log/bootstrap.fail-migration" -maxdepth 0 -type f -delete
  run_backup_capture bootstrap-lock-run -- "$BOOTSTRAP_MANAGER" "$BOOTSTRAP_BACKUP"
  assert_status "$CAPTURE_STATUS" 0 'pre-role migration fault resume status'
  assert_file_equals "$CASE_DIR/log/bootstrap.resume-revision" \
    'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' \
    'bootstrap reclaim did not export the exact state-bound target revision'
  assert_path_absent "$BACKUP_DIR/.bootstrap-restore.state" \
    'pre-role migration resume left state'
  assert_path_absent "$BACKUP_DIR/.backup-operation.lock" \
    'pre-role migration resume left lock'

  new_case
  prepare_bootstrap_fixture
  write_bootstrap_manager
  : > "$CASE_DIR/log/bootstrap.fail-after-provision"
  run_backup_capture bootstrap-restore "$BOOTSTRAP_BACKUP" \
    --confirm 'BOOTSTRAP-RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 74 'post-role provisioning fault status'
  assert_file_contains "$BACKUP_DIR/.bootstrap-restore.state" 'phase=provisioning' \
    'post-role provisioning fault phase'
  assert_path_exists "$CASE_DIR/log/bootstrap.provisioned" \
    'post-role provisioning fault did not reach role split boundary'
  assert_path_exists "$CASE_DIR/log/runtime.nologin" \
    'post-role provisioning fault did not fail closed with runtime NOLOGIN'
  find "$CASE_DIR/log/bootstrap.fail-after-provision" -maxdepth 0 -type f -delete
  run_backup_capture bootstrap-lock-run -- "$BOOTSTRAP_MANAGER" "$BOOTSTRAP_BACKUP"
  assert_status "$CAPTURE_STATUS" 0 'post-role provisioning fault resume status'
  assert_file_contains "$CASE_DIR/log/restore-provision.modes" ':restore' \
    'post-role provisioning resume did not converge through steady provisioning'
  assert_path_absent "$CASE_DIR/log/runtime.nologin" \
    'post-role provisioning resume left runtime NOLOGIN'

  new_case
  prepare_bootstrap_fixture
  write_bootstrap_manager
  : > "$CASE_DIR/log/bootstrap.fail-after-provision"
  run_backup_capture bootstrap-restore "$BOOTSTRAP_BACKUP" \
    --confirm 'BOOTSTRAP-RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 74 'post-split bridge seed status'
  find "$CASE_DIR/log/bootstrap.fail-after-provision" \
    "$CASE_DIR/log/bootstrap.provisioned" -maxdepth 0 -type f -delete
  : > "$CASE_DIR/log/bootstrap.bridge-post-split"
  run_backup_capture bootstrap-lock-run -- "$BOOTSTRAP_MANAGER" "$BOOTSTRAP_BACKUP"
  assert_status "$CAPTURE_STATUS" 0 'post-split bridge resume status'
  assert_file_contains "$CASE_DIR/log/restore-provision.modes" ':restore' \
    'post-split bridge resume did not use steady convergence'
  assert_path_absent "$CASE_DIR/log/bootstrap.bridge-post-split" \
    'post-split bridge resume left the reserved bridge marker'

  new_case
  prepare_bootstrap_fixture
  write_bootstrap_manager
  : > "$CASE_DIR/log/bootstrap.fail-after-cutover"
  run_backup_capture bootstrap-restore "$BOOTSTRAP_BACKUP" \
    --confirm 'BOOTSTRAP-RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 74 'post-cutover commit fault status'
  assert_file_contains "$BACKUP_DIR/.bootstrap-restore.state" 'phase=cutover' \
    'post-cutover commit fault phase'
  assert_path_exists "$CASE_DIR/log/bootstrap.cutover" \
    'post-cutover commit fault did not commit cutover'
  assert_path_exists "$CASE_DIR/log/runtime.nologin" \
    'post-cutover commit fault did not fail closed with runtime NOLOGIN'
  find "$CASE_DIR/log/bootstrap.fail-after-cutover" -maxdepth 0 -type f -delete
  run_backup_capture bootstrap-lock-run -- "$BOOTSTRAP_MANAGER" "$BOOTSTRAP_BACKUP"
  assert_status "$CAPTURE_STATUS" 0 'post-cutover commit fault resume status'
  assert_file_contains "$CASE_DIR/log/restore-provision.modes" ':restore' \
    'post-cutover commit resume did not restore runtime privileges'
  assert_path_absent "$BACKUP_DIR/.bootstrap-restore.state" \
    'post-cutover commit resume left state'
  assert_path_absent "$BACKUP_DIR/.backup-operation.lock" \
    'post-cutover commit resume left lock'
}

test_bootstrap_pre_split_drift_fails_closed() {
  local drift
  for drift in role database object; do
    new_case
    prepare_bootstrap_fixture
    write_bootstrap_manager
    : > "$CASE_DIR/log/bootstrap.fail-before-provision"
    run_backup_capture bootstrap-restore "$BOOTSTRAP_BACKUP" \
      --confirm 'BOOTSTRAP-RESTORE:address_atlas_sync'
    assert_status "$CAPTURE_STATUS" 74 \
      "pre-split ${drift} drift seed status"
    assert_file_contains "$BACKUP_DIR/.bootstrap-restore.state" 'phase=provisioning' \
      "pre-split ${drift} drift seed phase"
    assert_path_absent "$CASE_DIR/log/bootstrap.provisioned" \
      "pre-split ${drift} drift seed crossed role split"
    find "$CASE_DIR/log/bootstrap.fail-before-provision" -maxdepth 0 -type f -delete
    MOCK_BOOTSTRAP_PRISTINE_RESULT=invalid
    MOCK_BOOTSTRAP_PRE_SPLIT_RESULT=invalid
    if [[ "$drift" == object ]]; then
      MOCK_BOOTSTRAP_SYSTEM_DATABASE_RESULT=invalid
    fi
    run_backup_capture bootstrap-lock-run -- "$BOOTSTRAP_MANAGER" "$BOOTSTRAP_BACKUP"
    assert_status "$CAPTURE_STATUS" 75 \
      "pre-split ${drift} drift resume status"
    assert_path_absent "$CASE_DIR/log/bootstrap.provisioned" \
      "pre-split ${drift} drift triggered irreversible role split"
    assert_file_contains "$CASE_DIR/stderr" 'unrecognized control-plane state' \
      "pre-split ${drift} drift fail-closed message"
    assert_path_exists "$BACKUP_DIR/.backup-operation.lock" \
      "pre-split ${drift} drift released recovery lock"
    assert_path_exists "$BACKUP_DIR/.backup-operation.lock.preserve" \
      "pre-split ${drift} drift omitted recovery marker"
  done
}

test_bootstrap_finalized_no_lock_dead_claim_closes_safely() {
  local state_file lock_file claim_file temporary
  new_case
  prepare_bootstrap_fixture
  write_bootstrap_finalize_manager
  run_backup_capture bootstrap-restore "$BOOTSTRAP_BACKUP" \
    --confirm 'BOOTSTRAP-RESTORE:address_atlas_sync'
  assert_status "$CAPTURE_STATUS" 0 'standalone bootstrap awaiting-finalize status'
  state_file="$BACKUP_DIR/.bootstrap-restore.state"
  lock_file="$BACKUP_DIR/.backup-operation.lock"
  claim_file="$BACKUP_DIR/.bootstrap-lock-reclaim"
  assert_file_contains "$state_file" 'phase=awaiting-finalize' \
    'standalone bootstrap awaiting-finalize phase'
  temporary="${state_file}.test-finalized"
  sed 's/^phase=awaiting-finalize$/phase=finalized/' "$state_file" > "$temporary"
  chmod 0600 "$temporary"
  mv "$temporary" "$state_file"
  cp "$lock_file" "$claim_file"
  chmod 0600 "$claim_file"
  find "$lock_file" -maxdepth 0 -type f -delete
  run_backup_capture bootstrap-lock-run -- "$BOOTSTRAP_FINALIZE_MANAGER"
  assert_status "$CAPTURE_STATUS" 0 'finalized no-lock dead-claim closure status'
  assert_path_absent "$state_file" \
    'finalized no-lock closure left state'
  assert_path_absent "$lock_file" \
    'finalized no-lock closure left operation lock'
  assert_path_absent "$claim_file" \
    'finalized no-lock closure left reclaim claim'
  assert_file_contains "$CASE_DIR/stdout" \
    "Bootstrap restore finalized for address_atlas_sync at artifact ${EXPECTED_BACKUP_SHA}." \
    'finalized no-lock closure output'
}

install_psql_fake() {
  cat > "$CASE_DIR/bin/psql" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_LOG_DIR:?}"
{
  printf 'psql '
  printf '%q ' "$@"
  printf '\n'
} > "$MOCK_LOG_DIR/psql.argv"
printf '%s' "${PGPASSWORD:-}" > "$MOCK_LOG_DIR/psql.password"
case " $* " in
  *' --username address_atlas_runtime '*' --command SELECT current_user; '*)
    : > "$MOCK_LOG_DIR/psql.stdin"
    if [[ "${MOCK_PSQL_RUNTIME_EXIT:-0}" != '0' ]]; then
      printf '%s\n' "${MOCK_PSQL_STDERR:-}" >&2
    fi
    printf '%s\n' address_atlas_runtime
    exit "${MOCK_PSQL_RUNTIME_EXIT:-0}"
    ;;
esac
/bin/cat > "$MOCK_LOG_DIR/psql.stdin"
if [[ "${MOCK_PSQL_EXIT:-0}" != '0' ]]; then
  printf '%s\n' "${MOCK_PSQL_STDERR:-}" >&2
  exit "$MOCK_PSQL_EXIT"
fi
EOF
  chmod 0700 "$CASE_DIR/bin/psql"
}

run_provision_capture() {
  local runtime_password="$1"
  local desired_admin_password="$2"
  local current_admin_password="$3"
  local owner_password_decoy="$4"
  local provision_mode="${5:-steady}"
  local trace_mode="${6:-false}"
  local -a shell_command=(/bin/sh)
  [[ "$trace_mode" != true ]] || shell_command+=(-x)
  set +e
  env -i \
    PATH="$CASE_DIR/bin:/usr/bin:/bin" \
    HOME="$CASE_DIR/home" \
    MOCK_LOG_DIR="$CASE_DIR/log" \
    MOCK_PSQL_EXIT="${MOCK_PROVISION_PSQL_EXIT:-0}" \
    MOCK_PSQL_RUNTIME_EXIT="${MOCK_PROVISION_PSQL_RUNTIME_EXIT:-0}" \
    MOCK_PSQL_STDERR="${MOCK_PROVISION_PSQL_STDERR:-}" \
    ADDRESS_ATLAS_DATABASE_ROLE_MODE="$provision_mode" \
    POSTGRES_RUNTIME_PASSWORD="$runtime_password" \
    POSTGRES_ADMIN_PASSWORD="$desired_admin_password" \
    POSTGRES_ADMIN_CURRENT_PASSWORD="$current_admin_password" \
    POSTGRES_PASSWORD="$owner_password_decoy" \
    POSTGRES_DB=address_atlas_sync \
    PGHOST='postgres.test' \
    PGPORT=5432 \
    PSQL_BIN="$CASE_DIR/bin/psql" \
    "${shell_command[@]}" "$PROVISION_SCRIPT" \
      > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr"
  CAPTURE_STATUS=$?
  set -e
}

test_provision_password_validation() {
  local valid_runtime='RuntimeServiceSecret_3Ld8Qw5Nz7Rx2Km9'
  local valid_admin='AdminControlSecret_4Fx8Lm2Qs7Vz9Tr5'
  local current_admin='CurrentAdminSecret_7Hs2Lm9Qx4Zv8Nk6'
  local owner_decoy='OWNER_PASSWORD_MUST_NOT_BE_USED_72cd'
  local short_password invalid_password long_password candidate
  new_case
  install_psql_fake
  short_password="$(printf 'a%.0s' {1..31})"
  invalid_password="$(printf 'a%.0s' {1..31})!"
  long_password="$(printf 'a%.0s' {1..129})"
  for candidate in '' "$short_password" "$invalid_password" "$long_password" 'replace_me_with_password'; do
    find "$CASE_DIR/log" -type f -delete
    run_provision_capture "$candidate" "$valid_admin" "$current_admin" "$owner_decoy"
    assert_status "$CAPTURE_STATUS" 65 'invalid runtime password exit status'
    assert_path_absent "$CASE_DIR/log/psql.argv" 'psql ran for an invalid runtime password'
  done
  for candidate in '' "$short_password" "$invalid_password" "$long_password" 'example_admin_password_value_12345'; do
    find "$CASE_DIR/log" -type f -delete
    run_provision_capture "$valid_runtime" "$candidate" "$current_admin" "$owner_decoy"
    assert_status "$CAPTURE_STATUS" 65 'invalid admin password exit status'
    assert_path_absent "$CASE_DIR/log/psql.argv" 'psql ran for an invalid admin password'
  done
}

test_provision_steady_admin_only_secret_safety() {
  local runtime_password='RuntimeServiceSecret_3Ld8Qw5Nz7Rx2Km9'
  local desired_admin_password='AdminControlSecret_4Fx8Lm2Qs7Vz9Tr5'
  local current_admin_password="$desired_admin_password"
  local owner_password_decoy='OWNER_PASSWORD_MUST_NOT_BE_USED_72cd'
  new_case
  install_psql_fake
  MOCK_PROVISION_PSQL_EXIT=0
  run_provision_capture "$runtime_password" "$desired_admin_password" \
    "$current_admin_password" "$owner_password_decoy"
  assert_status "$CAPTURE_STATUS" 0 'steady runtime role provisioning exit status'
  assert_file_equals "$CASE_DIR/stdout" \
    'Validated isolated admin/owner roles and the exact address_atlas_runtime privilege contract.' \
    'runtime role success output'
  assert_file_equals "$CASE_DIR/stderr" '' 'runtime role provisioning stderr'
  assert_file_contains "$CASE_DIR/log/psql.argv" '--host postgres.test' 'psql host argument'
  assert_file_contains "$CASE_DIR/log/psql.argv" '--port 5432' 'psql port argument'
  assert_file_contains "$CASE_DIR/log/psql.argv" '--username address_atlas_admin' 'psql admin argument'
  assert_file_contains "$CASE_DIR/log/psql.argv" '--dbname address_atlas_sync' 'psql database argument'
  assert_file_equals "$CASE_DIR/log/psql.password" "$current_admin_password" 'current admin credential was not used for authentication'
  for secret in "$runtime_password" "$desired_admin_password" "$current_admin_password" "$owner_password_decoy"; do
    assert_file_not_contains "$CASE_DIR/log/psql.argv" "$secret" 'database secret leaked to psql argv'
    assert_file_not_contains "$CASE_DIR/stdout" "$secret" 'database secret leaked to stdout'
    assert_file_not_contains "$CASE_DIR/stderr" "$secret" 'database secret leaked to stderr'
  done
  assert_file_not_contains "$CASE_DIR/log/psql.stdin" "$desired_admin_password" \
    'steady mode sent the admin credential into SQL'
  assert_file_not_contains "$CASE_DIR/log/psql.stdin" "$runtime_password" \
    'steady mode sent the runtime credential into SQL'
  assert_file_not_contains "$CASE_DIR/log/psql.stdin" "$owner_password_decoy" 'owner fallback password entered SQL stdin'
  assert_file_contains "$CASE_DIR/log/psql.stdin" "current_user <> 'address_atlas_admin'" 'direct admin authentication preflight'
  assert_file_contains "$CASE_DIR/log/psql.stdin" 'REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public' 'ambient DML revocation'
  assert_file_contains "$CASE_DIR/log/psql.stdin" 'GRANT SELECT ON TABLE public.sync_schema_migrations TO address_atlas_runtime;' 'migration ledger grant'
  assert_file_contains "$CASE_DIR/log/psql.stdin" 'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.users TO address_atlas_runtime;' 'users exact grant'
  assert_file_contains "$CASE_DIR/log/psql.stdin" 'GRANT SELECT, INSERT ON TABLE public.account_deletion_receipts TO address_atlas_runtime;' 'deletion receipt exact grant'
  assert_file_not_contains "$CASE_DIR/log/psql.stdin" 'GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES' 'broad runtime table grant remains'
}

test_provision_restore_secret_transport() {
  local runtime_password='RuntimeServiceSecret_3Ld8Qw5Nz7Rx2Km9'
  local admin_password='AdminControlSecret_4Fx8Lm2Qs7Vz9Tr5'
  local owner_decoy='OWNER_PASSWORD_MUST_NOT_BE_USED_72cd'
  new_case
  install_psql_fake
  run_provision_capture "$runtime_password" "$admin_password" \
    "$admin_password" "$owner_decoy" restore true
  assert_status "$CAPTURE_STATUS" 0 'restore credential transport status'
  assert_file_contains "$CASE_DIR/log/psql.stdin" \
    'COPY pg_temp.address_atlas_role_secrets' \
    'restore did not use COPY data transport for credentials'
  assert_file_contains "$CASE_DIR/log/psql.stdin" \
    $'admin_password\t'"$admin_password" \
    'restore admin credential was not transported as COPY data'
  assert_file_contains "$CASE_DIR/log/psql.stdin" \
    $'runtime_password\t'"$runtime_password" \
    'restore runtime credential was not transported as COPY data'
  assert_file_not_contains "$CASE_DIR/log/psql.stdin" \
    "\\set admin_password ${admin_password}" \
    'restore expanded the admin credential into psql statement text'
  assert_file_not_contains "$CASE_DIR/log/psql.stdin" \
    "PASSWORD '${runtime_password}'" \
    'restore expanded the runtime credential into SQL statement text'
  assert_file_contains "$CASE_DIR/log/psql.stdin" \
    "SET SESSION pg_stat_statements.track = 'none';" \
    'restore did not disable nested statement statistics before COPY'
  assert_file_contains "$CASE_DIR/log/psql.stdin" \
    'SET SESSION pgaudit.log_statement = off;' \
    'restore did not redact audit statement text before COPY'
  for secret in "$runtime_password" "$admin_password" "$owner_decoy"; do
    assert_file_not_contains "$CASE_DIR/stderr" "$secret" \
      'restore shell tracing disclosed a database credential'
  done
}

test_provision_bad_admin_never_falls_back_to_owner() {
  local runtime_password='RuntimeServiceSecret_3Ld8Qw5Nz7Rx2Km9'
  local desired_admin_password='WrongAdminCredential_2Qx7Nv4Ls8Jm5Tk9'
  local wrong_admin_password="$desired_admin_password"
  local owner_password_decoy='OWNER_PASSWORD_WOULD_SUCCEED_IF_USED_72cd'
  new_case
  install_psql_fake
  MOCK_PROVISION_PSQL_EXIT=28
  run_provision_capture "$runtime_password" "$desired_admin_password" \
    "$wrong_admin_password" "$owner_password_decoy"
  [[ "$CAPTURE_STATUS" -ne 0 ]] || fail 'bad admin credential silently succeeded'
  assert_file_equals "$CASE_DIR/log/psql.password" "$wrong_admin_password" 'steady mode did not use the supplied admin credential'
  assert_file_not_contains "$CASE_DIR/log/psql.argv" "$owner_password_decoy" 'owner fallback secret leaked to argv'
  assert_file_not_contains "$CASE_DIR/stdout" "$owner_password_decoy" 'owner fallback secret leaked to stdout'
  assert_file_not_contains "$CASE_DIR/stderr" "$owner_password_decoy" 'owner fallback secret leaked to stderr'
}

test_provision_failure_diagnostics_are_secret_safe() {
  local runtime_password='RuntimeServiceSecret_3Ld8Qw5Nz7Rx2Km9'
  local admin_password='AdminControlSecret_4Fx8Lm2Qs7Vz9Tr5'
  local owner_decoy='OWNER_PASSWORD_MUST_NOT_BE_USED_72cd'
  local leaked_detail='psql expanded secret: RuntimeServiceSecret_3Ld8Qw5Nz7Rx2Km9'
  new_case
  install_psql_fake
  MOCK_PROVISION_PSQL_RUNTIME_EXIT=28
  MOCK_PROVISION_PSQL_STDERR="$leaked_detail"
  run_provision_capture "$runtime_password" "$admin_password" \
    "$admin_password" "$owner_decoy"
  assert_status "$CAPTURE_STATUS" 65 'runtime authentication diagnostic status'
  assert_file_contains "$CASE_DIR/stderr" \
    'ROLE_PROVISION_FAILED mode=steady stage=runtime-auth' \
    'runtime authentication failure lacked a fixed diagnostic marker'
  assert_file_not_contains "$CASE_DIR/stderr" "$leaked_detail" \
    'runtime authentication leaked raw psql stderr'

  new_case
  install_psql_fake
  MOCK_PROVISION_PSQL_RUNTIME_EXIT=0
  MOCK_PROVISION_PSQL_EXIT=28
  MOCK_PROVISION_PSQL_STDERR="$leaked_detail"
  run_provision_capture "$runtime_password" "$admin_password" \
    "$admin_password" "$owner_decoy"
  assert_status "$CAPTURE_STATUS" 74 'convergence transaction diagnostic status'
  assert_file_contains "$CASE_DIR/stderr" \
    'ROLE_PROVISION_FAILED mode=steady stage=convergence-transaction' \
    'convergence failure lacked a fixed diagnostic marker'
  assert_file_not_contains "$CASE_DIR/stderr" "$leaked_detail" \
    'convergence transaction leaked raw psql stderr'
}

install_bootstrap_psql_failure_fake() {
  cat > "$CASE_DIR/bin/psql" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_LOG_DIR:?}"
call=1
if [[ -f "$MOCK_LOG_DIR/psql.calls" ]]; then
  call=$(( $(< "$MOCK_LOG_DIR/psql.calls") + 1 ))
fi
printf '%s\n' "$call" > "$MOCK_LOG_DIR/psql.calls"
/bin/cat >/dev/null
if [[ "$call" -eq "${MOCK_PSQL_FAIL_CALL:?}" ]]; then
  printf '%s\n' "${MOCK_PSQL_STDERR:?}" >&2
  exit 28
fi
EOF
  chmod 0700 "$CASE_DIR/bin/psql"
}

run_bootstrap_provision_capture() {
  local fail_call="$1"
  local leaked_detail="$2"
  local trace_mode="${3:-false}"
  local -a shell_command=(/bin/sh)
  [[ "$trace_mode" != true ]] || shell_command+=(-x)
  set +e
  env -i \
    PATH="$CASE_DIR/bin:/usr/bin:/bin" \
    HOME="$CASE_DIR/home" \
    MOCK_LOG_DIR="$CASE_DIR/log" \
    MOCK_PSQL_FAIL_CALL="$fail_call" \
    MOCK_PSQL_STDERR="$leaked_detail" \
    ADDRESS_ATLAS_DATABASE_ROLE_MODE=bootstrap \
    POSTGRES_PASSWORD='OwnerBootstrapSecret_7Gm2Qv9Lx4Np8Yk6' \
    POSTGRES_ADMIN_PASSWORD='AdminControlSecret_4Fx8Lm2Qs7Vz9Tr5' \
    POSTGRES_RUNTIME_PASSWORD='RuntimeServiceSecret_3Ld8Qw5Nz7Rx2Km9' \
    POSTGRES_DB=address_atlas_sync \
    PGHOST='postgres.test' \
    PGPORT=5432 \
    PSQL_BIN="$CASE_DIR/bin/psql" \
    "${shell_command[@]}" "$BOOTSTRAP_ROLE_SCRIPT" \
      > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr"
  CAPTURE_STATUS=$?
  set -e
}

test_bootstrap_failure_diagnostics_are_secret_safe() {
  local leaked_detail='psql expanded secret: OwnerBootstrapSecret_7Gm2Qv9Lx4Np8Yk6'
  new_case
  install_bootstrap_psql_failure_fake
  run_bootstrap_provision_capture 1 "$leaked_detail" true
  assert_status "$CAPTURE_STATUS" 74 'bridge creation diagnostic status'
  assert_file_contains "$CASE_DIR/stderr" \
    'ROLE_PROVISION_FAILED mode=bootstrap stage=bridge-create' \
    'bridge creation failure lacked a fixed diagnostic marker'
  assert_file_not_contains "$CASE_DIR/stderr" "$leaked_detail" \
    'bridge creation leaked raw psql stderr'
  assert_file_not_contains "$CASE_DIR/stderr" \
    'OwnerBootstrapSecret_7Gm2Qv9Lx4Np8Yk6' \
    'bridge creation shell tracing disclosed the owner credential'
  assert_file_not_contains "$CASE_DIR/stderr" \
    'AdminControlSecret_4Fx8Lm2Qs7Vz9Tr5' \
    'bridge creation shell tracing disclosed the admin credential'
  assert_file_not_contains "$CASE_DIR/stderr" \
    'RuntimeServiceSecret_3Ld8Qw5Nz7Rx2Km9' \
    'bridge creation shell tracing disclosed the runtime credential'

  new_case
  install_bootstrap_psql_failure_fake
  run_bootstrap_provision_capture 2 "$leaked_detail" true
  assert_status "$CAPTURE_STATUS" 74 'role split diagnostic status'
  assert_file_contains "$CASE_DIR/stderr" \
    'ROLE_PROVISION_FAILED mode=bootstrap stage=role-split' \
    'role split failure lacked a fixed diagnostic marker'
  assert_file_not_contains "$CASE_DIR/stderr" "$leaked_detail" \
    'role split leaked raw psql stderr'
  assert_file_not_contains "$CASE_DIR/stderr" \
    'OwnerBootstrapSecret_7Gm2Qv9Lx4Np8Yk6' \
    'role split shell tracing disclosed the owner credential'
  assert_file_not_contains "$CASE_DIR/stderr" \
    'AdminControlSecret_4Fx8Lm2Qs7Vz9Tr5' \
    'role split shell tracing disclosed the admin credential'
  assert_file_not_contains "$CASE_DIR/stderr" \
    'RuntimeServiceSecret_3Ld8Qw5Nz7Rx2Km9' \
    'role split shell tracing disclosed the runtime credential'
}

test_secret_entrypoints_disable_shell_trace() {
  local owner_secret='OwnerTraceSentinel_7Gm2Qv9Lx4Np8Yk6'
  local admin_secret='AdminTraceSentinel_4Fx8Lm2Qs7Vz9Tr5'
  local runtime_secret='RuntimeTraceSentinel_3Ld8Qw5Nz7Rx2Km9'
  local script output status secret
  local -a scripts=(
    "$BACKUP_SCRIPT"
    "$SCRIPT_DIR/manage-prod.sh"
    "$SCRIPT_DIR/provision-restored-database.sh"
    "$SCRIPT_DIR/migrate-restored-database.sh"
    "$PROVISION_SCRIPT"
    "$BOOTSTRAP_ROLE_SCRIPT"
  )
  new_case
  for script in "${scripts[@]}"; do
    output="$CASE_DIR/$(basename "$script").trace"
    status=0
    env -i \
      PATH=/usr/bin:/bin \
      HOME="$CASE_DIR/home" \
      POSTGRES_PASSWORD="$owner_secret" \
      POSTGRES_ADMIN_PASSWORD="$admin_secret" \
      POSTGRES_ADMIN_CURRENT_PASSWORD="$admin_secret" \
      POSTGRES_RUNTIME_PASSWORD="$runtime_secret" \
      "$OPS_TEST_BASH_BIN" -x "$script" \
        > /dev/null 2> "$output" || status=$?
    [[ "$status" -ne 0 ]] || fail "trace probe unexpectedly executed ${script}"
    assert_file_contains "$output" '+ set +x' \
      "${script} did not disable shell tracing immediately"
    for secret in "$owner_secret" "$admin_secret" "$runtime_secret"; do
      assert_file_not_contains "$output" "$secret" \
        "${script} disclosed a credential under shell tracing"
    done
  done
}
run_case() {
  local name="$1"
  local function_name="$2"
  local status
  if [[ -n "${OPS_TEST_FILTER:-}" && "$name" != *"$OPS_TEST_FILTER"* ]]; then
    return 0
  fi
  set +e
  (
    trap - EXIT INT TERM
    set -e
    "$function_name"
  )
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    PASSED=$((PASSED + 1))
    printf 'ok - %s\n' "$name"
  else
    FAILED=$((FAILED + 1))
    printf 'not ok - %s\n' "$name"
  fi
  set +e
}

run_case 'monitor healthy' test_monitor_healthy
run_case 'monitor not ready' test_monitor_not_ready
run_case 'monitor unhealthy' test_monitor_unhealthy
run_case 'monitor rejects non-origin URLs before curl' test_monitor_rejects_non_origin_urls_before_curl
run_case 'backup classifies source fail-closed' test_backup_classify_source
run_case 'backup schema advisory-lock contract' test_backup_schema_lock_constant_contract
run_case 'backup rejects symlink destination' test_backup_rejects_symlink_destination
run_case 'backup create' test_backup_create
run_case 'backup rejects future native-config receipt' test_backup_rejects_future_native_config_receipt
run_case 'backup rejects lost remote schema lock' test_backup_rejects_lost_remote_schema_lock
run_case 'backup create-predeploy stopped-web provenance' test_backup_create_predeploy
run_case 'backup lock-run reentrant contract' test_backup_lock_run_reentrant_contract
run_case 'backup lock-run fast-child handshake' test_backup_lock_run_fast_children
run_case 'backup lock-run startup cancellation' test_backup_lock_run_honors_startup_cancellation
run_case 'backup lock-run cancels process group' test_backup_lock_run_cancels_process_group
run_case 'backup lock-run kills TERM-ignoring group' test_backup_lock_run_kills_term_ignoring_group
run_case 'backup freshness uses signed snapshot start' test_backup_snapshot_start_freshness
run_case 'backup verify' test_backup_verify
run_case 'backup rejects unsafe external sources' test_backup_rejects_unsafe_external_sources
run_case 'backup rejects missing or tampered authenticated set' test_backup_rejects_missing_or_tampered_authenticated_set
run_case 'backup rejects signed metadata mismatches' test_backup_rejects_signed_metadata_mismatches
run_case 'backup latest' test_backup_latest
run_case 'backup latest uses signed freshness' test_backup_latest_uses_signed_freshness
run_case 'backup canonical-prefix upgrade' test_backup_canonical_prefix_upgrade
run_case 'backup offsite contract' test_backup_offsite_contract
run_case 'backup self-verifies before delivery and retention' test_backup_self_verifies_before_delivery_and_retention
run_case 'backup restore drill' test_backup_drill
run_case 'backup drill preserves lock on cleanup failure' test_backup_drill_preserves_lock_on_cleanup_failure
run_case 'backup rejects control-plane role drift' test_backup_rejects_control_plane_role_drift
run_case 'restore confirmation gate' test_restore_confirmation_gate
run_case 'restore authorization gate' test_restore_authorization_gate
run_case 'restore rejects future native-config manifest before mutation' test_restore_rejects_future_native_config_manifest_before_mutation
run_case 'restore running-web gate' test_restore_web_service_gate
run_case 'restore preflights provisioning before quiesce' test_restore_preflights_provisioning_before_quiesce
run_case 'restore preflights migration before quiesce' test_restore_preflights_migration_before_quiesce
run_case 'restore distinguishes atomic cutover outcomes' test_restore_distinguishes_atomic_cutover_outcomes
run_case 'restore fresh-stage cutover' test_restore_fresh_stage_cutover
run_case 'restore preserves selected expired backup' test_restore_preserves_selected_expired_backup
run_case 'restore post-cutover rollback' test_restore_rolls_back_failed_post_cutover_validation
run_case 'restore rejects failed pre-cutover readiness' test_restore_rejects_failed_pre_cutover_readiness
run_case 'restore preserves lock on staging cleanup failure' test_restore_preserves_lock_on_staging_cleanup_failure
run_case 'restore rolls back failed privilege provisioning' test_restore_rolls_back_failed_privilege_provisioning
run_case 'restore preserves lock on uncertain runtime relock' test_restore_preserves_lock_when_runtime_relock_is_uncertain
run_case 'restore preserves lock on uncertain rollback' test_restore_preserves_lock_when_rollback_is_uncertain
run_case 'lock-run preserves lock when recovery marker write fails' test_lock_run_preserves_lock_when_recovery_marker_write_fails
run_case 'backup inspect machine contract and native boundaries' test_backup_inspect_contract_and_native_boundaries
run_case 'bootstrap restore gates and managed success' test_bootstrap_restore_gates_and_managed_success
run_case 'bootstrap rejects contaminated template staging' test_bootstrap_rejects_contaminated_template_staging
run_case 'bootstrap fault recovery boundaries' test_bootstrap_fault_recovery_boundaries
run_case 'bootstrap pre-split drift fails closed' test_bootstrap_pre_split_drift_fails_closed
run_case 'bootstrap finalized no-lock dead-claim closure' test_bootstrap_finalized_no_lock_dead_claim_closes_safely
run_case 'runtime role password validation' test_provision_password_validation
run_case 'runtime role steady admin-only secret safety' test_provision_steady_admin_only_secret_safety
run_case 'runtime role restore secret transport' test_provision_restore_secret_transport
run_case 'runtime role never falls back to owner' test_provision_bad_admin_never_falls_back_to_owner
run_case 'runtime role failure diagnostics are secret-safe' test_provision_failure_diagnostics_are_secret_safe
run_case 'bootstrap role failure diagnostics are secret-safe' test_bootstrap_failure_diagnostics_are_secret_safe
run_case 'secret-bearing entrypoints disable shell trace' test_secret_entrypoints_disable_shell_trace

printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
