#!/usr/bin/env bash

# Cross-process cutover fence shared by production service starts and the
# lock-bypassing emergency stop. The caller owns shell options and command
# dispatch. This file deliberately performs no work when sourced.

ADDRESS_ATLAS_CONTROL_ROOT="${ADDRESS_ATLAS_CONTROL_ROOT:-/var/lib/address-atlas/service-control}"
ADDRESS_ATLAS_EMERGENCY_STOP_FENCE="${ADDRESS_ATLAS_CONTROL_ROOT}/emergency-stop"
ADDRESS_ATLAS_SERVICE_CONTROL_LOCK="${ADDRESS_ATLAS_CONTROL_ROOT}/service-control.lock"
SERVICE_CONTROL_LOCK_HELD=false
SERVICE_CONTROL_LOCK_RECORD=""

service_control_stat_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

service_control_stat_owner() {
  stat -c %u "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null
}

service_control_stat_links() {
  stat -c %h "$1" 2>/dev/null || stat -f %l "$1" 2>/dev/null
}

service_control_process_start_identity() {
  local pid="$1"
  ps -o lstart= -p "$pid" 2>/dev/null
}

service_control_fsync_directory() {
  local directory="$1"
  "$NODE_BIN" --input-type=module - "$directory" <<'NODE'
import { closeSync, constants, fsyncSync, openSync } from "node:fs";

const directory = process.argv[2];
const descriptor = openSync(directory, constants.O_RDONLY);
try {
  fsyncSync(descriptor);
} finally {
  closeSync(descriptor);
}
NODE
}

