#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$SCRIPT_DIR/credential-rotation-state.mjs"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/address-atlas-credential-rotation.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
chmod 0700 "$TEST_ROOT"
cleanup() {
  find "$TEST_ROOT" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

CURRENT_ENV="$TEST_ROOT/production.env"
NEXT_ENV="${CURRENT_ENV}.next"
STATE_FILE="$TEST_ROOT/.database-credential-rotation.state"
BACKUP_PATH="$TEST_ROOT/address-atlas.dump.age"
CURRENT_OWNER='CurrentOwnerSecret_7Gm2Qv9Lx4Np8Yk6'
CURRENT_ADMIN='CurrentAdminSecret_4Fx8Lm2Qs7Vz9Tr5'
CURRENT_RUNTIME='CurrentRuntimeSecret_3Ld8Qw5Nz7Rx2Km9'
NEXT_OWNER='RotatedOwnerSecret_6Jn4Rv8Qx2Mc9Ts5'
NEXT_ADMIN='RotatedAdminSecret_9Hw3Kp6Jx8Nc2Vm7'
NEXT_RUNTIME='RotatedRuntimeSecret_8Jq2Vn6Gy4Ws9Pc3'
SOURCE_REVISION="$(printf '1%.0s' {1..40})"
MANAGE_PROD_SHA256="$(printf '2%.0s' {1..64})"
STATE_TOOL_SHA256="$(printf '3%.0s' {1..64})"
COMPOSE_SHA256="$(printf '4%.0s' {1..64})"
PROVISION_SHA256="$(printf '5%.0s' {1..64})"
BACKUP_TOOL_SHA256="$(printf '6%.0s' {1..64})"

write_environment() {
  local path="$1" owner="$2" admin="$3" runtime="$4" domain="$5"
  local database_query="${6:-}"
  {
    printf 'ADDRESS_ATLAS_DATABASE_ROLE_MODE=steady\n'
    printf 'ADDRESS_ATLAS_DOMAIN=%s\n' "$domain"
    printf 'POSTGRES_PASSWORD=%s\n' "$owner"
    printf 'POSTGRES_ADMIN_PASSWORD=%s\n' "$admin"
    printf 'POSTGRES_RUNTIME_PASSWORD=%s\n' "$runtime"
    printf 'SYNC_SCHEMA_DATABASE_URL=postgresql://address_atlas:%s@postgres:5432/address_atlas_sync%s\n' \
      "$owner" "$database_query"
    printf 'SYNC_DATABASE_URL=postgresql://address_atlas_runtime:%s@postgres:5432/address_atlas_sync%s\n' \
      "$runtime" "$database_query"
  } > "$path"
  chmod 0600 "$path"
}

write_environment "$CURRENT_ENV" "$CURRENT_OWNER" "$CURRENT_ADMIN" \
  "$CURRENT_RUNTIME" sync.example.test
write_environment "$NEXT_ENV" "$NEXT_OWNER" "$NEXT_ADMIN" \
  "$NEXT_RUNTIME" sync.example.test

resume_rotation_contract() {
  node "$TOOL" resume-contract "$STATE_FILE" "$CURRENT_ENV" "$NEXT_ENV" \
    "$SOURCE_REVISION" "$MANAGE_PROD_SHA256" "$STATE_TOOL_SHA256" \
    "$COMPOSE_SHA256" "$PROVISION_SHA256" "$BACKUP_TOOL_SHA256"
}
: > "$BACKUP_PATH"
chmod 0600 "$BACKUP_PATH"

contract="$(node "$TOOL" env-contract "$CURRENT_ENV" "$NEXT_ENV")"
IFS='|' read -r CURRENT_HASH NEXT_HASH extra <<< "$contract"
[[ -z "$extra" && "$CURRENT_HASH" =~ ^[0-9a-f]{64}$ \
   && "$NEXT_HASH" =~ ^[0-9a-f]{64}$ ]]

bad_next="$TEST_ROOT/bad-noncredential.env"
write_environment "$bad_next" "$NEXT_OWNER" "$NEXT_ADMIN" \
  "$NEXT_RUNTIME" changed.example.test
mv "$bad_next" "$NEXT_ENV"
if node "$TOOL" env-contract "$CURRENT_ENV" "$NEXT_ENV" \
    > "$TEST_ROOT/stdout" 2> "$TEST_ROOT/stderr"; then
  echo 'rotation accepted a non-credential environment change' >&2
  exit 1
fi
grep -F 'Non-credential environment key changed' "$TEST_ROOT/stderr" >/dev/null
! grep -F "$NEXT_RUNTIME" "$TEST_ROOT/stdout" "$TEST_ROOT/stderr" >/dev/null
write_environment "$NEXT_ENV" "$NEXT_OWNER" "$NEXT_ADMIN" \
  "$NEXT_RUNTIME" sync.example.test

# Remote PostgreSQL deployments frequently require TLS query parameters. A
# credential-only rotation accepts them but binds the full non-secret URL
# contract byte-for-byte so TLS policy cannot be weakened during rotation.
REMOTE_ENV="$TEST_ROOT/remote.env"
REMOTE_NEXT="${REMOTE_ENV}.next"
REMOTE_TLS='?sslmode=verify-full&sslrootcert=%2Fetc%2Faddress-atlas%2Fpostgres-ca.pem'
write_environment "$REMOTE_ENV" "$CURRENT_OWNER" "$CURRENT_ADMIN" \
  "$CURRENT_RUNTIME" sync.example.test "$REMOTE_TLS"
write_environment "$REMOTE_NEXT" "$NEXT_OWNER" "$NEXT_ADMIN" \
  "$NEXT_RUNTIME" sync.example.test "$REMOTE_TLS"
node "$TOOL" env-contract "$REMOTE_ENV" "$REMOTE_NEXT" >/dev/null
write_environment "$REMOTE_NEXT" "$NEXT_OWNER" "$NEXT_ADMIN" \
  "$NEXT_RUNTIME" sync.example.test \
  '?sslmode=require&sslrootcert=%2Fetc%2Faddress-atlas%2Fpostgres-ca.pem'
if node "$TOOL" env-contract "$REMOTE_ENV" "$REMOTE_NEXT" \
    > "$TEST_ROOT/stdout" 2> "$TEST_ROOT/stderr"; then
  echo 'rotation accepted a changed remote TLS contract' >&2
  exit 1
fi
grep -F 'database endpoint or TLS contract' "$TEST_ROOT/stderr" >/dev/null

node "$TOOL" state-write "$STATE_FILE" prepared "$CURRENT_HASH" "$NEXT_HASH" \
  "$SOURCE_REVISION" "$MANAGE_PROD_SHA256" "$STATE_TOOL_SHA256" \
  "$COMPOSE_SHA256" "$PROVISION_SHA256" "$BACKUP_TOOL_SHA256" \
  "$BACKUP_PATH" "$(printf 'a%.0s' {1..64})" "$(printf 'b%.0s' {1..40})" \
  "sha256:$(printf 'c%.0s' {1..64})" "$(printf 'd%.0s' {1..12})" \
  "$(printf 'e%.0s' {1..12})" "$(printf 'f%.0s' {1..12})" \
  address-atlas-prod-postgres
[[ "$(stat -c %a "$STATE_FILE" 2>/dev/null || stat -f %Lp "$STATE_FILE")" == 600 ]]
resume_rotation_contract >/dev/null
if node "$TOOL" resume-contract "$STATE_FILE" "$CURRENT_ENV" "$NEXT_ENV" \
    "$(printf '9%.0s' {1..40})" "$MANAGE_PROD_SHA256" "$STATE_TOOL_SHA256" \
    "$COMPOSE_SHA256" "$PROVISION_SHA256" "$BACKUP_TOOL_SHA256" \
    > "$TEST_ROOT/stdout" 2> "$TEST_ROOT/stderr"; then
  echo 'rotation resume accepted a changed source revision' >&2
  exit 1
fi
grep -F 'source revision or recovery toolchain differs' "$TEST_ROOT/stderr" >/dev/null
if node "$TOOL" resume-contract "$STATE_FILE" "$CURRENT_ENV" "$NEXT_ENV" \
    "$SOURCE_REVISION" "$MANAGE_PROD_SHA256" "$(printf '8%.0s' {1..64})" \
    "$COMPOSE_SHA256" "$PROVISION_SHA256" "$BACKUP_TOOL_SHA256" \
    > "$TEST_ROOT/stdout" 2> "$TEST_ROOT/stderr"; then
  echo 'rotation resume accepted a changed recovery tool' >&2
  exit 1
fi
grep -F 'source revision or recovery toolchain differs' "$TEST_ROOT/stderr" >/dev/null
if node "$TOOL" resume-contract "$STATE_FILE" "$CURRENT_ENV" "$NEXT_ENV" \
    "$SOURCE_REVISION" "$MANAGE_PROD_SHA256" "$STATE_TOOL_SHA256" \
    "$COMPOSE_SHA256" "$PROVISION_SHA256" "$(printf '7%.0s' {1..64})" \
    > "$TEST_ROOT/stdout" 2> "$TEST_ROOT/stderr"; then
  echo 'rotation resume accepted a changed backup tool' >&2
  exit 1
fi
grep -F 'source revision or recovery toolchain differs' "$TEST_ROOT/stderr" >/dev/null

node "$TOOL" run-with-deadline 5 -- sh -c 'exit 0'
set +e
node "$TOOL" run-with-deadline 1 -- sh -c 'sleep 30' \
  > "$TEST_ROOT/stdout" 2> "$TEST_ROOT/stderr"
deadline_status=$?
set -e
[[ "$deadline_status" -eq 124 ]] || {
  echo "rotation deadline returned ${deadline_status}, expected 124" >&2
  exit 1
}
if node "$TOOL" run-with-deadline 0 -- sh -c ':' \
    > "$TEST_ROOT/stdout" 2> "$TEST_ROOT/stderr"; then
  echo 'rotation deadline accepted a zero-second bound' >&2
  exit 1
fi

# Fault point 1: PostgreSQL committed, then the process died. The durable phase
# resumes directly at environment installation without another DB mutation.
node "$TOOL" state-advance "$STATE_FILE" prepared database-committed
grep -F '|database-committed|' <(node "$TOOL" state-read "$STATE_FILE") >/dev/null

# Fault point 2: rename+fsync committed but phase fsync did not. install-env is
# idempotent against either the A or B target hash, so replay is safe.
node "$TOOL" install-env "$NEXT_ENV" "$CURRENT_ENV" "$CURRENT_HASH" "$NEXT_HASH"
[[ "$(shasum -a 256 "$CURRENT_ENV" | awk '{print $1}')" == "$NEXT_HASH" ]]
node "$TOOL" install-env "$NEXT_ENV" "$CURRENT_ENV" "$CURRENT_HASH" "$NEXT_HASH"
node "$TOOL" state-advance "$STATE_FILE" database-committed environment-committed

# Fault point 3: fake Docker restarted the exact release but the service phase
# was not recorded. Replaying the idempotent restart then advancing is safe.
cat > "$TEST_ROOT/docker" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_DOCKER_LOG:?}"
[[ "${FAKE_DOCKER_FAIL_AFTER_RESTART:-false}" != true ]] || exit 99
FAKE
chmod 0700 "$TEST_ROOT/docker"
set +e
FAKE_DOCKER_LOG="$TEST_ROOT/docker.log" FAKE_DOCKER_FAIL_AFTER_RESTART=true \
  "$TEST_ROOT/docker" compose up -d --no-build --no-deps --force-recreate web caddy
