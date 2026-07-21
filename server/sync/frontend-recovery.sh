#!/usr/bin/env bash

# Shared, testable recovery boundary for operations that must stop the public
# frontend before mutating PostgreSQL. The caller owns `set -e`, the EXIT trap,
# and the public smoke implementation. This file deliberately performs no work
# when sourced.

PREDEPLOY_FRONTEND_STATE_CAPTURED=false
PREDEPLOY_FRONTEND_RUNNING_SERVICES=()
PREDEPLOY_FRONTEND_RUNNING_CONTAINERS=()
PREDEPLOY_CADDY_CONTAINER_ID=""
PREDEPLOY_CADDY_RUNNING=false

fixed_frontend_container_for_service() {
  local service="$1"
  local containers candidate count=0 selected=""
  containers="$($DOCKER_BIN ps -aq \
    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME_FIXED}" \
    --filter "label=com.docker.compose.service=${service}")" || {
    echo "Unable to inspect the fixed-project ${service} container." >&2
    return 69
  }
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    count=$((count + 1))
    selected="$candidate"
  done <<< "$containers"
  [[ "$count" -le 1 ]] || {
    echo "Multiple fixed-project ${service} containers exist; exact frontend recovery is ambiguous." >&2
    return 66
  }
  printf '%s\n' "$selected"
}

inspect_captured_frontend_container() {
  local service="$1"
  local container="$2"
  local expected_running="$3"
  local metadata running project observed_service image_id revision extra
  metadata="$($DOCKER_BIN inspect --format \
    '{{.State.Running}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.Image}}|{{index .Config.Labels "org.opencontainers.image.revision"}}' \
    "$container" 2>/dev/null)" || return 69
  IFS='|' read -r running project observed_service image_id revision extra <<< "$metadata"
  [[ -z "$extra" && "$running" == "$expected_running" \
     && "$project" == "$COMPOSE_PROJECT_NAME_FIXED" \
     && "$observed_service" == "$service" ]] || return 67
  if [[ "$service" == "web" ]]; then
    [[ "$container" == "$PREVIOUS_WEB_CONTAINER_ID" \
       && "$image_id" == "$PREVIOUS_WEB_IMAGE_ID" \
       && "$revision" == "$PREVIOUS_WEB_REVISION" ]] || return 67
  fi
}

capture_fixed_frontend_runtime_state() {
  PREDEPLOY_FRONTEND_STATE_CAPTURED=false
  PREDEPLOY_FRONTEND_RUNNING_SERVICES=()
  PREDEPLOY_FRONTEND_RUNNING_CONTAINERS=()
  PREDEPLOY_CADDY_CONTAINER_ID=""
  PREDEPLOY_CADDY_RUNNING=false

  local web_container caddy_container caddy_metadata caddy_running caddy_project
  local caddy_service caddy_image caddy_revision extra
  web_container="$(fixed_frontend_container_for_service web)" || return $?
  [[ "$web_container" == "${PREVIOUS_WEB_CONTAINER_ID:-}" ]] || {
    echo "The captured web provenance changed before the maintenance stop." >&2
    return 73
  }
  if [[ -n "$web_container" ]]; then
    local inspect_status=0
    inspect_captured_frontend_container web "$web_container" \
      "${PREVIOUS_WEB_RUNNING:-false}" || inspect_status=$?
    if [[ "$inspect_status" -ne 0 ]]; then
      echo "The captured web container changed before the maintenance stop." >&2
      return "$inspect_status"
    fi
    if [[ "$PREVIOUS_WEB_RUNNING" == "true" ]]; then
      PREDEPLOY_FRONTEND_RUNNING_SERVICES+=(web)
      PREDEPLOY_FRONTEND_RUNNING_CONTAINERS+=("$web_container")
    fi
  fi

  caddy_container="$(fixed_frontend_container_for_service caddy)" || return $?
  PREDEPLOY_CADDY_CONTAINER_ID="$caddy_container"
  if [[ -n "$caddy_container" ]]; then
    caddy_metadata="$($DOCKER_BIN inspect --format \
      '{{.State.Running}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.Image}}|{{index .Config.Labels "org.opencontainers.image.revision"}}' \
      "$caddy_container" 2>/dev/null)" || return 69
    IFS='|' read -r caddy_running caddy_project caddy_service caddy_image \
      caddy_revision extra <<< "$caddy_metadata"
    [[ -z "$extra" && ( "$caddy_running" == "true" || "$caddy_running" == "false" ) \
       && "$caddy_project" == "$COMPOSE_PROJECT_NAME_FIXED" \
       && "$caddy_service" == "caddy" ]] || {
      echo "The existing Caddy container lacks exact fixed-project provenance." >&2
      return 67
    }
    PREDEPLOY_CADDY_RUNNING="$caddy_running"
    if [[ "$caddy_running" == "true" ]]; then
      PREDEPLOY_FRONTEND_RUNNING_SERVICES+=(caddy)
      PREDEPLOY_FRONTEND_RUNNING_CONTAINERS+=("$caddy_container")
    fi
  fi
  PREDEPLOY_FRONTEND_STATE_CAPTURED=true
}

assert_no_unexpected_running_frontend() {
  local service observed expected="" candidate count=0
  for service in web caddy; do
    [[ "$service" == "web" ]] \
      && expected="${PREVIOUS_WEB_CONTAINER_ID:-}" \
      || expected="${PREDEPLOY_CADDY_CONTAINER_ID:-}"
    observed="$($DOCKER_BIN ps -q \
      --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME_FIXED}" \
      --filter "label=com.docker.compose.service=${service}")" || return 69
    count=0
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] || continue
      count=$((count + 1))
      [[ "$candidate" == "$expected" ]] || return 67
    done <<< "$observed"
    [[ "$count" -le 1 ]] || return 67
  done
}