validate_service_control_root() {
  [[ "$ADDRESS_ATLAS_CONTROL_ROOT" == /* \
     && "$ADDRESS_ATLAS_CONTROL_ROOT" != "/" \
     && "$ADDRESS_ATLAS_CONTROL_ROOT" != *$'\n'* ]] || {
    echo "ADDRESS_ATLAS_CONTROL_ROOT must be a safe absolute directory." >&2
    return 65
  }

  local parent mode owner permissions parent_mode parent_owner parent_permissions
  parent="$(dirname "$ADDRESS_ATLAS_CONTROL_ROOT")"
  [[ -d "$parent" && ! -L "$parent" \
     && "$(cd "$parent" 2>/dev/null && pwd -P)" == "$parent" ]] || {
    echo "The emergency-control parent must be a canonical non-symlink directory." >&2
    return 66
  }
  parent_mode="$(service_control_stat_mode "$parent" || true)"
  parent_owner="$(service_control_stat_owner "$parent" || true)"
  [[ "$parent_mode" =~ ^[0-7]{3,4}$ && "$parent_owner" =~ ^[0-9]+$ ]] || {
    echo "Unable to validate the emergency-control parent metadata." >&2
    return 66
  }
  parent_permissions=$((8#$parent_mode))
  [[ "$parent_owner" -eq "$(id -u)" \
     && $((parent_permissions & 8#022)) -eq 0 ]] || {
    echo "The emergency-control parent must be operator-owned and non-writable by group/other." >&2
    return 66
  }

  if [[ ! -e "$ADDRESS_ATLAS_CONTROL_ROOT" \
      && ! -L "$ADDRESS_ATLAS_CONTROL_ROOT" ]]; then
    if ! mkdir -m 0700 "$ADDRESS_ATLAS_CONTROL_ROOT"; then
      [[ -d "$ADDRESS_ATLAS_CONTROL_ROOT" \
         && ! -L "$ADDRESS_ATLAS_CONTROL_ROOT" ]] || {
        echo "Unable to create the private emergency-control directory." >&2
        return 74
      }
    fi
    service_control_fsync_directory "$parent" || {
      echo "Unable to durably publish the emergency-control directory." >&2
      return 74
    }
  fi

  [[ -d "$ADDRESS_ATLAS_CONTROL_ROOT" \
     && ! -L "$ADDRESS_ATLAS_CONTROL_ROOT" \
     && "$(cd "$ADDRESS_ATLAS_CONTROL_ROOT" 2>/dev/null && pwd -P)" \
          == "$ADDRESS_ATLAS_CONTROL_ROOT" ]] || {
    echo "The emergency-control directory is not a canonical private directory." >&2
    return 66
  }
  mode="$(service_control_stat_mode "$ADDRESS_ATLAS_CONTROL_ROOT" || true)"
  owner="$(service_control_stat_owner "$ADDRESS_ATLAS_CONTROL_ROOT" || true)"
  [[ "$mode" =~ ^[0-7]{3,4}$ && "$owner" =~ ^[0-9]+$ ]] || {
    echo "Unable to validate the emergency-control directory metadata." >&2
    return 66
  }
  permissions=$((8#$mode))
  [[ "$owner" -eq "$(id -u)" && $((permissions & 8#077)) -eq 0 ]] || {
    echo "The emergency-control directory must be operator-owned and private." >&2
    return 66
  }
}

validate_emergency_stop_fence() {
  [[ -d "$ADDRESS_ATLAS_EMERGENCY_STOP_FENCE" \
     && ! -L "$ADDRESS_ATLAS_EMERGENCY_STOP_FENCE" ]] || {
    echo "The emergency-stop fence is malformed; refusing service mutation." >&2
    return 73
  }
  local mode owner permissions entry
  mode="$(service_control_stat_mode "$ADDRESS_ATLAS_EMERGENCY_STOP_FENCE" || true)"
  owner="$(service_control_stat_owner "$ADDRESS_ATLAS_EMERGENCY_STOP_FENCE" || true)"
  [[ "$mode" =~ ^[0-7]{3,4}$ && "$owner" =~ ^[0-9]+$ ]] || return 73
  permissions=$((8#$mode))
  [[ "$owner" -eq "$(id -u)" && $((permissions & 8#077)) -eq 0 ]] || {
    echo "The emergency-stop fence is not operator-owned/private." >&2
    return 73
  }
  entry="$(find "$ADDRESS_ATLAS_EMERGENCY_STOP_FENCE" -mindepth 1 \
    -maxdepth 1 -print -quit 2>/dev/null || true)"
  [[ -z "$entry" ]] || {
    echo "The emergency-stop fence contains unexpected data; refusing service mutation." >&2
    return 73
  }
}

request_terminal_emergency_stop() {
  validate_service_control_root || return $?
  if [[ -e "$ADDRESS_ATLAS_EMERGENCY_STOP_FENCE" \
      || -L "$ADDRESS_ATLAS_EMERGENCY_STOP_FENCE" ]]; then
    validate_emergency_stop_fence || return $?
  else
    mkdir -m 0700 "$ADDRESS_ATLAS_EMERGENCY_STOP_FENCE" || {
      [[ -e "$ADDRESS_ATLAS_EMERGENCY_STOP_FENCE" \
         || -L "$ADDRESS_ATLAS_EMERGENCY_STOP_FENCE" ]] \
        && validate_emergency_stop_fence \
        || return 74
    }
  fi
  service_control_fsync_directory "$ADDRESS_ATLAS_CONTROL_ROOT" || {
    echo "Unable to durably publish the emergency-stop fence." >&2
    return 74
  }
}

assert_terminal_emergency_stop_not_requested() {
  validate_service_control_root || return $?
  if [[ -e "$ADDRESS_ATLAS_EMERGENCY_STOP_FENCE" \
      || -L "$ADDRESS_ATLAS_EMERGENCY_STOP_FENCE" ]]; then
    validate_emergency_stop_fence || return $?
    echo "The durable emergency-stop fence is active; service mutation is blocked." >&2
    echo "After incident review, clear it through manage-prod.sh clear-emergency-stop." >&2
    return 75
  fi
}

validate_service_control_lock() {
  [[ -f "$ADDRESS_ATLAS_SERVICE_CONTROL_LOCK" \
     && ! -L "$ADDRESS_ATLAS_SERVICE_CONTROL_LOCK" ]] || {
    echo "The service-control lock is malformed." >&2
    return 73
  }
  local mode owner links permissions
  mode="$(service_control_stat_mode "$ADDRESS_ATLAS_SERVICE_CONTROL_LOCK" || true)"
  owner="$(service_control_stat_owner "$ADDRESS_ATLAS_SERVICE_CONTROL_LOCK" || true)"
  links="$(service_control_stat_links "$ADDRESS_ATLAS_SERVICE_CONTROL_LOCK" || true)"
  # The atomic hard-link publisher briefly exposes link count two until its
  # private candidate name is removed. Both names live in the same 0700 root.
  [[ "$mode" =~ ^[0-7]{3,4}$ && "$owner" =~ ^[0-9]+$ \
     && ( "$links" == 1 || "$links" == 2 ) ]] || return 73
  permissions=$((8#$mode))
  [[ "$owner" -eq "$(id -u)" && $((permissions & 8#077)) -eq 0 ]] || {
    echo "The service-control lock is not operator-owned/private." >&2
    return 73
  }
}

read_service_control_lock_owner() {
  validate_service_control_lock || return $?
  local lines=() line
  while IFS= read -r line; do
    lines+=("$line")
  done < "$ADDRESS_ATLAS_SERVICE_CONTROL_LOCK"
  [[ "${#lines[@]}" -eq 2 \
     && "${lines[0]}" == pid=* \
     && "${lines[1]}" == start=* ]] || {
    echo "The service-control lock owner record is malformed." >&2
    return 73
  }
  SERVICE_CONTROL_OBSERVED_PID="${lines[0]#pid=}"
  SERVICE_CONTROL_OBSERVED_START="${lines[1]#start=}"
  [[ "$SERVICE_CONTROL_OBSERVED_PID" =~ ^[1-9][0-9]*$ \
     && -n "$SERVICE_CONTROL_OBSERVED_START" \
     && "${#SERVICE_CONTROL_OBSERVED_START}" -le 200 ]] || {
    echo "The service-control lock owner identity is malformed." >&2
    return 73
  }
}

service_control_lock_owner_is_live() {
  read_service_control_lock_owner || return $?
  kill -0 "$SERVICE_CONTROL_OBSERVED_PID" 2>/dev/null || return 1
  local observed_start
  observed_start="$(service_control_process_start_identity \
    "$SERVICE_CONTROL_OBSERVED_PID" || true)"
  [[ -n "$observed_start" \
     && "$observed_start" == "$SERVICE_CONTROL_OBSERVED_START" ]]
}

publish_service_control_lock() {
  local start candidate record
  start="$(service_control_process_start_identity "$$" || true)"
  [[ -n "$start" && "${#start}" -le 200 ]] || {
    echo "Unable to bind the service-control lock to this process." >&2
    return 74
  }
  record="pid=$$"$'\n'"start=${start}"
  candidate="$(mktemp "${ADDRESS_ATLAS_CONTROL_ROOT}/.service-control-owner.XXXXXX")" \
    || return 74
  chmod 0600 "$candidate"
  printf '%s\n' "$record" > "$candidate" || {
    find "$candidate" -maxdepth 0 -type f -delete 2>/dev/null || true
    return 74
  }
  if ln "$candidate" "$ADDRESS_ATLAS_SERVICE_CONTROL_LOCK" 2>/dev/null; then
    find "$candidate" -maxdepth 0 -type f -delete 2>/dev/null || true
    SERVICE_CONTROL_LOCK_RECORD="$record"
    SERVICE_CONTROL_LOCK_HELD=true
    return 0
  fi
  find "$candidate" -maxdepth 0 -type f -delete 2>/dev/null || true
  return 1
}

acquire_service_control_lock() {
  [[ "$SERVICE_CONTROL_LOCK_HELD" == false ]] || {
    echo "Nested service-control locks are not supported." >&2
    return 70
  }
  validate_service_control_root || return $?
  local attempt live_status
  for attempt in {1..1500}; do
    if [[ ! -e "$ADDRESS_ATLAS_SERVICE_CONTROL_LOCK" \
        && ! -L "$ADDRESS_ATLAS_SERVICE_CONTROL_LOCK" ]]; then
      publish_service_control_lock && return 0
    fi
    live_status=0
    service_control_lock_owner_is_live || live_status=$?
    if [[ "$live_status" -eq 1 ]]; then
      echo "A stale service-control lock exists; the emergency-stop fence remains authoritative." >&2
      echo "Verify the recorded PID/start identity and Docker state, then remove only ${ADDRESS_ATLAS_SERVICE_CONTROL_LOCK}." >&2
      return 75
    fi
    [[ "$live_status" -eq 0 ]] || return "$live_status"
    sleep 0.1
  done
  echo "Timed out waiting for the bounded service-control cutover lock." >&2
  return 75
}

release_service_control_lock() {
  [[ "$SERVICE_CONTROL_LOCK_HELD" == true \
     && -n "$SERVICE_CONTROL_LOCK_RECORD" ]] || return 70
  validate_service_control_lock || return $?
  local observed
  observed="$(< "$ADDRESS_ATLAS_SERVICE_CONTROL_LOCK")"
  [[ "$observed" == "$SERVICE_CONTROL_LOCK_RECORD" ]] || {
    echo "The service-control lock owner changed unexpectedly." >&2
    return 73
  }
  find "$ADDRESS_ATLAS_SERVICE_CONTROL_LOCK" -maxdepth 0 \
    -type f -delete || return 74
  SERVICE_CONTROL_LOCK_HELD=false
  SERVICE_CONTROL_LOCK_RECORD=""
}

run_service_mutation_if_allowed() {
  acquire_service_control_lock || return $?
  local command_status=0 release_status=0
  if assert_terminal_emergency_stop_not_requested; then
    "$@" || command_status=$?
  else
    command_status=$?
  fi
  release_service_control_lock || release_status=$?
  [[ "$release_status" -eq 0 ]] || return "$release_status"
  return "$command_status"
}

clear_terminal_emergency_stop() {
  acquire_service_control_lock || return $?
  local clear_status=0 release_status=0
  if assert_fixed_project_stopped; then
    if [[ -e "$ADDRESS_ATLAS_EMERGENCY_STOP_FENCE" \
        || -L "$ADDRESS_ATLAS_EMERGENCY_STOP_FENCE" ]]; then
      if validate_emergency_stop_fence; then
        if rmdir "$ADDRESS_ATLAS_EMERGENCY_STOP_FENCE"; then
          if service_control_fsync_directory "$ADDRESS_ATLAS_CONTROL_ROOT"; then
            :
          else
            # The visible clear succeeded but its directory entry is not known
            # durable. Re-arm the fence before returning an uncertain failure.
            mkdir -m 0700 "$ADDRESS_ATLAS_EMERGENCY_STOP_FENCE" \
              2>/dev/null || true
            service_control_fsync_directory "$ADDRESS_ATLAS_CONTROL_ROOT" \
              2>/dev/null || true
            echo "Unable to durably clear the emergency-stop fence; it was re-armed." >&2
            clear_status=74
          fi
        else
          echo "Unable to remove the validated emergency-stop fence." >&2
          clear_status=74
        fi
      else
        clear_status=$?
      fi
    fi
  else
    clear_status=$?
  fi
  release_service_control_lock || release_status=$?
  [[ "$release_status" -eq 0 ]] || return "$release_status"
  [[ "$clear_status" -eq 0 ]] || return "$clear_status"
  echo "Cleared the durable emergency-stop fence; a new locked operation may start services."
}
