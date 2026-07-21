#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
monitor_script="$SCRIPT_DIR/monitor-sync.sh"
monitor_service="$SCRIPT_DIR/systemd/address-atlas-monitor.service"
monitor_timer="$SCRIPT_DIR/systemd/address-atlas-monitor.timer"
backup_service="$SCRIPT_DIR/systemd/address-atlas-backup.service"
restore_drill_service="$SCRIPT_DIR/systemd/address-atlas-restore-drill.service"

max_total="$(sed -n 's/^MAX_TOTAL_TIMEOUT_SECONDS=//p' "$monitor_script")"
unit_timeout="$(sed -n 's/^TimeoutStartSec=\([0-9][0-9]*\)s$/\1/p' "$monitor_service")"
timer_interval="$(sed -n 's/^OnUnitActiveSec=\([0-9][0-9]*\)min$/\1/p' "$monitor_timer")"

[[ "$max_total" =~ ^[1-9][0-9]*$ \
   && "$unit_timeout" =~ ^[1-9][0-9]*$ \
   && "$timer_interval" =~ ^[1-9][0-9]*$ ]] || {
  echo 'monitor/systemd timing contract is malformed' >&2
  exit 1
}
(( unit_timeout >= max_total + 5 )) || {
  echo 'systemd can kill a valid monitor execution before its total deadline' >&2
  exit 1
}
(( unit_timeout < timer_interval * 60 )) || {
  echo 'monitor service timeout must remain below its one-minute activation interval' >&2
  exit 1
}
grep -F 'User=nobody' "$monitor_service" >/dev/null
grep -F 'NoNewPrivileges=true' "$monitor_service" >/dev/null
grep -F 'Persistent=true' "$monitor_timer" >/dev/null

for stateful_service in "$backup_service" "$restore_drill_service"; do
  grep -F 'ProtectSystem=strict' "$stateful_service" >/dev/null
  grep -F 'Environment=ADDRESS_ATLAS_CONTROL_ROOT=/var/lib/address-atlas/service-control' \
    "$stateful_service" >/dev/null
  grep -E '^ReadWritePaths=.*(^| )/var/lib/address-atlas/service-control( |$)' \
    "$stateful_service" >/dev/null
done

echo 'systemd-contract-tests: 2/2 passed'
