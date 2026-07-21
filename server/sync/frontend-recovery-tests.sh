#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/address-atlas-frontend-recovery.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
cleanup() {
  find "$TEST_ROOT" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

WEB_ID=aaaaaaaaaaaa
CADDY_ID=bbbbbbbbbbbb
WEB_IMAGE="sha256:$(printf 'a%.0s' {1..64})"
WEB_REVISION="$(printf 'b%.0s' {1..40})"

write_fake_docker() {
  cat > "$TEST_ROOT/docker" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
state_dir="${FAKE_DOCKER_STATE:?}"
command="${1:-}"
shift || true
case "$command" in
  ps)
    include_stopped=false
    service=""
    for argument in "$@"; do
      [[ "$argument" == "-aq" ]] && include_stopped=true
      [[ "$argument" == *'compose.service=web' ]] && service=web
      [[ "$argument" == *'compose.service=caddy' ]] && service=caddy
    done
    case "$service" in
      web)
        if [[ "$include_stopped" == true || "$(< "$state_dir/web.running")" == true ]]; then
          printf '%s\n' aaaaaaaaaaaa
        fi
        ;;
      caddy)
        if [[ "$include_stopped" == true || "$(< "$state_dir/caddy.running")" == true ]]; then
          printf '%s\n' bbbbbbbbbbbb
        fi
        ;;
    esac
    ;;
  inspect)
    container="${!#}"
    case "$container" in
      aaaaaaaaaaaa)
        printf '%s|address-atlas-sync|web|sha256:%s|%s\n' \
          "$(< "$state_dir/web.running")" \
          "$(printf 'a%.0s' {1..64})" "$(printf 'b%.0s' {1..40})"
        ;;
      bbbbbbbbbbbb)
        printf '%s|address-atlas-sync|caddy|sha256:%s|\n' \
          "$(< "$state_dir/caddy.running")" "$(printf 'c%.0s' {1..64})"
        ;;
      *) exit 69 ;;
    esac
    ;;
  stop)
    if [[ ! -e "$state_dir/stop.called" ]]; then
      # Prove the original non-transactional failure: web has stopped, Caddy has not.
      : > "$state_dir/stop.called"
      printf 'false\n' > "$state_dir/web.running"
      printf 'stop-partial\n' >> "$state_dir/docker.log"
      exit 71
    fi
    printf 'false\n' > "$state_dir/web.running"
    printf 'false\n' > "$state_dir/caddy.running"
    printf 'stop-cleanup\n' >> "$state_dir/docker.log"
    ;;
  start)
    printf 'start %s\n' "$*" >> "$state_dir/docker.log"
    case "${FAKE_START_MODE:-success}" in
      before) exit 1 ;;
      partial)
        printf 'true\n' > "$state_dir/web.running"
        printf 'false\n' > "$state_dir/caddy.running"
        exit 1
        ;;
      success)
        printf 'true\n' > "$state_dir/web.running"
        printf 'true\n' > "$state_dir/caddy.running"
        ;;
      *) exit 64 ;;
    esac
    ;;
  *) exit 64 ;;
esac
FAKE
  chmod 0700 "$TEST_ROOT/docker"
}

run_scenario() {
  local start_mode="$1"
  local scenario="$2"
  local smoke_failure="${3:-false}"
  local case_dir="$TEST_ROOT/$scenario"
  mkdir -m 0700 "$case_dir"
  mkdir -m 0700 "$case_dir/service-control"
  printf 'true\n' > "$case_dir/web.running"
  printf 'true\n' > "$case_dir/caddy.running"
  : > "$case_dir/docker.log"
  write_fake_docker

  set +e
  FAKE_DOCKER_STATE="$case_dir" \
  FAKE_START_MODE="$start_mode" \
  FAKE_SMOKE_FAILURE="$smoke_failure" \
  TEST_DOCKER="$TEST_ROOT/docker" \
  TEST_CONTROL_LIBRARY="$SCRIPT_DIR/service-control.sh" \
  TEST_LIBRARY="$SCRIPT_DIR/frontend-recovery.sh" \
  TEST_CASE_DIR="$case_dir" \
  TEST_WEB_IMAGE="$WEB_IMAGE" \
  TEST_WEB_REVISION="$WEB_REVISION" \
    bash <<'HARNESS' > "$case_dir/stdout" 2> "$case_dir/stderr"
set -euo pipefail
DOCKER_BIN="$TEST_DOCKER"
NODE_BIN="$(command -v node)"
COMPOSE_PROJECT_NAME_FIXED=address-atlas-sync
ADDRESS_ATLAS_CONTROL_ROOT="$TEST_CASE_DIR/service-control"
PREDEPLOY_RECOVERY_ENABLED=false
PREVIOUS_WEB_CONTAINER_ID=aaaaaaaaaaaa
PREVIOUS_WEB_IMAGE_ID="$TEST_WEB_IMAGE"
PREVIOUS_WEB_REVISION="$TEST_WEB_REVISION"
PREVIOUS_WEB_RUNNING=true
source "$TEST_CONTROL_LIBRARY"
source "$TEST_LIBRARY"
smoke_public_with_retries() {
  printf 'smoke %s\n' "$1" >> "$TEST_CASE_DIR/docker.log"
  [[ "${FAKE_SMOKE_FAILURE:-false}" != true ]]
}
exit_cleanup() {
  local original_status=$?
  local recovery_status=0
  trap - EXIT
  recover_previous_frontend_if_needed || recovery_status=$?
  [[ "$recovery_status" -eq 0 ]] || original_status="$recovery_status"
  exit "$original_status"
}
trap exit_cleanup EXIT
stop_frontend_before_database_mutation
printf 'restore-called\n' > "$TEST_CASE_DIR/restore.called"
HARNESS
  SCENARIO_STATUS=$?
  set -e
}