fault_status=$?
set -e
[[ "$fault_status" -eq 99 ]]
grep -F '|environment-committed|' <(node "$TOOL" state-read "$STATE_FILE") >/dev/null
FAKE_DOCKER_LOG="$TEST_ROOT/docker.log" \
  "$TEST_ROOT/docker" compose up -d --no-build --no-deps --force-recreate web caddy
[[ "$(wc -l < "$TEST_ROOT/docker.log" | tr -d '[:space:]')" == 2 ]]
node "$TOOL" state-advance "$STATE_FILE" environment-committed service-verified

# Compose shell variables outrank --env-file. Source the production wrappers,
# export stale and hostile values in the parent, and make a fake Compose
# renderer prove both db-rotate and web resolve desired configuration from B
# inside a positive allowlist environment. The same fake injects each B-side
# restart fault and proves no unverified public container remains running.
{
  sed -n '/^run_with_rotation_clean_environment()/,/^}/p' "$SCRIPT_DIR/manage-prod.sh"
  sed -n '/^run_database_credential_rotation_mode()/,/^}/p' "$SCRIPT_DIR/manage-prod.sh"
  sed -n '/^verify_rotated_frontend_current()/,/^}/p' "$SCRIPT_DIR/manage-prod.sh"
  sed -n '/^restart_rotated_frontend_once()/,/^}/p' "$SCRIPT_DIR/manage-prod.sh"
  sed -n '/^restart_rotated_frontend()/,/^}/p' "$SCRIPT_DIR/manage-prod.sh"
} > "$TEST_ROOT/rotation-wrappers.sh"
mkdir -m 0700 "$TEST_ROOT/service-control"
ADDRESS_ATLAS_CONTROL_ROOT="$TEST_ROOT/service-control"
# shellcheck source=service-control.sh
source "$SCRIPT_DIR/service-control.sh"
# shellcheck source=frontend-recovery.sh
source "$SCRIPT_DIR/frontend-recovery.sh"
# shellcheck source=/dev/null
source "$TEST_ROOT/rotation-wrappers.sh"
cat > "$TEST_ROOT/docker-precedence" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
fake_root="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
mode="$(<"$fake_root/fake-mode")"
args=("$@")
if [[ "${1:-}" == image && "${2:-}" == inspect ]]; then exit 0; fi
if [[ "${1:-}" == tag ]]; then exit 0; fi
if [[ "${1:-}" == ps ]]; then
  service=''
  [[ " $* " == *'service=web'* ]] && service=web
  [[ " $* " == *'service=caddy'* ]] && service=caddy
  [[ -n "$service" ]] || exit 65
  if [[ "${2:-}" == -aq || "$(<"$fake_root/${service}-running")" == true ]]; then
    cat "$fake_root/${service}-container"
  fi
  exit 0
