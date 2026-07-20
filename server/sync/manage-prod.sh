#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/compose.prod.yml"
ENV_FILE="${ADDRESS_ATLAS_PROD_ENV_FILE:-${SCRIPT_DIR}/.env.production}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
COMPOSE_PROJECT_NAME_FIXED="address-atlas-sync"
usage() {
  echo "Usage: $0 {up|down|config|detect-volume|detect-volumes}" >&2
  exit 64
}

validate_volume_name() {
  local value="$1"
  local variable_name="$2"
  if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]+$ ]]; then
    echo "Invalid ${variable_name} value." >&2
    exit 65
  fi
}

configured_volume_from_env_file() {
  local variable_name="$1"
  [[ -f "$ENV_FILE" ]] || return 0
  local line value
  line="$(grep -E "^[[:space:]]*${variable_name}[[:space:]]*=" "$ENV_FILE" | tail -n 1 || true)"
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

append_candidate() {
  local candidate="$1"
  [[ -n "$candidate" ]] || return 0
  local existing
  for existing in "${candidates[@]:-}"; do
    [[ "$existing" == "$candidate" ]] && return 0
  done
  candidates+=("$candidate")
}

detect_managed_volume() {
  local variable_name="$1"
  local descriptor="$2"
  local compose_volume_name="$3"
  local stable_volume="$4"
  shift 4
  local legacy_volumes=("$@")

  local configured="${!variable_name-}"
  if [[ -z "$configured" ]]; then
    configured="$(configured_volume_from_env_file "$variable_name")"
  fi

  local candidates=()
  local candidate compose_project volume_list
  # `caddy-data` and `caddy-config` are common Compose logical names. Filtering
  # on that label alone can discover an unrelated stack and, if it is the only
  # match, attach its ACME state to Address Atlas. Search only project names used
  # by the documented Address Atlas layouts; exact historical names below remain
  # the compatibility fallback for engines that lost their labels.
  for compose_project in "address-atlas-sync" "address-atlas"; do
    if ! volume_list="$("$DOCKER_BIN" volume ls \
      --filter "label=com.docker.compose.project=${compose_project}" \
      --filter "label=com.docker.compose.volume=${compose_volume_name}" \
      --format '{{.Name}}')"; then
      echo "Unable to inspect Docker volumes; refusing to guess the ${descriptor} volume." >&2
      exit 69
    fi
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] || continue
      if ! "$DOCKER_BIN" volume inspect "$candidate" >/dev/null 2>&1; then
        echo "Docker reported ${descriptor} volume '${candidate}', but it could not be inspected; refusing to continue." >&2
        exit 69
      fi
      append_candidate "$candidate"
    done <<< "$volume_list"
  done

  # Older Docker/Compose versions may not retain labels consistently. Probe
  # every exact historical name as a compatibility fallback.
  for candidate in "$stable_volume" "${legacy_volumes[@]}"; do
    if "$DOCKER_BIN" volume inspect "$candidate" >/dev/null 2>&1; then
      append_candidate "$candidate"
    fi
  done

  if [[ -n "$configured" ]]; then
    validate_volume_name "$configured" "$variable_name"
    local configured_exists=false
    if "$DOCKER_BIN" volume inspect "$configured" >/dev/null 2>&1; then
      configured_exists=true
      append_candidate "$configured"
    fi
    if [[ "$configured_exists" == true ]]; then
      printf '%s\n' "$configured"
      return 0
    fi
    if [[ "${#candidates[@]}" -gt 0 ]]; then
      echo "Configured ${descriptor} volume '${configured}' does not exist, but historical Address Atlas volumes were found:" >&2
      printf '  %s\n' "${candidates[@]}" >&2
      echo "Refusing to attach a new empty volume. Set ${variable_name} to the authoritative existing name." >&2
      exit 66
    fi
  fi

  # A deployment may have been started with an undocumented custom Compose
  # project name. Its volume carries the right logical label, but we cannot
  # distinguish it from an unrelated stack that happens to use a common name
  # such as `caddy-data`. Treat unscoped matches only as evidence that state
  # exists: never auto-adopt them and never silently create a fresh stable
  # volume beside them. An existing explicit override is authoritative and has
  # already returned above. A missing override must still pass this scan: only
  # the exact documented stable name can acknowledge a confirmed clean install.
  local foreign_candidates=()
  if ! volume_list="$("$DOCKER_BIN" volume ls \
    --filter "label=com.docker.compose.volume=${compose_volume_name}" \
    --format '{{.Name}}')"; then
    echo "Unable to inspect Docker volumes; refusing to guess the ${descriptor} volume." >&2
    exit 69
  fi
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    local recognized=false
    local existing
    for existing in "${candidates[@]:-}"; do
      if [[ "$existing" == "$candidate" ]]; then
        recognized=true
        break
      fi
    done
    [[ "$recognized" == true ]] && continue
    if ! "$DOCKER_BIN" volume inspect "$candidate" >/dev/null 2>&1; then
      echo "Docker reported ${descriptor} volume '${candidate}', but it could not be inspected; refusing to continue." >&2
      exit 69
    fi
    local duplicate=false
    for existing in "${foreign_candidates[@]:-}"; do
      if [[ "$existing" == "$candidate" ]]; then
        duplicate=true
        break
      fi
    done
    [[ "$duplicate" == true ]] || foreign_candidates+=("$candidate")
  done <<< "$volume_list"

  if [[ "${#foreign_candidates[@]}" -gt 0 ]]; then
    if [[ -n "$configured" && "$configured" == "$stable_volume" ]]; then
      printf '%s\n' "$configured"
      return 0
    fi
    echo "Docker volumes with the '${compose_volume_name}' Compose label exist outside recognized Address Atlas projects:" >&2
    printf '  %s\n' "${foreign_candidates[@]}" >&2
    echo "They may belong to a custom Address Atlas project or to an unrelated stack; refusing to create or adopt ${descriptor} state automatically." >&2
    echo "Inspect them, then set ${variable_name} to the authoritative existing volume, or to '${stable_volume}' only after confirming this is a new installation." >&2
    exit 66
  fi

  if [[ -n "$configured" ]]; then
    if [[ "$configured" == "$stable_volume" ]]; then
      # No known or unrecognized labeled state exists. The exact documented
      # stable name is the only missing volume Compose may create implicitly.
      printf '%s\n' "$configured"
      return 0
    fi
    echo "Configured ${descriptor} volume '${configured}' does not exist." >&2
    echo "Refusing to create an arbitrary named volume because this may be a typo during an upgrade." >&2
    echo "Use '${stable_volume}' for a confirmed new installation, or pre-create and inspect '${configured}' before setting ${variable_name}." >&2
    exit 66
  fi

  case "${#candidates[@]}" in
    0)
      printf '%s\n' "$stable_volume"
      ;;
    1)
      printf '%s\n' "${candidates[0]}"
      ;;
    *)
      echo "Multiple Address Atlas ${descriptor} volumes were found; refusing to choose or copy data automatically:" >&2
      printf '  %s\n' "${candidates[@]}" >&2
      echo "Inspect them, then set ${variable_name} to the authoritative volume in ${ENV_FILE}." >&2
      exit 66
      ;;
  esac
}