run_scenario success recovery_success
[[ "$SCENARIO_STATUS" -eq 71 ]] || {
  echo "partial stop status was not preserved after successful recovery" >&2
  exit 1
}
[[ ! -e "$TEST_ROOT/recovery_success/restore.called" ]] || {
  echo "database restore continued after a partial frontend stop" >&2
  exit 1
}
grep -F "start $WEB_ID $CADDY_ID" "$TEST_ROOT/recovery_success/docker.log" >/dev/null
grep -F "smoke $WEB_REVISION" "$TEST_ROOT/recovery_success/docker.log" >/dev/null
[[ "$(< "$TEST_ROOT/recovery_success/web.running")" == true \
   && "$(< "$TEST_ROOT/recovery_success/caddy.running")" == true ]] || {
  echo "the exact previous frontend set was not restored" >&2
  exit 1
}

run_scenario before recovery_failure
[[ "$SCENARIO_STATUS" -eq 70 ]] || {
  echo "a failed exact recovery was not visible in the final exit status" >&2
  exit 1
}
[[ ! -e "$TEST_ROOT/recovery_failure/restore.called" ]] || {
  echo "database restore continued after failed frontend recovery" >&2
  exit 1
}
grep -F 'CRITICAL The exact captured frontend containers could not be restarted.' \
  "$TEST_ROOT/recovery_failure/stderr" >/dev/null
[[ "$(< "$TEST_ROOT/recovery_failure/web.running")" == false \
   && "$(< "$TEST_ROOT/recovery_failure/caddy.running")" == false ]] || {
  echo "failed recovery did not stop the fixed frontend" >&2
  exit 1
}

run_scenario partial partial_start_failure
[[ "$SCENARIO_STATUS" -eq 70 ]]
[[ "$(< "$TEST_ROOT/partial_start_failure/web.running")" == false \
   && "$(< "$TEST_ROOT/partial_start_failure/caddy.running")" == false ]] || {
  echo "partial restart remained publicly running" >&2
  exit 1
}
grep -F 'stop-cleanup' "$TEST_ROOT/partial_start_failure/docker.log" >/dev/null

run_scenario success smoke_failure true
[[ "$SCENARIO_STATUS" -eq 70 ]]
[[ "$(< "$TEST_ROOT/smoke_failure/web.running")" == false \
   && "$(< "$TEST_ROOT/smoke_failure/caddy.running")" == false ]] || {
  echo "smoke-failing frontend remained publicly running" >&2
  exit 1
}
grep -F 'CRITICAL The exact captured frontend restarted but its old revision failed public smoke.' \
  "$TEST_ROOT/smoke_failure/stderr" >/dev/null

extract_case_body() {
  local case_name="$1"
  awk -v start="  ${case_name})" '
    $0 == start { found = 1 }
    found { print }
    found && $0 == "    ;;" { exit }
  ' "$SCRIPT_DIR/manage-prod.sh"
}

assert_recovery_boundary_order() {
  local case_name="$1"
  local mutation_pattern="$2"
  local body stop_line disarm_line mutation_line
  body="$(extract_case_body "$case_name")"
  stop_line="$(grep -n -m1 'stop_frontend_before_database_mutation' <<< "$body" | cut -d: -f1)"
  disarm_line="$(grep -n -m1 'PREDEPLOY_RECOVERY_ENABLED=false' <<< "$body" | cut -d: -f1)"
  mutation_line="$(grep -n -m1 "$mutation_pattern" <<< "$body" | cut -d: -f1)"
  [[ "$stop_line" =~ ^[0-9]+$ && "$disarm_line" =~ ^[0-9]+$ \
     && "$mutation_line" =~ ^[0-9]+$ \
     && "$stop_line" -lt "$disarm_line" \
     && "$disarm_line" -lt "$mutation_line" ]] || {
    echo "${case_name} does not keep exact frontend recovery armed until the database mutation boundary" >&2
    exit 1
  }
}

assert_recovery_boundary_order restore 'bash "$BACKUP_SCRIPT" restore'
assert_recovery_boundary_order bootstrap-restore 'bash "$BACKUP_SCRIPT" bootstrap-restore'

echo 'frontend-recovery-tests: 6/6 passed'
