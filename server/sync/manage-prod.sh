#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/compose.prod.yml"
ENV_FILE="${ADDRESS_ATLAS_PROD_ENV_FILE:-${SCRIPT_DIR}/.env.production}"
ENV_SNAPSHOT_DIRECTORY=""
ENV_SNAPSHOT_FILE=""
ENV_SNAPSHOT_ROOT=""
PREDEPLOY_RECOVERY_ENABLED=false
PREDEPLOY_COMPOSE_COMMAND=()
IMMUTABLE_SOURCE_ROOT=""
IMMUTABLE_SOURCE_BASE=""
IMMUTABLE_SOURCE_STAGING=""
IMMUTABLE_SOURCE_ARCHIVE=""
DOCKER_BIN="${DOCKER_BIN:-docker}"
GIT_BIN="${GIT_BIN:-git}"
CURL_BIN="${CURL_BIN:-curl}"
NODE_BIN="${NODE_BIN:-node}"
COMPOSE_PROJECT_NAME_FIXED="address-atlas-sync"
BACKUP_SCRIPT="${ADDRESS_ATLAS_BACKUP_SCRIPT:-${SCRIPT_DIR}/postgres-backup.sh}"
NATIVE_CONFIG_STATE_TOOL="${SCRIPT_DIR}/native-config-deploy-state.mjs"
PINNED_POSTGRES_IMAGE="postgres:16.14-alpine3.24@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777"
EXPECTED_RESTORE_MIGRATION_HEAD=3
usage() {
  cat >&2 <<EOF
Usage:
  $0 {up|down|maintenance|config|detect-volume|detect-volumes|backup|verify-backup|restore-drill}
  $0 adopt-native-config --confirm ADOPT:<revision>:<version>:<sha256>
  $0 restore <absolute-backup.dump.age> --confirm RESTORE:<database>
  $0 bootstrap-restore <absolute-backup.dump.age> --confirm BOOTSTRAP-RESTORE:<database>

  up             create and verify an encrypted PostgreSQL backup, then deploy
  down           emergency-stop the fixed Address Atlas project without volume discovery
  maintenance    stop only Caddy/web while leaving PostgreSQL available
  backup         create an encrypted PostgreSQL backup of the running stack
  verify-backup  fully decrypt/inspect the newest backup without writing plaintext
  restore-drill  restore the newest backup into an isolated temporary database
  restore        replace production only after explicit env + confirmation gates
  bootstrap-restore
                 recover a lost host onto a provably pristine PostgreSQL 16 cluster
                 and return service only after policy, database, and public checks
  adopt-native-config
                 one-time, explicit recovery of a missing live config receipt
EOF
  exit 64
}

build_revision() {
  local revision
  revision="$("$GIT_BIN" -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null)" || {
    echo "Unable to resolve the deployment Git revision." >&2
    exit 69
  }
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Deployment Git revision is malformed." >&2
    exit 65
  }
  printf '%s\n' "$revision"
}

assert_clean_deployment_checkout() {
  if [[ -n "$("$GIT_BIN" -C "$ROOT_DIR" status --porcelain --untracked-files=normal)" ]]; then
    echo "Production deployment requires a clean Git checkout; refusing an unidentifiable image build." >&2
    exit 65
  fi
}

assert_authorized_deployment_revision() {
  local mode="${1:-exact}"
  [[ "$mode" == "exact" || "$mode" == "install-resume" \
     || "$mode" == "bootstrap-resume" ]] || return 70
  local branch head remote_head
  branch="$("$GIT_BIN" -C "$ROOT_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null)" || {
    echo "Production deployment requires the checked-out main branch, not detached HEAD." >&2
    exit 65
  }
  [[ "$branch" == "main" ]] || {
    echo "Production deployment is restricted to the main branch." >&2
    exit 65
  }
  "$GIT_BIN" -C "$ROOT_DIR" fetch --quiet --no-tags origin \
    refs/heads/main:refs/remotes/origin/main || {
    echo "Unable to refresh the authoritative origin/main deployment ref." >&2
    exit 69
  }
  head="$("$GIT_BIN" -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null)" || exit 69
  remote_head="$("$GIT_BIN" -C "$ROOT_DIR" rev-parse refs/remotes/origin/main 2>/dev/null)" || {
    echo "Unable to resolve the authoritative origin/main deployment ref." >&2
    exit 69
  }
  [[ "$head" =~ ^[0-9a-f]{40}$ && "$remote_head" =~ ^[0-9a-f]{40}$ ]] || exit 69
  if [[ "$mode" == "exact" ]]; then
    [[ "$head" == "$remote_head" ]] || {
      echo "Production deployment requires HEAD to equal the freshly fetched origin/main commit." >&2
      exit 67
    }
  elif [[ "$mode" == "install-resume" ]]; then
    [[ -n "${INSTALL_REVISION:-}" && "$head" == "$INSTALL_REVISION" ]] || {
      echo "First-install recovery must run from the exact recorded revision." >&2
      exit 67
    }
    "$GIT_BIN" -C "$ROOT_DIR" merge-base --is-ancestor "$head" "$remote_head" || {
      echo "The interrupted first-install revision is not an ancestor of current origin/main." >&2
      exit 67
    }
  else
    [[ "${ADDRESS_ATLAS_BOOTSTRAP_TARGET_REVISION:-}" =~ ^[0-9a-f]{40}$ \
       && "$head" == "$ADDRESS_ATLAS_BOOTSTRAP_TARGET_REVISION" ]] || {
      echo "Bootstrap recovery must run from the exact target revision recorded by durable recovery state." >&2
      exit 67
    }
    "$GIT_BIN" -C "$ROOT_DIR" merge-base --is-ancestor "$head" "$remote_head" || {
      echo "Bootstrap recovery must resume from its recorded revision, which must remain an ancestor of origin/main." >&2
      exit 67
    }
  fi
}

assert_deployed_revision_is_authorized_ancestor() {
  local revision="$1"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || return 65
  "$GIT_BIN" -C "$ROOT_DIR" cat-file -e "${revision}^{commit}" 2>/dev/null || {
    echo "The running release revision is not a known Git commit." >&2
    return 67
  }
  "$GIT_BIN" -C "$ROOT_DIR" merge-base --is-ancestor \
    "$revision" refs/remotes/origin/main || {
    echo "The running release revision is not an ancestor of authoritative origin/main." >&2
    return 67
  }
}

assert_postgres_container_uses_volume() {
  local container="$1"
  local expected_volume="$2"
  local mount_record
  mount_record="$("$DOCKER_BIN" inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Type}}|{{.Name}}{{"\n"}}{{end}}{{end}}' "$container" 2>/dev/null)" || {
    echo "Unable to inspect the PostgreSQL data mount for container '${container}'." >&2
    exit 69
  }
  [[ "$mount_record" == "volume|${expected_volume}" ]] || {
    echo "The fixed-project PostgreSQL container '${container}' does not mount the selected authoritative volume '${expected_volume}'." >&2
    echo "Observed data mount: ${mount_record:-<missing or ambiguous>}. Refusing to start or back up the wrong database." >&2
    exit 67
  }
}

capture_previous_web_release() {
  PREVIOUS_WEB_IMAGE_ID=""
  PREVIOUS_WEB_REVISION=""
  PREVIOUS_WEB_RUNNING="false"
  local containers container_count=0 container="" candidate metadata
  containers="$("$DOCKER_BIN" ps -aq \
    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME_FIXED}" \
    --filter "label=com.docker.compose.service=web")" || {
    echo "Unable to inspect the currently deployed web container." >&2
    exit 69
  }
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    container_count=$((container_count + 1))
    container="$candidate"
  done <<< "$containers"
  [[ "$container_count" -le 1 ]] || {
    echo "Multiple fixed-project web containers exist; refusing an ambiguous deployment rollback point." >&2
    exit 66
  }
  [[ "$container_count" -eq 1 ]] || return 0

  metadata="$("$DOCKER_BIN" inspect --format '{{.Image}}|{{index .Config.Labels "org.opencontainers.image.revision"}}|{{.State.Running}}' "$container" 2>/dev/null)" || {
    echo "Unable to inspect the currently deployed web image provenance." >&2
    exit 69
  }
  IFS='|' read -r PREVIOUS_WEB_IMAGE_ID PREVIOUS_WEB_REVISION PREVIOUS_WEB_RUNNING <<< "$metadata"
  [[ "$PREVIOUS_WEB_IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ \
     && "$PREVIOUS_WEB_REVISION" =~ ^[0-9a-f]{40}$ \
     && ( "$PREVIOUS_WEB_RUNNING" == "true" || "$PREVIOUS_WEB_RUNNING" == "false" ) ]] || {
    echo "The existing web container lacks exact image/revision provenance; refusing a deployment without a safe rollback point." >&2
    exit 67
  }
}

native_config_state_file() {
  local path="${ADDRESS_ATLAS_NATIVE_CONFIG_STATE_FILE:-}"
  [[ -n "$path" ]] || path="$(configured_volume_from_env_file ADDRESS_ATLAS_NATIVE_CONFIG_STATE_FILE)"
  printf '%s\n' "${path:-/var/lib/address-atlas/native-config-deployment.json}"
}

install_deployment_state_file() {
  local path="${ADDRESS_ATLAS_INSTALL_STATE_FILE:-}"
  [[ -n "$path" ]] || path="$(configured_volume_from_env_file ADDRESS_ATLAS_INSTALL_STATE_FILE)"
  printf '%s\n' "${path:-/var/lib/address-atlas/install-deployment.json}"
}

load_install_deployment_state() {
  local expected_volume="$1"
  INSTALL_STATE_FILE="$(install_deployment_state_file)"
  INSTALL_PHASE=""
  INSTALL_REVISION=""
  INSTALL_IMAGE_ID=""
  INSTALL_POSTGRES_VOLUME=""
  "$NODE_BIN" "$NATIVE_CONFIG_STATE_TOOL" validate "$INSTALL_STATE_FILE" || {
    echo "The first-install recovery state path is not safely prepared." >&2
    exit 66
  }
  if [[ -e "$INSTALL_STATE_FILE" || -L "$INSTALL_STATE_FILE" ]]; then
    local record extra
    record="$("$NODE_BIN" "$NATIVE_CONFIG_STATE_TOOL" install-read "$INSTALL_STATE_FILE")" || {
      echo "The first-install recovery state is invalid; refusing deployment." >&2
      exit 66
    }
    IFS='|' read -r INSTALL_PHASE INSTALL_REVISION INSTALL_IMAGE_ID \
      INSTALL_POSTGRES_VOLUME extra <<< "$record"
    [[ -z "$extra" \
       && "$INSTALL_REVISION" == "$ADDRESS_ATLAS_BUILD_REVISION" \
       && "$INSTALL_POSTGRES_VOLUME" == "$expected_volume" ]] || {
      echo "The unfinished first-install state belongs to different source or storage; resume its exact revision first." >&2
      exit 67
    }
  fi
}

record_install_deployment_phase() {
  local phase="$1"
  [[ -n "$INSTALL_REVISION" && -n "$INSTALL_IMAGE_ID" \
     && -n "$INSTALL_POSTGRES_VOLUME" ]] || {
    echo "Internal first-install recovery provenance is missing." >&2
    return 70
  }
  "$NODE_BIN" "$NATIVE_CONFIG_STATE_TOOL" install-write \
    "$INSTALL_STATE_FILE" "$phase" "$INSTALL_REVISION" \
    "$INSTALL_IMAGE_ID" "$INSTALL_POSTGRES_VOLUME" >/dev/null || return $?
  INSTALL_PHASE="$phase"
}

complete_install_deployment_state() {
  [[ -n "$INSTALL_PHASE" ]] || return 0
  "$NODE_BIN" "$NATIVE_CONFIG_STATE_TOOL" install-delete \
    "$INSTALL_STATE_FILE" "$INSTALL_REVISION" "$INSTALL_IMAGE_ID" \
    "$INSTALL_POSTGRES_VOLUME" || {
    echo "The deployment is live and verified, but first-install recovery state cleanup failed." >&2
    return 74
  }
  INSTALL_PHASE=""
}

fingerprint_native_config() {
  command -v "$NODE_BIN" >/dev/null 2>&1 || {
    echo "Node.js is required for native-config deployment continuity checks." >&2
    return 69
  }
  "$NODE_BIN" "$NATIVE_CONFIG_STATE_TOOL" fingerprint
}

record_candidate_native_config() {
  local config="$1"
  local config_record config_extra
  config_record="$(printf '%s' "$config" | fingerprint_native_config)" || return 1
  IFS='|' read -r CANDIDATE_CONFIG_VERSION CANDIDATE_CONFIG_DIGEST \
    CANDIDATE_CONFIG_UPDATED_AT_MS config_extra <<< "$config_record"
  [[ -z "$config_extra" ]]
}

clear_backup_native_config_receipt() {
  unset ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_VERSION \
    ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_SHA256 \
    ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_UPDATED_AT_EPOCH_MS \
    ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_SERVING_REVISION
}

set_backup_native_config_receipt() {
  local version="$1" digest="$2" updated_at="$3" revision="$4"
  clear_backup_native_config_receipt
  [[ "$version" =~ ^[0-9]+$ && "$version" -ge 5 && "$version" -le 2000000000 \
     && "$digest" =~ ^[0-9a-f]{64}$ \
     && "$updated_at" =~ ^[1-9][0-9]*$ && "$updated_at" -le 8640000000000000 \
     && "$revision" =~ ^[0-9a-f]{40}$ ]] || {
    echo "The verified native-config receipt cannot be bound into a backup manifest." >&2
    return 65
  }
  ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_VERSION="$version"
  ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_SHA256="$digest"
  ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_UPDATED_AT_EPOCH_MS="$updated_at"
  ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_SERVING_REVISION="$revision"
  export ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_VERSION \
    ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_SHA256 \
    ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_UPDATED_AT_EPOCH_MS \
    ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_SERVING_REVISION
}