detect_volume() {
  detect_managed_volume \
    "ADDRESS_ATLAS_POSTGRES_VOLUME" \
    "PostgreSQL data" \
    "address-atlas-prod-postgres" \
    "address-atlas-prod-postgres" \
    "address-atlas-sync_address-atlas-prod-postgres" \
    "address-atlas_address-atlas-prod-postgres"
}

detect_caddy_data_volume() {
  detect_managed_volume \
    "ADDRESS_ATLAS_CADDY_DATA_VOLUME" \
    "Caddy data" \
    "caddy-data" \
    "address-atlas-caddy-data" \
    "address-atlas-sync_caddy-data" \
    "address-atlas_caddy-data"
}

detect_caddy_config_volume() {
  detect_managed_volume \
    "ADDRESS_ATLAS_CADDY_CONFIG_VOLUME" \
    "Caddy config" \
    "caddy-config" \
    "address-atlas-caddy-config" \
    "address-atlas-sync_caddy-config" \
    "address-atlas_caddy-config"
}

detect_all_volumes() {
  local postgres_volume caddy_data_volume caddy_config_volume
  postgres_volume="$(detect_volume)"
  caddy_data_volume="$(detect_caddy_data_volume)"
  caddy_config_volume="$(detect_caddy_config_volume)"
  printf 'PostgreSQL data: %s\nCaddy data: %s\nCaddy config: %s\n' \
    "$postgres_volume" "$caddy_data_volume" "$caddy_config_volume"
}