fi
if [[ "${1:-}" == stop ]]; then
  printf 'false\n' > "$fake_root/web-running"
  printf 'false\n' > "$fake_root/caddy-running"
  exit 0
fi
if [[ "${1:-}" == start ]]; then
  [[ "${2:-}" == "$(<"$fake_root/caddy-container")" ]] || exit 67
  printf 'true\n' > "$fake_root/caddy-running"
  exit 0
fi
if [[ "${1:-}" == inspect ]]; then
  if [[ "${!#}" == "$(<"$fake_root/caddy-container")" ]]; then
    printf '%s|address-atlas-sync|caddy\n' "$(<"$fake_root/caddy-running")"
    exit 0
  fi
  revision="$(<"$fake_root/web-revision")"
  [[ "$mode" != identity-fail ]] || revision="$(printf '9%.0s' {1..40})"
  printf '%s|address-atlas-sync|web|%s|%s\n' \
    "$(<"$fake_root/web-running")" "$(<"$fake_root/web-image")" "$revision"
  exit 0
fi
[[ "${1:-}" == compose ]] || exit 64
for forbidden in POSTGRES_PASSWORD POSTGRES_ADMIN_PASSWORD \
    POSTGRES_RUNTIME_PASSWORD SYNC_SCHEMA_DATABASE_URL SYNC_DATABASE_URL \
    ADDRESS_ATLAS_DOMAIN ADDRESS_ATLAS_DATABASE_ROLE_MODE \
    NATIVE_ENDPOINT_CONFIG_VERSION; do
  [[ -z "${!forbidden:-}" ]] || {
    echo "forbidden inherited desired value: ${forbidden}" >&2
    exit 88
  }