load_durable_native_config_baseline() {
  clear_backup_native_config_receipt
  BASELINE_CONFIG_VERSION=""
  BASELINE_CONFIG_DIGEST=""
  BASELINE_CONFIG_UPDATED_AT_MS=""
  BASELINE_CONFIG_REVISION=""
  BASELINE_CONFIG_IMAGE_ID=""
  APPROVED_CONFIG_VERSION=""
  APPROVED_CONFIG_DIGEST=""
  APPROVED_CONFIG_UPDATED_AT_MS=""
  NATIVE_CONFIG_STATE_FILE="$(native_config_state_file)"
  "$NODE_BIN" "$NATIVE_CONFIG_STATE_TOOL" validate "$NATIVE_CONFIG_STATE_FILE" || {
    echo "The native-config deployment receipt path is not safely prepared." >&2
    exit 66
  }

  local state_record="" state_extra=""
  if [[ -e "$NATIVE_CONFIG_STATE_FILE" || -L "$NATIVE_CONFIG_STATE_FILE" ]]; then
    state_record="$("$NODE_BIN" "$NATIVE_CONFIG_STATE_TOOL" read "$NATIVE_CONFIG_STATE_FILE")" || {
      echo "The durable native-config deployment receipt is invalid; refusing deployment." >&2
      exit 66
    }
    IFS='|' read -r BASELINE_CONFIG_VERSION BASELINE_CONFIG_DIGEST \
      BASELINE_CONFIG_UPDATED_AT_MS BASELINE_CONFIG_REVISION \
      BASELINE_CONFIG_IMAGE_ID state_extra <<< "$state_record"
    [[ -z "$state_extra" ]] || {
      echo "The durable native-config deployment receipt is malformed." >&2
      exit 66
    }
  fi
}

merge_signed_backup_native_config_baseline() {
  local version="$1" digest="$2" updated_at="$3" revision="$4" image_id="$5"
  [[ "$version" =~ ^[0-9]+$ && "$version" -ge 5 && "$version" -le 2000000000 \
     && "$digest" =~ ^[0-9a-f]{64}$ \
     && "$updated_at" =~ ^[1-9][0-9]*$ && "$updated_at" -le 8640000000000000 \
     && "$revision" =~ ^[0-9a-f]{40}$ \
     && "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "The signed backup native-config baseline is malformed." >&2
    return 65
  }

  if [[ -z "$BASELINE_CONFIG_VERSION" ]]; then
    BASELINE_CONFIG_VERSION="$version"
    BASELINE_CONFIG_DIGEST="$digest"
    BASELINE_CONFIG_UPDATED_AT_MS="$updated_at"
    BASELINE_CONFIG_REVISION="$revision"
    BASELINE_CONFIG_IMAGE_ID="$image_id"
  elif (( BASELINE_CONFIG_VERSION == version )); then
    [[ "$BASELINE_CONFIG_DIGEST" == "$digest" \
       && "$BASELINE_CONFIG_UPDATED_AT_MS" == "$updated_at" ]] || {
      echo "The durable and signed backup config baselines conflict at one version." >&2
      return 67
    }
  elif (( BASELINE_CONFIG_VERSION < version )); then
    (( BASELINE_CONFIG_UPDATED_AT_MS <= updated_at )) || {
      echo "The signed backup config has a newer version but an older policy timestamp." >&2
      return 67
    }
    BASELINE_CONFIG_VERSION="$version"
    BASELINE_CONFIG_DIGEST="$digest"
    BASELINE_CONFIG_UPDATED_AT_MS="$updated_at"
    BASELINE_CONFIG_REVISION="$revision"
    BASELINE_CONFIG_IMAGE_ID="$image_id"
  else
    (( BASELINE_CONFIG_UPDATED_AT_MS >= updated_at )) || {
      echo "The durable config receipt has a newer version but an older policy timestamp." >&2
      return 67
    }
  fi

  SIGNED_BACKUP_CONFIG_VERSION="$version"
  SIGNED_BACKUP_CONFIG_DIGEST="$digest"
  SIGNED_BACKUP_CONFIG_UPDATED_AT_MS="$updated_at"
  SIGNED_BACKUP_CONFIG_REVISION="$revision"
  SIGNED_BACKUP_WEB_IMAGE_ID="$image_id"
}

capture_native_config_baseline() {
  load_durable_native_config_baseline

  if [[ -n "$PREVIOUS_WEB_IMAGE_ID" && "$PREVIOUS_WEB_RUNNING" == "true" ]]; then
    local domain live_version live_digest live_updated_at
    domain="$(production_domain)" || exit $?
    probe_public_native_config \
      "https://${domain}/config/native?deployment_probe=${PREVIOUS_WEB_REVISION}" \
      "$PREVIOUS_WEB_REVISION" || {
      echo "Unable to verify the currently served native config and revision before deployment." >&2
      exit 69
    }
    live_version="$CANDIDATE_CONFIG_VERSION"
    live_digest="$CANDIDATE_CONFIG_DIGEST"
    live_updated_at="$CANDIDATE_CONFIG_UPDATED_AT_MS"
    if [[ -n "$BASELINE_CONFIG_VERSION" ]]; then
      [[ "$BASELINE_CONFIG_VERSION" == "$live_version" \
         && "$BASELINE_CONFIG_DIGEST" == "$live_digest" \
         && "$BASELINE_CONFIG_UPDATED_AT_MS" == "$live_updated_at" \
         && "$BASELINE_CONFIG_REVISION" == "$PREVIOUS_WEB_REVISION" \
         && "$BASELINE_CONFIG_IMAGE_ID" == "$PREVIOUS_WEB_IMAGE_ID" ]] || {
        echo "The live web/config state disagrees with its last verified deployment receipt." >&2
        exit 67
      }
    else
      echo "A running release has no durable native-config deployment receipt; explicit recovery is required." >&2
      exit 67
    fi
  elif [[ -n "$PREVIOUS_WEB_IMAGE_ID" ]]; then
    if [[ -n "$BASELINE_CONFIG_VERSION" ]]; then
      [[ "$BASELINE_CONFIG_REVISION" == "$PREVIOUS_WEB_REVISION" \
         && "$BASELINE_CONFIG_IMAGE_ID" == "$PREVIOUS_WEB_IMAGE_ID" ]] || {
        echo "A stopped web container disagrees with its exact durable deployment receipt." >&2
        exit 67
      }
    elif [[ -n "${INSTALL_PHASE:-}" ]]; then
      [[ "$INSTALL_REVISION" == "$PREVIOUS_WEB_REVISION" \
         && "$INSTALL_IMAGE_ID" == "$PREVIOUS_WEB_IMAGE_ID" ]] || {
        echo "The stopped first-install web container disagrees with its recovery provenance." >&2
        exit 67
      }
    else
      echo "A stopped web container is not a verified rollback point without an exact durable deployment receipt." >&2
      exit 67
    fi
  fi
  if [[ -n "$BASELINE_CONFIG_VERSION" ]]; then
    set_backup_native_config_receipt \
      "$BASELINE_CONFIG_VERSION" "$BASELINE_CONFIG_DIGEST" \
      "$BASELINE_CONFIG_UPDATED_AT_MS" "$BASELINE_CONFIG_REVISION" || exit $?
  fi
}

stop_fixed_project() {
  local containers=()
  local container
  while IFS= read -r container; do
    [[ -n "$container" ]] && containers+=("$container")
  done < <("$DOCKER_BIN" ps -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME_FIXED}")
  if [[ "${#containers[@]}" -eq 0 ]]; then
    echo "Address Atlas production containers are already stopped."
    return 0
  fi
  "$DOCKER_BIN" stop --time 30 "${containers[@]}" >/dev/null
  echo "Stopped ${#containers[@]} Address Atlas production container(s); volumes and containers were preserved."
}

stop_fixed_frontend() {
  local containers=()
  local service container existing duplicate
  for service in caddy web; do
    while IFS= read -r container; do
      [[ -n "$container" ]] || continue
      duplicate=false
      for existing in "${containers[@]:-}"; do
        [[ "$existing" == "$container" ]] && duplicate=true
      done
      [[ "$duplicate" == true ]] || containers+=("$container")
    done < <("$DOCKER_BIN" ps -q \
      --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME_FIXED}" \
      --filter "label=com.docker.compose.service=${service}")
  done
  if [[ "${#containers[@]}" -eq 0 ]]; then
    echo "Address Atlas Caddy/web containers are already stopped."
    return 0
  fi
  "$DOCKER_BIN" stop --time 30 "${containers[@]}" >/dev/null
  echo "Stopped Address Atlas Caddy/web; PostgreSQL remains available for maintenance."
}

wait_for_postgres_health() {
  local container="$1"
  local attempt status
  for attempt in {1..45}; do
    status="$("$DOCKER_BIN" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || true)"
    [[ "$status" == "healthy" ]] && return 0
    [[ "$status" == "unhealthy" || "$status" == "exited" || "$status" == "dead" ]] && break
    sleep 2
  done
  echo "PostgreSQL did not become healthy before the encrypted backup gate." >&2
  exit 70
}

ensure_postgres_container_ready() {
  local expected_volume="$1"
  shift
  local compose_command=("$@")
  local postgres_containers=()
  local container
  while IFS= read -r container; do
    [[ -n "$container" ]] && postgres_containers+=("$container")
  done < <("$DOCKER_BIN" ps -aq \
    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME_FIXED}" \
    --filter "label=com.docker.compose.service=postgres")

  if [[ "${#postgres_containers[@]}" -gt 1 ]]; then
    echo "Multiple fixed-project PostgreSQL containers exist; refusing to choose a backup source." >&2
    exit 66
  fi
  if [[ "${#postgres_containers[@]}" -eq 1 ]]; then
    container="${postgres_containers[0]}"
    assert_postgres_container_uses_volume "$container" "$expected_volume"
    if [[ "$("$DOCKER_BIN" inspect --format '{{.State.Running}}' "$container")" != "true" ]]; then
      "$DOCKER_BIN" start "$container" >/dev/null
    fi
  else
    "$DOCKER_BIN" "${compose_command[@]}" up -d postgres
    container="$("$DOCKER_BIN" ps -q \
      --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME_FIXED}" \
      --filter "label=com.docker.compose.service=postgres")"
    [[ -n "$container" ]] || {
      echo "Compose did not create the production PostgreSQL container." >&2
      exit 70
    }
    assert_postgres_container_uses_volume "$container" "$expected_volume"
  fi

  wait_for_postgres_health "$container"
  READY_POSTGRES_CONTAINER="$container"
}

require_existing_postgres_container_ready() {
  local expected_volume="$1"
  local containers=() container
  while IFS= read -r container; do
    [[ -n "$container" ]] && containers+=("$container")
  done < <("$DOCKER_BIN" ps -aq \
    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME_FIXED}" \
    --filter "label=com.docker.compose.service=postgres")
  [[ "${#containers[@]}" -eq 1 ]] || {
    echo "A production backup requires exactly one existing fixed-project PostgreSQL container." >&2
    exit 66
  }
  container="${containers[0]}"
  assert_postgres_container_uses_volume "$container" "$expected_volume"
  if [[ "$("$DOCKER_BIN" inspect --format '{{.State.Running}}' "$container")" != "true" ]]; then
    "$DOCKER_BIN" start "$container" >/dev/null
  fi
  wait_for_postgres_health "$container"
  READY_POSTGRES_CONTAINER="$container"
}

prepare_verified_predeploy_backup() {
  local expected_volume="$1"
  shift
  local compose_command=("$@")
  ensure_postgres_container_ready "$expected_volume" "${compose_command[@]}"
  local backup
  backup="$({
    unset ADDRESS_ATLAS_BUILD_REVISION
    ADDRESS_ATLAS_POSTGRES_CONTAINER="$READY_POSTGRES_CONTAINER" \
      bash "$BACKUP_SCRIPT" create-predeploy
  })"
  ADDRESS_ATLAS_POSTGRES_CONTAINER="$READY_POSTGRES_CONTAINER" \
    bash "$BACKUP_SCRIPT" verify "$backup" >/dev/null
  echo "Verified encrypted pre-deploy backup: ${backup}"
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