assert_volume_mount_safe_for_up() {
  local volume="$1"
  local descriptor="$2"
  local expected_service="$3"
  local mounted_containers

  if ! mounted_containers="$("$DOCKER_BIN" ps \
    --filter "volume=${volume}" \
    --format '{{.ID}}|{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.service"}}')"; then
    echo "Unable to inspect running containers using ${descriptor} volume '${volume}'; refusing to start." >&2
    exit 69
  fi

  local container_id compose_project compose_service
  while IFS='|' read -r container_id compose_project compose_service; do
    [[ -n "$container_id" ]] || continue
    if [[ "$compose_project" != "$COMPOSE_PROJECT_NAME_FIXED" || "$compose_service" != "$expected_service" ]]; then
      echo "Running container '${container_id}' already mounts ${descriptor} volume '${volume}'." >&2
      echo "It belongs to Compose project '${compose_project:-<unlabeled>}' service '${compose_service:-<unlabeled>}', not ${COMPOSE_PROJECT_NAME_FIXED}/${expected_service}." >&2
      echo "Stop the legacy or foreign stack cleanly before starting Address Atlas; refusing simultaneous volume attachment." >&2
      exit 67
    fi
  done <<< "$mounted_containers"
}

[[ "$#" -eq 1 ]] || usage
command="$1"
case "$command" in
  detect-volume)
    detect_volume
    ;;
  detect-volumes)
    detect_all_volumes
    ;;
  up|down|config)
    if [[ ! -f "$ENV_FILE" && ( "$command" != "config" || -n "${ADDRESS_ATLAS_PROD_ENV_FILE:-}" ) ]]; then
      echo "Missing production environment file: ${ENV_FILE}" >&2
      echo "Copy server/sync/.env.production.example and fill in its secrets first." >&2
      exit 66
    fi
    selected_postgres_volume="$(detect_volume)"
    selected_caddy_data_volume="$(detect_caddy_data_volume)"
    selected_caddy_config_volume="$(detect_caddy_config_volume)"
    export ADDRESS_ATLAS_POSTGRES_VOLUME="$selected_postgres_volume"
    export ADDRESS_ATLAS_CADDY_DATA_VOLUME="$selected_caddy_data_volume"
    export ADDRESS_ATLAS_CADDY_CONFIG_VOLUME="$selected_caddy_config_volume"
    echo "Using PostgreSQL volume: ${selected_postgres_volume}"
    echo "Using Caddy data volume: ${selected_caddy_data_volume}"
    echo "Using Caddy config volume: ${selected_caddy_config_volume}"
    compose_args=(compose)
    if [[ -f "$ENV_FILE" ]]; then
      compose_args+=(--env-file "$ENV_FILE")
    fi
    # CLI project selection outranks COMPOSE_PROJECT_NAME from the shell/env
    # file and the Compose top-level name. Keep ownership labels deterministic.
    compose_args+=(--project-name "$COMPOSE_PROJECT_NAME_FIXED" -f "$COMPOSE_FILE")
    if [[ "$command" == "config" ]]; then
      exec "$DOCKER_BIN" "${compose_args[@]}" config --quiet
    elif [[ "$command" == "up" ]]; then
      assert_volume_mount_safe_for_up "$selected_postgres_volume" "PostgreSQL data" "postgres"
      assert_volume_mount_safe_for_up "$selected_caddy_data_volume" "Caddy data" "caddy"
      assert_volume_mount_safe_for_up "$selected_caddy_config_volume" "Caddy config" "caddy"
      exec "$DOCKER_BIN" "${compose_args[@]}" up -d --build
    fi
    exec "$DOCKER_BIN" "${compose_args[@]}" down
    ;;
  *)
    usage
    ;;
esac