fail_safe_stop_fixed_frontend() {
  local containers=()
  local service observed container existing duplicate=false collection_failed=false
  for service in caddy web; do
    if ! observed="$($DOCKER_BIN ps -q \
        --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME_FIXED}" \
        --filter "label=com.docker.compose.service=${service}")"; then
      collection_failed=true
      continue
    fi
    while IFS= read -r container; do
      [[ -n "$container" ]] || continue
      duplicate=false
      for existing in "${containers[@]:-}"; do
        [[ "$existing" == "$container" ]] && duplicate=true
      done
      [[ "$duplicate" == true ]] || containers+=("$container")
    done <<< "$observed"
  done

  local stop_failed=false
  if [[ "${#containers[@]}" -gt 0 ]]; then
    "$DOCKER_BIN" stop --time 30 "${containers[@]}" >/dev/null 2>&1 \
      || stop_failed=true
  fi

  local verification_failed="$collection_failed"
  for service in caddy web; do
    if ! observed="$($DOCKER_BIN ps -q \
        --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME_FIXED}" \
        --filter "label=com.docker.compose.service=${service}")"; then
      verification_failed=true
      continue
    fi
    while IFS= read -r container; do
      [[ -z "$container" ]] || verification_failed=true
    done <<< "$observed"
  done
  if [[ "$stop_failed" == true || "$verification_failed" == true ]]; then
    echo "CRITICAL Unable to prove every fixed-project Caddy/web container is stopped." >&2
    return 70
  fi
  return 0
}

stop_captured_frontend() {
  [[ "$PREDEPLOY_FRONTEND_STATE_CAPTURED" == "true" ]] || return 70
  if [[ "${#PREDEPLOY_FRONTEND_RUNNING_CONTAINERS[@]}" -eq 0 ]]; then
    echo "Address Atlas Caddy/web containers are already stopped."
    return 0
  fi
  "$DOCKER_BIN" stop --time 30 \
    "${PREDEPLOY_FRONTEND_RUNNING_CONTAINERS[@]}" >/dev/null
  local index
  for index in "${!PREDEPLOY_FRONTEND_RUNNING_CONTAINERS[@]}"; do
    inspect_captured_frontend_container \
      "${PREDEPLOY_FRONTEND_RUNNING_SERVICES[$index]}" \
      "${PREDEPLOY_FRONTEND_RUNNING_CONTAINERS[$index]}" false || return $?
  done
  assert_no_unexpected_running_frontend || {
    echo "An unexpected fixed-project frontend container appeared during the maintenance stop." >&2
    return 73
  }
  echo "Stopped the exact captured Address Atlas frontend containers; PostgreSQL remains available."
}

stop_frontend_before_database_mutation() {
  capture_fixed_frontend_runtime_state || return $?
  if [[ "${#PREDEPLOY_FRONTEND_RUNNING_CONTAINERS[@]}" -gt 0 ]]; then
    # Arm recovery before the first fallible/non-transactional Docker stop. A
    # signal or per-container error may otherwise leave only half the old public
    # frontend running.
    PREDEPLOY_RECOVERY_ENABLED=true
  fi
  stop_captured_frontend
}

recover_previous_frontend_if_needed() {
  [[ "${PREDEPLOY_RECOVERY_ENABLED:-false}" == "true" ]] || return 0
  PREDEPLOY_RECOVERY_ENABLED=false
  [[ "$PREDEPLOY_FRONTEND_STATE_CAPTURED" == "true" ]] || return 70
  if [[ "${#PREDEPLOY_FRONTEND_RUNNING_CONTAINERS[@]}" -eq 0 ]]; then
    return 0
  fi
  assert_no_unexpected_running_frontend || {
    echo "CRITICAL Exact frontend recovery found an unexpected running container; refusing to create an ambiguous public stack." >&2
    fail_safe_stop_fixed_frontend || true
    return 70
  }
  echo "Pre-database work failed; restarting the exact captured frontend containers." >&2
  run_service_mutation_if_allowed \
    "$DOCKER_BIN" start "${PREDEPLOY_FRONTEND_RUNNING_CONTAINERS[@]}" \
      >/dev/null || {
    echo "CRITICAL The exact captured frontend containers could not be restarted." >&2
    fail_safe_stop_fixed_frontend || true
    return 70
  }
  local index web_was_running=false caddy_was_running=false
  for index in "${!PREDEPLOY_FRONTEND_RUNNING_CONTAINERS[@]}"; do
    inspect_captured_frontend_container \
      "${PREDEPLOY_FRONTEND_RUNNING_SERVICES[$index]}" \
      "${PREDEPLOY_FRONTEND_RUNNING_CONTAINERS[$index]}" true || {
      echo "CRITICAL A restarted frontend container no longer matches its captured identity/provenance." >&2
      fail_safe_stop_fixed_frontend || true
      return 70
    }
    [[ "${PREDEPLOY_FRONTEND_RUNNING_SERVICES[$index]}" == "web" ]] \
      && web_was_running=true
    [[ "${PREDEPLOY_FRONTEND_RUNNING_SERVICES[$index]}" == "caddy" ]] \
      && caddy_was_running=true
  done
  if [[ "$web_was_running" == "true" && "$caddy_was_running" == "true" ]]; then
    smoke_public_with_retries "$PREVIOUS_WEB_REVISION" || {
      echo "CRITICAL The exact captured frontend restarted but its old revision failed public smoke." >&2
      fail_safe_stop_fixed_frontend || true
      return 70
    }
  fi
  echo "The exact previously running frontend container set is serving again." >&2
}