validate_production_environment_file() {
  local required="$1"
  [[ "$required" == "true" || "$required" == "false" ]] || return 70
  if [[ ! -e "$ENV_FILE" && ! -L "$ENV_FILE" ]]; then
    if [[ "$required" == "true" || -n "${ADDRESS_ATLAS_PROD_ENV_FILE:-}" ]]; then
      echo "Missing production environment file: ${ENV_FILE}" >&2
      return 66
    fi
    return 0
  fi
  [[ "$ENV_FILE" == /* && -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || {
    echo "Production environment file must be an absolute regular non-symlink file." >&2
    return 66
  }
  local parent canonical mode owner parent_mode parent_owner permissions parent_permissions
  parent="$(dirname "$ENV_FILE")"
  canonical="$(cd "$parent" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$ENV_FILE")")" || {
    echo "Production environment parent directory is unavailable." >&2
    return 66
  }
  [[ "$canonical" == "$ENV_FILE" && ! -L "$parent" ]] || {
    echo "Production environment path must be canonical and contain no final-directory symlink." >&2
    return 66
  }
  mode="$(stat -c %a "$ENV_FILE" 2>/dev/null \
    || stat -f %Lp "$ENV_FILE" 2>/dev/null || true)"
  owner="$(stat -c %u "$ENV_FILE" 2>/dev/null \
    || stat -f %u "$ENV_FILE" 2>/dev/null || true)"
  parent_mode="$(stat -c %a "$parent" 2>/dev/null \
    || stat -f %Lp "$parent" 2>/dev/null || true)"
  parent_owner="$(stat -c %u "$parent" 2>/dev/null \
    || stat -f %u "$parent" 2>/dev/null || true)"
  [[ "$mode" =~ ^[0-7]{3,4}$ && "$parent_mode" =~ ^[0-7]{3,4}$ \
     && "$owner" =~ ^[0-9]+$ && "$parent_owner" =~ ^[0-9]+$ ]] || {
    echo "Unable to validate production environment file metadata." >&2
    return 66
  }
  permissions=$((8#$mode))
  parent_permissions=$((8#$parent_mode))
  [[ "$owner" -eq "$(id -u)" && "$parent_owner" -eq "$(id -u)" \
     && $((permissions & 8#077)) -eq 0 \
     && $((parent_permissions & 8#022)) -eq 0 ]] || {
    echo "Production environment file must be operator-owned/private in a non-writable operator-owned directory." >&2
    return 66
  }
}

environment_file_identity() {
  local file="$1"
  stat -c '%d:%i:%s:%Y:%Z' "$file" 2>/dev/null \
    || stat -f '%d:%i:%z:%m:%c' "$file" 2>/dev/null
}

cleanup_environment_snapshot() {
  if [[ -n "$ENV_SNAPSHOT_FILE" \
      && "$ENV_SNAPSHOT_FILE" == "$ENV_SNAPSHOT_DIRECTORY/production.env" \
      && -f "$ENV_SNAPSHOT_FILE" && ! -L "$ENV_SNAPSHOT_FILE" ]]; then
    find "$ENV_SNAPSHOT_FILE" -maxdepth 0 -type f -delete 2>/dev/null || true
  fi
  if [[ -n "$ENV_SNAPSHOT_DIRECTORY" \
      && -n "$ENV_SNAPSHOT_ROOT" \
      && "$ENV_SNAPSHOT_DIRECTORY" == "$ENV_SNAPSHOT_ROOT"/address-atlas-production-env.* \
      && -d "$ENV_SNAPSHOT_DIRECTORY" && ! -L "$ENV_SNAPSHOT_DIRECTORY" ]]; then
    rmdir "$ENV_SNAPSHOT_DIRECTORY" 2>/dev/null || true
  fi
}

recover_previous_frontend_if_needed() {
  [[ "$PREDEPLOY_RECOVERY_ENABLED" == "true" ]] || return 0
  PREDEPLOY_RECOVERY_ENABLED=false
  if [[ -z "${PREVIOUS_WEB_IMAGE_ID:-}" \
      || "${PREVIOUS_WEB_RUNNING:-false}" != "true" \
      || "${#PREDEPLOY_COMPOSE_COMMAND[@]}" -eq 0 ]]; then
    return 0
  fi
  echo "Pre-deploy work failed; restarting the exact captured frontend containers." >&2
  if ! env ADDRESS_ATLAS_BUILD_REVISION="$PREVIOUS_WEB_REVISION" \
      "$DOCKER_BIN" "${PREDEPLOY_COMPOSE_COMMAND[@]}" start web caddy >/dev/null \
      || ! smoke_public_with_retries "$PREVIOUS_WEB_REVISION"; then
    echo "CRITICAL The captured frontend could not be restarted and verified; keep the service in maintenance and investigate." >&2
    return 70
  fi
  echo "The previously verified frontend release is serving again." >&2
}

manage_exit_cleanup() {
  local status=$?
  trap - EXIT
  recover_previous_frontend_if_needed || true
  if [[ -n "$IMMUTABLE_SOURCE_STAGING" \
      && -d "$IMMUTABLE_SOURCE_STAGING" && ! -L "$IMMUTABLE_SOURCE_STAGING" ]]; then
    find "$IMMUTABLE_SOURCE_STAGING" -type d -exec chmod u+w {} + 2>/dev/null || true
    find "$IMMUTABLE_SOURCE_STAGING" -depth -delete 2>/dev/null || true
  fi
  if [[ -n "$IMMUTABLE_SOURCE_ARCHIVE" \
      && -f "$IMMUTABLE_SOURCE_ARCHIVE" && ! -L "$IMMUTABLE_SOURCE_ARCHIVE" ]]; then
    find "$IMMUTABLE_SOURCE_ARCHIVE" -maxdepth 0 -type f -delete 2>/dev/null || true
  fi
  cleanup_environment_snapshot
  exit "$status"
}

assert_equivalent_source_trees() {
  local candidate="$1"
  local cached="$2"
  "$NODE_BIN" --input-type=module - "$candidate" "$cached" <<'NODE'
import { createHash } from "node:crypto";
import { lstatSync, readFileSync, readdirSync, readlinkSync } from "node:fs";
import { join } from "node:path";

const [candidate, cached] = process.argv.slice(2);

function snapshot(root) {
  const entries = [];
  function visit(relativePath) {
    const absolutePath = relativePath ? join(root, relativePath) : root;
    const metadata = lstatSync(absolutePath);
    const common = {
      path: relativePath || ".",
      mode: metadata.mode & 0o777,
      uid: metadata.uid,
      gid: metadata.gid
    };
    if (metadata.isDirectory()) {
      entries.push({ ...common, type: "directory" });
      for (const name of readdirSync(absolutePath).sort()) {
        visit(relativePath ? join(relativePath, name) : name);
      }
    } else if (metadata.isFile()) {
      entries.push({
        ...common,
        type: "file",
        size: metadata.size,
        digest: createHash("sha256").update(readFileSync(absolutePath)).digest("hex")
      });
    } else if (metadata.isSymbolicLink()) {
      entries.push({ ...common, type: "symlink", target: readlinkSync(absolutePath) });
    } else {
      throw new Error(`unsupported source entry type: ${relativePath || "."}`);
    }
  }
  visit("");
  return entries;
}

try {
  if (JSON.stringify(snapshot(candidate)) !== JSON.stringify(snapshot(cached))) {
    process.exitCode = 1;
  }
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
NODE
}

prepare_immutable_source_tree() {
  [[ "$ADDRESS_ATLAS_BUILD_REVISION" =~ ^[0-9a-f]{40}$ ]] || return 70
  local base="${ADDRESS_ATLAS_DEPLOY_SOURCE_ROOT:-}"
  [[ -n "$base" ]] || base="$(configured_volume_from_env_file ADDRESS_ATLAS_DEPLOY_SOURCE_ROOT)"
  base="${base:-/var/lib/address-atlas/deploy-sources}"
  IMMUTABLE_SOURCE_BASE="$base"
  [[ "$base" == /* && "$base" != "/" && "$base" != *$'\n'* ]] || {
    echo "ADDRESS_ATLAS_DEPLOY_SOURCE_ROOT must be a safe absolute directory." >&2
    return 65
  }
  local parent mode owner permissions tree target archive
  parent="$(dirname "$base")"
  [[ -d "$parent" && ! -L "$parent" \
     && "$(cd "$parent" && pwd -P)" == "$parent" ]] || {
    echo "Immutable deployment source parent must already exist at a canonical non-symlink path." >&2
    return 66
  }
  mode="$(stat -c %a "$parent" 2>/dev/null || stat -f %Lp "$parent" 2>/dev/null || true)"
  owner="$(stat -c %u "$parent" 2>/dev/null || stat -f %u "$parent" 2>/dev/null || true)"
  [[ "$mode" =~ ^[0-7]{3,4}$ && "$owner" == "$(id -u)" ]] || return 66
  permissions=$((8#$mode))
  (( (permissions & 8#077) == 0 )) || {
    echo "Immutable deployment source parent must be operator-owned and private." >&2
    return 66
  }
  if [[ ! -e "$base" && ! -L "$base" ]]; then
    mkdir "$base"
    chmod 0700 "$base"
  fi
  [[ -d "$base" && ! -L "$base" && "$(cd "$base" && pwd -P)" == "$base" ]] || return 66
  mode="$(stat -c %a "$base" 2>/dev/null || stat -f %Lp "$base" 2>/dev/null || true)"
  owner="$(stat -c %u "$base" 2>/dev/null || stat -f %u "$base" 2>/dev/null || true)"
  [[ "$mode" =~ ^[0-7]{3,4}$ && "$owner" == "$(id -u)" ]] || return 66
  permissions=$((8#$mode))
  (( (permissions & 8#077) == 0 )) || return 66
  tree="$("$GIT_BIN" -C "$ROOT_DIR" rev-parse "${ADDRESS_ATLAS_BUILD_REVISION}^{tree}" 2>/dev/null)" || return 69
  [[ "$tree" =~ ^[0-9a-f]{40}$ ]] || return 69
  target="${base}/${ADDRESS_ATLAS_BUILD_REVISION}-${tree}"
  IMMUTABLE_SOURCE_STAGING="${base}/.source-${ADDRESS_ATLAS_BUILD_REVISION}-$$"
  archive="${base}/.source-${ADDRESS_ATLAS_BUILD_REVISION}-$$.tar"
  IMMUTABLE_SOURCE_ARCHIVE="$archive"
  [[ ! -e "$IMMUTABLE_SOURCE_STAGING" && ! -L "$IMMUTABLE_SOURCE_STAGING" \
     && ! -e "$archive" && ! -L "$archive" ]] || return 73
  mkdir "$IMMUTABLE_SOURCE_STAGING"
  chmod 0700 "$IMMUTABLE_SOURCE_STAGING"
  "$GIT_BIN" -C "$ROOT_DIR" archive --format=tar --output="$archive" \
    "$ADDRESS_ATLAS_BUILD_REVISION" || return 69
  [[ -f "$archive" && ! -L "$archive" ]] || return 69
  tar -xf "$archive" -C "$IMMUTABLE_SOURCE_STAGING"
  find "$archive" -maxdepth 0 -type f -delete
  IMMUTABLE_SOURCE_ARCHIVE=""
  # Normalize the freshly extracted Git tree to the cache's read-only contract
  # before comparing metadata. Never recurse through archive-controlled links.
  find "$IMMUTABLE_SOURCE_STAGING" -type d -exec chmod a-w {} +
  find "$IMMUTABLE_SOURCE_STAGING" -type f -exec chmod a-w {} +
  if [[ -e "$target" || -L "$target" ]]; then
    [[ -d "$target" && ! -L "$target" ]] || return 66
    assert_equivalent_source_trees "$IMMUTABLE_SOURCE_STAGING" "$target" || {
      echo "The durable deployment source cache differs from the immutable Git tree." >&2
      return 67
    }
    find "$IMMUTABLE_SOURCE_STAGING" -type d -exec chmod u+w {} +
    find "$IMMUTABLE_SOURCE_STAGING" -depth -delete
  else
    mv "$IMMUTABLE_SOURCE_STAGING" "$target"
  fi
  IMMUTABLE_SOURCE_STAGING=""
  IMMUTABLE_SOURCE_ROOT="$target"
  local required_source
  for required_source in \
    server/sync/compose.prod.yml \
    server/sync/Dockerfile \
    server/sync/Caddyfile \
    server/sync/bootstrap-database-roles.sh \
    server/sync/postgres-backup.sh \
    server/sync/migrate-restored-database.sh \
    server/sync/provision-restored-database.sh \
    server/sync/provision-runtime-role.sh \
    server/sync/native-config-deploy-state.mjs; do
    [[ -f "$IMMUTABLE_SOURCE_ROOT/$required_source" \
       && ! -L "$IMMUTABLE_SOURCE_ROOT/$required_source" ]] || return 67
  done
  COMPOSE_FILE="$IMMUTABLE_SOURCE_ROOT/server/sync/compose.prod.yml"
  NATIVE_CONFIG_STATE_TOOL="$IMMUTABLE_SOURCE_ROOT/server/sync/native-config-deploy-state.mjs"
  if [[ -z "${ADDRESS_ATLAS_BACKUP_SCRIPT:-}" ]]; then
    BACKUP_SCRIPT="$IMMUTABLE_SOURCE_ROOT/server/sync/postgres-backup.sh"
  fi
}

prune_immutable_source_cache() {
  local base="$IMMUTABLE_SOURCE_BASE"
  [[ -n "$base" && -d "$base" && ! -L "$base" \
     && -n "$IMMUTABLE_SOURCE_ROOT" ]] || return 0
  local containers container mounts source relative referenced_root
  local referenced_roots=()
  containers="$("$DOCKER_BIN" ps -aq \
    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME_FIXED}")" || {
    echo "Warning: unable to inspect container mounts; skipping deployment cache pruning." >&2
    return 0
  }
  while IFS= read -r container; do
    [[ -n "$container" ]] || continue
    mounts="$("$DOCKER_BIN" inspect --format \
      '{{range .Mounts}}{{println .Source}}{{end}}' "$container" 2>/dev/null)" || {
      echo "Warning: unable to inspect container mounts; skipping deployment cache pruning." >&2
      return 0
    }
    while IFS= read -r source; do
      [[ "$source" == "$base/"* ]] || continue
      relative="${source#"$base/"}"
      referenced_root="${relative%%/*}"
      [[ "$referenced_root" =~ ^[0-9a-f]{40}-[0-9a-f]{40}$ ]] || continue
      referenced_roots+=("$base/$referenced_root")
    done <<< "$mounts"
  done <<< "$containers"

  local candidate name protected
  for candidate in "$base"/*-*; do
    [[ -e "$candidate" || -L "$candidate" ]] || continue
    name="$(basename "$candidate")"
    [[ "$name" =~ ^[0-9a-f]{40}-[0-9a-f]{40}$ ]] || continue
    protected=false
    for referenced_root in "${referenced_roots[@]:-}"; do
      [[ "$candidate" == "$referenced_root" ]] && protected=true
    done
    if [[ "$protected" == true \
        || "$candidate" == "$IMMUTABLE_SOURCE_ROOT" \
        || ( "${PREVIOUS_WEB_REVISION:-}" =~ ^[0-9a-f]{40}$ \
          && "$name" == "${PREVIOUS_WEB_REVISION}-"* ) ]]; then
      continue
    fi
    if [[ ! -d "$candidate" || -L "$candidate" \
        || "$(dirname "$candidate")" != "$base" ]]; then
      echo "Warning: refusing to prune unsafe deployment cache entry ${candidate}." >&2
      continue
    fi
    # Cache entries are regenerated from an authorized Git commit. Never
    # follow archive-controlled links or cross a mounted filesystem while
    # making the read-only tree removable.
    if ! find "$candidate" -xdev -type d -exec chmod u+w {} + \
        || ! find "$candidate" -xdev -depth -delete; then
      echo "Warning: unable to prune obsolete deployment cache ${candidate}." >&2
    fi
  done
}

snapshot_production_environment() {
  validate_production_environment_file true || exit $?
  local before after temporary_root
  before="$(environment_file_identity "$ENV_FILE")" || {
    echo "Unable to capture production environment file identity." >&2
    exit 66
  }
  if [[ -n "${ADDRESS_ATLAS_PRELOCK_ENV_IDENTITY:-}" \
      || -n "${ADDRESS_ATLAS_PRELOCK_ENV_SHA256:-}" ]]; then
    [[ -n "${ADDRESS_ATLAS_PRELOCK_ENV_IDENTITY:-}" \
       && "${ADDRESS_ATLAS_PRELOCK_ENV_SHA256:-}" =~ ^[0-9a-f]{64}$ \
       && "$before" == "$ADDRESS_ATLAS_PRELOCK_ENV_IDENTITY" \
       && "$(sha256_regular_file "$ENV_FILE")" \
            == "$ADDRESS_ATLAS_PRELOCK_ENV_SHA256" ]] || {
      echo "Production environment changed before bootstrap lock reclaim completed; refusing recovery." >&2
      exit 73
    }
  fi
  temporary_root="${TMPDIR:-/tmp}"
  [[ "$temporary_root" == /* && -d "$temporary_root" ]] || {
    echo "A valid absolute temporary directory is required for the locked environment snapshot." >&2
    exit 74
  }
  ENV_SNAPSHOT_ROOT="$(cd "$temporary_root" && pwd -P)" || exit 74
  ENV_SNAPSHOT_DIRECTORY="$(mktemp -d "${ENV_SNAPSHOT_ROOT%/}/address-atlas-production-env.XXXXXX")" || exit 74
  trap manage_exit_cleanup EXIT
  ENV_SNAPSHOT_DIRECTORY="$(cd "$ENV_SNAPSHOT_DIRECTORY" && pwd -P)" || exit 74
  chmod 0700 "$ENV_SNAPSHOT_DIRECTORY"
  ENV_SNAPSHOT_FILE="$ENV_SNAPSHOT_DIRECTORY/production.env"
  cp "$ENV_FILE" "$ENV_SNAPSHOT_FILE"
  chmod 0600 "$ENV_SNAPSHOT_FILE"
  after="$(environment_file_identity "$ENV_FILE")" || {
    echo "Production environment file disappeared while it was being frozen." >&2
    exit 66
  }
  [[ "$before" == "$after" ]] && cmp -s "$ENV_FILE" "$ENV_SNAPSHOT_FILE" || {
    echo "Production environment file changed while it was being frozen; retry the operation." >&2
    exit 73
  }
  if [[ -n "${ADDRESS_ATLAS_PRELOCK_ENV_SHA256:-}" ]]; then
    [[ "$(sha256_regular_file "$ENV_SNAPSHOT_FILE")" \
        == "$ADDRESS_ATLAS_PRELOCK_ENV_SHA256" ]] || {
      echo "Locked production environment snapshot differs from its bootstrap reclaim binding." >&2
      exit 73
    }
  fi
  ORIGINAL_ENV_FILE="$ENV_FILE"
  ENV_FILE="$ENV_SNAPSHOT_FILE"
  export ADDRESS_ATLAS_PROD_ENV_FILE="$ENV_FILE"
  validate_production_environment_file true || exit $?
  if [[ -n "${ADDRESS_ATLAS_PRELOCK_ENV_FILE_BINDINGS:-}" ]]; then
    local bound_name snapshot_value
    for bound_name in $ADDRESS_ATLAS_PRELOCK_ENV_FILE_BINDINGS; do
      case "$bound_name" in
        ADDRESS_ATLAS_ALLOW_BOOTSTRAP_LOCK_RECLAIM|ADDRESS_ATLAS_EXPECTED_BACKUP_SHA256|POSTGRES_ADMIN_PASSWORD) ;;
        *)
          echo "Bootstrap reclaim environment binding list is invalid." >&2
          exit 70
          ;;
      esac
      snapshot_value="$(configured_volume_from_env_file "$bound_name")"
      [[ -n "$snapshot_value" && "$snapshot_value" == "${!bound_name}" ]] || {
        echo "Bootstrap reclaim input ${bound_name} changed before the locked snapshot." >&2
        exit 73
      }
    done
  fi
}

load_backup_lock_environment() {
  local configured="${ADDRESS_ATLAS_BACKUP_DIR:-}"
  local source="environment"
  if [[ -z "$configured" ]]; then
    source="file"
    configured="$(configured_volume_from_env_file ADDRESS_ATLAS_BACKUP_DIR)"
  fi
  configured="${configured:-/var/backups/address-atlas}"
  ADDRESS_ATLAS_BACKUP_DIR="$configured"
  ADDRESS_ATLAS_LOCKED_BACKUP_DIR="$configured"
  ADDRESS_ATLAS_LOCKED_BACKUP_DIR_SOURCE="$source"
  export ADDRESS_ATLAS_BACKUP_DIR ADDRESS_ATLAS_LOCKED_BACKUP_DIR \
    ADDRESS_ATLAS_LOCKED_BACKUP_DIR_SOURCE
}

load_bootstrap_reclaim_dispatch_environment() {
  local name value bindings=""
  for name in \
    ADDRESS_ATLAS_ALLOW_BOOTSTRAP_LOCK_RECLAIM \
    ADDRESS_ATLAS_EXPECTED_BACKUP_SHA256 \
    POSTGRES_ADMIN_PASSWORD; do
    [[ -z "${!name:-}" ]] || continue
    value="$(configured_volume_from_env_file "$name")"
    [[ -n "$value" ]] || continue
    printf -v "$name" '%s' "$value"
    export "$name"
    bindings="${bindings}${name} "
  done
  ADDRESS_ATLAS_PRELOCK_ENV_IDENTITY="$(environment_file_identity "$ENV_FILE")" || {
    echo "Unable to bind the production environment before bootstrap lock reclaim." >&2
    return 66
  }
  ADDRESS_ATLAS_PRELOCK_ENV_SHA256="$(sha256_regular_file "$ENV_FILE")" || return $?
  ADDRESS_ATLAS_PRELOCK_ENV_FILE_BINDINGS="${bindings% }"
  export ADDRESS_ATLAS_PRELOCK_ENV_IDENTITY ADDRESS_ATLAS_PRELOCK_ENV_SHA256 \
    ADDRESS_ATLAS_PRELOCK_ENV_FILE_BINDINGS
}

assert_snapshot_uses_locked_backup_directory() {
  local configured effective
  if [[ "${ADDRESS_ATLAS_LOCKED_BACKUP_DIR_SOURCE:-}" == "environment" ]]; then
    effective="${ADDRESS_ATLAS_BACKUP_DIR:-/var/backups/address-atlas}"
  else
    configured="$(configured_volume_from_env_file ADDRESS_ATLAS_BACKUP_DIR)"
    effective="${configured:-/var/backups/address-atlas}"
  fi
  [[ -n "${ADDRESS_ATLAS_LOCKED_BACKUP_DIR:-}" \
     && "$effective" == "$ADDRESS_ATLAS_LOCKED_BACKUP_DIR" \
     && "${ADDRESS_ATLAS_BACKUP_DIR:-}" == "$ADDRESS_ATLAS_LOCKED_BACKUP_DIR" ]] || {
    echo "Production backup directory changed between lock acquisition and environment snapshot." >&2
    exit 73
  }
}

load_backup_environment() {
  local name value
  for name in \
    ADDRESS_ATLAS_BACKUP_DIR \
    ADDRESS_ATLAS_BACKUP_RETENTION_DAYS \
    ADDRESS_ATLAS_BACKUP_MAX_AGE_HOURS \
    ADDRESS_ATLAS_BACKUP_MAX_BYTES \
    ADDRESS_ATLAS_BACKUP_AGE_RECIPIENT \
    ADDRESS_ATLAS_BACKUP_AGE_IDENTITY_FILE \
    ADDRESS_ATLAS_BACKUP_SIGNING_PRIVATE_KEY_FILE \
    ADDRESS_ATLAS_BACKUP_SIGNATURE_PUBLIC_KEY_FILE \
    ADDRESS_ATLAS_BACKUP_OFFSITE_REQUIRED \
    ADDRESS_ATLAS_BACKUP_OFFSITE_HOOK \
    ADDRESS_ATLAS_ALLOW_BOOTSTRAP_RESTORE \
    ADDRESS_ATLAS_EXPECTED_BACKUP_SHA256 \
    ADDRESS_ATLAS_ALLOW_BOOTSTRAP_LOCK_RECLAIM \
    POSTGRES_ADMIN_PASSWORD \
    POSTGRES_PASSWORD \
    POSTGRES_RUNTIME_PASSWORD; do
    [[ -z "${!name:-}" ]] || continue
    value="$(configured_volume_from_env_file "$name")"
    [[ -n "$value" ]] || continue
    printf -v "$name" '%s' "$value"
    export "$name"
  done
}

assert_no_unfinished_bootstrap_recovery() {
  local state_file="${ADDRESS_ATLAS_BACKUP_DIR}/.bootstrap-restore.state"
  [[ ! -e "$state_file" && ! -L "$state_file" ]] || {
    echo "An unfinished fresh-cluster recovery blocks this production operation." >&2
    echo "Resume the exact bootstrap-restore artifact and target before any other state change." >&2
    return 75
  }
}

configure_restore_contract() {
  local revision="$1"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || return 70
  local operations_root="${IMMUTABLE_SOURCE_ROOT:-$ROOT_DIR}"
  ADDRESS_ATLAS_BACKUP_RESTORE_MIGRATION_HOOK="${operations_root}/server/sync/migrate-restored-database.sh"
  ADDRESS_ATLAS_BACKUP_RESTORE_PROVISION_HOOK="${operations_root}/server/sync/provision-restored-database.sh"
  ADDRESS_ATLAS_RESTORE_BUILD_REVISION="$revision"
  ADDRESS_ATLAS_RESTORE_IMAGE="address-atlas-sync:${revision}"
  ADDRESS_ATLAS_RESTORE_PROVISION_IMAGE="$PINNED_POSTGRES_IMAGE"
  export ADDRESS_ATLAS_BACKUP_RESTORE_MIGRATION_HOOK \
    ADDRESS_ATLAS_BACKUP_RESTORE_PROVISION_HOOK \
    ADDRESS_ATLAS_RESTORE_BUILD_REVISION ADDRESS_ATLAS_RESTORE_IMAGE \
    ADDRESS_ATLAS_RESTORE_PROVISION_IMAGE
}

sha256_regular_file() {
  local path="$1"
  [[ "$path" == /* && -f "$path" && ! -L "$path" ]] || {
    echo "Cannot fingerprint an unsafe recovery toolchain file: ${path}." >&2
    return 66
  }
  "$NODE_BIN" --input-type=module - "$path" <<'NODE'
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

const path = process.argv[2];
process.stdout.write(createHash("sha256").update(readFileSync(path)).digest("hex") + "\n");
NODE
}

assert_exact_bootstrap_postgres_image() {
  local container="$1"
  local expected_id metadata observed_id configured_image extra
  expected_id="$($DOCKER_BIN image inspect --format '{{.Id}}' \
    "$PINNED_POSTGRES_IMAGE" 2>/dev/null)" || {
    echo "The reviewed immutable PostgreSQL 16 image is unavailable." >&2
    return 69
  }
  metadata="$($DOCKER_BIN inspect --format '{{.Image}}|{{.Config.Image}}' \
    "$container" 2>/dev/null)" || {
    echo "Unable to inspect bootstrap PostgreSQL image provenance." >&2
    return 69
  }
  IFS='|' read -r observed_id configured_image extra <<< "$metadata"
  [[ -z "$extra" && "$expected_id" =~ ^sha256:[0-9a-f]{64}$ \
     && "$observed_id" == "$expected_id" \
     && "$configured_image" == "$PINNED_POSTGRES_IMAGE" ]] || {
    echo "Bootstrap recovery requires the exact reviewed PostgreSQL 16 image and digest." >&2
    return 67
  }
  BOOTSTRAP_TARGET_PROVISION_IMAGE_ID="$expected_id"
}

inspect_bootstrap_backup() {
  local backup="$1" expected_database="$2"
  local output prefix schema artifact_sha database config_version config_digest
  local config_updated_at config_revision source_web_image source_postgres_image
  local migration_head snapshot_started extra
  output="$({
    ADDRESS_ATLAS_POSTGRES_CONTAINER="$READY_POSTGRES_CONTAINER" \
      bash "$BACKUP_SCRIPT" inspect "$backup"
  })" || return $?
  [[ -n "$output" && "$output" != *$'\n'* ]] || {
    echo "Backup inspection did not return exactly one canonical metadata record." >&2
    return 65
  }
  IFS='|' read -r prefix schema artifact_sha database config_version \
    config_digest config_updated_at config_revision source_web_image \
    source_postgres_image migration_head snapshot_started extra <<< "$output"
  [[ -z "$extra" && "$prefix" == "BACKUP_METADATA" && "$schema" == "4" \
     && "$artifact_sha" =~ ^[0-9a-f]{64}$ \
     && "$database" == "$expected_database" \
     && "$config_version" =~ ^[0-9]+$ \
     && "$config_version" -ge 5 && "$config_version" -le 2000000000 \
     && "$config_digest" =~ ^[0-9a-f]{64}$ \
     && "$config_updated_at" =~ ^[1-9][0-9]*$ \
     && "$config_revision" =~ ^[0-9a-f]{40}$ \
     && "$source_web_image" =~ ^sha256:[0-9a-f]{64}$ \
     && "$source_postgres_image" =~ ^sha256:[0-9a-f]{64}$ \
     && "$migration_head" =~ ^[1-3]$ \
     && "$snapshot_started" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
    echo "The signed backup is not a canonical schema-v4 recovery artifact for ${expected_database}." >&2
    return 65
  }
  if [[ -n "${ADDRESS_ATLAS_EXPECTED_BACKUP_SHA256:-}" \
      && "$ADDRESS_ATLAS_EXPECTED_BACKUP_SHA256" != "$artifact_sha" ]]; then
    echo "The operator-approved backup digest differs from the inspected signed artifact." >&2
    return 67
  fi
  assert_deployed_revision_is_authorized_ancestor "$config_revision" || return $?
  ADDRESS_ATLAS_EXPECTED_BACKUP_SHA256="$artifact_sha"
  export ADDRESS_ATLAS_EXPECTED_BACKUP_SHA256
  BOOTSTRAP_BACKUP_SHA256="$artifact_sha"
  BOOTSTRAP_BACKUP_DATABASE="$database"
  BOOTSTRAP_BACKUP_CONFIG_VERSION="$config_version"
  BOOTSTRAP_BACKUP_CONFIG_DIGEST="$config_digest"
  BOOTSTRAP_BACKUP_CONFIG_UPDATED_AT="$config_updated_at"
  BOOTSTRAP_BACKUP_CONFIG_REVISION="$config_revision"
  BOOTSTRAP_BACKUP_SOURCE_WEB_IMAGE="$source_web_image"
  BOOTSTRAP_BACKUP_SOURCE_POSTGRES_IMAGE="$source_postgres_image"
  BOOTSTRAP_BACKUP_MIGRATION_HEAD="$migration_head"
}

assert_existing_web_matches_recovery_evidence() {
  [[ -n "${PREVIOUS_WEB_IMAGE_ID:-}" ]] || return 0
  if [[ "$PREVIOUS_WEB_RUNNING" == "false" \
      && "$PREVIOUS_WEB_REVISION" == "$ADDRESS_ATLAS_BUILD_REVISION" \
      && -n "${BOOTSTRAP_TARGET_WEB_IMAGE_ID:-}" \
      && "$PREVIOUS_WEB_IMAGE_ID" == "$BOOTSTRAP_TARGET_WEB_IMAGE_ID" ]]; then
    return 0
  fi
  if [[ -n "${BASELINE_CONFIG_VERSION:-}" ]]; then
    [[ "$PREVIOUS_WEB_REVISION" == "$BASELINE_CONFIG_REVISION" \
       && "$PREVIOUS_WEB_IMAGE_ID" == "$BASELINE_CONFIG_IMAGE_ID" ]] || {
      echo "The existing web container conflicts with its durable native-config receipt." >&2
      return 67
    }
    assert_deployed_revision_is_authorized_ancestor "$PREVIOUS_WEB_REVISION" || return $?
  else
    [[ "$PREVIOUS_WEB_REVISION" == "$BOOTSTRAP_BACKUP_CONFIG_REVISION" \
       && "$PREVIOUS_WEB_IMAGE_ID" == "$BOOTSTRAP_BACKUP_SOURCE_WEB_IMAGE" ]] || {
      echo "An existing web container has neither durable nor signed recovery provenance." >&2
      return 67
    }
  fi
}

prepare_bootstrap_target_receipt_contract() {
  inspect_install_candidate_image || return $?
  BOOTSTRAP_TARGET_WEB_IMAGE_ID="$CANDIDATE_IMAGE_ID"
  BOOTSTRAP_TARGET_MIGRATION_HOOK_DIGEST="$(sha256_regular_file \
    "$ADDRESS_ATLAS_BACKUP_RESTORE_MIGRATION_HOOK")" || return $?
  BOOTSTRAP_TARGET_PROVISION_HOOK_DIGEST="$(sha256_regular_file \
    "$ADDRESS_ATLAS_BACKUP_RESTORE_PROVISION_HOOK")" || return $?
  BOOTSTRAP_TARGET_PROVISION_SOURCE_DIGEST="$(sha256_regular_file \
    "${ADDRESS_ATLAS_BACKUP_RESTORE_PROVISION_HOOK%/*}/provision-runtime-role.sh")" || return $?
  BOOTSTRAP_TARGET_BOOTSTRAP_SOURCE_DIGEST="$(sha256_regular_file \
    "${ADDRESS_ATLAS_BACKUP_RESTORE_PROVISION_HOOK%/*}/bootstrap-database-roles.sh")" || return $?
}

validate_bootstrap_restore_receipt() {
  local output="$1" receipt lines prefix backup_sha config_version config_digest
  local config_updated_at source_revision source_web_image database storage_identity
  local quarantine target_revision target_web_image target_provision_image migration_head
  local migration_hook_digest provision_hook_digest provision_source_digest
  local bootstrap_source_digest extra
  lines="$(printf '%s\n' "$output" | awk '/^BOOTSTRAP_RESTORE_RECEIPT\|/ { print }')"
  [[ -n "$lines" && "$lines" != *$'\n'* ]] || {
    echo "Bootstrap engine did not return exactly one structured recovery receipt." >&2
    return 65
  }
  receipt="$lines"
  IFS='|' read -r prefix backup_sha config_version config_digest \
    config_updated_at source_revision source_web_image database storage_identity \
    quarantine target_revision target_web_image target_provision_image migration_head \
    migration_hook_digest provision_hook_digest provision_source_digest \
    bootstrap_source_digest extra <<< "$receipt"
  [[ -z "$extra" && "$prefix" == "BOOTSTRAP_RESTORE_RECEIPT" \
     && "$backup_sha" == "$BOOTSTRAP_BACKUP_SHA256" \
     && "$config_version" == "$BOOTSTRAP_BACKUP_CONFIG_VERSION" \
     && "$config_digest" == "$BOOTSTRAP_BACKUP_CONFIG_DIGEST" \
     && "$config_updated_at" == "$BOOTSTRAP_BACKUP_CONFIG_UPDATED_AT" \
     && "$source_revision" == "$BOOTSTRAP_BACKUP_CONFIG_REVISION" \
     && "$source_web_image" == "$BOOTSTRAP_BACKUP_SOURCE_WEB_IMAGE" \
     && "$database" == "$BOOTSTRAP_BACKUP_DATABASE" \
     && "$storage_identity" =~ ^sha256:[0-9a-f]{64}$ \
     && "$quarantine" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ \
     && "$target_revision" == "$ADDRESS_ATLAS_BUILD_REVISION" \
     && "$target_web_image" == "$BOOTSTRAP_TARGET_WEB_IMAGE_ID" \
     && "$target_provision_image" == "$BOOTSTRAP_TARGET_PROVISION_IMAGE_ID" \
     && "$migration_head" == "$EXPECTED_RESTORE_MIGRATION_HEAD" \
     && "$migration_hook_digest" == "$BOOTSTRAP_TARGET_MIGRATION_HOOK_DIGEST" \
     && "$provision_hook_digest" == "$BOOTSTRAP_TARGET_PROVISION_HOOK_DIGEST" \
     && "$provision_source_digest" == "$BOOTSTRAP_TARGET_PROVISION_SOURCE_DIGEST" \
     && "$bootstrap_source_digest" == "$BOOTSTRAP_TARGET_BOOTSTRAP_SOURCE_DIGEST" ]] || {
    echo "Bootstrap engine receipt does not match the inspected artifact, storage, or target toolchain." >&2
    return 67
  }
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

initialize_production_compose_context() {
  SELECTED_POSTGRES_VOLUME="$(detect_volume)"
  SELECTED_CADDY_DATA_VOLUME="$(detect_caddy_data_volume)"
  SELECTED_CADDY_CONFIG_VOLUME="$(detect_caddy_config_volume)"
  export ADDRESS_ATLAS_POSTGRES_VOLUME="$SELECTED_POSTGRES_VOLUME"
  export ADDRESS_ATLAS_CADDY_DATA_VOLUME="$SELECTED_CADDY_DATA_VOLUME"
  export ADDRESS_ATLAS_CADDY_CONFIG_VOLUME="$SELECTED_CADDY_CONFIG_VOLUME"
  rebuild_production_compose_args
  ADDRESS_ATLAS_BUILD_REVISION="$(build_revision)"
  export ADDRESS_ATLAS_BUILD_REVISION
}

rebuild_production_compose_args() {
  PRODUCTION_COMPOSE_ARGS=(compose)
  if [[ -f "$ENV_FILE" ]]; then
    PRODUCTION_COMPOSE_ARGS+=(--env-file "$ENV_FILE")
  fi
  PRODUCTION_COMPOSE_ARGS+=(--project-name "$COMPOSE_PROJECT_NAME_FIXED" -f "$COMPOSE_FILE")
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

production_domain() {
  local domain="${ADDRESS_ATLAS_DOMAIN:-}"
  [[ -n "$domain" ]] || domain="$(configured_volume_from_env_file ADDRESS_ATLAS_DOMAIN)"
  if [[ ! "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ \
     || "$domain" == *..* ]]; then
    echo "ADDRESS_ATLAS_DOMAIN must be an exact hostname without a scheme, port, path, query, or fragment." >&2
    return 65
  fi
  printf '%s\n' "$domain"
}

database_role_mode() {
  local mode="${ADDRESS_ATLAS_DATABASE_ROLE_MODE:-}"
  [[ -n "$mode" ]] || mode="$(configured_volume_from_env_file ADDRESS_ATLAS_DATABASE_ROLE_MODE)"
  mode="${mode:-steady}"
  case "$mode" in
    bootstrap|steady) printf '%s\n' "$mode" ;;
    *)
      echo "ADDRESS_ATLAS_DATABASE_ROLE_MODE must be exactly bootstrap or steady." >&2
      return 65
      ;;
  esac
}

running_web_container() {
  local containers count=0 selected="" candidate
  containers="$("$DOCKER_BIN" ps -q \
    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME_FIXED}" \
    --filter "label=com.docker.compose.service=web")" || return 69
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    count=$((count + 1))
    selected="$candidate"
  done <<< "$containers"
  [[ "$count" -eq 1 ]] || return 70
  printf '%s\n' "$selected"
}

https_get_bounded() {
  local url="$1"
  "$CURL_BIN" \
    --proto '=https' \
    --tlsv1.2 \
    --silent \
    --show-error \
    --fail \
    --max-redirs 0 \
    --max-filesize 65536 \
    --connect-timeout 5 \
    --max-time 15 \
    --header 'accept: application/json' \
    --header 'cache-control: no-cache' \
    "$url" 2>/dev/null
}

probe_public_native_config() {
  local url="$1"
  local expected_revision="$2"
  [[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] || return 70
  local temporary_root="${TMPDIR:-/tmp}"
  [[ -d "$temporary_root" ]] || return 74
  local probe_dir headers body config status=0
  probe_dir="$(mktemp -d "${temporary_root%/}/address-atlas-config-probe.XXXXXX")" || return 74
  probe_dir="$(cd "$probe_dir" && pwd -P)" || return 74
  headers="$probe_dir/headers"
  body="$probe_dir/body.json"
  "$CURL_BIN" \
    --proto '=https' \
    --tlsv1.2 \
    --silent \
    --show-error \
    --fail \
    --max-redirs 0 \
    --max-filesize 1000000 \
    --connect-timeout 5 \
    --max-time 15 \
    --header 'accept: application/json' \
    --header 'cache-control: no-cache' \
    --dump-header "$headers" \
    --output "$body" \
    "$url" 2>/dev/null || status=1
  if [[ "$status" -eq 0 \
     && -f "$headers" && ! -L "$headers" \
     && -f "$body" && ! -L "$body" ]]; then
    config="$(<"$body")" || status=1
    record_candidate_native_config "$config" || status=1
  elif [[ "$status" -eq 0 ]]; then
    status=1
  fi
  if [[ "$status" -eq 0 ]]; then
    "$NODE_BIN" "$NATIVE_CONFIG_STATE_TOOL" verify-response \
      "$headers" "$CANDIDATE_CONFIG_DIGEST" "$expected_revision" || status=1
  fi
  rm -rf "$probe_dir"
  [[ "$status" -eq 0 ]]
}

smoke_public_once() {
  local expected_revision="$1"
  [[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] || return 70
  command -v "$CURL_BIN" >/dev/null 2>&1 || {
    echo "curl is required for the post-deploy public smoke test." >&2
    return 69
  }
  CANDIDATE_CONFIG_VERSION=""
  CANDIDATE_CONFIG_DIGEST=""
  CANDIDATE_CONFIG_UPDATED_AT_MS=""
  local domain base live ready expected_config_version
  domain="$(production_domain)" || return $?
  base="https://${domain}"
  live="$(https_get_bounded "${base}/livez")" || return 1
  [[ "$live" == '{"ok":true,"service":"address-atlas-sync"}' ]] || return 1
  ready="$(https_get_bounded "${base}/healthz")" || return 1
  [[ "$ready" == '{"ok":true,"service":"address-atlas-sync"}' ]] || return 1
  probe_public_native_config \
    "${base}/config/native?deployment_probe=${expected_revision}" "$expected_revision" || return 1
  expected_config_version="${NATIVE_ENDPOINT_CONFIG_VERSION:-}"
  [[ -n "$expected_config_version" ]] \
    || expected_config_version="$(configured_volume_from_env_file NATIVE_ENDPOINT_CONFIG_VERSION)"
  expected_config_version="${expected_config_version:-5}"
  [[ "$expected_config_version" =~ ^[0-9]+$ \
     && "$CANDIDATE_CONFIG_VERSION" == "$expected_config_version" ]] || return 1
}

smoke_public_with_retries() {
  local expected_revision="$1"
  [[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] || return 70
  local attempts="${ADDRESS_ATLAS_SMOKE_ATTEMPTS:-12}"
  [[ "$attempts" =~ ^[1-9][0-9]*$ && "$attempts" -le 12 ]] || {
    echo "ADDRESS_ATLAS_SMOKE_ATTEMPTS must be an integer from 1 through 12." >&2
    return 65
  }
  local attempt
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    if smoke_public_once "$expected_revision"; then
      echo "Public post-deploy smoke passed for /livez, /healthz, and /config/native."
      return 0
    fi
    (( attempt == attempts )) || sleep 5
  done
  echo "Public post-deploy smoke failed after ${attempts} attempt(s)." >&2
  return 70
}

validate_candidate_native_config_transition() {
  local require_approved="${1:-false}"
  [[ "$require_approved" == "true" || "$require_approved" == "false" ]] || {
    echo "Internal native-config transition mode is invalid." >&2
    return 70
  }
  [[ "$CANDIDATE_CONFIG_VERSION" =~ ^[0-9]+$ \
     && "$CANDIDATE_CONFIG_DIGEST" =~ ^[0-9a-f]{64}$ \
     && "$CANDIDATE_CONFIG_UPDATED_AT_MS" =~ ^[0-9]+$ ]] || {
    echo "The verified native-config fingerprint is missing or malformed." >&2
    return 70
  }

  if [[ "$require_approved" == "true" ]]; then
    [[ "$CANDIDATE_CONFIG_VERSION" == "$APPROVED_CONFIG_VERSION" \
       && "$CANDIDATE_CONFIG_DIGEST" == "$APPROVED_CONFIG_DIGEST" \
       && "$CANDIDATE_CONFIG_UPDATED_AT_MS" == "$APPROVED_CONFIG_UPDATED_AT_MS" ]] || {
      echo "Served native config differs from the privately approved candidate policy." >&2
      return 67
    }
  elif [[ -n "$BASELINE_CONFIG_VERSION" ]]; then
    (( CANDIDATE_CONFIG_VERSION >= BASELINE_CONFIG_VERSION )) || {
      echo "Candidate native config would roll clients back to an older version." >&2
      return 67
    }
    (( CANDIDATE_CONFIG_UPDATED_AT_MS >= BASELINE_CONFIG_UPDATED_AT_MS )) || {
      echo "Candidate native config has an older policy timestamp." >&2
      return 67
    }
    if (( CANDIDATE_CONFIG_VERSION == BASELINE_CONFIG_VERSION )) \
      && [[ "$CANDIDATE_CONFIG_DIGEST" != "$BASELINE_CONFIG_DIGEST" ]]; then
      echo "Candidate native config changes policy without advancing configVersion." >&2
      return 67
    fi
  fi

  if [[ "$require_approved" == "false" ]]; then
    APPROVED_CONFIG_VERSION="$CANDIDATE_CONFIG_VERSION"
    APPROVED_CONFIG_DIGEST="$CANDIDATE_CONFIG_DIGEST"
    APPROVED_CONFIG_UPDATED_AT_MS="$CANDIDATE_CONFIG_UPDATED_AT_MS"
  fi
}

preflight_private_web_config() {
  local revision="$1"
  local mode="$2"
  shift 2
  local compose_command=("$@")
  [[ "$revision" =~ ^[0-9a-f]{40}$ \
     && ( "$mode" == "candidate" || "$mode" == "rollback" \
       || "$mode" == "policy-only" || "$mode" == "approved" ) ]] || {
    echo "Internal private web-config preflight arguments are invalid." >&2
    return 70
  }
  local name="address-atlas-config-preflight-$$-${revision:0:8}"
  if "$DOCKER_BIN" ps -aq --filter "name=^/${name}$" | grep -q .; then
    echo "A private native-config preflight container already exists: ${name}." >&2
    return 67
  fi
  if ! env ADDRESS_ATLAS_BUILD_REVISION="$revision" \
    "$DOCKER_BIN" "${compose_command[@]}" run --detach --name "$name" --no-deps web \
      >/dev/null; then
    echo "Unable to start the private native-config preflight container." >&2
    return 70
  fi

  local status=0 attempt health="" config="" provenance image_id observed_revision extra
  if [[ "$mode" == "policy-only" ]]; then
    # A pristine replacement database has no schema or runtime role yet, so
    # /healthz must fail. Prove the exact immutable image can boot and serve a
    # valid policy before any restore mutation, without weakening the full
    # readiness preflight that runs again after cutover.
    for attempt in {1..45}; do
      health="$("$DOCKER_BIN" inspect --format \
        '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$name" 2>/dev/null || true)"
      if [[ "$health" == "exited" || "$health" == "dead" ]]; then
        status=70
        break
      fi
      if config="$("$DOCKER_BIN" exec "$name" \
          wget -q -O - http://127.0.0.1:3000/config/native 2>/dev/null)"; then
        break
      fi
      sleep 2
    done
    [[ -n "$config" ]] || status=70
  else
    for attempt in {1..45}; do
      health="$("$DOCKER_BIN" inspect --format \
        '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$name" 2>/dev/null || true)"
      [[ "$health" == "healthy" ]] && break
      if [[ "$health" == "unhealthy" || "$health" == "exited" || "$health" == "dead" ]]; then
        status=70
        break
      fi
      sleep 2
    done
    [[ "$health" == "healthy" ]] || status=70
    if [[ "$status" -eq 0 ]]; then
      config="$("$DOCKER_BIN" exec "$name" \
        wget -q -O - http://127.0.0.1:3000/config/native 2>/dev/null)" || status=70
    fi
  fi
  if [[ "$status" -eq 0 ]]; then
    provenance="$("$DOCKER_BIN" inspect --format \
      '{{.Image}}|{{index .Config.Labels "org.opencontainers.image.revision"}}' \
      "$name" 2>/dev/null)" || status=69
    IFS='|' read -r image_id observed_revision extra <<< "$provenance"
    [[ -z "$extra" && "$image_id" =~ ^sha256:[0-9a-f]{64}$ \
       && "$observed_revision" == "$revision" ]] || status=67
  fi
  "$DOCKER_BIN" rm --force "$name" >/dev/null 2>&1 || status=70
  [[ "$status" -eq 0 ]] || {
    echo "Private native-config preflight failed for revision ${revision}." >&2
    return "$status"
  }
  record_candidate_native_config "$config" || {
    echo "Private candidate returned an invalid native config." >&2
    return 65
  }
  if [[ "$mode" == "candidate" || "$mode" == "policy-only" ]]; then
    validate_candidate_native_config_transition false
  else
    validate_candidate_native_config_transition true || {
      echo "The preflight image cannot serve the exact approved monotonic native config." >&2
      return 67
    }
  fi
}

inspect_install_candidate_image() {
  local image="address-atlas-sync:${ADDRESS_ATLAS_BUILD_REVISION}"
  local metadata image_id revision extra
  metadata="$("$DOCKER_BIN" image inspect --format \
    '{{.Id}}|{{index .Config.Labels "org.opencontainers.image.revision"}}' \
    "$image" 2>/dev/null)" || {
    echo "Unable to inspect the first-install candidate image." >&2
    return 69
  }
  IFS='|' read -r image_id revision extra <<< "$metadata"
  [[ -z "$extra" && "$image_id" =~ ^sha256:[0-9a-f]{64}$ \
     && "$revision" == "$ADDRESS_ATLAS_BUILD_REVISION" ]] || {
    echo "The first-install candidate image lacks exact immutable provenance." >&2
    return 67
  }
  CANDIDATE_IMAGE_ID="$image_id"
}

ensure_install_candidate_container() {
  local compose_command=("$@")
  capture_previous_web_release
  if [[ -z "$PREVIOUS_WEB_IMAGE_ID" ]]; then
    "$DOCKER_BIN" "${compose_command[@]}" create --no-build --no-deps web >/dev/null || {
      echo "Unable to create the stopped first-install web provenance container." >&2
      return 70
    }
    capture_previous_web_release
  fi
  [[ "$PREVIOUS_WEB_RUNNING" == "false" \
     && "$PREVIOUS_WEB_REVISION" == "$INSTALL_REVISION" \
     && "$PREVIOUS_WEB_IMAGE_ID" == "$INSTALL_IMAGE_ID" ]] || {
    echo "The stopped first-install web container does not match its durable recovery state." >&2
    return 67
  }
}

clear_unserved_install_candidate_from_rollback() {
  PREVIOUS_WEB_IMAGE_ID=""
  PREVIOUS_WEB_REVISION=""
  PREVIOUS_WEB_RUNNING="false"
}

begin_first_install() {
  local postgres_volume="$1"
  shift
  local compose_command=("$@")
  "$DOCKER_BIN" "${compose_command[@]}" build web
  inspect_install_candidate_image
  INSTALL_PHASE="candidate-ready"
  INSTALL_REVISION="$ADDRESS_ATLAS_BUILD_REVISION"
  INSTALL_IMAGE_ID="$CANDIDATE_IMAGE_ID"
  INSTALL_POSTGRES_VOLUME="$postgres_volume"
  record_install_deployment_phase candidate-ready
  ensure_install_candidate_container "${compose_command[@]}"
  clear_unserved_install_candidate_from_rollback
}

validate_resumable_first_install() {
  local compose_command=("$@")
  inspect_install_candidate_image
  [[ "$CANDIDATE_IMAGE_ID" == "$INSTALL_IMAGE_ID" ]] || {
    echo "The interrupted first-install image tag no longer resolves to its recorded immutable image." >&2
    return 67
  }
  ensure_install_candidate_container "${compose_command[@]}"
  clear_unserved_install_candidate_from_rollback
}

persist_verified_native_config_receipt() {
  local expected_revision="$1"
  [[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Internal native-config receipt revision is invalid." >&2
    return 70
  }
  validate_candidate_native_config_transition true || return $?

  local web_container provenance image_id revision extra
  web_container="$(running_web_container)" || {
    echo "Expected exactly one running web container for the deployment receipt." >&2
    return 70
  }
  provenance="$("$DOCKER_BIN" inspect --format \
    '{{.Image}}|{{index .Config.Labels "org.opencontainers.image.revision"}}' \
    "$web_container" 2>/dev/null)" || return 69
  IFS='|' read -r image_id revision extra <<< "$provenance"
  [[ -z "$extra" \
     && "$image_id" =~ ^sha256:[0-9a-f]{64}$ \
     && "$revision" == "$expected_revision" ]] || {
    echo "Running web provenance does not match the verified deployment revision." >&2
    return 67
  }

  "$NODE_BIN" "$NATIVE_CONFIG_STATE_TOOL" write \
    "$NATIVE_CONFIG_STATE_FILE" \
    "$CANDIDATE_CONFIG_VERSION" \
    "$CANDIDATE_CONFIG_DIGEST" \
    "$CANDIDATE_CONFIG_UPDATED_AT_MS" \
    "$revision" \
    "$image_id" >/dev/null || {
    echo "Unable to persist the verified native-config deployment receipt." >&2
    return 74
  }
}

rollback_web_release() {
  local compose_command=("$@")
  [[ -n "${PREVIOUS_WEB_IMAGE_ID:-}" && -n "${PREVIOUS_WEB_REVISION:-}" ]] || {
    echo "No previous web release exists for automatic rollback." >&2
    return 1
  }
  "$DOCKER_BIN" image inspect "$PREVIOUS_WEB_IMAGE_ID" >/dev/null 2>&1 || {
    echo "The previous web image is no longer available for rollback." >&2
    return 1
  }
  "$DOCKER_BIN" tag "$PREVIOUS_WEB_IMAGE_ID" "address-atlas-sync:${PREVIOUS_WEB_REVISION}" || {
    echo "Unable to retag the previous verified web image for rollback." >&2
    return 70
  }
  env ADDRESS_ATLAS_BUILD_REVISION="$PREVIOUS_WEB_REVISION" \
    "$DOCKER_BIN" "${compose_command[@]}" up -d --no-build --wait --wait-timeout 120 || {
      echo "Unable to restart the previous verified web image." >&2
      return 70
    }
  smoke_public_with_retries "$PREVIOUS_WEB_REVISION" || return $?
  persist_verified_native_config_receipt "$PREVIOUS_WEB_REVISION" || return $?
  echo "Rolled the web tier back to revision ${PREVIOUS_WEB_REVISION}; forward-only database migrations remain applied."
}

deploy_and_verify_or_rollback() {
  local compose_command=("$@")
  if "$DOCKER_BIN" "${compose_command[@]}" up -d --no-build --wait --wait-timeout 120 \
    && smoke_public_with_retries "$ADDRESS_ATLAS_BUILD_REVISION" \
    && persist_verified_native_config_receipt "$ADDRESS_ATLAS_BUILD_REVISION"; then
    return 0
  fi
  echo "Deployment verification failed; attempting the captured web-image rollback." >&2
  if rollback_web_release "${compose_command[@]}"; then
    return 70
  fi
  stop_fixed_frontend || true
  echo "Automatic rollback failed or was unavailable; Caddy/web were stopped to avoid serving an unverified release." >&2
  return 70
}

deploy_and_verify_without_rollback() {
  local compose_command=("$@")
  if "$DOCKER_BIN" "${compose_command[@]}" up -d --no-build --wait --wait-timeout 120 \
    && smoke_public_with_retries "$ADDRESS_ATLAS_BUILD_REVISION" \
    && persist_verified_native_config_receipt "$ADDRESS_ATLAS_BUILD_REVISION"; then
    return 0
  fi
  stop_fixed_frontend || true
  echo "Recovery deployment verification failed; Caddy/web remain stopped and bootstrap state remains resumable." >&2
  return 70
}

[[ "$#" -ge 1 ]] || usage
command="$1"
if [[ "$command" == "restore" || "$command" == "bootstrap-restore" ]]; then
  [[ "$#" -eq 4 && "$3" == "--confirm" ]] || usage
elif [[ "$command" == "adopt-native-config" ]]; then
  [[ "$#" -eq 3 && "$2" == "--confirm" ]] || usage
else
  [[ "$#" -eq 1 ]] || usage
fi

# Every stateful production operation shares one cross-process host lock.
# Deploy/restore hold it from the first source/provenance read through migration,
# role convergence, public smoke, and durable receipt. Backup/drill commands
# acquire the same lock internally; emergency `down` deliberately bypasses it.
case "$command" in
  up|backup|verify-backup|restore-drill|restore|bootstrap-restore|maintenance|adopt-native-config)
    if [[ -z "${ADDRESS_ATLAS_OPERATION_LOCK_OWNER_PID:-}" ]]; then
      validate_production_environment_file true
      load_backup_lock_environment
      if [[ "$command" == "bootstrap-restore" \
          && ( -e "${ADDRESS_ATLAS_BACKUP_DIR}/.bootstrap-restore.state" \
            || -L "${ADDRESS_ATLAS_BACKUP_DIR}/.bootstrap-restore.state" ) ]]; then
        load_bootstrap_reclaim_dispatch_environment
        [[ "${ADDRESS_ATLAS_ALLOW_BOOTSTRAP_LOCK_RECLAIM:-}" \
              == "YES_I_VERIFIED_STALE_OWNER" \
           && "${ADDRESS_ATLAS_EXPECTED_BACKUP_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || {
          echo "Resuming bootstrap recovery requires explicit stale-owner verification and the exact inspected backup SHA-256." >&2
          echo "Set ADDRESS_ATLAS_ALLOW_BOOTSTRAP_LOCK_RECLAIM=YES_I_VERIFIED_STALE_OWNER and ADDRESS_ATLAS_EXPECTED_BACKUP_SHA256, then retry the same command." >&2
          exit 77
        }
        ADDRESS_ATLAS_BOOTSTRAP_RECOVERY_RESUME=true
        export ADDRESS_ATLAS_BOOTSTRAP_RECOVERY_RESUME
        exec bash "$BACKUP_SCRIPT" bootstrap-lock-run -- \
          "${SCRIPT_DIR}/manage-prod.sh" "$@"
      fi
      exec bash "$BACKUP_SCRIPT" lock-run -- "${SCRIPT_DIR}/manage-prod.sh" "$@"
    fi
    # Never trust the inherited marker alone: the backup tool proves that this
    # process is a descendant of the PID recorded in the owner-only lock file.
    bash "$BACKUP_SCRIPT" assert-lock >/dev/null
    snapshot_production_environment
    assert_snapshot_uses_locked_backup_directory
    load_backup_environment
    [[ "$command" == "bootstrap-restore" ]] \
      || assert_no_unfinished_bootstrap_recovery
    ;;
esac
case "$command" in
  down)
    # Emergency stop deliberately bypasses environment parsing and every volume
    # discovery/adoption decision. Exact Compose ownership labels are enough to
    # identify the running project, and preserving containers makes the next
    # pre-deploy backup possible even after an emergency stop.
    stop_fixed_project
    ;;
  maintenance)
    stop_fixed_frontend
    ;;
  adopt-native-config)
    validate_production_environment_file true
    assert_clean_deployment_checkout
    ADDRESS_ATLAS_BUILD_REVISION="$(build_revision)"
    export ADDRESS_ATLAS_BUILD_REVISION
    assert_authorized_deployment_revision exact
    prepare_immutable_source_tree
    capture_previous_web_release
    [[ -n "$PREVIOUS_WEB_IMAGE_ID" && "$PREVIOUS_WEB_RUNNING" == "true" ]] || {
      echo "Exactly one running, provenance-bound web release is required for config receipt adoption." >&2
      exit 67
    }
    assert_deployed_revision_is_authorized_ancestor "$PREVIOUS_WEB_REVISION" || exit $?
    NATIVE_CONFIG_STATE_FILE="$(native_config_state_file)"
    "$NODE_BIN" "$NATIVE_CONFIG_STATE_TOOL" validate "$NATIVE_CONFIG_STATE_FILE" || exit $?
    [[ ! -e "$NATIVE_CONFIG_STATE_FILE" && ! -L "$NATIVE_CONFIG_STATE_FILE" ]] || {
      echo "A native-config deployment receipt already exists; adoption cannot overwrite it." >&2
      exit 67
    }
    adoption_domain="$(production_domain)" || exit $?
    probe_public_native_config \
      "https://${adoption_domain}/config/native?deployment_probe=${PREVIOUS_WEB_REVISION}" \
      "$PREVIOUS_WEB_REVISION" || {
      echo "The running native config could not be bound to the exact serving revision." >&2
      exit 69
    }
    expected_adoption="ADOPT:${PREVIOUS_WEB_REVISION}:${CANDIDATE_CONFIG_VERSION}:${CANDIDATE_CONFIG_DIGEST}"
    [[ "$3" == "$expected_adoption" ]] || {
      echo "Confirmation must exactly equal ${expected_adoption}." >&2
      exit 64
    }
    "$NODE_BIN" "$NATIVE_CONFIG_STATE_TOOL" write \
      "$NATIVE_CONFIG_STATE_FILE" "$CANDIDATE_CONFIG_VERSION" \
      "$CANDIDATE_CONFIG_DIGEST" "$CANDIDATE_CONFIG_UPDATED_AT_MS" \
      "$PREVIOUS_WEB_REVISION" "$PREVIOUS_WEB_IMAGE_ID" >/dev/null
    echo "Adopted the exact running native-config fingerprint and release provenance."
    ;;
  backup)
    validate_production_environment_file true
    load_backup_environment
    assert_clean_deployment_checkout
    initialize_production_compose_context
    prepare_immutable_source_tree
    load_install_deployment_state "$SELECTED_POSTGRES_VOLUME"
    [[ -z "$INSTALL_PHASE" ]] || {
      echo "Finish or recover the interrupted first installation before creating a production backup." >&2
      exit 77
    }
    assert_authorized_deployment_revision exact
    capture_previous_web_release
    [[ -n "$PREVIOUS_WEB_IMAGE_ID" ]] || {
      echo "A backup requires exact source web release provenance." >&2
      exit 67
    }
    capture_native_config_baseline
    require_existing_postgres_container_ready "$SELECTED_POSTGRES_VOLUME"
    created_backup="$({
      ADDRESS_ATLAS_POSTGRES_CONTAINER="$READY_POSTGRES_CONTAINER" \
        bash "$BACKUP_SCRIPT" create
    })"
    ADDRESS_ATLAS_POSTGRES_CONTAINER="$READY_POSTGRES_CONTAINER" \
      bash "$BACKUP_SCRIPT" verify "$created_backup" >/dev/null
    printf '%s\n' "$created_backup"
    ;;
  verify-backup)
    validate_production_environment_file true
    load_backup_environment
    bash "$BACKUP_SCRIPT" latest
    ;;
  restore-drill)
    validate_production_environment_file true
    load_backup_environment
    assert_clean_deployment_checkout
    initialize_production_compose_context
    prepare_immutable_source_tree
    load_install_deployment_state "$SELECTED_POSTGRES_VOLUME"
    [[ -z "$INSTALL_PHASE" ]] || {
      echo "Resume or recover the unfinished first installation before running a restore drill." >&2
      exit 77
    }
    assert_authorized_deployment_revision exact
    rebuild_production_compose_args
    assert_volume_mount_safe_for_up "$SELECTED_POSTGRES_VOLUME" "PostgreSQL data" "postgres"
    ensure_postgres_container_ready \
      "$SELECTED_POSTGRES_VOLUME" "${PRODUCTION_COMPOSE_ARGS[@]}"
    "$DOCKER_BIN" "${PRODUCTION_COMPOSE_ARGS[@]}" build web
    configure_restore_contract "$ADDRESS_ATLAS_BUILD_REVISION"
    assert_clean_deployment_checkout
    assert_authorized_deployment_revision exact
    latest_backup="$(bash "$BACKUP_SCRIPT" latest)"
    bash "$BACKUP_SCRIPT" drill "$latest_backup"
    ;;
  restore)
    validate_production_environment_file true
    load_backup_environment
    assert_clean_deployment_checkout
    initialize_production_compose_context
    prepare_immutable_source_tree
    load_install_deployment_state "$SELECTED_POSTGRES_VOLUME"
    [[ -z "$INSTALL_PHASE" ]] || {
      echo "Production restore is unavailable during an unfinished first installation." >&2
      exit 77
    }
    assert_authorized_deployment_revision exact
    rebuild_production_compose_args
    assert_volume_mount_safe_for_up "$SELECTED_POSTGRES_VOLUME" "PostgreSQL data" "postgres"
    assert_volume_mount_safe_for_up "$SELECTED_CADDY_DATA_VOLUME" "Caddy data" "caddy"
    assert_volume_mount_safe_for_up "$SELECTED_CADDY_CONFIG_VOLUME" "Caddy config" "caddy"
    ensure_postgres_container_ready \
      "$SELECTED_POSTGRES_VOLUME" "${PRODUCTION_COMPOSE_ARGS[@]}"
    capture_previous_web_release
    [[ -n "$PREVIOUS_WEB_IMAGE_ID" ]] || {
      echo "Production restore requires an exact verified web rollback release." >&2
      exit 67
    }
    capture_native_config_baseline
    PREDEPLOY_COMPOSE_COMMAND=("${PRODUCTION_COMPOSE_ARGS[@]}")
    "$DOCKER_BIN" "${PRODUCTION_COMPOSE_ARGS[@]}" build web
    configure_restore_contract "$ADDRESS_ATLAS_BUILD_REVISION"
    preflight_private_web_config \
      "$ADDRESS_ATLAS_BUILD_REVISION" candidate "${PRODUCTION_COMPOSE_ARGS[@]}"
    "$DOCKER_BIN" image inspect "$PREVIOUS_WEB_IMAGE_ID" >/dev/null 2>&1 || {
      echo "The verified rollback image is unavailable before production restore." >&2
      exit 67
    }
    "$DOCKER_BIN" tag "$PREVIOUS_WEB_IMAGE_ID" "address-atlas-sync:${PREVIOUS_WEB_REVISION}"
    preflight_private_web_config \
      "$PREVIOUS_WEB_REVISION" rollback "${PRODUCTION_COMPOSE_ARGS[@]}"
    previous_frontend_was_running="$PREVIOUS_WEB_RUNNING"
    stop_fixed_frontend
    if [[ "$previous_frontend_was_running" == "true" ]]; then
      PREDEPLOY_RECOVERY_ENABLED=true
    fi
    assert_clean_deployment_checkout
    assert_authorized_deployment_revision exact
    # Once database replacement starts, an error deliberately leaves the web
    # tier stopped. The restore engine may have quiesced LOGIN or quarantined a
    # candidate, so blindly restarting the old frontend would be unsafe.
    PREDEPLOY_RECOVERY_ENABLED=false
    bash "$BACKUP_SCRIPT" restore "$2" "$3" "$4"
    "$DOCKER_BIN" "${PRODUCTION_COMPOSE_ARGS[@]}" \
      --profile admin run --rm --no-deps db-provision
    preflight_private_web_config \
      "$ADDRESS_ATLAS_BUILD_REVISION" candidate "${PRODUCTION_COMPOSE_ARGS[@]}"
    preflight_private_web_config \
      "$PREVIOUS_WEB_REVISION" rollback "${PRODUCTION_COMPOSE_ARGS[@]}"
    assert_clean_deployment_checkout
    assert_authorized_deployment_revision exact
    deploy_and_verify_or_rollback "${PRODUCTION_COMPOSE_ARGS[@]}"
    prune_immutable_source_cache
    ;;
  bootstrap-restore)
    validate_production_environment_file true
    load_backup_environment
    bootstrap_backup_path="$2"
    bootstrap_confirmation="$4"
    [[ "$bootstrap_backup_path" == /* \
       && "$bootstrap_backup_path" == *.dump.age \
       && "$bootstrap_backup_path" != *$'\n'* ]] || {
      echo "Bootstrap recovery requires an absolute single-line .dump.age artifact path." >&2
      exit 65
    }
    [[ "$bootstrap_confirmation" == BOOTSTRAP-RESTORE:* ]] || {
      echo "Bootstrap confirmation must exactly use BOOTSTRAP-RESTORE:<database>." >&2
      exit 64
    }
    bootstrap_database="${bootstrap_confirmation#BOOTSTRAP-RESTORE:}"
    [[ "$bootstrap_database" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ \
       && "$bootstrap_confirmation" == "BOOTSTRAP-RESTORE:${bootstrap_database}" ]] || {
      echo "Bootstrap recovery database confirmation is malformed." >&2
      exit 64
    }
    [[ "${ADDRESS_ATLAS_ALLOW_BOOTSTRAP_RESTORE:-}" \
          == "YES_I_UNDERSTAND_FRESH_CLUSTER_ONLY" ]] || {
      echo "Fresh-cluster recovery requires ADDRESS_ATLAS_ALLOW_BOOTSTRAP_RESTORE=YES_I_UNDERSTAND_FRESH_CLUSTER_ONLY." >&2
      exit 77
    }
    assert_clean_deployment_checkout
    ADDRESS_ATLAS_BUILD_REVISION="$(build_revision)"
    export ADDRESS_ATLAS_BUILD_REVISION
    bootstrap_authorization_mode=exact
    [[ "${ADDRESS_ATLAS_BOOTSTRAP_RECOVERY_RESUME:-false}" != "true" ]] \
      || bootstrap_authorization_mode=bootstrap-resume
    assert_authorized_deployment_revision "$bootstrap_authorization_mode"
    initialize_production_compose_context
    prepare_immutable_source_tree
    load_install_deployment_state "$SELECTED_POSTGRES_VOLUME"
    [[ -z "$INSTALL_PHASE" ]] || {
      echo "Fresh-cluster recovery cannot overlap an unfinished first installation." >&2
      exit 77
    }
    rebuild_production_compose_args
    [[ "$(database_role_mode)" == "steady" ]] || {
      echo "Fresh-cluster recovery requires ADDRESS_ATLAS_DATABASE_ROLE_MODE=steady." >&2
      exit 65
    }
    assert_volume_mount_safe_for_up \
      "$SELECTED_POSTGRES_VOLUME" "PostgreSQL data" "postgres"
    assert_volume_mount_safe_for_up \
      "$SELECTED_CADDY_DATA_VOLUME" "Caddy data" "caddy"
    assert_volume_mount_safe_for_up \
      "$SELECTED_CADDY_CONFIG_VOLUME" "Caddy config" "caddy"

    capture_previous_web_release
    load_durable_native_config_baseline
    PREDEPLOY_RECOVERY_ENABLED=false
    stop_fixed_frontend
    ensure_postgres_container_ready \
      "$SELECTED_POSTGRES_VOLUME" "${PRODUCTION_COMPOSE_ARGS[@]}"
    assert_exact_bootstrap_postgres_image "$READY_POSTGRES_CONTAINER"
    inspect_bootstrap_backup "$bootstrap_backup_path" "$bootstrap_database"
    merge_signed_backup_native_config_baseline \
      "$BOOTSTRAP_BACKUP_CONFIG_VERSION" \
      "$BOOTSTRAP_BACKUP_CONFIG_DIGEST" \
      "$BOOTSTRAP_BACKUP_CONFIG_UPDATED_AT" \
      "$BOOTSTRAP_BACKUP_CONFIG_REVISION" \
      "$BOOTSTRAP_BACKUP_SOURCE_WEB_IMAGE"

    "$DOCKER_BIN" "${PRODUCTION_COMPOSE_ARGS[@]}" build web
    configure_restore_contract "$ADDRESS_ATLAS_BUILD_REVISION"
    prepare_bootstrap_target_receipt_contract
    assert_existing_web_matches_recovery_evidence
    preflight_private_web_config \
      "$ADDRESS_ATLAS_BUILD_REVISION" policy-only \
      "${PRODUCTION_COMPOSE_ARGS[@]}"
    assert_clean_deployment_checkout
    assert_authorized_deployment_revision "$bootstrap_authorization_mode"

    bootstrap_engine_output="$({
      ADDRESS_ATLAS_POSTGRES_CONTAINER="$READY_POSTGRES_CONTAINER" \
        bash "$BACKUP_SCRIPT" bootstrap-restore \
          "$bootstrap_backup_path" --confirm "$bootstrap_confirmation"
    })" || exit $?
    validate_bootstrap_restore_receipt "$bootstrap_engine_output"
    printf '%s\n' "$bootstrap_engine_output"

    preflight_private_web_config \
      "$ADDRESS_ATLAS_BUILD_REVISION" approved \
      "${PRODUCTION_COMPOSE_ARGS[@]}"
    assert_clean_deployment_checkout
    assert_authorized_deployment_revision "$bootstrap_authorization_mode"
    # A pre-loss image is evidence only. It is never a rollback target after
    # database bootstrap; any cutover failure must leave the frontend stopped.
    PREVIOUS_WEB_IMAGE_ID=""
    PREVIOUS_WEB_REVISION=""
    PREVIOUS_WEB_RUNNING="false"
    deploy_and_verify_without_rollback "${PRODUCTION_COMPOSE_ARGS[@]}"

    ADDRESS_ATLAS_BOOTSTRAP_FINALIZE_ACK="PUBLIC_SMOKE_AND_RECEIPT_PERSISTED"
    export ADDRESS_ATLAS_BOOTSTRAP_FINALIZE_ACK
    ADDRESS_ATLAS_POSTGRES_CONTAINER="$READY_POSTGRES_CONTAINER" \
      bash "$BACKUP_SCRIPT" bootstrap-finalize \
        --confirm "BOOTSTRAP-FINALIZE:${bootstrap_database}"
    prune_immutable_source_cache
    echo "Fresh-cluster recovery is live, receipt-bound, and finalized."
    ;;
  detect-volume)
    validate_production_environment_file false
    detect_volume
    ;;
  detect-volumes)
    validate_production_environment_file false
    detect_all_volumes
    ;;
  up|config)
    if [[ "$command" == "up" ]]; then
      validate_production_environment_file true
      assert_clean_deployment_checkout
    else
      validate_production_environment_file false
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
    export ADDRESS_ATLAS_BUILD_REVISION="$(build_revision)"
    selected_database_role_mode="$(database_role_mode)"
    if [[ "$command" == "config" ]]; then
      exec "$DOCKER_BIN" "${compose_args[@]}" config --quiet
    elif [[ "$command" == "up" ]]; then
      assert_volume_mount_safe_for_up "$selected_postgres_volume" "PostgreSQL data" "postgres"
      assert_volume_mount_safe_for_up "$selected_caddy_data_volume" "Caddy data" "caddy"
      assert_volume_mount_safe_for_up "$selected_caddy_config_volume" "Caddy config" "caddy"
      load_backup_environment
      prepare_immutable_source_tree
      load_install_deployment_state "$selected_postgres_volume"
      deployment_authorization_mode=exact
      [[ -z "$INSTALL_PHASE" ]] || deployment_authorization_mode=install-resume
      assert_authorized_deployment_revision "$deployment_authorization_mode"
      compose_args=(compose)
      if [[ -f "$ENV_FILE" ]]; then
        compose_args+=(--env-file "$ENV_FILE")
      fi
      compose_args+=(--project-name "$COMPOSE_PROJECT_NAME_FIXED" -f "$COMPOSE_FILE")
      capture_previous_web_release
      capture_native_config_baseline
      PREDEPLOY_COMPOSE_COMMAND=("${compose_args[@]}")
      previous_frontend_was_running="$PREVIOUS_WEB_RUNNING"
      stop_fixed_frontend
      if [[ "$previous_frontend_was_running" == "true" ]]; then
        PREDEPLOY_RECOVERY_ENABLED=true
      fi
      ensure_postgres_container_ready \
        "$selected_postgres_volume" "${compose_args[@]}"
      source_classification="$({
        unset ADDRESS_ATLAS_BUILD_REVISION
        ADDRESS_ATLAS_POSTGRES_CONTAINER="$READY_POSTGRES_CONTAINER" \
          bash "$BACKUP_SCRIPT" classify-source
      })"
      [[ "$source_classification" == "brand-new-empty" \
         || "$source_classification" == "existing-or-ambiguous" ]] || {
        echo "The production database source could not be classified safely." >&2
        exit 69
      }

      if [[ -n "$INSTALL_PHASE" ]]; then
        if [[ "$source_classification" == "brand-new-empty" \
            && "$INSTALL_PHASE" != "candidate-ready" ]]; then
          echo "First-install recovery phase claims schema progress but the database is empty." >&2
          exit 67
        fi
        validate_resumable_first_install "${compose_args[@]}"
        if [[ "$source_classification" == "existing-or-ambiguous" ]]; then
          # No public receipt exists during a crash-resumable first install.
          # Bind the safety backup to the exact stopped candidate only after a
          # private config/provenance preflight of that recorded image.
          preflight_private_web_config \
            "$ADDRESS_ATLAS_BUILD_REVISION" candidate "${compose_args[@]}"
          set_backup_native_config_receipt \
            "$CANDIDATE_CONFIG_VERSION" "$CANDIDATE_CONFIG_DIGEST" \
            "$CANDIDATE_CONFIG_UPDATED_AT_MS" "$ADDRESS_ATLAS_BUILD_REVISION"
          prepare_verified_predeploy_backup \
            "$selected_postgres_volume" "${compose_args[@]}"
        else
          echo "Confirmed an empty first-install database; no data exists to back up."
        fi
      elif [[ "$source_classification" == "brand-new-empty" ]]; then
        [[ -z "$PREVIOUS_WEB_IMAGE_ID" && -z "$BASELINE_CONFIG_VERSION" ]] || {
          echo "A database classified as empty conflicts with existing release provenance." >&2
          exit 67
        }
        [[ "$selected_database_role_mode" == "bootstrap" ]] || {
          echo "A confirmed first installation requires ADDRESS_ATLAS_DATABASE_ROLE_MODE=bootstrap." >&2
          exit 65
        }
        echo "Confirmed a brand-new empty database; beginning crash-resumable first installation."
        begin_first_install \
          "$selected_postgres_volume" "${compose_args[@]}"
      else
        prepare_verified_predeploy_backup \
          "$selected_postgres_volume" "${compose_args[@]}"
        "$DOCKER_BIN" "${compose_args[@]}" build web
      fi

      "$DOCKER_BIN" "${compose_args[@]}" --profile admin run --rm --no-deps schema
      if [[ -n "$INSTALL_PHASE" ]]; then
        if [[ "$INSTALL_PHASE" == "candidate-ready" ]]; then
          record_install_deployment_phase schema-ready
        fi
        if [[ "$INSTALL_PHASE" == "schema-ready" ]]; then
          [[ "$selected_database_role_mode" == "bootstrap" ]] || {
            echo "Unfinished first-install role creation must resume in bootstrap mode." >&2
            exit 65
          }
          # A crash can occur after the role split transaction commits but
          # before its phase receipt is fsynced. Steady convergence succeeds
          # only for that exact already-complete state and is mutation-free on
          # missing/wrong desired credentials; otherwise run the one-time split.
          if "$DOCKER_BIN" "${compose_args[@]}" --profile admin run --rm --no-deps db-provision; then
            echo "Recovered a committed database role split after interruption."
          else
            "$DOCKER_BIN" "${compose_args[@]}" --profile admin run --rm --no-deps db-role-bootstrap
          fi
          record_install_deployment_phase roles-ready
          echo "Database role bootstrap completed. Set ADDRESS_ATLAS_DATABASE_ROLE_MODE=steady before the next deploy."
        else
          "$DOCKER_BIN" "${compose_args[@]}" --profile admin run --rm --no-deps db-provision
        fi
      elif [[ "$selected_database_role_mode" == "bootstrap" ]]; then
        "$DOCKER_BIN" "${compose_args[@]}" --profile admin run --rm --no-deps db-role-bootstrap
        echo "Database role bootstrap completed. Set ADDRESS_ATLAS_DATABASE_ROLE_MODE=steady before the next deploy."
      else
        "$DOCKER_BIN" "${compose_args[@]}" --profile admin run --rm --no-deps db-provision
      fi
      preflight_private_web_config \
        "$ADDRESS_ATLAS_BUILD_REVISION" candidate "${compose_args[@]}"
      if [[ -n "$PREVIOUS_WEB_IMAGE_ID" ]]; then
        "$DOCKER_BIN" image inspect "$PREVIOUS_WEB_IMAGE_ID" >/dev/null 2>&1 || {
          echo "The previous verified web image is unavailable for rollback preflight." >&2
          exit 67
        }
        "$DOCKER_BIN" tag \
          "$PREVIOUS_WEB_IMAGE_ID" "address-atlas-sync:${PREVIOUS_WEB_REVISION}"
        preflight_private_web_config \
          "$PREVIOUS_WEB_REVISION" rollback "${compose_args[@]}"
      fi
      # Close the approval-to-cutover race: a new main commit or a local edit
      # after build/migration leaves the old verified web tier serving and
      # requires a fresh deployment from the new authoritative revision.
      assert_clean_deployment_checkout
      assert_authorized_deployment_revision "$deployment_authorization_mode"
      PREDEPLOY_RECOVERY_ENABLED=false
      deploy_and_verify_or_rollback "${compose_args[@]}"
      complete_install_deployment_state
      prune_immutable_source_cache
    fi
    ;;
  *)
    usage
    ;;
esac