done
env_file=''
for ((index=0; index < ${#args[@]}; index++)); do
  [[ "${args[$index]}" == --env-file ]] \
    && env_file="${args[$((index + 1))]}"
done
value() {
  local name="$1" inherited line result
  inherited="${!name:-}"
  if [[ -n "$inherited" ]]; then
    result="$inherited"
  else
    line="$(grep -E "^${name}=" "$env_file")"
    result="${line#*=}"
  fi
  printf '%s' "$result" | shasum -a 256 | awk '{print $1}'
}
printf 'owner=%s runtime_url=%s\n' \
  "$(value POSTGRES_PASSWORD)" "$(value SYNC_DATABASE_URL)" \
  >> "$fake_root/precedence.log"
printf 'true\n' > "$fake_root/web-running"
[[ "$mode" != compose-partial ]] || exit 99
FAKE
chmod 0700 "$TEST_ROOT/docker-precedence"
DOCKER_BIN="$TEST_ROOT/docker-precedence"
ROTATION_COMPOSE_ARGS=(compose --env-file "$NEXT_ENV" -f ignored.yml)
export POSTGRES_PASSWORD="$CURRENT_OWNER"
export POSTGRES_ADMIN_PASSWORD="$CURRENT_ADMIN"
export POSTGRES_RUNTIME_PASSWORD="$CURRENT_RUNTIME"
export SYNC_SCHEMA_DATABASE_URL="postgresql://address_atlas:${CURRENT_OWNER}@postgres:5432/address_atlas_sync"
export SYNC_DATABASE_URL="postgresql://address_atlas_runtime:${CURRENT_RUNTIME}@postgres:5432/address_atlas_sync"
export ADDRESS_ATLAS_ROTATE_CURRENT_OWNER_PASSWORD="$CURRENT_OWNER"
export ADDRESS_ATLAS_ROTATE_CURRENT_ADMIN_PASSWORD="$CURRENT_ADMIN"
export ADDRESS_ATLAS_ROTATE_CURRENT_RUNTIME_PASSWORD="$CURRENT_RUNTIME"
export ADDRESS_ATLAS_DOMAIN=attacker.invalid
export ADDRESS_ATLAS_DATABASE_ROLE_MODE=bootstrap
export NATIVE_ENDPOINT_CONFIG_VERSION=999999
ROTATION_WEB_IMAGE_ID="sha256:$(printf 'c%.0s' {1..64})"
ROTATION_REVISION="$(printf 'b%.0s' {1..40})"
ROTATION_CADDY_CONTAINER_ID="$(printf 'e%.0s' {1..12})"
ORIGINAL_ENV_FILE="$CURRENT_ENV"
COMPOSE_PROJECT_NAME_FIXED=address-atlas-sync
COMPOSE_FILE=ignored.yml
NODE_BIN="$(command -v node)"
CREDENTIAL_ROTATION_STATE_TOOL="$TOOL"
ROTATION_COMMAND_TIMEOUT_SECONDS=5
printf '%s\n' "$ROTATION_WEB_IMAGE_ID" > "$TEST_ROOT/web-image"
printf '%s\n' "$ROTATION_REVISION" > "$TEST_ROOT/web-revision"
printf '%s\n' "$ROTATION_CADDY_CONTAINER_ID" > "$TEST_ROOT/caddy-container"
printf '%s\n' webnew000001 > "$TEST_ROOT/web-container"
printf 'false\n' > "$TEST_ROOT/web-running"
printf 'false\n' > "$TEST_ROOT/caddy-running"
printf 'success\n' > "$TEST_ROOT/fake-mode"
run_database_credential_rotation_mode verify-rotation
smoke_public_with_retries() {
  [[ "$(<"$TEST_ROOT/fake-mode")" != smoke-fail ]]
}
restart_rotated_frontend
expected_owner_hash="$(printf '%s' "$NEXT_OWNER" | shasum -a 256 | awk '{print $1}')"
expected_runtime_url_hash="$({
  printf 'postgresql://address_atlas_runtime:%s@postgres:5432/address_atlas_sync' \
    "$NEXT_RUNTIME"
} | shasum -a 256 | awk '{print $1}')"
[[ "$(grep -Fc "owner=${expected_owner_hash} runtime_url=${expected_runtime_url_hash}" \
    "$TEST_ROOT/precedence.log")" == 2 ]]

assert_restart_failure_stops_frontend() {
  local injected_mode="$1"
  printf 'false\n' > "$TEST_ROOT/web-running"
  printf 'false\n' > "$TEST_ROOT/caddy-running"
  printf '%s\n' "$injected_mode" > "$TEST_ROOT/fake-mode"
  if restart_rotated_frontend >/dev/null 2>&1; then
    echo "B-side restart unexpectedly accepted ${injected_mode}" >&2
    exit 1
  fi
  [[ "$(<"$TEST_ROOT/web-running")" == false \
     && "$(<"$TEST_ROOT/caddy-running")" == false ]] || {
    echo "B-side ${injected_mode} failure left an unverified frontend running" >&2
    exit 1
  }
}
assert_restart_failure_stops_frontend compose-partial
assert_restart_failure_stops_frontend smoke-fail
assert_restart_failure_stops_frontend identity-fail
printf 'success\n' > "$TEST_ROOT/fake-mode"
restart_rotated_frontend

set +e
ADDRESS_ATLAS_BACKUP_SCRIPT="$TEST_ROOT/untrusted-backup" \
  bash "$SCRIPT_DIR/manage-prod.sh" rotate-database-credentials \
    "$NEXT_ENV" --confirm "ROTATE-DATABASE-CREDENTIALS:${NEXT_HASH}" \
    > "$TEST_ROOT/stdout" 2> "$TEST_ROOT/stderr"
override_status=$?
set -e
[[ "$override_status" -eq 65 ]]
grep -F 'Credential rotation forbids ADDRESS_ATLAS_BACKUP_SCRIPT' \
  "$TEST_ROOT/stderr" >/dev/null

node "$TOOL" cleanup-next "$NEXT_ENV" "$NEXT_HASH"
[[ ! -e "$NEXT_ENV" ]]
resume_rotation_contract >/dev/null
node "$TOOL" state-delete "$STATE_FILE" "$NEXT_HASH"
[[ ! -e "$STATE_FILE" ]]

# Integration contract: manage-prod must persist each phase only after its
# side effect and use the exact .next-to-production path.
python3 - "$SCRIPT_DIR/manage-prod.sh" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
rotation_start = text.index("  rotate-database-credentials)")
rotation_end = text.index("  restore)", rotation_start)
rotation = text[rotation_start:rotation_end]
needles = [
    "state-write \\",
    "run_database_credential_rotation_mode rotate",
    "prepared database-committed",
    "install-env \\",
    "database-committed environment-committed",
    "restart_rotated_frontend",
    "environment-committed service-verified",
    "verify_rotated_frontend_current",
    "cleanup-next \\",
    "state-delete \\",
]
positions = [rotation.index(needle) for needle in needles]
if positions != sorted(positions):
    raise SystemExit("credential-rotation side effects and durable phases are out of order")
if rotation.index("load_credential_rotation_state") > rotation.index(
        'assert_authorized_deployment_revision "$rotation_authorization_mode"'):
    raise SystemExit("credential-rotation resume does not load its exact source binding before authorization")
if 'rotation_authorization_mode=rotation-resume' not in rotation:
    raise SystemExit("credential-rotation recovery cannot authorize its exact journaled source revision")
if rotation.count('"$ROTATION_ACTIVE_BACKUP_TOOL_SHA256"') < 2:
    raise SystemExit("credential-rotation journal does not bind the backup implementation on create and resume")
guard = 'Credential rotation forbids ADDRESS_ATLAS_BACKUP_SCRIPT'
lock_dispatch = '# Every stateful production operation shares one cross-process host lock.'
if guard not in text or text.index(guard) > text.index(lock_dispatch):
    raise SystemExit("credential-rotation backup override is not rejected before lock dispatch")
if 'env -i "${isolated_environment[@]}" "$@"' not in text:
    raise SystemExit("credential-rotation commands lack a positive environment allowlist")
for function_name, inherited_name in (
    ("production_domain", "ADDRESS_ATLAS_DOMAIN:-"),
    ("database_role_mode", "ADDRESS_ATLAS_DATABASE_ROLE_MODE:-"),
):
    start = text.index(f"{function_name}()")
    end = text.index("\n}", start)
    if inherited_name in text[start:end]:
        raise SystemExit(f"{function_name} still trusts inherited desired configuration")
PY

echo 'credential-rotation-tests: 19/19 passed'
