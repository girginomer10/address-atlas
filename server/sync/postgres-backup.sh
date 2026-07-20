#!/usr/bin/env bash
set -euo pipefail

# Encrypted, signed PostgreSQL backup/restore tooling for the production
# Compose stack. Plaintext dumps stream directly from pg_dump to age.

DOCKER_BIN="${DOCKER_BIN:-docker}"
AGE_BIN="${AGE_BIN:-age}"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"
NODE_BIN="${NODE_BIN:-node}"
PROJECT_NAME="address-atlas-sync"
BACKUP_DIR="${ADDRESS_ATLAS_BACKUP_DIR:-/var/backups/address-atlas}"
RETENTION_DAYS="${ADDRESS_ATLAS_BACKUP_RETENTION_DAYS:-30}"
MAX_AGE_HOURS="${ADDRESS_ATLAS_BACKUP_MAX_AGE_HOURS:-8}"
MAX_BACKUP_BYTES="${ADDRESS_ATLAS_BACKUP_MAX_BYTES:-53687091200}"
OWNER_USER="address_atlas"
ADMIN_USER="address_atlas_admin"
RUNTIME_USER="address_atlas_runtime"
MANIFEST_SCHEMA_VERSION=4
EXPECTED_MIGRATION_HEAD=3
SCHEMA_MIGRATION_ADVISORY_LOCK=1094992973
EXPECTED_RESTORE_PROVISION_IMAGE='postgres:16.14-alpine3.24@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777'
BACKUP_OPERATION_LOCK_HELD=false
BOOTSTRAP_LOCK_RECLAIM_ACTIVE=false
BOOTSTRAP_RECLAIM_CLAIM_FILE=""

usage() {
  cat >&2 <<'EOF'
Usage:
  postgres-backup.sh create
  postgres-backup.sh create-predeploy
  postgres-backup.sh classify-source
  postgres-backup.sh verify <absolute-backup.dump.age>
  postgres-backup.sh inspect <absolute-backup.dump.age>
  postgres-backup.sh latest
  postgres-backup.sh drill <absolute-backup.dump.age>
  postgres-backup.sh restore <absolute-backup.dump.age> --confirm RESTORE:<database>
  postgres-backup.sh bootstrap-restore <absolute-backup.dump.age> --confirm BOOTSTRAP-RESTORE:<database>
  postgres-backup.sh bootstrap-finalize --confirm BOOTSTRAP-FINALIZE:<database>
  postgres-backup.sh bootstrap-lock-run -- <absolute-trusted-executable> [arguments...]
  postgres-backup.sh lock-run -- <absolute-trusted-executable> [arguments...]
  postgres-backup.sh assert-lock

Required environment:
  create:
    ADDRESS_ATLAS_BACKUP_AGE_RECIPIENT
    ADDRESS_ATLAS_BACKUP_AGE_IDENTITY_FILE
    ADDRESS_ATLAS_BACKUP_SIGNING_PRIVATE_KEY_FILE
    ADDRESS_ATLAS_BACKUP_SIGNATURE_PUBLIC_KEY_FILE
  verify/latest:
    ADDRESS_ATLAS_BACKUP_AGE_IDENTITY_FILE
    ADDRESS_ATLAS_BACKUP_SIGNATURE_PUBLIC_KEY_FILE
  drill:
    all verify variables plus POSTGRES_ADMIN_PASSWORD, POSTGRES_RUNTIME_PASSWORD,
    and both restore hooks/image identifiers listed below
  restore:
    all create, verify, and drill variables
  bootstrap-restore:
    all verify and drill variables plus the explicit bootstrap authorization
    ADDRESS_ATLAS_ALLOW_BOOTSTRAP_RESTORE=YES_I_UNDERSTAND_FRESH_CLUSTER_ONLY
    ADDRESS_ATLAS_EXPECTED_BACKUP_SHA256=<inspect-command-artifact-sha256>
  bootstrap-finalize:
    all bootstrap-restore variables plus
    ADDRESS_ATLAS_BOOTSTRAP_FINALIZE_ACK=PUBLIC_SMOKE_AND_RECEIPT_PERSISTED
  bootstrap-lock-run:
    all bootstrap-restore/finalize variables plus
    ADDRESS_ATLAS_ALLOW_BOOTSTRAP_LOCK_RECLAIM=YES_I_VERIFIED_STALE_OWNER
    Reclaim exports the state-bound ADDRESS_ATLAS_BOOTSTRAP_TARGET_REVISION to
    the trusted manager so it can rebuild only the exact recorded revision.

Optional offsite contract:
  ADDRESS_ATLAS_BACKUP_OFFSITE_HOOK=/absolute/private/executable
  ADDRESS_ATLAS_BACKUP_OFFSITE_REQUIRED=true|false

The hook receives four completed local artifact paths: encrypted dump,
checksum, canonical manifest, and detached manifest signature. Required
delivery failures never delete the completed local set.

Production restore additionally requires:
  ADDRESS_ATLAS_ALLOW_PRODUCTION_RESTORE=YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED
  ADDRESS_ATLAS_BACKUP_RESTORE_PROVISION_HOOK=/absolute/private/executable
  ADDRESS_ATLAS_RESTORE_PROVISION_IMAGE=<immutable-postgres-image@sha256:digest>
  POSTGRES_RUNTIME_PASSWORD=<restricted-runtime-secret>
  The web container must be stopped. A fresh encrypted safety backup is created
  before a fresh staging database is restored and atomically cut over.

Every drill/restore runs the immutable current-image migration/readiness hook:
  ADDRESS_ATLAS_BACKUP_RESTORE_MIGRATION_HOOK=/absolute/private/executable
  ADDRESS_ATLAS_RESTORE_BUILD_REVISION=<full-lowercase-git-sha>
  ADDRESS_ATLAS_RESTORE_IMAGE=<immutable-image-tagged-with-that-sha>
  POSTGRES_PASSWORD=<restricted-owner-secret>

New backups also require a caller-verified native-config receipt, signed into
manifest schema v4:
  ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_VERSION=<positive-integer>
  ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_SHA256=<lowercase-sha256>
  ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_UPDATED_AT_EPOCH_MS=<positive-integer>
  ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_SERVING_REVISION=<full-lowercase-git-sha>
EOF
  exit 64
}

die() {
  printf 'ERROR %s\n' "$1" >&2
  exit "${2:-1}"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1" 69
}

scrub_environment() {
  local variable
  while IFS= read -r variable; do
    unset "$variable" 2>/dev/null || true
  done < <(builtin compgen -e)
}

validate_uint() {
  local value="$1"
  local name="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "${name} must be a non-negative integer." 65
}

validate_identifier() {
  local value="$1"
  local name="$2"
  [[ "$value" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "${#value}" -le 63 ]] \
    || die "${name} is not a safe PostgreSQL identifier." 65
}

validate_backup_dir() {
  [[ "$BACKUP_DIR" == /* && "$BACKUP_DIR" != "/" ]] \
    || die "ADDRESS_ATLAS_BACKUP_DIR must be an absolute directory other than /." 65
  [[ "$BACKUP_DIR" != *$'\n'* ]] || die "Backup directory must not contain a newline." 65
  validate_no_symlink_components "$BACKUP_DIR"
  validate_uint "$RETENTION_DAYS" "ADDRESS_ATLAS_BACKUP_RETENTION_DAYS"
  validate_uint "$MAX_AGE_HOURS" "ADDRESS_ATLAS_BACKUP_MAX_AGE_HOURS"
  validate_uint "$MAX_BACKUP_BYTES" "ADDRESS_ATLAS_BACKUP_MAX_BYTES"
  [[ "$MAX_BACKUP_BYTES" -gt 0 ]] \
    || die "ADDRESS_ATLAS_BACKUP_MAX_BYTES must be greater than zero." 65
}

prepare_backup_directory() {
  validate_backup_dir
  umask 077
  mkdir -p "$BACKUP_DIR"
  validate_no_symlink_components "$BACKUP_DIR"
  [[ -d "$BACKUP_DIR" && ! -L "$BACKUP_DIR" ]] \
    || die "Backup destination is not a regular directory." 65
  [[ "$(file_owner_uid "$BACKUP_DIR")" -eq "$(id -u)" ]] \
    || die "Backup directory must be owned by the effective user." 65
  chmod 0700 "$BACKUP_DIR"
  [[ "$(file_mode "$BACKUP_DIR")" =~ ^0?700$ ]] \
    || die "Backup directory permissions could not be restricted to 0700." 65
  # Inspect the final directory as a parent of a hypothetical child after
  # mkdir. This rejects writable or foreign-owned path components that could
  # otherwise replace the destination after validation.
  validate_trusted_parent_components "${BACKUP_DIR}/.path-sentinel" \
    "The backup directory"
}

sha256_stream() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    die "A SHA-256 implementation (sha256sum or shasum) is required." 69
  fi
}

sha256_file() {
  sha256_stream < "$1"
}

iso8601_epoch() {
  local value="$1"
  local parsed
  if parsed="$(date -u -d "$value" +%s 2>/dev/null)"; then
    printf '%s\n' "$parsed"
    return 0
  fi
  if parsed="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$value" +%s 2>/dev/null)"; then
    printf '%s\n' "$parsed"
    return 0
  fi
  die "Unable to parse signed backup creation time." 65
}

file_mode() {
  if stat -c %a "$1" >/dev/null 2>&1; then
    stat -c %a "$1"
  else
    stat -f %Lp "$1"
  fi
}

file_owner_uid() {
  if stat -c %u "$1" >/dev/null 2>&1; then
    stat -c %u "$1"
  else
    stat -f %u "$1"
  fi
}

file_size() {
  if stat -c %s "$1" >/dev/null 2>&1; then
    stat -c %s "$1"
  else
    stat -f %z "$1"
  fi
}

snapshot_regular_file() {
  local source="$1" destination="$2" expected_size="$3" max_size="$4"
  local description="$5"
  require_command "$NODE_BIN"
  "$NODE_BIN" -e '
    "use strict";
    const fs = require("node:fs");
    const [source, destination, expectedRaw, maximumRaw, effectiveUidRaw] =
      process.argv.slice(1);
    const expected = BigInt(expectedRaw);
    const maximum = BigInt(maximumRaw);
    const effectiveUid = BigInt(effectiveUidRaw);
    let sourceFd;
    let destinationFd;
    let destinationCreated = false;
    try {
      sourceFd = fs.openSync(
        source,
        fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK,
      );
      const sourceStat = fs.fstatSync(sourceFd, { bigint: true });
      if (!sourceStat.isFile()
          || (sourceStat.uid !== 0n && sourceStat.uid !== effectiveUid)
          || (sourceStat.mode & 0o22n) !== 0n
          || sourceStat.size !== expected
          || sourceStat.size <= 0n
          || sourceStat.size > maximum) {
        throw new Error("unsafe source metadata");
      }
      destinationFd = fs.openSync(
        destination,
        fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL
          | fs.constants.O_NOFOLLOW,
        0o600,
      );
      destinationCreated = true;
      if (!fs.fstatSync(destinationFd).isFile()) {
        throw new Error("unsafe destination metadata");
      }
      const buffer = Buffer.allocUnsafe(1024 * 1024);
      let remaining = expected;
      while (remaining > 0n) {
        const requested = Number(remaining > BigInt(buffer.length)
          ? BigInt(buffer.length) : remaining);
        const bytesRead = fs.readSync(sourceFd, buffer, 0, requested, null);
        if (bytesRead <= 0) throw new Error("source truncated during snapshot");
        let written = 0;
        while (written < bytesRead) {
          written += fs.writeSync(
            destinationFd,
            buffer,
            written,
            bytesRead - written,
            null,
          );
        }
        remaining -= BigInt(bytesRead);
      }
      if (fs.readSync(sourceFd, buffer, 0, 1, null) !== 0) {
        throw new Error("source grew during snapshot");
      }
      fs.fsyncSync(destinationFd);
    } catch (_error) {
      if (destinationFd !== undefined) {
        try { fs.closeSync(destinationFd); } catch (_closeError) {}
        destinationFd = undefined;
      }
      if (destinationCreated) {
        try { fs.unlinkSync(destination); } catch (_unlinkError) {}
      }
      process.exitCode = 1;
    } finally {
      if (sourceFd !== undefined) {
        try { fs.closeSync(sourceFd); } catch (_closeError) {}
      }
      if (destinationFd !== undefined) {
        try { fs.closeSync(destinationFd); } catch (_closeError) {}
      }
    }
  ' -- "$source" "$destination" "$expected_size" "$max_size" "$(id -u)" \
    || die "${description} changed or violated the no-follow snapshot contract." 73
}

sync_durably() {
  local path="$1"
  if ! sync -f "$path" >/dev/null 2>&1; then
    sync
  fi
}

validate_no_symlink_components() {
  local path="$1"
  local remainder="${path#/}"
  local current=""
  local component
  while [[ -n "$remainder" ]]; do
    if [[ "$remainder" == *"/"* ]]; then
      component="${remainder%%/*}"
      remainder="${remainder#*"/"}"
    else
      component="$remainder"
      remainder=""
    fi
    [[ -n "$component" && "$component" != "." && "$component" != ".." ]] \
      || die "Backup path contains an unsafe component." 65
    current="${current}/${component}"
    [[ ! -L "$current" ]] || die "Security-sensitive path contains a symlink component." 65
  done
}

validate_trusted_parent_components() {
  local path="$1" description="$2"
  [[ "$path" == /* && "$path" != *$'\n'* ]] \
    || die "${description} path is not a safe absolute path." 65
  local parent="${path%/*}"
  [[ -n "$parent" ]] || parent="/"
  validate_no_symlink_components "$parent"
  local remainder="${parent#/}" current="" component mode owner permissions
  local current_uid
  current_uid="$(id -u)"
  [[ "$parent" == "/" ]] && remainder=""
  while [[ -n "$remainder" ]]; do
    if [[ "$remainder" == *"/"* ]]; then
      component="${remainder%%/*}"
      remainder="${remainder#*"/"}"
    else
      component="$remainder"
      remainder=""
    fi
    current="${current}/${component}"
    [[ -d "$current" && ! -L "$current" ]] \
      || die "${description} has a non-directory or symbolic parent component." 65
    mode="$(file_mode "$current")"
    owner="$(file_owner_uid "$current")"
    [[ "$mode" =~ ^[0-7]{3,4}$ && "$owner" =~ ^[0-9]+$ ]] \
      || die "Unable to validate ${description} parent metadata." 65
    permissions=$((8#$mode))
    [[ "$owner" -eq 0 || "$owner" -eq "$current_uid" ]] \
      || die "${description} parent must be owned by root or the effective user." 65
    (( (permissions & 8#022) == 0 )) \
      || die "${description} parent must not be writable by group or other users." 65
  done
}

validate_private_file() {
  local path="$1"
  local description="$2"
  [[ -n "$path" && "$path" == /* && -f "$path" && ! -L "$path" ]] \
    || die "${description} must name an existing absolute regular file." 66
  validate_trusted_parent_components "$path" "$description"
  local mode owner permissions
  mode="$(file_mode "$path")"
  owner="$(file_owner_uid "$path")"
  [[ "$mode" =~ ^[0-7]{3,4}$ && "$owner" =~ ^[0-9]+$ ]] \
    || die "Unable to validate ${description} metadata." 65
  permissions=$((8#$mode))
  [[ "$owner" -eq "$(id -u)" ]] \
    || die "${description} must be owned by the effective user." 65
  (( (permissions & 8#077) == 0 )) \
    || die "${description} must not be accessible by group or other users." 65
}

validate_trusted_public_file() {
  local path="$1"
  local description="$2"
  [[ -n "$path" && "$path" == /* && -f "$path" && ! -L "$path" ]] \
    || die "${description} must name an existing absolute regular file." 66
  validate_trusted_parent_components "$path" "$description"
  local mode owner permissions current_uid
  mode="$(file_mode "$path")"
  owner="$(file_owner_uid "$path")"
  current_uid="$(id -u)"
  [[ "$mode" =~ ^[0-7]{3,4}$ && "$owner" =~ ^[0-9]+$ ]] \
    || die "Unable to validate ${description} metadata." 65
  permissions=$((8#$mode))
  [[ "$owner" -eq 0 || "$owner" -eq "$current_uid" ]] \
    || die "${description} must be owned by root or the effective user." 65
  (( (permissions & 8#022) == 0 )) \
    || die "${description} must not be writable by group or other users." 65
}

validate_identity_file() {
  local identity="${ADDRESS_ATLAS_BACKUP_AGE_IDENTITY_FILE:-}"
  validate_private_file "$identity" "The age identity file"
  printf '%s\n' "$identity"
}

validate_signing_private_key() {
  local private_key="${ADDRESS_ATLAS_BACKUP_SIGNING_PRIVATE_KEY_FILE:-}"
  validate_private_file "$private_key" "The backup signing private key"
  "$OPENSSL_BIN" pkey -in "$private_key" -check -noout >/dev/null 2>&1 \
    || die "The backup signing private key is invalid or encrypted." 65
  printf '%s\n' "$private_key"
}

validate_signature_public_key() {
  local public_key="${ADDRESS_ATLAS_BACKUP_SIGNATURE_PUBLIC_KEY_FILE:-}"
  validate_trusted_public_file "$public_key" "The backup signature public key"
  "$OPENSSL_BIN" pkey -pubin -in "$public_key" -noout >/dev/null 2>&1 \
    || die "The backup signature public key is invalid." 65
  printf '%s\n' "$public_key"
}

prepare_offsite_hook() {
  local required="${ADDRESS_ATLAS_BACKUP_OFFSITE_REQUIRED:-false}"
  local hook="${ADDRESS_ATLAS_BACKUP_OFFSITE_HOOK:-}"
  [[ "$required" == "true" || "$required" == "false" ]] \
    || die "ADDRESS_ATLAS_BACKUP_OFFSITE_REQUIRED must be true or false." 65
  if [[ -z "$hook" ]]; then
    [[ "$required" == "false" ]] \
      || die "A required offsite backup hook is not configured." 66
    OFFSITE_HOOK=""
    OFFSITE_REQUIRED="$required"
    return 0
  fi
  [[ "$hook" == /* && -f "$hook" && -x "$hook" && ! -L "$hook" ]] \
    || die "The offsite backup hook must be an absolute non-symlink executable file." 65
  validate_trusted_parent_components "$hook" "The offsite backup hook"
  local mode owner permissions
  mode="$(file_mode "$hook")"
  owner="$(file_owner_uid "$hook")"
  [[ "$mode" =~ ^[0-7]{3,4}$ && "$owner" =~ ^[0-9]+$ ]] \
    || die "Unable to validate offsite backup hook metadata." 65
  permissions=$((8#$mode))
  [[ "$owner" -eq "$(id -u)" ]] \
    || die "The offsite backup hook must be owned by the effective user." 65
  (( (permissions & 8#022) == 0 )) \
    || die "The offsite backup hook must not be writable by group or other users." 65
  OFFSITE_HOOK="$hook"
  OFFSITE_REQUIRED="$required"
}

validate_restore_migration_hook() {
  local hook="${ADDRESS_ATLAS_BACKUP_RESTORE_MIGRATION_HOOK:-}"
  [[ -n "$hook" && "$hook" == /* && -f "$hook" && -x "$hook" && ! -L "$hook" ]] \
    || die "Restore validation requires an absolute non-symlink migration/readiness hook." 66
  validate_trusted_parent_components "$hook" "The restore migration hook"
  local mode owner permissions
  mode="$(file_mode "$hook")"
  owner="$(file_owner_uid "$hook")"
  [[ "$mode" =~ ^[0-7]{3,4}$ && "$owner" =~ ^[0-9]+$ ]] \
    || die "Unable to validate restore migration hook metadata." 65
  permissions=$((8#$mode))
  [[ "$owner" -eq "$(id -u)" ]] \
    || die "The restore migration hook must be owned by the effective user." 65
  (( (permissions & 8#022) == 0 )) \
    || die "The restore migration hook must not be writable by group or other users." 65
  RESTORE_MIGRATION_HOOK="$hook"
  RESTORE_MIGRATION_HOOK_DIGEST="$(sha256_file "$hook")"
}

validate_restore_provision_hook() {
  local hook="${ADDRESS_ATLAS_BACKUP_RESTORE_PROVISION_HOOK:-}"
  [[ -n "$hook" && "$hook" == /* && -f "$hook" && -x "$hook" && ! -L "$hook" ]] \
    || die "Production restore requires an absolute non-symlink privilege-provisioning hook." 66
  validate_trusted_parent_components "$hook" "The restore privilege-provisioning hook"
  local mode owner permissions
  mode="$(file_mode "$hook")"
  owner="$(file_owner_uid "$hook")"
  [[ "$mode" =~ ^[0-7]{3,4}$ && "$owner" =~ ^[0-9]+$ ]] \
    || die "Unable to validate restore privilege-provisioning hook metadata." 65
  permissions=$((8#$mode))
  [[ "$owner" -eq "$(id -u)" ]] \
    || die "The restore privilege-provisioning hook must be owned by the effective user." 65
  (( (permissions & 8#022) == 0 )) \
    || die "The restore privilege-provisioning hook must not be writable by group or other users." 65
  RESTORE_PROVISION_HOOK="$hook"
  RESTORE_PROVISION_HOOK_DIGEST="$(sha256_file "$hook")"
}

current_boot_identity() {
  if [[ -r /proc/sys/kernel/random/boot_id ]]; then
    tr -d '\r\n' < /proc/sys/kernel/random/boot_id
  else
    sysctl -n kern.boottime 2>/dev/null | tr -d '\r\n' || true
  fi
}

process_start_identity() {
  local pid="$1"
  if [[ -r "/proc/${pid}/stat" ]]; then
    local stat_line fields
    stat_line="$(< "/proc/${pid}/stat")"
    fields="${stat_line##*) }"
    awk '{ print $20 }' <<< "$fields"
  else
    ps -o lstart= -p "$pid" 2>/dev/null | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' || true
  fi
}

lock_is_live() {
  local lock_file="$1"
  [[ -f "$lock_file" && ! -L "$lock_file" ]] || return 1
  local pid stored_boot stored_start running_boot running_start
  pid="$(sed -n 's/^pid=//p' "$lock_file")"
  stored_boot="$(sed -n 's/^boot=//p' "$lock_file")"
  stored_start="$(sed -n 's/^start=//p' "$lock_file")"
  [[ "$pid" =~ ^[1-9][0-9]*$ && -n "$stored_start" ]] || return 1
  running_boot="$(current_boot_identity)"
  if [[ -n "$stored_boot" && -n "$running_boot" && "$stored_boot" != "$running_boot" ]]; then
    return 1
  fi
  kill -0 "$pid" 2>/dev/null || return 1
  running_start="$(process_start_identity "$pid")"
  [[ -n "$running_start" && "$stored_start" == "$running_start" ]]
}

process_has_ancestor() {
  local expected_ancestor="$1"
  local current_pid="$$"
  local parent_pid
  local depth
  for depth in {1..32}; do
    [[ "$current_pid" == "$expected_ancestor" ]] && return 0
    parent_pid="$(ps -o ppid= -p "$current_pid" 2>/dev/null \
      | tr -d '[:space:]')"
    [[ "$parent_pid" =~ ^[1-9][0-9]*$ && "$parent_pid" != "$current_pid" ]] \
      || return 1
    current_pid="$parent_pid"
  done
  return 1
}

inherited_operation_lock_is_valid() {
  local lock_file="$1"
  local expected_owner="${ADDRESS_ATLAS_OPERATION_LOCK_OWNER_PID:-}"
  [[ -n "$expected_owner" ]] || return 1
  [[ "$expected_owner" =~ ^[1-9][0-9]*$ ]] \
    || die "ADDRESS_ATLAS_OPERATION_LOCK_OWNER_PID is invalid." 65
  [[ "$(sed -n 's/^pid=//p' "$lock_file" 2>/dev/null)" == "$expected_owner" ]] \
    && lock_is_live "$lock_file" \
    && process_has_ancestor "$expected_owner" \
    || die "The inherited backup operation lock is absent, stale, or not owned by an ancestor." 75
}

acquire_backup_lock() {
  local lock_file="$1"
  local preserve_file="${lock_file}.preserve"
  local reclaim_file="${BACKUP_DIR}/.bootstrap-lock-reclaim"
  local candidate="${lock_file}.candidate.$$"
  [[ "$BOOTSTRAP_LOCK_RECLAIM_ACTIVE" == "true" \
      || ( ! -e "$reclaim_file" && ! -L "$reclaim_file" ) ]] \
    || die "A bootstrap lock-reclaim operation is active or stale." 75
  [[ ! -e "$preserve_file" && ! -L "$preserve_file" ]] \
    || die "A manual-recovery lock marker exists; verify service/database state, then remove the lock and marker explicitly." 75
  printf 'pid=%s\nboot=%s\nstart=%s\n' \
    "$$" "$(current_boot_identity)" "$(process_start_identity "$$")" > "$candidate"
  sync_durably "$candidate"
  if ln "$candidate" "$lock_file" 2>/dev/null; then
    find "$candidate" -maxdepth 0 -type f -delete
    return 0
  fi
  find "$candidate" -maxdepth 0 -type f -delete
  if lock_is_live "$lock_file"; then
    die "Another backup operation is already running." 75
  fi
  die "A stale or malformed backup operation lock exists; verify no operation is running, then remove it explicitly." 75
}

cleanup_bootstrap_reclaim_claim() {
  if [[ -n "$BOOTSTRAP_RECLAIM_CLAIM_FILE" ]]; then
    find "$BOOTSTRAP_RECLAIM_CLAIM_FILE" -maxdepth 0 -type f -delete 2>/dev/null || true
    BOOTSTRAP_RECLAIM_CLAIM_FILE=""
    BOOTSTRAP_LOCK_RECLAIM_ACTIVE=false
  fi
}

preserve_operation_lock_for_recovery() {
  local lock_file="$1"
  local marker="${lock_file}.preserve"
  local candidate="${marker}.candidate.$$"
  [[ ! -L "$marker" && ! -e "$candidate" && ! -L "$candidate" ]] || return 1
  printf '%s\n' 'manual-recovery-required' > "$candidate" || return 1
  chmod 0600 "$candidate" || return 1
  sync_durably "$candidate"
  mv -f "$candidate" "$marker" || return 1
  sync_durably "$BACKUP_DIR"
}

resolve_compose_container() {
  local service="$1"
  local include_stopped="$2"
  local containers
  if [[ "$include_stopped" == "true" ]]; then
    containers="$("$DOCKER_BIN" ps -aq \
      --filter "label=com.docker.compose.project=${PROJECT_NAME}" \
      --filter "label=com.docker.compose.service=${service}")" \
      || die "Unable to inspect the production ${service} container." 69
  else
    containers="$("$DOCKER_BIN" ps -q \
      --filter "label=com.docker.compose.project=${PROJECT_NAME}" \
      --filter "label=com.docker.compose.service=${service}")" \
      || die "Unable to inspect the production ${service} container." 69
  fi
  local count=0
  local selected=""
  local candidate
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    count=$((count + 1))
    selected="$candidate"
  done <<< "$containers"
  [[ "$count" -eq 1 ]] \
    || die "Expected exactly one ${PROJECT_NAME}/${service} container; found ${count}." 66
  printf '%s\n' "$selected"
}

resolve_postgres_container() {
  local configured="${ADDRESS_ATLAS_POSTGRES_CONTAINER:-}"
  if [[ -n "$configured" ]]; then
    [[ "$configured" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]+$ ]] \
      || die "ADDRESS_ATLAS_POSTGRES_CONTAINER is invalid." 65
    "$DOCKER_BIN" inspect "$configured" >/dev/null 2>&1 \
      || die "Configured PostgreSQL container does not exist." 66
    printf '%s\n' "$configured"
    return 0
  fi
  resolve_compose_container postgres false
}

assert_web_service_stopped() {
  local running_web
  if ! running_web="$("$DOCKER_BIN" ps -q \
      --filter "label=com.docker.compose.project=${PROJECT_NAME}" \
      --filter "label=com.docker.compose.service=web")"; then
    die "Unable to verify that the production web service is stopped." 69
  fi
  [[ -z "$running_web" ]] \
    || die "Stop the production web service before restoring PostgreSQL." 77
}

container_value() {
  local container="$1"
  local name="$2"
  "$DOCKER_BIN" exec "$container" printenv "$name" 2>/dev/null \
    || die "The PostgreSQL container does not expose ${name}." 66
}

database_context() {
  local container="$1"
  DB_NAME="${ADDRESS_ATLAS_POSTGRES_DB:-$(container_value "$container" POSTGRES_DB)}"
  DB_USER="${ADDRESS_ATLAS_POSTGRES_USER:-$(container_value "$container" POSTGRES_USER)}"
  validate_identifier "$DB_NAME" "PostgreSQL database name"
  validate_identifier "$DB_USER" "PostgreSQL user"
  [[ "$DB_USER" == "$OWNER_USER" ]] \
    || die "Backups must run as the address_atlas database owner." 65
}

load_native_config_receipt() {
  local web_revision="$1"
  NATIVE_CONFIG_VERSION="${ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_VERSION:-}"
  NATIVE_CONFIG_DIGEST="${ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_SHA256:-}"
  NATIVE_CONFIG_UPDATED_AT_EPOCH_MS="${ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_UPDATED_AT_EPOCH_MS:-}"
  NATIVE_CONFIG_SERVING_REVISION="${ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_SERVING_REVISION:-}"
  [[ "$NATIVE_CONFIG_VERSION" =~ ^[1-9][0-9]*$ \
      && "$NATIVE_CONFIG_VERSION" -ge 5 \
      && "$NATIVE_CONFIG_VERSION" -le 2000000000 ]] \
    || die "ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_VERSION is invalid." 65
  [[ "$NATIVE_CONFIG_DIGEST" =~ ^[0-9a-f]{64}$ ]] \
    || die "ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_SHA256 is invalid." 65
  [[ "$NATIVE_CONFIG_UPDATED_AT_EPOCH_MS" =~ ^[1-9][0-9]*$ \
      && "$NATIVE_CONFIG_UPDATED_AT_EPOCH_MS" -le 8640000000000000 ]] \
    || die "ADDRESS_ATLAS_BACKUP_NATIVE_CONFIG_UPDATED_AT_EPOCH_MS is invalid." 65
  [[ "$NATIVE_CONFIG_SERVING_REVISION" =~ ^[0-9a-f]{40}$ \
      && "$NATIVE_CONFIG_SERVING_REVISION" == "$web_revision" ]] \
    || die "The native-config receipt must be bound to the inspected serving revision." 65
}

classify_source_database() {
  require_command "$DOCKER_BIN"
  local container result
  container="$(resolve_postgres_container)"
  database_context "$container"
  result="$("$DOCKER_BIN" exec "$container" sh -ceu '
    export PGPASSWORD="$POSTGRES_PASSWORD"
    PGOPTIONS="-c search_path=pg_catalog"
    export PGOPTIONS
    exec psql --username "$1" --dbname "$2" --no-psqlrc --tuples-only --no-align \
      --set ON_ERROR_STOP=1 --command \
      "SELECT CASE WHEN
         '"'"'address_atlas_source_classification_v2'"'"' = '"'"'address_atlas_source_classification_v2'"'"'
         AND EXISTS (
           SELECT 1
           FROM pg_catalog.pg_database AS database
           WHERE database.datname = pg_catalog.current_database()
             AND pg_catalog.pg_get_userbyid(database.datdba) = '"'"'address_atlas'"'"'
             AND NOT database.datistemplate
             AND database.datallowconn
             AND database.datconnlimit = -1
             AND COALESCE(database.datacl, pg_catalog.acldefault('"'"'d'"'"', database.datdba))
                 = pg_catalog.acldefault('"'"'d'"'"', database.datdba)
             AND pg_catalog.shobj_description(
                   database.oid, '"'"'pg_database'"'"'
                 ) IS NULL
         )
         AND EXISTS (
           SELECT 1
           FROM pg_catalog.pg_namespace AS namespace
           WHERE namespace.nspname = '"'"'public'"'"'
             AND pg_catalog.pg_get_userbyid(namespace.nspowner) = '"'"'pg_database_owner'"'"'
             AND namespace.nspacl IS NOT NULL
             AND (
               SELECT pg_catalog.count(*)
               FROM pg_catalog.aclexplode(namespace.nspacl)
             ) = 3
             AND (
               SELECT pg_catalog.count(*)
               FROM pg_catalog.aclexplode(namespace.nspacl) AS acl
               WHERE acl.grantee = namespace.nspowner
                 AND acl.privilege_type = '"'"'USAGE'"'"'
             ) = 1
             AND (
               SELECT pg_catalog.count(*)
               FROM pg_catalog.aclexplode(namespace.nspacl) AS acl
               WHERE acl.grantee = namespace.nspowner
                 AND acl.privilege_type = '"'"'CREATE'"'"'
             ) = 1
             AND (
               SELECT pg_catalog.count(*)
               FROM pg_catalog.aclexplode(namespace.nspacl) AS acl
               WHERE acl.grantee = 0 AND acl.privilege_type = '"'"'USAGE'"'"'
             ) = 1
             AND NOT EXISTS (
               SELECT 1
               FROM pg_catalog.aclexplode(namespace.nspacl) AS acl
               WHERE acl.grantor <> namespace.nspowner
                  OR acl.is_grantable
                  OR NOT (
                    (acl.grantee = namespace.nspowner
                     AND acl.privilege_type IN ('"'"'USAGE'"'"', '"'"'CREATE'"'"'))
                    OR (acl.grantee = 0 AND acl.privilege_type = '"'"'USAGE'"'"')
                  )
             )
             AND pg_catalog.obj_description(
                   namespace.oid, '"'"'pg_namespace'"'"'
                 ) = '"'"'standard public schema'"'"'
         )
         AND NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_namespace
           WHERE nspname NOT IN ('"'"'pg_catalog'"'"', '"'"'pg_toast'"'"', '"'"'information_schema'"'"', '"'"'public'"'"')
         )
         AND NOT EXISTS (
           SELECT 1
           FROM pg_catalog.pg_class AS relation
           JOIN pg_catalog.pg_namespace AS namespace
             ON namespace.oid = relation.relnamespace
           WHERE namespace.nspname NOT IN ('"'"'pg_catalog'"'"', '"'"'pg_toast'"'"', '"'"'information_schema'"'"')
         )
         AND NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_proc AS routine
           JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
           WHERE namespace.nspname = '"'"'public'"'"'
         )
         AND NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_type AS item
           JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = item.typnamespace
           WHERE namespace.nspname = '"'"'public'"'"'
         )
         AND NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_collation AS catalog_collation
           JOIN pg_catalog.pg_namespace AS namespace
             ON namespace.oid = catalog_collation.collnamespace
           WHERE namespace.nspname = '"'"'public'"'"'
         )
         AND NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_operator AS operator
           JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = operator.oprnamespace
           WHERE namespace.nspname = '"'"'public'"'"'
         )
         AND NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_conversion AS conversion
           JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = conversion.connamespace
           WHERE namespace.nspname = '"'"'public'"'"'
         )
         AND NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_opclass AS operator_class
           JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = operator_class.opcnamespace
           WHERE namespace.nspname = '"'"'public'"'"'
         )
         AND NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_opfamily AS operator_family
           JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = operator_family.opfnamespace
           WHERE namespace.nspname = '"'"'public'"'"'
         )
         AND NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_ts_config AS configuration
           JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = configuration.cfgnamespace
           WHERE namespace.nspname = '"'"'public'"'"'
         )
         AND NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_ts_dict AS dictionary
           JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = dictionary.dictnamespace
           WHERE namespace.nspname = '"'"'public'"'"'
         )
         AND NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_ts_parser AS parser
           JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = parser.prsnamespace
           WHERE namespace.nspname = '"'"'public'"'"'
         )
         AND NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_ts_template AS template
           JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = template.tmplnamespace
           WHERE namespace.nspname = '"'"'public'"'"'
         )
         AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_transform)
         AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_cast WHERE oid >= 16384)
         AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_am WHERE oid >= 16384)
         AND (SELECT pg_catalog.count(*) FROM pg_catalog.pg_extension) = 1
         AND EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = '"'"'plpgsql'"'"')
         AND NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_language
           WHERE lanname NOT IN ('"'"'internal'"'"', '"'"'c'"'"', '"'"'sql'"'"', '"'"'plpgsql'"'"')
              OR (lanacl IS NOT NULL
                  AND lanacl <> pg_catalog.acldefault('"'"'l'"'"', lanowner))
         )
         AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_largeobject_metadata)
         AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_publication)
         AND NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_subscription
           WHERE subdbid = (
             SELECT oid FROM pg_catalog.pg_database
             WHERE datname = pg_catalog.current_database()
           )
         )
         AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_foreign_data_wrapper)
         AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_foreign_server)
         AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_user_mapping)
         AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_event_trigger)
         AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_default_acl)
         AND NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_shseclabel AS label
           WHERE label.classoid = '"'"'pg_catalog.pg_database'"'"'::pg_catalog.regclass
             AND label.objoid = (
               SELECT oid FROM pg_catalog.pg_database
               WHERE datname = pg_catalog.current_database()
             )
         )
         AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_seclabel)
         AND NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_db_role_setting AS setting
           WHERE setting.setdatabase = (
                   SELECT oid FROM pg_catalog.pg_database
                   WHERE datname = pg_catalog.current_database()
                 )
              OR setting.setrole = (
                   SELECT oid FROM pg_catalog.pg_roles
                   WHERE rolname = '"'"'address_atlas'"'"'
                 )
         )
       THEN '"'"'brand-new-empty'"'"' ELSE '"'"'existing-or-ambiguous'"'"' END"
  ' sh "$DB_USER" "$DB_NAME")" \
    || die "Unable to classify the source database safely." 69
  [[ "$result" == "brand-new-empty" || "$result" == "existing-or-ambiguous" ]] \
    || die "Source database classification returned an unexpected result." 65
  printf '%s\n' "$result"
}

expected_migration_ledger() {
  canonical_migration_ledger "$EXPECTED_MIGRATION_HEAD"
}

canonical_migration_ledger() {
  local head="$1"
  [[ "$head" =~ ^[1-3]$ && "$head" -le "$EXPECTED_MIGRATION_HEAD" ]] \
    || die "Unsupported canonical migration ledger head." 65
  printf '%s\n' \
    '1|core-schema-ledger|95334a9cc097e1f3ee3a6dcd21b65720c359235a0737531938837799df71fe46'
  if (( head >= 2 )); then
    printf '%s\n' \
      '2|vault-accounting-trigger|370460a2d8e85eb9a1471ac300e7d82efcc16bf9b7f6339e2559507ce2c8d518'
  fi
  if (( head >= 3 )); then
    printf '%s\n' \
      '3|account-deletion-receipts|1a7393b31cfcfd3135532e911a2e824385cb25b7d9f6611e48ad4cda91db0555'
  fi
}

migration_digest_for_head() {
  canonical_migration_ledger "$1" | sha256_stream
}

read_migration_ledger() {
  local container="$1"
  local database="$2"
  local user="$3"
  "$DOCKER_BIN" exec "$container" sh -ceu '
    export PGPASSWORD="$POSTGRES_PASSWORD"
    PGOPTIONS="-c search_path=pg_catalog"
    export PGOPTIONS
    exec psql --username "$1" --dbname "$2" --no-psqlrc --tuples-only --no-align \
      --field-separator="|" --set ON_ERROR_STOP=1 --command \
      "SELECT version, name, checksum FROM public.sync_schema_migrations ORDER BY version"
  ' sh "$user" "$database"
}

identify_supported_migration_ledger() {
  local actual="$1"
  local head expected
  for head in 1 2 3; do
    expected="$(canonical_migration_ledger "$head")"
    if [[ "$actual" == "$expected" ]]; then
      DETECTED_MIGRATION_HEAD="$head"
      DETECTED_MIGRATION_DIGEST="$(migration_digest_for_head "$head")"
      return 0
    fi
  done
  die "Database migration ledger is not a complete canonical prefix of the supported history." 65
}

manifest_path() { printf '%s.manifest.json\n' "$1"; }
checksum_path() { printf '%s.sha256\n' "$1"; }
signature_path() { printf '%s.manifest.sig\n' "$1"; }

write_manifest() {
  local path="$1" snapshot_started="$2" completed="$3" database="$4"
  local size="$5" digest="$6" web_revision="$7" web_image_id="$8"
  local postgres_image_id="$9" native_version="${10}" native_digest="${11}"
  local native_updated_at="${12}" native_revision="${13}"
  local migration_head="${14}" ledger_digest="${15}"
  printf '{\n  "schemaVersion": %s,\n  "snapshotStartedAt": "%s",\n  "completedAt": "%s",\n  "database": "%s",\n  "encryptedBytes": %s,\n  "sha256": "%s",\n  "sourceWebRevision": "%s",\n  "sourceWebImageId": "%s",\n  "sourcePostgresImageId": "%s",\n  "nativeConfigVersion": %s,\n  "nativeConfigSha256": "%s",\n  "nativeConfigUpdatedAtEpochMs": %s,\n  "nativeConfigServingRevision": "%s",\n  "migrationHeadVersion": %s,\n  "migrationLedgerSha256": "%s"\n}\n' \
    "$MANIFEST_SCHEMA_VERSION" "$snapshot_started" "$completed" "$database" "$size" "$digest" \
    "$web_revision" "$web_image_id" "$postgres_image_id" \
    "$native_version" "$native_digest" "$native_updated_at" "$native_revision" \
    "$migration_head" "$ledger_digest" > "$path"
}

parse_canonical_manifest() {
  local manifest="$1"
  local line_count actual expected
  MANIFEST_SCHEMA="$(sed -n 's/^  "schemaVersion": \([0-9][0-9]*\),$/\1/p' "$manifest")"
  line_count="$(wc -l < "$manifest" | tr -d '[:space:]')"
  case "$MANIFEST_SCHEMA" in
    3) [[ "$line_count" == "13" ]] || die "Backup manifest is not canonical." 65 ;;
    4) [[ "$line_count" == "17" ]] || die "Backup manifest is not canonical." 65 ;;
    *) die "Backup manifest schema version is unsupported." 65 ;;
  esac
  MANIFEST_SNAPSHOT_STARTED="$(sed -n 's/^  "snapshotStartedAt": "\([^"]*\)",$/\1/p' "$manifest")"
  MANIFEST_COMPLETED="$(sed -n 's/^  "completedAt": "\([^"]*\)",$/\1/p' "$manifest")"
  MANIFEST_DATABASE="$(sed -n 's/^  "database": "\([^"]*\)",$/\1/p' "$manifest")"
  MANIFEST_SIZE="$(sed -n 's/^  "encryptedBytes": \([0-9][0-9]*\),$/\1/p' "$manifest")"
  MANIFEST_SHA256="$(sed -n 's/^  "sha256": "\([0-9a-f]*\)",$/\1/p' "$manifest")"
  MANIFEST_WEB_REVISION="$(sed -n 's/^  "sourceWebRevision": "\([0-9a-f]*\)",$/\1/p' "$manifest")"
  MANIFEST_WEB_IMAGE="$(sed -n 's/^  "sourceWebImageId": "\(sha256:[0-9a-f]*\)",$/\1/p' "$manifest")"
  MANIFEST_POSTGRES_IMAGE="$(sed -n 's/^  "sourcePostgresImageId": "\(sha256:[0-9a-f]*\)",$/\1/p' "$manifest")"
  MANIFEST_NATIVE_CONFIG_VERSION=""
  MANIFEST_NATIVE_CONFIG_DIGEST=""
  MANIFEST_NATIVE_CONFIG_UPDATED_AT_EPOCH_MS=""
  MANIFEST_NATIVE_CONFIG_SERVING_REVISION=""
  if [[ "$MANIFEST_SCHEMA" == "4" ]]; then
    MANIFEST_NATIVE_CONFIG_VERSION="$(sed -n 's/^  "nativeConfigVersion": \([0-9][0-9]*\),$/\1/p' "$manifest")"
    MANIFEST_NATIVE_CONFIG_DIGEST="$(sed -n 's/^  "nativeConfigSha256": "\([0-9a-f]*\)",$/\1/p' "$manifest")"
    MANIFEST_NATIVE_CONFIG_UPDATED_AT_EPOCH_MS="$(sed -n 's/^  "nativeConfigUpdatedAtEpochMs": \([0-9][0-9]*\),$/\1/p' "$manifest")"
    MANIFEST_NATIVE_CONFIG_SERVING_REVISION="$(sed -n 's/^  "nativeConfigServingRevision": "\([0-9a-f]*\)",$/\1/p' "$manifest")"
  fi
  MANIFEST_MIGRATION_HEAD="$(sed -n 's/^  "migrationHeadVersion": \([0-9][0-9]*\),$/\1/p' "$manifest")"
  MANIFEST_MIGRATION_DIGEST="$(sed -n 's/^  "migrationLedgerSha256": "\([0-9a-f]*\)"$/\1/p' "$manifest")"
  [[ "$MANIFEST_SNAPSHOT_STARTED" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ \
      && "$MANIFEST_COMPLETED" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || die "Backup manifest snapshot timing is malformed." 65
  [[ "$(iso8601_epoch "$MANIFEST_COMPLETED")" -ge "$(iso8601_epoch "$MANIFEST_SNAPSHOT_STARTED")" ]] \
    || die "Backup manifest completion precedes its snapshot start." 65
  validate_identifier "$MANIFEST_DATABASE" "Backup manifest database name"
  [[ "$MANIFEST_SIZE" =~ ^[1-9][0-9]*$ ]] || die "Backup manifest size is malformed." 65
  [[ "$MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "Backup manifest digest is malformed." 65
  [[ "$MANIFEST_WEB_REVISION" =~ ^[0-9a-f]{40}$ ]] \
    || die "Backup manifest web revision is malformed." 65
  [[ "$MANIFEST_WEB_IMAGE" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || die "Backup manifest web image provenance is malformed." 65
  [[ "$MANIFEST_POSTGRES_IMAGE" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || die "Backup manifest PostgreSQL image provenance is malformed." 65
  if [[ "$MANIFEST_SCHEMA" == "4" ]]; then
    [[ "$MANIFEST_NATIVE_CONFIG_VERSION" =~ ^[1-9][0-9]*$ \
        && "$MANIFEST_NATIVE_CONFIG_VERSION" -ge 5 \
        && "$MANIFEST_NATIVE_CONFIG_VERSION" -le 2000000000 ]] \
      || die "Backup manifest native-config version is malformed." 65
    [[ "$MANIFEST_NATIVE_CONFIG_DIGEST" =~ ^[0-9a-f]{64}$ ]] \
      || die "Backup manifest native-config digest is malformed." 65
    [[ "$MANIFEST_NATIVE_CONFIG_UPDATED_AT_EPOCH_MS" =~ ^[1-9][0-9]*$ \
        && "$MANIFEST_NATIVE_CONFIG_UPDATED_AT_EPOCH_MS" -le 8640000000000000 ]] \
      || die "Backup manifest native-config timestamp is malformed." 65
    [[ "$MANIFEST_NATIVE_CONFIG_SERVING_REVISION" == "$MANIFEST_WEB_REVISION" ]] \
      || die "Backup manifest native-config receipt is not bound to its serving revision." 65
  fi
  [[ "$MANIFEST_MIGRATION_HEAD" =~ ^[1-3]$ \
      && "$MANIFEST_MIGRATION_HEAD" -le "$EXPECTED_MIGRATION_HEAD" ]] \
    || die "Backup manifest migration head is not a supported canonical prefix." 65
  [[ "$MANIFEST_MIGRATION_DIGEST" == "$(migration_digest_for_head "$MANIFEST_MIGRATION_HEAD")" ]] \
    || die "Backup manifest migration ledger digest is unsupported." 65
  if [[ "$MANIFEST_SCHEMA" == "3" ]]; then
    expected="$(printf '{\n  "schemaVersion": 3,\n  "snapshotStartedAt": "%s",\n  "completedAt": "%s",\n  "database": "%s",\n  "encryptedBytes": %s,\n  "sha256": "%s",\n  "sourceWebRevision": "%s",\n  "sourceWebImageId": "%s",\n  "sourcePostgresImageId": "%s",\n  "migrationHeadVersion": %s,\n  "migrationLedgerSha256": "%s"\n}' \
      "$MANIFEST_SNAPSHOT_STARTED" "$MANIFEST_COMPLETED" "$MANIFEST_DATABASE" \
      "$MANIFEST_SIZE" "$MANIFEST_SHA256" "$MANIFEST_WEB_REVISION" \
      "$MANIFEST_WEB_IMAGE" "$MANIFEST_POSTGRES_IMAGE" \
      "$MANIFEST_MIGRATION_HEAD" "$MANIFEST_MIGRATION_DIGEST")"
  else
    expected="$(printf '{\n  "schemaVersion": 4,\n  "snapshotStartedAt": "%s",\n  "completedAt": "%s",\n  "database": "%s",\n  "encryptedBytes": %s,\n  "sha256": "%s",\n  "sourceWebRevision": "%s",\n  "sourceWebImageId": "%s",\n  "sourcePostgresImageId": "%s",\n  "nativeConfigVersion": %s,\n  "nativeConfigSha256": "%s",\n  "nativeConfigUpdatedAtEpochMs": %s,\n  "nativeConfigServingRevision": "%s",\n  "migrationHeadVersion": %s,\n  "migrationLedgerSha256": "%s"\n}' \
      "$MANIFEST_SNAPSHOT_STARTED" "$MANIFEST_COMPLETED" "$MANIFEST_DATABASE" \
      "$MANIFEST_SIZE" "$MANIFEST_SHA256" "$MANIFEST_WEB_REVISION" \
      "$MANIFEST_WEB_IMAGE" "$MANIFEST_POSTGRES_IMAGE" \
      "$MANIFEST_NATIVE_CONFIG_VERSION" "$MANIFEST_NATIVE_CONFIG_DIGEST" \
      "$MANIFEST_NATIVE_CONFIG_UPDATED_AT_EPOCH_MS" \
      "$MANIFEST_NATIVE_CONFIG_SERVING_REVISION" "$MANIFEST_MIGRATION_HEAD" \
      "$MANIFEST_MIGRATION_DIGEST")"
  fi
  actual="$(< "$manifest")"
  [[ "$actual" == "$expected" ]] || die "Backup manifest is not canonical." 65
}

verify_artifact_metadata() {
  local backup="$1" expected_database="$2"
  local checksum manifest signature public_key actual_checksum actual_size
  local checksum_content expected_checksum_content
  checksum="$(checksum_path "$backup")"
  manifest="$(manifest_path "$backup")"
  signature="$(signature_path "$backup")"
  [[ -f "$backup" && ! -L "$backup" \
      && -f "$checksum" && ! -L "$checksum" \
      && -f "$manifest" && ! -L "$manifest" \
      && -f "$signature" && -s "$signature" && ! -L "$signature" ]] \
    || die "The complete four-file backup artifact set is required." 66
  public_key="$(validate_signature_public_key)"
  "$OPENSSL_BIN" dgst -sha256 -verify "$public_key" \
    -signature "$signature" "$manifest" >/dev/null 2>&1 \
    || die "Backup manifest signature verification failed." 65
  parse_canonical_manifest "$manifest"
  [[ "$MANIFEST_DATABASE" == "$expected_database" ]] \
    || die "Backup database does not match the configured production database." 65
  actual_checksum="$(sha256_file "$backup")"
  actual_size="$(wc -c < "$backup" | tr -d '[:space:]')"
  [[ "$actual_checksum" == "$MANIFEST_SHA256" ]] \
    || die "Encrypted backup digest does not match its signed manifest." 65
  [[ "$actual_size" == "$MANIFEST_SIZE" \
      && "$actual_size" -le "$MAX_BACKUP_BYTES" ]] \
    || die "Encrypted backup size does not match its signed manifest." 65
  checksum_content="$(< "$checksum")"
  expected_checksum_content="${MANIFEST_SHA256}  $(basename "$backup")"
  [[ "$(wc -l < "$checksum" | tr -d '[:space:]')" == "1" \
      && "$checksum_content" == "$expected_checksum_content" ]] \
    || die "Backup checksum sidecar is malformed or inconsistent." 65
}

cleanup_staging_directory() {
  local directory="$1"
  [[ -n "$directory" && "$directory" == "${BACKUP_DIR}/.address-atlas-"* \
      && -d "$directory" && ! -L "$directory" ]] || return 0
  find "$directory" -mindepth 1 -maxdepth 1 -type f -delete 2>/dev/null || true
  rmdir "$directory" 2>/dev/null || true
}

assert_no_unfinished_bootstrap_restore() {
  local state_file="${BACKUP_DIR}/.bootstrap-restore.state"
  [[ ! -e "$state_file" && ! -L "$state_file" ]] \
    || die "An unfinished bootstrap restore blocks backup, drill, and ordinary restore operations." 75
}

stage_backup_artifacts() {
  local source_backup="$1" staging_directory="$2"
  [[ "$source_backup" == /* && "$source_backup" == *.dump.age \
      && "$source_backup" != *$'\n'* ]] \
    || die "Backup path must be an absolute single-line .dump.age path." 65
  local source_checksum source_manifest source_signature
  source_checksum="$(checksum_path "$source_backup")"
  source_manifest="$(manifest_path "$source_backup")"
  source_signature="$(signature_path "$source_backup")"
  validate_trusted_public_file "$source_backup" "The encrypted backup source"
  validate_trusted_public_file "$source_checksum" "The backup checksum source"
  validate_trusted_public_file "$source_manifest" "The backup manifest source"
  validate_trusted_public_file "$source_signature" "The backup signature source"
  local checksum_size manifest_size signature_size source_size
  checksum_size="$(file_size "$source_checksum")"
  manifest_size="$(file_size "$source_manifest")"
  signature_size="$(file_size "$source_signature")"
  [[ "$checksum_size" =~ ^[1-9][0-9]*$ && "$checksum_size" -le 256 \
      && "$manifest_size" =~ ^[1-9][0-9]*$ && "$manifest_size" -le 4096 \
      && "$signature_size" =~ ^[1-9][0-9]*$ && "$signature_size" -le 16384 ]] \
    || die "Backup control artifacts exceed their safe staging size limits." 65
  [[ ! -e "$staging_directory" && ! -L "$staging_directory" ]] \
    || die "A stale backup verification staging directory exists." 73
  umask 077
  mkdir "$staging_directory"
  chmod 0700 "$staging_directory"
  local staged_backup="${staging_directory}/$(basename "$source_backup")"
  snapshot_regular_file "$source_signature" "$(signature_path "$staged_backup")" \
    "$signature_size" 16384 "The backup signature source"
  snapshot_regular_file "$source_manifest" "$(manifest_path "$staged_backup")" \
    "$manifest_size" 4096 "The backup manifest source"
  local public_key
  public_key="$(validate_signature_public_key)"
  "$OPENSSL_BIN" dgst -sha256 -verify "$public_key" \
    -signature "$(signature_path "$staged_backup")" \
    "$(manifest_path "$staged_backup")" >/dev/null 2>&1 \
    || die "Backup manifest signature verification failed before payload staging." 65
  parse_canonical_manifest "$(manifest_path "$staged_backup")"
  source_size="$(file_size "$source_backup")"
  [[ "$source_size" =~ ^[1-9][0-9]*$ && "$source_size" == "$MANIFEST_SIZE" \
      && "$source_size" -le "$MAX_BACKUP_BYTES" ]] \
    || die "Encrypted backup source size does not match its signed manifest." 65
  snapshot_regular_file "$source_checksum" "$(checksum_path "$staged_backup")" \
    "$checksum_size" 256 "The backup checksum source"
  snapshot_regular_file "$source_backup" "$staged_backup" \
    "$source_size" "$MAX_BACKUP_BYTES" "The encrypted backup source"
  printf '%s\n' "$staged_backup"
}

decrypt_to_pg_restore() {
  local container="$1" backup="$2" identity="$3"
  shift 3
  "$AGE_BIN" --decrypt --identity "$identity" "$backup" \
    | "$DOCKER_BIN" exec -i "$container" sh -ceu '
        export PGPASSWORD="$POSTGRES_PASSWORD"
        exec pg_restore "$@"
      ' sh "$@"
}

create_backup() {
  local allow_stopped_web="${1:-false}"
  local skip_retention="${2:-false}"
  [[ "$allow_stopped_web" == "true" || "$allow_stopped_web" == "false" ]] \
    || die "Internal backup provenance mode is invalid." 70
  [[ "$skip_retention" == "true" || "$skip_retention" == "false" ]] \
    || die "Internal backup retention mode is invalid." 70
  prepare_backup_directory
  assert_no_unfinished_bootstrap_restore
  require_command "$DOCKER_BIN"
  require_command "$AGE_BIN"
  require_command "$OPENSSL_BIN"
  local recipient="${ADDRESS_ATLAS_BACKUP_AGE_RECIPIENT:-}"
  [[ -n "$recipient" && "$recipient" != *$'\n'* ]] \
    || die "ADDRESS_ATLAS_BACKUP_AGE_RECIPIENT is required and must be one line." 66
  local identity signing_key public_key
  identity="$(validate_identity_file)"
  signing_key="$(validate_signing_private_key)"
  public_key="$(validate_signature_public_key)"
  prepare_offsite_hook
  # Bash 5 runs a top-level EXIT trap after function locals have unwound.
  # Mutable state owned by an EXIT cleanup must therefore remain an
  # operation-prefixed script global; do not casually convert it back to local.
  CREATE_CLEANUP_LOCK_FILE="${BACKUP_DIR}/.backup-operation.lock"
  CREATE_CLEANUP_OWNS_OPERATION_LOCK=false
  CREATE_CLEANUP_TEMPORARY_BACKUP=""
  CREATE_CLEANUP_TEMPORARY_MANIFEST=""
  CREATE_CLEANUP_TEMPORARY_CHECKSUM=""
  CREATE_CLEANUP_TEMPORARY_SIGNATURE=""
  CREATE_CLEANUP_SCHEMA_LOCK_INPUT=""
  CREATE_CLEANUP_SCHEMA_LOCK_OUTPUT=""
  CREATE_CLEANUP_SCHEMA_LOCK_PID=""
  CREATE_CLEANUP_SCHEMA_LOCK_START=""
  CREATE_CLEANUP_SCHEMA_LOCK_FD_OPEN=false
  release_schema_backup_lock() {
    if [[ "$CREATE_CLEANUP_SCHEMA_LOCK_FD_OPEN" == "true" ]]; then
      printf '\\q\n' >&7 2>/dev/null || true
      exec 7>&-
      CREATE_CLEANUP_SCHEMA_LOCK_FD_OPEN=false
    fi
    if [[ -n "$CREATE_CLEANUP_SCHEMA_LOCK_PID" ]]; then
      local release_attempt
      for release_attempt in {1..50}; do
        kill -0 "$CREATE_CLEANUP_SCHEMA_LOCK_PID" 2>/dev/null || break
        sleep 0.05
      done
      if kill -0 "$CREATE_CLEANUP_SCHEMA_LOCK_PID" 2>/dev/null; then
        kill -TERM "$CREATE_CLEANUP_SCHEMA_LOCK_PID" 2>/dev/null || true
      fi
      wait "$CREATE_CLEANUP_SCHEMA_LOCK_PID" 2>/dev/null || true
      CREATE_CLEANUP_SCHEMA_LOCK_PID=""
    fi
    [[ -z "$CREATE_CLEANUP_SCHEMA_LOCK_INPUT" ]] \
      || find "$CREATE_CLEANUP_SCHEMA_LOCK_INPUT" -maxdepth 0 \
        \( -type p -o -type f \) -delete 2>/dev/null || true
    [[ -z "$CREATE_CLEANUP_SCHEMA_LOCK_OUTPUT" ]] \
      || find "$CREATE_CLEANUP_SCHEMA_LOCK_OUTPUT" -maxdepth 0 \
        -type f -delete 2>/dev/null || true
    CREATE_CLEANUP_SCHEMA_LOCK_INPUT=""
    CREATE_CLEANUP_SCHEMA_LOCK_OUTPUT=""
    CREATE_CLEANUP_SCHEMA_LOCK_START=""
  }
  acquire_schema_backup_lock() {
    local lock_container="$1" lock_user="$2" lock_database="$3"
    if (: >&7) 2>/dev/null; then
      die "Internal file descriptor 7 is already in use." 70
    fi
    CREATE_CLEANUP_SCHEMA_LOCK_INPUT="${BACKUP_DIR}/.schema-backup-lock-input.$$"
    CREATE_CLEANUP_SCHEMA_LOCK_OUTPUT="${BACKUP_DIR}/.schema-backup-lock-output.$$"
    [[ ! -e "$CREATE_CLEANUP_SCHEMA_LOCK_INPUT" \
        && ! -L "$CREATE_CLEANUP_SCHEMA_LOCK_INPUT" \
        && ! -e "$CREATE_CLEANUP_SCHEMA_LOCK_OUTPUT" \
        && ! -L "$CREATE_CLEANUP_SCHEMA_LOCK_OUTPUT" ]] \
      || die "A stale schema backup lock staging path exists." 73
    mkfifo -m 0600 "$CREATE_CLEANUP_SCHEMA_LOCK_INPUT"
    : > "$CREATE_CLEANUP_SCHEMA_LOCK_OUTPUT"
    "$DOCKER_BIN" exec -i "$lock_container" sh -ceu '
      ADDRESS_ATLAS_SCHEMA_LOCK_SESSION=1
      export ADDRESS_ATLAS_SCHEMA_LOCK_SESSION
      export PGPASSWORD="$POSTGRES_PASSWORD"
      PGOPTIONS="-c search_path=pg_catalog"
      export PGOPTIONS
      exec psql --username "$1" --dbname "$2" --no-psqlrc --quiet \
        --tuples-only --no-align --set ON_ERROR_STOP=1
    ' sh "$lock_user" "$lock_database" \
      < "$CREATE_CLEANUP_SCHEMA_LOCK_INPUT" \
      > "$CREATE_CLEANUP_SCHEMA_LOCK_OUTPUT" 2>&1 &
    CREATE_CLEANUP_SCHEMA_LOCK_PID=$!
    local identity_attempt
    for identity_attempt in {1..20}; do
      CREATE_CLEANUP_SCHEMA_LOCK_START="$(process_start_identity \
        "$CREATE_CLEANUP_SCHEMA_LOCK_PID")"
      [[ -n "$CREATE_CLEANUP_SCHEMA_LOCK_START" ]] && break
      kill -0 "$CREATE_CLEANUP_SCHEMA_LOCK_PID" 2>/dev/null \
        || die "The schema advisory-lock client exited during startup." 74
      sleep 0.05
    done
    [[ -n "$CREATE_CLEANUP_SCHEMA_LOCK_START" ]] \
      || die "Unable to bind the schema advisory lock to its client process." 74
    exec 7> "$CREATE_CLEANUP_SCHEMA_LOCK_INPUT"
    CREATE_CLEANUP_SCHEMA_LOCK_FD_OPEN=true
    printf 'SELECT pg_catalog.pg_advisory_lock(%s);\n' \
      "$SCHEMA_MIGRATION_ADVISORY_LOCK" >&7
    printf '%s\n' \
      '\echo ADDRESS_ATLAS_SCHEMA_LOCK_ACQUIRED' >&7
    local lock_attempt
    for lock_attempt in {1..200}; do
      if grep -qx 'ADDRESS_ATLAS_SCHEMA_LOCK_ACQUIRED' \
          "$CREATE_CLEANUP_SCHEMA_LOCK_OUTPUT"; then
        return 0
      fi
      kill -0 "$CREATE_CLEANUP_SCHEMA_LOCK_PID" 2>/dev/null \
        || die "The schema advisory-lock session exited before acquiring the lock." 74
      sleep 0.05
    done
    die "Timed out acquiring the PostgreSQL schema advisory lock for backup." 75
  }
  prove_schema_backup_lock() {
    [[ -n "$CREATE_CLEANUP_SCHEMA_LOCK_PID" \
        && -n "$CREATE_CLEANUP_SCHEMA_LOCK_START" ]] \
      || die "The schema advisory-lock session is not initialized." 74
    kill -0 "$CREATE_CLEANUP_SCHEMA_LOCK_PID" 2>/dev/null \
      || die "The schema advisory-lock client exited before pg_dump completed." 74
    [[ "$(process_start_identity "$CREATE_CLEANUP_SCHEMA_LOCK_PID")" \
        == "$CREATE_CLEANUP_SCHEMA_LOCK_START" ]] \
      || die "The schema advisory-lock client identity changed before pg_dump completed." 74
    printf '%s\n' \
      "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_catalog.pg_locks WHERE locktype = 'advisory' AND pid = pg_catalog.pg_backend_pid() AND database = (SELECT oid FROM pg_catalog.pg_database WHERE datname = pg_catalog.current_database()) AND classid = 0::pg_catalog.oid AND objid = ${SCHEMA_MIGRATION_ADVISORY_LOCK}::pg_catalog.oid AND objsubid = 1 AND mode = 'ExclusiveLock' AND granted) THEN 'ADDRESS_ATLAS_SCHEMA_LOCK_STILL_HELD' ELSE 'ADDRESS_ATLAS_SCHEMA_LOCK_LOST' END;" >&7
    local proof_attempt
    for proof_attempt in {1..200}; do
      if grep -qx 'ADDRESS_ATLAS_SCHEMA_LOCK_STILL_HELD' \
          "$CREATE_CLEANUP_SCHEMA_LOCK_OUTPUT"; then
        return 0
      fi
      if grep -qx 'ADDRESS_ATLAS_SCHEMA_LOCK_LOST' \
          "$CREATE_CLEANUP_SCHEMA_LOCK_OUTPUT"; then
        die "The PostgreSQL session no longer held the schema advisory lock after pg_dump." 74
      fi
      kill -0 "$CREATE_CLEANUP_SCHEMA_LOCK_PID" 2>/dev/null \
        || die "The schema advisory-lock session exited before post-dump proof." 74
      [[ "$(process_start_identity "$CREATE_CLEANUP_SCHEMA_LOCK_PID")" \
          == "$CREATE_CLEANUP_SCHEMA_LOCK_START" ]] \
        || die "The schema advisory-lock client identity changed during post-dump proof." 74
      sleep 0.05
    done
    die "Timed out proving the PostgreSQL schema advisory lock after pg_dump." 75
  }
  cleanup_create() {
    release_schema_backup_lock
    [[ -z "$CREATE_CLEANUP_TEMPORARY_BACKUP" ]] \
      || find "$CREATE_CLEANUP_TEMPORARY_BACKUP" -maxdepth 0 \
        -type f -delete 2>/dev/null || true
    [[ -z "$CREATE_CLEANUP_TEMPORARY_MANIFEST" ]] \
      || find "$CREATE_CLEANUP_TEMPORARY_MANIFEST" -maxdepth 0 \
        -type f -delete 2>/dev/null || true
    [[ -z "$CREATE_CLEANUP_TEMPORARY_CHECKSUM" ]] \
      || find "$CREATE_CLEANUP_TEMPORARY_CHECKSUM" -maxdepth 0 \
        -type f -delete 2>/dev/null || true
    [[ -z "$CREATE_CLEANUP_TEMPORARY_SIGNATURE" ]] \
      || find "$CREATE_CLEANUP_TEMPORARY_SIGNATURE" -maxdepth 0 \
        -type f -delete 2>/dev/null || true
    if [[ "$CREATE_CLEANUP_OWNS_OPERATION_LOCK" == "true" ]]; then
      find "$CREATE_CLEANUP_LOCK_FILE" -maxdepth 0 \
        -type f -delete 2>/dev/null || true
    fi
  }
  if [[ "$BACKUP_OPERATION_LOCK_HELD" != "true" ]]; then
    if [[ -n "${ADDRESS_ATLAS_OPERATION_LOCK_OWNER_PID:-}" ]]; then
      inherited_operation_lock_is_valid "$CREATE_CLEANUP_LOCK_FILE"
    else
      acquire_backup_lock "$CREATE_CLEANUP_LOCK_FILE"
      CREATE_CLEANUP_OWNS_OPERATION_LOCK=true
    fi
    BACKUP_OPERATION_LOCK_HELD=true
  fi
  trap cleanup_create EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # Source provenance and the schema ledger are protected by the same operation
  # lock as the dump. Otherwise a deploy can migrate or replace the web image
  # between metadata collection and pg_dump.
  local container web_container
  container="$(resolve_postgres_container)"
  web_container="$(resolve_compose_container web "$allow_stopped_web")"
  database_context "$container"
  acquire_schema_backup_lock "$container" "$DB_USER" "$DB_NAME"
  local migration_ledger ledger_digest
  migration_ledger="$(read_migration_ledger "$container" "$DB_NAME" "$DB_USER")"
  identify_supported_migration_ledger "$migration_ledger"
  ledger_digest="$(printf '%s\n' "$migration_ledger" | sha256_stream)"
  [[ "$ledger_digest" == "$DETECTED_MIGRATION_DIGEST" ]] \
    || die "Canonical migration ledger digest could not be reproduced." 70
  local web_revision web_image_id postgres_image_id
  web_revision="$("$DOCKER_BIN" inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$web_container")"
  web_image_id="$("$DOCKER_BIN" inspect --format '{{.Image}}' "$web_container")"
  postgres_image_id="$("$DOCKER_BIN" inspect --format '{{.Image}}' "$container")"
  [[ "$web_revision" =~ ^[0-9a-f]{40}$ ]] \
    || die "Running web container has no valid immutable source revision." 65
  [[ "$web_image_id" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || die "Running web container has no valid immutable image ID." 65
  [[ "$postgres_image_id" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || die "PostgreSQL container has no valid immutable image ID." 65
  load_native_config_receipt "$web_revision"

  local timestamp backup manifest checksum signature snapshot_started completed
  snapshot_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  timestamp="${snapshot_started//[-:]/}"
  backup="${BACKUP_DIR}/address-atlas-${timestamp}.dump.age"
  manifest="$(manifest_path "$backup")"
  checksum="$(checksum_path "$backup")"
  signature="$(signature_path "$backup")"
  CREATE_CLEANUP_TEMPORARY_BACKUP="${backup}.partial.$$"
  CREATE_CLEANUP_TEMPORARY_MANIFEST="${manifest}.partial.$$"
  CREATE_CLEANUP_TEMPORARY_CHECKSUM="${checksum}.partial.$$"
  CREATE_CLEANUP_TEMPORARY_SIGNATURE="${signature}.partial.$$"
  [[ ! -e "$backup" && ! -e "$manifest" && ! -e "$checksum" && ! -e "$signature" \
      && ! -e "$CREATE_CLEANUP_TEMPORARY_BACKUP" \
      && ! -e "$CREATE_CLEANUP_TEMPORARY_MANIFEST" \
      && ! -e "$CREATE_CLEANUP_TEMPORARY_CHECKSUM" \
      && ! -e "$CREATE_CLEANUP_TEMPORARY_SIGNATURE" ]] \
    || die "A backup artifact already exists for ${timestamp}; retry in one second." 73
  "$DOCKER_BIN" exec "$container" sh -ceu '
      export PGPASSWORD="$POSTGRES_PASSWORD"
      exec pg_dump --format=custom --compress=6 --no-owner --no-privileges \
        --username "$1" --dbname "$2"
    ' sh "$DB_USER" "$DB_NAME" \
    | "$AGE_BIN" --encrypt --recipient "$recipient" \
      --output "$CREATE_CLEANUP_TEMPORARY_BACKUP"
  [[ -s "$CREATE_CLEANUP_TEMPORARY_BACKUP" ]] \
    || die "Encrypted backup output is empty." 74
  prove_schema_backup_lock
  release_schema_backup_lock
  local digest size
  digest="$(sha256_file "$CREATE_CLEANUP_TEMPORARY_BACKUP")"
  size="$(wc -c < "$CREATE_CLEANUP_TEMPORARY_BACKUP" | tr -d '[:space:]')"
  [[ "$size" =~ ^[1-9][0-9]*$ && "$size" -le "$MAX_BACKUP_BYTES" ]] \
    || die "Encrypted backup exceeds ADDRESS_ATLAS_BACKUP_MAX_BYTES." 74
  completed="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s  %s\n' "$digest" "$(basename "$backup")" \
    > "$CREATE_CLEANUP_TEMPORARY_CHECKSUM"
  write_manifest "$CREATE_CLEANUP_TEMPORARY_MANIFEST" "$snapshot_started" "$completed" \
    "$DB_NAME" "$size" "$digest" \
    "$web_revision" "$web_image_id" "$postgres_image_id" \
    "$NATIVE_CONFIG_VERSION" "$NATIVE_CONFIG_DIGEST" \
    "$NATIVE_CONFIG_UPDATED_AT_EPOCH_MS" "$NATIVE_CONFIG_SERVING_REVISION" \
    "$DETECTED_MIGRATION_HEAD" "$ledger_digest"
  "$OPENSSL_BIN" dgst -sha256 -sign "$signing_key" \
    -out "$CREATE_CLEANUP_TEMPORARY_SIGNATURE" \
    "$CREATE_CLEANUP_TEMPORARY_MANIFEST" >/dev/null 2>&1 \
    || die "Unable to sign the backup manifest." 74
  [[ -s "$CREATE_CLEANUP_TEMPORARY_SIGNATURE" ]] \
    || die "Backup manifest signature is empty." 74
  "$OPENSSL_BIN" dgst -sha256 -verify "$public_key" \
    -signature "$CREATE_CLEANUP_TEMPORARY_SIGNATURE" \
    "$CREATE_CLEANUP_TEMPORARY_MANIFEST" >/dev/null 2>&1 \
    || die "Backup signing and verification keys do not match." 65
  sync_durably "$CREATE_CLEANUP_TEMPORARY_BACKUP"
  sync_durably "$CREATE_CLEANUP_TEMPORARY_CHECKSUM"
  sync_durably "$CREATE_CLEANUP_TEMPORARY_MANIFEST"
  sync_durably "$CREATE_CLEANUP_TEMPORARY_SIGNATURE"
  mv "$CREATE_CLEANUP_TEMPORARY_CHECKSUM" "$checksum"
  CREATE_CLEANUP_TEMPORARY_CHECKSUM=""
  mv "$CREATE_CLEANUP_TEMPORARY_MANIFEST" "$manifest"
  CREATE_CLEANUP_TEMPORARY_MANIFEST=""
  mv "$CREATE_CLEANUP_TEMPORARY_SIGNATURE" "$signature"
  CREATE_CLEANUP_TEMPORARY_SIGNATURE=""
  sync_durably "$BACKUP_DIR"
  mv "$CREATE_CLEANUP_TEMPORARY_BACKUP" "$backup"
  CREATE_CLEANUP_TEMPORARY_BACKUP=""
  sync_durably "$BACKUP_DIR"
  verify_artifact_metadata "$backup" "$DB_NAME"
  decrypt_to_pg_restore "$container" "$backup" "$identity" --list >/dev/null \
    || die "Newly created backup could not be decrypted and inspected." 74
  if [[ -n "$OFFSITE_HOOK" ]]; then
    if ! env -i PATH=/usr/bin:/bin HOME=/ \
      "$OFFSITE_HOOK" "$backup" "$checksum" "$manifest" "$signature" >/dev/null 2>&1; then
      if [[ "$OFFSITE_REQUIRED" == "true" ]]; then
        die "Required offsite backup delivery failed; the completed local artifact set was retained." 74
      fi
      printf 'WARNING Optional offsite backup delivery failed; the completed local artifact set was retained.\n' >&2
    fi
  fi
  if [[ "$skip_retention" == "false" ]] && (( RETENTION_DAYS > 0 )); then
    local expired
    while IFS= read -r expired; do
      [[ -n "$expired" && "$expired" != "$backup" ]] || continue
      local expired_artifact
      for expired_artifact in "$expired" "$(checksum_path "$expired")" \
        "$(manifest_path "$expired")" "$(signature_path "$expired")"; do
        [[ -f "$expired_artifact" && ! -L "$expired_artifact" ]] || continue
        find "$expired_artifact" -maxdepth 0 -type f -delete
      done
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f \
      -name 'address-atlas-*.dump.age' -mtime "+${RETENTION_DAYS}" -print)
  fi
  if [[ "$CREATE_CLEANUP_OWNS_OPERATION_LOCK" == "true" ]]; then
    find "$CREATE_CLEANUP_LOCK_FILE" -maxdepth 0 -type f -delete
    BACKUP_OPERATION_LOCK_HELD=false
    sync_durably "$BACKUP_DIR"
  fi
  trap - EXIT INT TERM
  printf '%s\n' "$backup"
}

verify_backup() {
  local backup="$1"
  [[ "$backup" == /* && "$backup" == *.dump.age ]] \
    || die "Backup path must be an absolute .dump.age path." 65
  require_command "$DOCKER_BIN"
  require_command "$AGE_BIN"
  require_command "$OPENSSL_BIN"
  local identity container
  identity="$(validate_identity_file)"
  container="$(resolve_postgres_container)"
  database_context "$container"
  verify_artifact_metadata "$backup" "$DB_NAME"
  decrypt_to_pg_restore "$container" "$backup" "$identity" --list >/dev/null
  printf 'Verified encrypted and signed backup: %s\n' "$backup"
}

create_predeploy_backup() {
  assert_web_service_stopped
  create_backup true false
}

verify_external_backup() {
  local source_backup="$1"
  prepare_backup_directory
  EXTERNAL_VERIFY_CLEANUP_STAGING_DIRECTORY="${BACKUP_DIR}/.address-atlas-verify.$$"
  cleanup_external_verify() {
    cleanup_staging_directory "$EXTERNAL_VERIFY_CLEANUP_STAGING_DIRECTORY"
  }
  trap cleanup_external_verify EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  local staged_backup
  staged_backup="$(stage_backup_artifacts "$source_backup" \
    "$EXTERNAL_VERIFY_CLEANUP_STAGING_DIRECTORY")"
  verify_backup "$staged_backup" >/dev/null
  cleanup_staging_directory "$EXTERNAL_VERIFY_CLEANUP_STAGING_DIRECTORY"
  trap - EXIT INT TERM
  printf 'Verified encrypted and signed backup: %s\n' "$source_backup"
}

inspect_external_backup() {
  local source_backup="$1"
  prepare_backup_directory
  EXTERNAL_INSPECT_CLEANUP_STAGING_DIRECTORY="${BACKUP_DIR}/.address-atlas-inspect.$$"
  cleanup_external_inspect() {
    cleanup_staging_directory "$EXTERNAL_INSPECT_CLEANUP_STAGING_DIRECTORY"
  }
  trap cleanup_external_inspect EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  local staged_backup
  staged_backup="$(stage_backup_artifacts "$source_backup" \
    "$EXTERNAL_INSPECT_CLEANUP_STAGING_DIRECTORY")"
  verify_backup "$staged_backup" >/dev/null
  printf 'BACKUP_METADATA|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$MANIFEST_SCHEMA" "$MANIFEST_SHA256" "$MANIFEST_DATABASE" \
    "${MANIFEST_NATIVE_CONFIG_VERSION:--}" \
    "${MANIFEST_NATIVE_CONFIG_DIGEST:--}" \
    "${MANIFEST_NATIVE_CONFIG_UPDATED_AT_EPOCH_MS:--}" \
    "${MANIFEST_NATIVE_CONFIG_SERVING_REVISION:--}" \
    "$MANIFEST_WEB_IMAGE" "$MANIFEST_POSTGRES_IMAGE" \
    "$MANIFEST_MIGRATION_HEAD" "$MANIFEST_SNAPSHOT_STARTED"
  cleanup_staging_directory "$EXTERNAL_INSPECT_CLEANUP_STAGING_DIRECTORY"
  trap - EXIT INT TERM
}

latest_backup() {
  prepare_backup_directory
  local latest=""
  local candidate
  for candidate in "$BACKUP_DIR"/address-atlas-*.dump.age; do
    [[ -f "$candidate" && ! -L "$candidate" ]] || continue
    if [[ -z "$latest" || "$candidate" > "$latest" ]]; then
      latest="$candidate"
    fi
  done
  [[ -n "$latest" ]] || die "No encrypted PostgreSQL backup exists in ${BACKUP_DIR}." 66
  verify_backup "$latest" >/dev/null
  local signed_compact expected_basename now snapshot_epoch age_seconds max_seconds
  signed_compact="${MANIFEST_SNAPSHOT_STARTED//[-:]/}"
  expected_basename="address-atlas-${signed_compact}.dump.age"
  [[ "$(basename "$latest")" == "$expected_basename" ]] \
    || die "Managed backup filename does not match its signed snapshot start." 65
  now="$(date +%s)"
  snapshot_epoch="$(iso8601_epoch "$MANIFEST_SNAPSHOT_STARTED")"
  age_seconds=$((now - snapshot_epoch))
  max_seconds=$((MAX_AGE_HOURS * 3600))
  (( age_seconds >= 0 && age_seconds <= max_seconds )) \
    || die "Latest backup is older than ${MAX_AGE_HOURS} hour(s): ${latest}" 66
  printf '%s\n' "$latest"
}

run_restore_checks() {
  local container="$1" database="$2" user="$3"
  local expected_ledger
  expected_ledger="$(expected_migration_ledger)"
  "$DOCKER_BIN" exec "$container" sh -ceu '
      export PGPASSWORD="$POSTGRES_PASSWORD"
      PGOPTIONS="-c search_path=pg_catalog"
      export PGOPTIONS
      result="$(psql --username "$1" --dbname "$2" --no-psqlrc --tuples-only --no-align \
        --set ON_ERROR_STOP=1 --command \
        "SELECT pg_catalog.count(*) FROM (VALUES (pg_catalog.to_regclass('"'"'public.sync_schema_migrations'"'"')), (pg_catalog.to_regclass('"'"'public.users'"'"')), (pg_catalog.to_regclass('"'"'public.passkey_credentials'"'"')), (pg_catalog.to_regclass('"'"'public.consumed_challenges'"'"')), (pg_catalog.to_regclass('"'"'public.registration_usage'"'"')), (pg_catalog.to_regclass('"'"'public.session_grants'"'"')), (pg_catalog.to_regclass('"'"'public.vault_global_ingress_usage'"'"')), (pg_catalog.to_regclass('"'"'public.vault_write_usage'"'"')), (pg_catalog.to_regclass('"'"'public.sync_storage_usage'"'"')), (pg_catalog.to_regclass('"'"'public.vault_snapshots'"'"')), (pg_catalog.to_regclass('"'"'public.account_deletion_receipts'"'"'))) AS required_table(name) WHERE name IS NOT NULL")"
      [ "$result" = "11" ]
      psql --username "$1" --dbname "$2" --no-psqlrc --tuples-only --no-align \
        --set ON_ERROR_STOP=1 --command \
        "SELECT CASE WHEN pg_catalog.count(*) = 1 AND pg_catalog.bool_and(total_snapshot_bytes >= 0 AND reconciled_contract_version = 1 AND reconcile_required = false) THEN 1 ELSE 0 END FROM public.sync_storage_usage WHERE singleton = true" \
        | grep -qx 1
      ledger="$(psql --username "$1" --dbname "$2" --no-psqlrc --tuples-only --no-align \
        --field-separator="|" --set ON_ERROR_STOP=1 --command \
        "SELECT version, name, checksum FROM public.sync_schema_migrations ORDER BY version")"
      [ "$ledger" = "$3" ]
  ' sh "$user" "$database" "$expected_ledger"
}

validate_restore_migration_contract() {
  validate_restore_migration_hook
  local restore_revision="${ADDRESS_ATLAS_RESTORE_BUILD_REVISION:-}"
  local restore_image="${ADDRESS_ATLAS_RESTORE_IMAGE:-}"
  local owner_password="${POSTGRES_PASSWORD:-}"
  local resolved_docker restore_image_id restore_image_revision
  [[ "$restore_revision" =~ ^[0-9a-f]{40}$ ]] \
    || die "ADDRESS_ATLAS_RESTORE_BUILD_REVISION must be a full lowercase Git SHA." 65
  [[ "$restore_image" =~ ^[A-Za-z0-9._/:@-]+$ \
      && "$restore_image" == *":${restore_revision}" ]] \
    || die "ADDRESS_ATLAS_RESTORE_IMAGE must be tagged with the exact restore build revision." 65
  [[ "${#owner_password}" -ge 32 && "${#owner_password}" -le 128 \
      && "$owner_password" =~ ^[A-Za-z0-9_-]+$ ]] \
    || die "POSTGRES_PASSWORD must be a URL-safe 32-128 character owner secret for restore migration." 65
  resolved_docker="$(command -v "$DOCKER_BIN")" \
    || die "Unable to resolve DOCKER_BIN for the restore migration hook." 69
  [[ "$resolved_docker" == /* && -x "$resolved_docker" ]] \
    || die "Resolved DOCKER_BIN is not an absolute executable." 69
  restore_image_id="$("$DOCKER_BIN" image inspect --format '{{.Id}}' \
    "$restore_image" 2>/dev/null)" \
    || die "The immutable restore application image is unavailable." 69
  [[ "$restore_image_id" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || die "The immutable restore application image ID is malformed." 65
  restore_image_revision="$("$DOCKER_BIN" image inspect --format \
    '{{ index .Config.Labels "org.opencontainers.image.revision" }}' \
    "$restore_image" 2>/dev/null)" \
    || die "The immutable restore application image revision is unavailable." 69
  [[ "$restore_image_revision" == "$restore_revision" ]] \
    || die "The restore application image revision label does not match the requested build." 65
  RESTORE_IMAGE_ID="$restore_image_id"
}

migrate_restored_database_if_needed() {
  local container="$1"
  local database="$2"
  local source_head="$3"
  [[ "$source_head" =~ ^[1-3]$ && "$source_head" -le "$EXPECTED_MIGRATION_HEAD" ]] \
    || die "Restored backup migration head is invalid." 65
  validate_restore_migration_contract
  local restore_revision="${ADDRESS_ATLAS_RESTORE_BUILD_REVISION:-}"
  local restore_image="${ADDRESS_ATLAS_RESTORE_IMAGE:-}"
  local owner_password="${POSTGRES_PASSWORD:-}"
  local resolved_docker
  [[ "$restore_revision" =~ ^[0-9a-f]{40}$ ]] \
    || die "ADDRESS_ATLAS_RESTORE_BUILD_REVISION must be a full lowercase Git SHA." 65
  [[ "$restore_image" =~ ^[A-Za-z0-9._/:@-]+$ \
      && "$restore_image" == *":${restore_revision}" ]] \
    || die "ADDRESS_ATLAS_RESTORE_IMAGE must be tagged with the exact restore build revision." 65
  [[ "${#owner_password}" -ge 32 && "${#owner_password}" -le 128 \
      && "$owner_password" =~ ^[A-Za-z0-9_-]+$ ]] \
    || die "POSTGRES_PASSWORD must be a URL-safe 32-128 character owner secret for restore migration." 65
  resolved_docker="$(command -v "$DOCKER_BIN")" \
    || die "Unable to resolve DOCKER_BIN for the restore migration hook." 69
  [[ "$resolved_docker" == /* && -x "$resolved_docker" ]] \
    || die "Resolved DOCKER_BIN is not an absolute executable." 69
  if ! (
    scrub_environment
    export PATH=/usr/bin:/bin HOME=/
    export DOCKER_BIN="$resolved_docker"
    export POSTGRES_PASSWORD="$owner_password"
    export ADDRESS_ATLAS_RESTORE_IMAGE="$restore_image"
    export ADDRESS_ATLAS_RESTORE_BUILD_REVISION="$restore_revision"
    exec "$RESTORE_MIGRATION_HOOK" \
      "$container" "$database" "$source_head" "$EXPECTED_MIGRATION_HEAD"
  ) >/dev/null 2>&1; then
    die "Restore migration/readiness hook failed; the fresh database was not cut over." 74
  fi
}

runtime_access_contract_is_valid() {
  local container="$1" database="$2" runtime_password="$3"
  {
    printf '%s\n' "$runtime_password"
    cat <<'SQL'
WITH expected(table_name, privilege_type) AS (
  VALUES
    ('sync_schema_migrations', 'SELECT'),
    ('users', 'SELECT'), ('users', 'INSERT'), ('users', 'UPDATE'), ('users', 'DELETE'),
    ('passkey_credentials', 'SELECT'), ('passkey_credentials', 'INSERT'),
      ('passkey_credentials', 'UPDATE'),
    ('consumed_challenges', 'SELECT'), ('consumed_challenges', 'INSERT'),
      ('consumed_challenges', 'DELETE'),
    ('registration_usage', 'SELECT'), ('registration_usage', 'INSERT'),
      ('registration_usage', 'UPDATE'), ('registration_usage', 'DELETE'),
    ('session_grants', 'SELECT'), ('session_grants', 'INSERT'),
      ('session_grants', 'UPDATE'), ('session_grants', 'DELETE'),
    ('vault_global_ingress_usage', 'SELECT'), ('vault_global_ingress_usage', 'INSERT'),
      ('vault_global_ingress_usage', 'UPDATE'), ('vault_global_ingress_usage', 'DELETE'),
    ('vault_write_usage', 'SELECT'), ('vault_write_usage', 'INSERT'),
      ('vault_write_usage', 'UPDATE'), ('vault_write_usage', 'DELETE'),
    ('sync_storage_usage', 'SELECT'), ('sync_storage_usage', 'UPDATE'),
    ('vault_snapshots', 'SELECT'), ('vault_snapshots', 'INSERT'),
      ('vault_snapshots', 'UPDATE'),
    ('account_deletion_receipts', 'SELECT'), ('account_deletion_receipts', 'INSERT')
), table_privilege(privilege_type) AS (
  VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'),
    ('REFERENCES'), ('TRIGGER')
)
SELECT CASE WHEN
  CURRENT_USER = 'address_atlas_runtime'
  AND pg_catalog.has_database_privilege(
    CURRENT_USER, pg_catalog.current_database(), 'CONNECT'
  )
  AND NOT pg_catalog.has_database_privilege(
    CURRENT_USER, pg_catalog.current_database(), 'CREATE'
  )
  AND NOT pg_catalog.has_database_privilege(
    CURRENT_USER, pg_catalog.current_database(), 'TEMPORARY'
  )
  AND pg_catalog.has_schema_privilege(CURRENT_USER, 'public', 'USAGE')
  AND NOT pg_catalog.has_schema_privilege(CURRENT_USER, 'public', 'CREATE')
  AND NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class AS relation
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
    CROSS JOIN table_privilege AS candidate
    WHERE namespace.nspname = 'public'
      AND relation.relkind IN ('r', 'p', 'v', 'm', 'f')
      AND pg_catalog.has_table_privilege(
            CURRENT_USER, relation.oid, candidate.privilege_type
          ) IS DISTINCT FROM EXISTS (
            SELECT 1 FROM expected
            WHERE expected.table_name = relation.relname
              AND expected.privilege_type = candidate.privilege_type
          )
  )
  AND NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class AS sequence
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = sequence.relnamespace
    WHERE namespace.nspname = 'public'
      AND sequence.relkind = 'S'
      AND (
        pg_catalog.has_sequence_privilege(CURRENT_USER, sequence.oid, 'USAGE')
        OR pg_catalog.has_sequence_privilege(CURRENT_USER, sequence.oid, 'SELECT')
        OR pg_catalog.has_sequence_privilege(CURRENT_USER, sequence.oid, 'UPDATE')
      )
  )
  AND NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS routine
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname = 'public'
      AND pg_catalog.has_function_privilege(
            CURRENT_USER, routine.oid, 'EXECUTE'
          )
  )
  AND NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_type AS item
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = item.typnamespace
    LEFT JOIN pg_catalog.pg_class AS relation ON relation.oid = item.typrelid
    WHERE namespace.nspname = 'public'
      AND (item.typtype IN ('d', 'e', 'r', 'm')
           OR (item.typtype = 'c' AND relation.relkind = 'c'))
      AND pg_catalog.has_type_privilege(CURRENT_USER, item.oid, 'USAGE')
  )
  AND EXISTS (
    SELECT 1 FROM public.sync_storage_usage
    WHERE singleton = true
  )
THEN 'ok' ELSE 'invalid' END;
SQL
  } | "$DOCKER_BIN" exec -i "$container" sh -ceu '
    IFS= read -r PGPASSWORD
    export PGPASSWORD
    PGOPTIONS="-c search_path=pg_catalog"
    export PGOPTIONS
    result="$(exec psql --username "$1" --dbname "$2" --no-psqlrc --quiet \
      --tuples-only --no-align --set ON_ERROR_STOP=1)"
    [ "$result" = ok ]
  ' sh "$RUNTIME_USER" "$database"
}

validate_restore_provision_contract() {
  validate_restore_provision_hook
  local runtime_password="${POSTGRES_RUNTIME_PASSWORD:-}"
  local owner_password="${POSTGRES_PASSWORD:-}"
  local restore_revision="${ADDRESS_ATLAS_RESTORE_BUILD_REVISION:-}"
  local restore_image="${ADDRESS_ATLAS_RESTORE_IMAGE:-}"
  local provision_image="${ADDRESS_ATLAS_RESTORE_PROVISION_IMAGE:-}"
  local provision_image_id provision_source bootstrap_source
  [[ "${#runtime_password}" -ge 32 && "${#runtime_password}" -le 128 \
      && "$runtime_password" =~ ^[A-Za-z0-9_-]+$ ]] \
    || die "POSTGRES_RUNTIME_PASSWORD must be a URL-safe 32-128 character runtime secret for restore provisioning." 65
  [[ "${#owner_password}" -ge 32 && "${#owner_password}" -le 128 \
      && "$owner_password" =~ ^[A-Za-z0-9_-]+$ ]] \
    || die "POSTGRES_PASSWORD must be a URL-safe 32-128 character owner secret for restore provisioning." 65
  [[ "$restore_revision" =~ ^[0-9a-f]{40}$ \
      && "$restore_image" =~ ^[A-Za-z0-9._/:@-]+$ \
      && "$restore_image" == *":${restore_revision}" ]] \
    || die "Restore provisioning requires the exact immutable restore image revision." 65
  [[ "$provision_image" == "$EXPECTED_RESTORE_PROVISION_IMAGE" ]] \
    || die "ADDRESS_ATLAS_RESTORE_PROVISION_IMAGE must equal the reviewed immutable PostgreSQL image." 65
  [[ "${#ADMIN_PASSWORD}" -ge 32 && "${#ADMIN_PASSWORD}" -le 128 \
      && "$ADMIN_PASSWORD" =~ ^[A-Za-z0-9_-]+$ ]] \
    || die "POSTGRES_ADMIN_PASSWORD must satisfy the URL-safe 32-128 character restore-provisioning contract." 65
  provision_source="${RESTORE_PROVISION_HOOK%/*}/provision-runtime-role.sh"
  [[ -f "$provision_source" && -x "$provision_source" && ! -L "$provision_source" ]] \
    || die "The canonical runtime-role provision script is unavailable beside the restore hook." 66
  validate_trusted_public_file "$provision_source" \
    "The canonical runtime-role provision script"
  RESTORE_PROVISION_SOURCE_DIGEST="$(sha256_file "$provision_source")"
  bootstrap_source="${RESTORE_PROVISION_HOOK%/*}/bootstrap-database-roles.sh"
  [[ -f "$bootstrap_source" && -x "$bootstrap_source" && ! -L "$bootstrap_source" ]] \
    || die "The canonical bootstrap-role provision script is unavailable beside the restore hook." 66
  validate_trusted_public_file "$bootstrap_source" \
    "The canonical bootstrap-role provision script"
  RESTORE_BOOTSTRAP_SOURCE_DIGEST="$(sha256_file "$bootstrap_source")"
  provision_image_id="$("$DOCKER_BIN" image inspect --format '{{.Id}}' \
    "$provision_image" 2>/dev/null)" \
    || die "The immutable restore provision image is unavailable." 69
  [[ "$provision_image_id" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || die "The immutable restore provision image ID is malformed." 65
  RESTORE_PROVISION_IMAGE_ID="$provision_image_id"
}

provision_restored_database() {
  local container="$1" database="$2" provision_mode="$3"
  [[ "$provision_mode" == "bootstrap" || "$provision_mode" == "drill" \
      || "$provision_mode" == "restore" ]] \
    || die "Internal restore provisioning mode is invalid." 70
  validate_restore_provision_contract
  local runtime_password="${POSTGRES_RUNTIME_PASSWORD:-}"
  local owner_password="${POSTGRES_PASSWORD:-}"
  local restore_revision="${ADDRESS_ATLAS_RESTORE_BUILD_REVISION:-}"
  local restore_image="${ADDRESS_ATLAS_RESTORE_IMAGE:-}"
  local provision_image="${ADDRESS_ATLAS_RESTORE_PROVISION_IMAGE:-}"
  local resolved_docker
  [[ "${#runtime_password}" -ge 32 && "${#runtime_password}" -le 128 \
      && "$runtime_password" =~ ^[A-Za-z0-9_-]+$ ]] \
    || die "POSTGRES_RUNTIME_PASSWORD must be a URL-safe 32-128 character runtime secret for restore provisioning." 65
  [[ "$restore_revision" =~ ^[0-9a-f]{40}$ \
      && "$restore_image" =~ ^[A-Za-z0-9._/:@-]+$ \
      && "$restore_image" == *":${restore_revision}" ]] \
    || die "Restore provisioning requires the exact immutable restore image revision." 65
  [[ "$provision_image" == "$EXPECTED_RESTORE_PROVISION_IMAGE" ]] \
    || die "ADDRESS_ATLAS_RESTORE_PROVISION_IMAGE must match the reviewed PostgreSQL image exactly." 65
  resolved_docker="$(command -v "$DOCKER_BIN")" \
    || die "Unable to resolve DOCKER_BIN for restore provisioning." 69
  [[ "$resolved_docker" == /* && -x "$resolved_docker" ]] \
    || die "Resolved DOCKER_BIN is not an absolute executable." 69
  if ! (
    scrub_environment
    export PATH=/usr/bin:/bin HOME=/
    export DOCKER_BIN="$resolved_docker"
    export POSTGRES_ADMIN_PASSWORD="$ADMIN_PASSWORD"
    export POSTGRES_RUNTIME_PASSWORD="$runtime_password"
    if [[ "$provision_mode" == "bootstrap" ]]; then
      export POSTGRES_PASSWORD="$owner_password"
    fi
    export ADDRESS_ATLAS_RESTORE_IMAGE="$restore_image"
    export ADDRESS_ATLAS_RESTORE_BUILD_REVISION="$restore_revision"
    export ADDRESS_ATLAS_RESTORE_PROVISION_IMAGE="$provision_image"
    export ADDRESS_ATLAS_RESTORE_PROVISION_MODE="$provision_mode"
    export ADDRESS_ATLAS_RESTORE_STAGING_ROOT="$BACKUP_DIR"
    exec "$RESTORE_PROVISION_HOOK" "$container" "$database"
  ) >/dev/null 2>&1; then
    die "Database privilege provisioning failed." 74
  fi
  admin_and_owner_context_is_valid "$container" "$database" true \
    || die "Restore provisioning did not establish the exact protected-role contract." 74
  runtime_access_contract_is_valid "$container" "$database" "$runtime_password" \
    || die "Restore provisioning did not establish the exact runtime access contract." 74
}

require_admin_password() {
  ADMIN_PASSWORD="${POSTGRES_ADMIN_PASSWORD:-}"
  [[ "${#ADMIN_PASSWORD}" -ge 32 && "${#ADMIN_PASSWORD}" -le 256 \
      && "$ADMIN_PASSWORD" != *$'\n'* && "$ADMIN_PASSWORD" != *$'\r'* ]] \
    || die "POSTGRES_ADMIN_PASSWORD must be a single-line 32-256 character secret." 65
}

admin_createdb() {
  local container="$1" database="$2"
  { printf '%s\n' "$ADMIN_PASSWORD"; } | "$DOCKER_BIN" exec -i "$container" sh -ceu '
    IFS= read -r PGPASSWORD
    export PGPASSWORD
    exec createdb --username "$1" --template=template0 --owner="$2" "$3"
  ' sh "$ADMIN_USER" "$OWNER_USER" "$database"
}

admin_dropdb() {
  local container="$1" database="$2"
  { printf '%s\n' "$ADMIN_PASSWORD"; } | "$DOCKER_BIN" exec -i "$container" sh -ceu '
    IFS= read -r PGPASSWORD
    export PGPASSWORD
    exec dropdb --if-exists --force --username "$1" "$2"
  ' sh "$ADMIN_USER" "$database"
}

admin_psql() {
  local container="$1" database="$2" transaction_mode="$3" sql="$4"
  {
    printf '%s\n' "$ADMIN_PASSWORD"
    printf '%s\n' "$sql"
  } | "$DOCKER_BIN" exec -i "$container" sh -ceu '
    IFS= read -r PGPASSWORD
    export PGPASSWORD
    PGOPTIONS="-c search_path=pg_catalog"
    export PGOPTIONS
    if [ "$3" = transaction ]; then
      exec psql --username "$1" --dbname "$2" --no-psqlrc --quiet \
        --tuples-only --no-align --set ON_ERROR_STOP=1 --single-transaction
    fi
    exec psql --username "$1" --dbname "$2" --no-psqlrc --quiet \
      --tuples-only --no-align --set ON_ERROR_STOP=1
  ' sh "$ADMIN_USER" "$database" "$transaction_mode"
}

quiesce_runtime_role() {
  local container="$1" result sql
  printf -v sql 'ALTER ROLE "%s" NOLOGIN;' "$RUNTIME_USER"
  admin_psql "$container" postgres transaction "$sql" >/dev/null \
    || die "Unable to quiesce the runtime role before restore." 74
  PRODUCTION_RESTORE_CLEANUP_RUNTIME_QUIESCED=true
  # Commit NOLOGIN before terminating sessions so a reconnect cannot slip
  # between the termination scan and visibility of the role change.
  printf -v sql 'SELECT pg_catalog.pg_terminate_backend(pid) FROM pg_catalog.pg_stat_activity WHERE usename = '\''%s'\'' AND pid <> pg_catalog.pg_backend_pid();' \
    "$RUNTIME_USER"
  admin_psql "$container" postgres plain "$sql" >/dev/null \
    || die "Unable to terminate runtime database sessions before restore." 74
  printf -v sql 'SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM pg_catalog.pg_stat_activity WHERE usename = '\''%s'\'' AND pid <> pg_catalog.pg_backend_pid()) THEN '\''ok'\'' ELSE '\''active'\'' END;' \
    "$RUNTIME_USER"
  result="$(admin_psql "$container" postgres plain "$sql")" \
    || die "Unable to confirm runtime database quiescence." 74
  [[ "$result" == "ok" ]] \
    || die "Runtime database sessions remained active after NOLOGIN was committed." 74
}

force_and_confirm_runtime_nologin() {
  local container="$1" result sql
  printf -v sql 'ALTER ROLE "%s" NOLOGIN;' "$RUNTIME_USER"
  admin_psql "$container" postgres transaction "$sql" >/dev/null || return 1
  printf -v sql 'SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '\''%s'\'' AND NOT rolcanlogin) THEN '\''ok'\'' ELSE '\''invalid'\'' END;' \
    "$RUNTIME_USER"
  result="$(admin_psql "$container" postgres plain "$sql")" || return 1
  [[ "$result" == "ok" ]]
}

admin_and_owner_context_is_valid() {
  local container="$1" database="$2" runtime_login_mode="${3:-either}"
  local result sql runtime_login_predicate
  case "$runtime_login_mode" in
    true) runtime_login_predicate='AND r.rolcanlogin' ;;
    false) runtime_login_predicate='AND NOT r.rolcanlogin' ;;
    either) runtime_login_predicate='' ;;
    *) return 1 ;;
  esac
  printf -v sql '%s\n' \
    "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_catalog.pg_roles r WHERE r.rolname = '${ADMIN_USER}' AND r.rolcanlogin AND r.rolsuper AND NOT r.rolcreatedb AND r.rolcreaterole AND NOT r.rolreplication AND NOT r.rolbypassrls AND NOT r.rolinherit AND r.rolconnlimit = -1 AND r.rolconfig IS NULL AND (r.rolvaliduntil IS NULL OR r.rolvaliduntil = 'infinity'::pg_catalog.timestamptz)) AND EXISTS (SELECT 1 FROM pg_catalog.pg_roles r WHERE r.rolname = '${OWNER_USER}' AND r.rolcanlogin AND NOT r.rolsuper AND NOT r.rolcreatedb AND NOT r.rolcreaterole AND NOT r.rolreplication AND NOT r.rolbypassrls AND NOT r.rolinherit AND r.rolconnlimit = -1 AND r.rolconfig IS NULL AND (r.rolvaliduntil IS NULL OR r.rolvaliduntil = 'infinity'::pg_catalog.timestamptz)) AND EXISTS (SELECT 1 FROM pg_catalog.pg_roles r WHERE r.rolname = '${RUNTIME_USER}' ${runtime_login_predicate} AND NOT r.rolsuper AND NOT r.rolcreatedb AND NOT r.rolcreaterole AND NOT r.rolreplication AND NOT r.rolbypassrls AND NOT r.rolinherit AND r.rolconnlimit = -1 AND r.rolconfig IS NULL AND (r.rolvaliduntil IS NULL OR r.rolvaliduntil = 'infinity'::pg_catalog.timestamptz)) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members m JOIN pg_catalog.pg_roles granted ON granted.oid = m.roleid JOIN pg_catalog.pg_roles member ON member.oid = m.member WHERE granted.rolname IN ('${OWNER_USER}', '${ADMIN_USER}', '${RUNTIME_USER}') OR member.rolname IN ('${OWNER_USER}', '${ADMIN_USER}', '${RUNTIME_USER}')) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_db_role_setting s LEFT JOIN pg_catalog.pg_roles r ON r.oid = s.setrole WHERE r.rolname IN ('${OWNER_USER}', '${ADMIN_USER}', '${RUNTIME_USER}') OR s.setdatabase = (SELECT d.oid FROM pg_catalog.pg_database d WHERE d.datname = '${database}')) AND EXISTS (SELECT 1 FROM pg_catalog.pg_database d JOIN pg_catalog.pg_roles owner_role ON owner_role.oid = d.datdba WHERE d.datname = '${database}' AND owner_role.rolname = '${OWNER_USER}') THEN 'ok' ELSE 'invalid' END;"
  if ! result="$(admin_psql "$container" postgres plain "$sql")"; then
    return 1
  fi
  [[ "$result" == "ok" ]]
}

assert_admin_and_owner_context() {
  admin_and_owner_context_is_valid "$1" "$2" "${3:-either}" \
    || die "Administrative, owner, runtime, membership, setting, or database ownership invariant failed." 65
}

postgres_storage_identity() {
  local container="$1" descriptor system_identifier
  descriptor="$("$DOCKER_BIN" inspect --format \
    '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Type}}|{{.Name}}|{{.Source}}{{"\n"}}{{end}}{{end}}' \
    "$container" 2>/dev/null)" \
    || die "Unable to inspect PostgreSQL storage identity." 69
  [[ -n "$descriptor" && "$descriptor" != *$'\n'* \
      && ( "$descriptor" == volume\|* || "$descriptor" == bind\|* ) ]] \
    || die "PostgreSQL must expose exactly one identifiable data mount." 65
  if ! system_identifier="$(bootstrap_owner_psql "$container" postgres plain \
      'SELECT system_identifier FROM pg_catalog.pg_control_system();' 2>/dev/null)"; then
    system_identifier="$(admin_psql "$container" postgres plain \
      'SELECT system_identifier FROM pg_catalog.pg_control_system();' 2>/dev/null)" \
      || die "Unable to read the PostgreSQL system identifier." 69
  fi
  [[ "$system_identifier" =~ ^[1-9][0-9]{15,19}$ ]] \
    || die "PostgreSQL system identifier is malformed." 65
  printf 'sha256:%s\n' \
    "$(printf '%s|%s' "$descriptor" "$system_identifier" | sha256_stream)"
}

write_bootstrap_restore_state() {
  local path="$1" phase="$2" database="$3" backup_digest="$4"
  local storage_identity="$5" staging_database="$6" quarantine_database="$7"
  local temporary="${path}.partial.$$"
  [[ "$phase" == "staging" || "$phase" == "provisioning" \
      || "$phase" == "provisioned" || "$phase" == "cutover" \
      || "$phase" == "awaiting-finalize" || "$phase" == "finalized" ]] \
    || die "Internal bootstrap-restore phase is invalid." 70
  [[ ! -e "$temporary" && ! -L "$temporary" \
      && ( ! -L "$path" ) ]] \
    || die "Bootstrap-restore state path is unsafe or has a stale partial file." 73
  umask 077
  printf 'schema=1\nphase=%s\ndatabase=%s\nbackupSha256=%s\nstorageIdentity=%s\nstagingDatabase=%s\nquarantineDatabase=%s\nnativeConfigVersion=%s\nnativeConfigSha256=%s\nnativeConfigUpdatedAtEpochMs=%s\nnativeConfigServingRevision=%s\nsourceWebImageId=%s\ntargetBuildRevision=%s\ntargetWebImageId=%s\ntargetProvisionImageId=%s\ntargetMigrationHead=%s\nmigrationHookSha256=%s\nprovisionHookSha256=%s\nprovisionSourceSha256=%s\nbootstrapSourceSha256=%s\n' \
    "$phase" "$database" "$backup_digest" "$storage_identity" \
    "$staging_database" "$quarantine_database" \
    "$MANIFEST_NATIVE_CONFIG_VERSION" "$MANIFEST_NATIVE_CONFIG_DIGEST" \
    "$MANIFEST_NATIVE_CONFIG_UPDATED_AT_EPOCH_MS" \
    "$MANIFEST_NATIVE_CONFIG_SERVING_REVISION" "$MANIFEST_WEB_IMAGE" \
    "${ADDRESS_ATLAS_RESTORE_BUILD_REVISION:-}" "$RESTORE_IMAGE_ID" \
    "$RESTORE_PROVISION_IMAGE_ID" "$EXPECTED_MIGRATION_HEAD" \
    "$RESTORE_MIGRATION_HOOK_DIGEST" "$RESTORE_PROVISION_HOOK_DIGEST" \
    "$RESTORE_PROVISION_SOURCE_DIGEST" "$RESTORE_BOOTSTRAP_SOURCE_DIGEST" \
    > "$temporary"
  chmod 0600 "$temporary"
  sync_durably "$temporary"
  mv "$temporary" "$path"
  sync_durably "$BACKUP_DIR"
}

read_bootstrap_restore_state() {
  local path="$1" actual expected
  validate_private_file "$path" "The bootstrap-restore recovery state"
  [[ "$(wc -l < "$path" | tr -d '[:space:]')" == 20 ]] \
    || die "Bootstrap-restore recovery state is not canonical." 65
  BOOTSTRAP_STATE_PHASE="$(sed -n 's/^phase=//p' "$path")"
  BOOTSTRAP_STATE_DATABASE="$(sed -n 's/^database=//p' "$path")"
  BOOTSTRAP_STATE_BACKUP_SHA256="$(sed -n 's/^backupSha256=//p' "$path")"
  BOOTSTRAP_STATE_STORAGE_IDENTITY="$(sed -n 's/^storageIdentity=//p' "$path")"
  BOOTSTRAP_STATE_STAGING_DATABASE="$(sed -n 's/^stagingDatabase=//p' "$path")"
  BOOTSTRAP_STATE_QUARANTINE_DATABASE="$(sed -n 's/^quarantineDatabase=//p' "$path")"
  BOOTSTRAP_STATE_NATIVE_CONFIG_VERSION="$(sed -n 's/^nativeConfigVersion=//p' "$path")"
  BOOTSTRAP_STATE_NATIVE_CONFIG_DIGEST="$(sed -n 's/^nativeConfigSha256=//p' "$path")"
  BOOTSTRAP_STATE_NATIVE_CONFIG_UPDATED_AT="$(sed -n 's/^nativeConfigUpdatedAtEpochMs=//p' "$path")"
  BOOTSTRAP_STATE_NATIVE_CONFIG_REVISION="$(sed -n 's/^nativeConfigServingRevision=//p' "$path")"
  BOOTSTRAP_STATE_WEB_IMAGE="$(sed -n 's/^sourceWebImageId=//p' "$path")"
  BOOTSTRAP_STATE_TARGET_REVISION="$(sed -n 's/^targetBuildRevision=//p' "$path")"
  BOOTSTRAP_STATE_TARGET_WEB_IMAGE="$(sed -n 's/^targetWebImageId=//p' "$path")"
  BOOTSTRAP_STATE_TARGET_PROVISION_IMAGE="$(sed -n 's/^targetProvisionImageId=//p' "$path")"
  BOOTSTRAP_STATE_TARGET_MIGRATION_HEAD="$(sed -n 's/^targetMigrationHead=//p' "$path")"
  BOOTSTRAP_STATE_MIGRATION_HOOK_DIGEST="$(sed -n 's/^migrationHookSha256=//p' "$path")"
  BOOTSTRAP_STATE_PROVISION_HOOK_DIGEST="$(sed -n 's/^provisionHookSha256=//p' "$path")"
  BOOTSTRAP_STATE_PROVISION_SOURCE_DIGEST="$(sed -n 's/^provisionSourceSha256=//p' "$path")"
  BOOTSTRAP_STATE_BOOTSTRAP_SOURCE_DIGEST="$(sed -n 's/^bootstrapSourceSha256=//p' "$path")"
  [[ "$BOOTSTRAP_STATE_PHASE" == "staging" \
      || "$BOOTSTRAP_STATE_PHASE" == "provisioning" \
      || "$BOOTSTRAP_STATE_PHASE" == "provisioned" \
      || "$BOOTSTRAP_STATE_PHASE" == "cutover" \
      || "$BOOTSTRAP_STATE_PHASE" == "awaiting-finalize" \
      || "$BOOTSTRAP_STATE_PHASE" == "finalized" ]] \
    || die "Bootstrap-restore recovery phase is invalid." 65
  validate_identifier "$BOOTSTRAP_STATE_DATABASE" "Bootstrap-restore target database"
  validate_identifier "$BOOTSTRAP_STATE_STAGING_DATABASE" "Bootstrap-restore staging database"
  validate_identifier "$BOOTSTRAP_STATE_QUARANTINE_DATABASE" "Bootstrap-restore quarantine database"
  [[ "$BOOTSTRAP_STATE_BACKUP_SHA256" =~ ^[0-9a-f]{64}$ \
      && "$BOOTSTRAP_STATE_STORAGE_IDENTITY" =~ ^sha256:[0-9a-f]{64}$ \
      && "$BOOTSTRAP_STATE_NATIVE_CONFIG_VERSION" =~ ^[0-9]+$ \
      && "$BOOTSTRAP_STATE_NATIVE_CONFIG_DIGEST" =~ ^[0-9a-f]{64}$ \
      && "$BOOTSTRAP_STATE_NATIVE_CONFIG_UPDATED_AT" =~ ^[0-9]+$ \
      && "$BOOTSTRAP_STATE_NATIVE_CONFIG_REVISION" =~ ^[0-9a-f]{40}$ \
      && "$BOOTSTRAP_STATE_WEB_IMAGE" =~ ^sha256:[0-9a-f]{64}$ \
      && "$BOOTSTRAP_STATE_TARGET_REVISION" =~ ^[0-9a-f]{40}$ \
      && "$BOOTSTRAP_STATE_TARGET_WEB_IMAGE" =~ ^sha256:[0-9a-f]{64}$ \
      && "$BOOTSTRAP_STATE_TARGET_PROVISION_IMAGE" =~ ^sha256:[0-9a-f]{64}$ \
      && "$BOOTSTRAP_STATE_TARGET_MIGRATION_HEAD" =~ ^[1-3]$ \
      && "$BOOTSTRAP_STATE_MIGRATION_HOOK_DIGEST" =~ ^[0-9a-f]{64}$ \
      && "$BOOTSTRAP_STATE_PROVISION_HOOK_DIGEST" =~ ^[0-9a-f]{64}$ \
      && "$BOOTSTRAP_STATE_PROVISION_SOURCE_DIGEST" =~ ^[0-9a-f]{64}$ \
      && "$BOOTSTRAP_STATE_BOOTSTRAP_SOURCE_DIGEST" =~ ^[0-9a-f]{64}$ ]] \
    || die "Bootstrap-restore recovery state metadata is malformed." 65
  expected="$(printf 'schema=1\nphase=%s\ndatabase=%s\nbackupSha256=%s\nstorageIdentity=%s\nstagingDatabase=%s\nquarantineDatabase=%s\nnativeConfigVersion=%s\nnativeConfigSha256=%s\nnativeConfigUpdatedAtEpochMs=%s\nnativeConfigServingRevision=%s\nsourceWebImageId=%s\ntargetBuildRevision=%s\ntargetWebImageId=%s\ntargetProvisionImageId=%s\ntargetMigrationHead=%s\nmigrationHookSha256=%s\nprovisionHookSha256=%s\nprovisionSourceSha256=%s\nbootstrapSourceSha256=%s' \
    "$BOOTSTRAP_STATE_PHASE" "$BOOTSTRAP_STATE_DATABASE" \
    "$BOOTSTRAP_STATE_BACKUP_SHA256" "$BOOTSTRAP_STATE_STORAGE_IDENTITY" \
    "$BOOTSTRAP_STATE_STAGING_DATABASE" "$BOOTSTRAP_STATE_QUARANTINE_DATABASE" \
    "$BOOTSTRAP_STATE_NATIVE_CONFIG_VERSION" "$BOOTSTRAP_STATE_NATIVE_CONFIG_DIGEST" \
    "$BOOTSTRAP_STATE_NATIVE_CONFIG_UPDATED_AT" "$BOOTSTRAP_STATE_NATIVE_CONFIG_REVISION" \
    "$BOOTSTRAP_STATE_WEB_IMAGE" "$BOOTSTRAP_STATE_TARGET_REVISION" \
    "$BOOTSTRAP_STATE_TARGET_WEB_IMAGE" "$BOOTSTRAP_STATE_TARGET_PROVISION_IMAGE" \
    "$BOOTSTRAP_STATE_TARGET_MIGRATION_HEAD" \
    "$BOOTSTRAP_STATE_MIGRATION_HOOK_DIGEST" \
    "$BOOTSTRAP_STATE_PROVISION_HOOK_DIGEST" \
    "$BOOTSTRAP_STATE_PROVISION_SOURCE_DIGEST" \
    "$BOOTSTRAP_STATE_BOOTSTRAP_SOURCE_DIGEST")"
  actual="$(< "$path")"
  [[ "$actual" == "$expected" ]] \
    || die "Bootstrap-restore recovery state is not canonical." 65
}

bootstrap_owner_createdb() {
  local container="$1" database="$2"
  { printf '%s\n' "$POSTGRES_PASSWORD"; } | "$DOCKER_BIN" exec -i "$container" sh -ceu '
    IFS= read -r PGPASSWORD
    export PGPASSWORD
    exec createdb --username "$1" --template=template0 --owner="$1" "$2"
  ' sh "$OWNER_USER" "$database"
}

bootstrap_owner_dropdb() {
  local container="$1" database="$2"
  { printf '%s\n' "$POSTGRES_PASSWORD"; } | "$DOCKER_BIN" exec -i "$container" sh -ceu '
    IFS= read -r PGPASSWORD
    export PGPASSWORD
    exec dropdb --if-exists --force --username "$1" "$2"
  ' sh "$OWNER_USER" "$database"
}

bootstrap_owner_psql() {
  local container="$1" database="$2" transaction_mode="$3" sql="$4"
  {
    printf '%s\n' "$POSTGRES_PASSWORD"
    printf '%s\n' "$sql"
  } | "$DOCKER_BIN" exec -i "$container" sh -ceu '
    IFS= read -r PGPASSWORD
    export PGPASSWORD
    PGOPTIONS="-c search_path=pg_catalog"
    export PGOPTIONS
    if [ "$3" = transaction ]; then
      exec psql --username "$1" --dbname "$2" --no-psqlrc --quiet \
        --tuples-only --no-align --set ON_ERROR_STOP=1 --single-transaction
    fi
    exec psql --username "$1" --dbname "$2" --no-psqlrc --quiet \
      --tuples-only --no-align --set ON_ERROR_STOP=1
  ' sh "$OWNER_USER" "$database" "$transaction_mode"
}

bootstrap_database_has_pristine_system_content() {
  local container="$1" database="$2" authentication_context="$3"
  local result sql
  validate_identifier "$database" "Bootstrap pristine-system database"
  printf -v sql '%s\n' \
    "SELECT CASE WHEN 'address_atlas_bootstrap_pristine_database_v1' = 'address_atlas_bootstrap_pristine_database_v1' AND EXISTS (SELECT 1 FROM pg_catalog.pg_namespace AS namespace WHERE namespace.nspname = 'public' AND pg_catalog.pg_get_userbyid(namespace.nspowner) = 'pg_database_owner' AND namespace.nspacl IS NOT NULL AND (SELECT pg_catalog.count(*) FROM pg_catalog.aclexplode(namespace.nspacl)) = 3 AND (SELECT pg_catalog.count(*) FROM pg_catalog.aclexplode(namespace.nspacl) AS acl WHERE acl.grantee = namespace.nspowner AND acl.privilege_type = 'USAGE') = 1 AND (SELECT pg_catalog.count(*) FROM pg_catalog.aclexplode(namespace.nspacl) AS acl WHERE acl.grantee = namespace.nspowner AND acl.privilege_type = 'CREATE') = 1 AND (SELECT pg_catalog.count(*) FROM pg_catalog.aclexplode(namespace.nspacl) AS acl WHERE acl.grantee = 0 AND acl.privilege_type = 'USAGE') = 1 AND NOT EXISTS (SELECT 1 FROM pg_catalog.aclexplode(namespace.nspacl) AS acl WHERE acl.grantor <> namespace.nspowner OR acl.is_grantable OR NOT ((acl.grantee = namespace.nspowner AND acl.privilege_type IN ('USAGE', 'CREATE')) OR (acl.grantee = 0 AND acl.privilege_type = 'USAGE'))) AND pg_catalog.obj_description(namespace.oid, 'pg_namespace') = 'standard public schema') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname NOT IN ('pg_catalog', 'pg_toast', 'information_schema', 'public')) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class AS relation JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace WHERE namespace.nspname NOT IN ('pg_catalog', 'pg_toast', 'information_schema')) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc AS routine JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace WHERE namespace.nspname = 'public') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_type AS item JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = item.typnamespace WHERE namespace.nspname = 'public') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_collation AS catalog_collation JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = catalog_collation.collnamespace WHERE namespace.nspname = 'public') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_operator AS operator JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = operator.oprnamespace WHERE namespace.nspname = 'public') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_conversion AS conversion JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = conversion.connamespace WHERE namespace.nspname = 'public') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_opclass AS operator_class JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = operator_class.opcnamespace WHERE namespace.nspname = 'public') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_opfamily AS operator_family JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = operator_family.opfnamespace WHERE namespace.nspname = 'public') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_ts_config AS configuration JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = configuration.cfgnamespace WHERE namespace.nspname = 'public') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_ts_dict AS dictionary JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = dictionary.dictnamespace WHERE namespace.nspname = 'public') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_ts_parser AS parser JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = parser.prsnamespace WHERE namespace.nspname = 'public') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_ts_template AS template JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = template.tmplnamespace WHERE namespace.nspname = 'public') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_transform) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_cast WHERE oid >= 16384) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_am WHERE oid >= 16384) AND (SELECT pg_catalog.count(*) FROM pg_catalog.pg_extension) = 1 AND EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'plpgsql') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_language WHERE lanname NOT IN ('internal', 'c', 'sql', 'plpgsql') OR (lanacl IS NOT NULL AND lanacl <> pg_catalog.acldefault('l', lanowner))) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_largeobject_metadata) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_publication) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_subscription WHERE subdbid = (SELECT oid FROM pg_catalog.pg_database WHERE datname = pg_catalog.current_database())) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_foreign_data_wrapper) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_foreign_server) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_user_mapping) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_event_trigger) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_default_acl) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_shseclabel AS label WHERE label.classoid = 'pg_catalog.pg_database'::pg_catalog.regclass AND label.objoid = (SELECT oid FROM pg_catalog.pg_database WHERE datname = pg_catalog.current_database())) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_seclabel) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_db_role_setting AS setting WHERE setting.setdatabase = (SELECT oid FROM pg_catalog.pg_database WHERE datname = pg_catalog.current_database())) THEN 'ok' ELSE 'invalid' END;"
  case "$authentication_context" in
    owner)
      result="$(bootstrap_owner_psql "$container" "$database" plain "$sql")" \
        || return 1
      ;;
    admin)
      result="$(admin_psql "$container" "$database" plain "$sql")" \
        || return 1
      ;;
    *) return 1 ;;
  esac
  [[ "$result" == "ok" ]]
}

bootstrap_cluster_is_pristine() {
  local container="$1" staging_database="${2:-}" classification result sql
  classification="$(classify_source_database)" || return 1
  [[ "$classification" == "brand-new-empty" ]] || return 1
  local staging_database_clause="" staging_owner_clause=""
  if [[ -n "$staging_database" ]]; then
    validate_identifier "$staging_database" "Bootstrap-restore staging database"
    staging_database_clause=", '${staging_database}'"
    staging_owner_clause="AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_database database JOIN pg_catalog.pg_roles owner ON owner.oid = database.datdba WHERE database.datname = '${staging_database}' AND owner.rolname <> '${OWNER_USER}')"
  fi
  printf -v sql '%s\n' \
    "SELECT CASE WHEN 'address_atlas_bootstrap_pristine_v1' = 'address_atlas_bootstrap_pristine_v1' AND CURRENT_USER = '${OWNER_USER}' AND EXISTS (SELECT 1 FROM pg_catalog.pg_roles role WHERE role.rolname = '${OWNER_USER}' AND role.oid = 10 AND role.rolsuper AND role.rolcreatedb AND role.rolcreaterole AND role.rolcanlogin AND role.rolreplication AND role.rolbypassrls AND role.rolinherit AND role.rolconnlimit = -1 AND role.rolconfig IS NULL) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles role WHERE role.rolname !~ '^pg_' AND role.rolname <> '${OWNER_USER}') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members edge JOIN pg_catalog.pg_roles granted ON granted.oid = edge.roleid JOIN pg_catalog.pg_roles member ON member.oid = edge.member WHERE granted.rolname !~ '^pg_' OR member.rolname !~ '^pg_') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_db_role_setting) AND EXISTS (SELECT 1 FROM pg_catalog.pg_database database JOIN pg_catalog.pg_roles owner ON owner.oid = database.datdba WHERE database.datname = '${DB_NAME}' AND NOT database.datistemplate AND database.datallowconn AND database.datconnlimit = -1 AND database.datacl IS NULL AND pg_catalog.shobj_description(database.oid, 'pg_database') IS NULL AND owner.rolname = '${OWNER_USER}') AND EXISTS (SELECT 1 FROM pg_catalog.pg_database database JOIN pg_catalog.pg_roles owner ON owner.oid = database.datdba WHERE database.datname = 'postgres' AND NOT database.datistemplate AND database.datallowconn AND database.datconnlimit = -1 AND database.datacl IS NULL AND pg_catalog.shobj_description(database.oid, 'pg_database') = 'default administrative connection database' AND owner.rolname = '${OWNER_USER}') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_database database WHERE database.datname NOT IN ('template0', 'template1', 'postgres', '${DB_NAME}'${staging_database_clause})) ${staging_owner_clause} AND EXISTS (SELECT 1 FROM pg_catalog.pg_database database JOIN pg_catalog.pg_roles owner ON owner.oid = database.datdba WHERE database.datname = 'template0' AND database.datistemplate AND NOT database.datallowconn AND database.datconnlimit = -1 AND database.datacl::pg_catalog.text = '{=c/address_atlas,address_atlas=CTc/address_atlas}' AND pg_catalog.shobj_description(database.oid, 'pg_database') = 'unmodifiable empty database' AND owner.rolname = '${OWNER_USER}') AND EXISTS (SELECT 1 FROM pg_catalog.pg_database database JOIN pg_catalog.pg_roles owner ON owner.oid = database.datdba WHERE database.datname = 'template1' AND database.datistemplate AND database.datallowconn AND database.datconnlimit = -1 AND database.datacl::pg_catalog.text = '{=c/address_atlas,address_atlas=CTc/address_atlas}' AND pg_catalog.shobj_description(database.oid, 'pg_database') = 'default template for new databases' AND owner.rolname = '${OWNER_USER}') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_tablespace WHERE spcname NOT IN ('pg_default', 'pg_global')) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_replication_slots) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_prepared_xacts) THEN 'ok' ELSE 'invalid' END;"
  result="$(bootstrap_owner_psql "$container" postgres plain "$sql")" || return 1
  [[ "$result" == "ok" ]] \
    && bootstrap_database_has_pristine_system_content "$container" postgres owner \
    && bootstrap_database_has_pristine_system_content "$container" template1 owner
}

canonical_recovery_cluster_is_valid() {
  local container="$1" staging_database="$2" quarantine_database="$3"
  local phase="$4" result sql database_clause contract_marker
  case "$phase" in
    pre-cutover)
      contract_marker='address_atlas_bootstrap_pre_cutover_v1'
      database_clause="AND EXISTS (SELECT 1 FROM pg_catalog.pg_database database JOIN pg_catalog.pg_roles owner ON owner.oid = database.datdba WHERE database.datname = '${DB_NAME}' AND database.datallowconn AND owner.rolname = '${ADMIN_USER}') AND EXISTS (SELECT 1 FROM pg_catalog.pg_database database JOIN pg_catalog.pg_roles owner ON owner.oid = database.datdba WHERE database.datname = '${staging_database}' AND database.datallowconn AND owner.rolname = '${OWNER_USER}') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_database WHERE datname = '${quarantine_database}')"
      ;;
    post-cutover)
      contract_marker='address_atlas_bootstrap_post_cutover_v1'
      database_clause="AND EXISTS (SELECT 1 FROM pg_catalog.pg_database database JOIN pg_catalog.pg_roles owner ON owner.oid = database.datdba WHERE database.datname = '${DB_NAME}' AND database.datallowconn AND owner.rolname = '${OWNER_USER}') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_database WHERE datname = '${staging_database}') AND EXISTS (SELECT 1 FROM pg_catalog.pg_database database JOIN pg_catalog.pg_roles owner ON owner.oid = database.datdba WHERE database.datname = '${quarantine_database}' AND NOT database.datallowconn AND owner.rolname = '${ADMIN_USER}')"
      ;;
    *) return 1 ;;
  esac
  printf -v sql '%s\n' \
    "SELECT CASE WHEN '${contract_marker}' = '${contract_marker}' AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles role WHERE role.rolname !~ '^pg_' AND role.rolname NOT IN ('${ADMIN_USER}', '${OWNER_USER}', '${RUNTIME_USER}')) AND (SELECT pg_catalog.count(*) FROM pg_catalog.pg_roles role WHERE role.rolname IN ('${ADMIN_USER}', '${OWNER_USER}', '${RUNTIME_USER}')) = 3 AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members edge JOIN pg_catalog.pg_roles granted ON granted.oid = edge.roleid JOIN pg_catalog.pg_roles member ON member.oid = edge.member WHERE granted.rolname !~ '^pg_' OR member.rolname !~ '^pg_') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_db_role_setting) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_database database WHERE database.datname NOT IN ('template0', 'template1', 'postgres', '${DB_NAME}', '${staging_database}', '${quarantine_database}')) AND EXISTS (SELECT 1 FROM pg_catalog.pg_database database JOIN pg_catalog.pg_roles owner ON owner.oid = database.datdba WHERE database.datname = 'postgres' AND NOT database.datistemplate AND database.datallowconn AND owner.rolname = '${ADMIN_USER}') AND EXISTS (SELECT 1 FROM pg_catalog.pg_database database JOIN pg_catalog.pg_roles owner ON owner.oid = database.datdba WHERE database.datname = 'template0' AND database.datistemplate AND NOT database.datallowconn AND owner.rolname = '${ADMIN_USER}') AND EXISTS (SELECT 1 FROM pg_catalog.pg_database database JOIN pg_catalog.pg_roles owner ON owner.oid = database.datdba WHERE database.datname = 'template1' AND database.datistemplate AND database.datallowconn AND owner.rolname = '${ADMIN_USER}') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_tablespace WHERE spcname NOT IN ('pg_default', 'pg_global')) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_replication_slots) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_prepared_xacts) ${database_clause} THEN 'ok' ELSE 'invalid' END;"
  result="$(admin_psql "$container" postgres plain "$sql")" || return 1
  [[ "$result" == "ok" ]] \
    && bootstrap_database_has_pristine_system_content "$container" postgres admin \
    && bootstrap_database_has_pristine_system_content "$container" template1 admin
}

post_split_pre_cutover_is_valid() {
  local container="$1" staging_database="$2" quarantine_database="$3"
  canonical_recovery_cluster_is_valid "$container" "$staging_database" \
    "$quarantine_database" pre-cutover \
    && run_restore_checks "$container" "$staging_database" "$OWNER_USER" \
    && admin_and_owner_context_is_valid "$container" "$staging_database" true \
    && runtime_access_contract_is_valid "$container" "$staging_database" \
      "${POSTGRES_RUNTIME_PASSWORD:-}"
}

post_split_pre_cutover_structure_is_valid() {
  local container="$1" staging_database="$2" quarantine_database="$3"
  canonical_recovery_cluster_is_valid "$container" "$staging_database" \
    "$quarantine_database" pre-cutover \
    && run_restore_checks "$container" "$staging_database" "$OWNER_USER" \
    && admin_and_owner_context_is_valid "$container" "$staging_database" either
}

post_split_bridge_pre_cutover_structure_is_valid() {
  local container="$1" staging_database="$2" quarantine_database="$3"
  local result sql
  printf -v sql '%s\n' \
    "SELECT CASE WHEN 'address_atlas_bootstrap_post_split_bridge_v1' = 'address_atlas_bootstrap_post_split_bridge_v1' AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles role WHERE role.rolname !~ '^pg_' AND role.rolname NOT IN ('${ADMIN_USER}', '${OWNER_USER}', '${RUNTIME_USER}', 'address_atlas_role_bridge')) AND (SELECT pg_catalog.count(*) FROM pg_catalog.pg_roles role WHERE role.rolname IN ('${ADMIN_USER}', '${OWNER_USER}', '${RUNTIME_USER}', 'address_atlas_role_bridge')) = 4 AND EXISTS (SELECT 1 FROM pg_catalog.pg_roles role WHERE role.rolname = 'address_atlas_role_bridge' AND role.rolsuper AND role.rolcreaterole AND NOT role.rolcreatedb AND NOT role.rolreplication AND NOT role.rolbypassrls AND NOT role.rolinherit AND role.rolcanlogin AND role.rolconnlimit = -1 AND role.rolconfig IS NULL) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members edge JOIN pg_catalog.pg_roles granted ON granted.oid = edge.roleid JOIN pg_catalog.pg_roles member ON member.oid = edge.member WHERE granted.rolname !~ '^pg_' OR member.rolname !~ '^pg_') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_db_role_setting) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_database database WHERE database.datname NOT IN ('template0', 'template1', 'postgres', '${DB_NAME}', '${staging_database}')) AND EXISTS (SELECT 1 FROM pg_catalog.pg_database database JOIN pg_catalog.pg_roles owner ON owner.oid = database.datdba WHERE database.datname = 'postgres' AND NOT database.datistemplate AND database.datallowconn AND owner.rolname = '${ADMIN_USER}') AND EXISTS (SELECT 1 FROM pg_catalog.pg_database database JOIN pg_catalog.pg_roles owner ON owner.oid = database.datdba WHERE database.datname = 'template0' AND database.datistemplate AND NOT database.datallowconn AND owner.rolname = '${ADMIN_USER}') AND EXISTS (SELECT 1 FROM pg_catalog.pg_database database JOIN pg_catalog.pg_roles owner ON owner.oid = database.datdba WHERE database.datname = 'template1' AND database.datistemplate AND database.datallowconn AND owner.rolname = '${ADMIN_USER}') AND EXISTS (SELECT 1 FROM pg_catalog.pg_database database JOIN pg_catalog.pg_roles owner ON owner.oid = database.datdba WHERE database.datname = '${DB_NAME}' AND NOT database.datistemplate AND database.datallowconn AND owner.rolname = '${ADMIN_USER}') AND EXISTS (SELECT 1 FROM pg_catalog.pg_database database JOIN pg_catalog.pg_roles owner ON owner.oid = database.datdba WHERE database.datname = '${staging_database}' AND NOT database.datistemplate AND database.datallowconn AND owner.rolname = '${OWNER_USER}') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_database WHERE datname = '${quarantine_database}') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_tablespace WHERE spcname NOT IN ('pg_default', 'pg_global')) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_replication_slots) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_prepared_xacts) THEN 'ok' ELSE 'invalid' END;"
  result="$(admin_psql "$container" postgres plain "$sql")" || return 1
  [[ "$result" == "ok" ]] \
    && bootstrap_database_has_pristine_system_content "$container" postgres admin \
    && bootstrap_database_has_pristine_system_content "$container" template1 admin \
    && run_restore_checks "$container" "$staging_database" "$OWNER_USER" \
    && admin_and_owner_context_is_valid "$container" "$staging_database" either
}

pre_split_recovery_is_valid() {
  local container="$1" staging_database="$2" quarantine_database="$3"
  local classification result sql
  classification="$(classify_source_database)" || return 1
  [[ "$classification" == "brand-new-empty" ]] || return 1
  printf -v sql '%s\n' \
    "SELECT CASE WHEN 'address_atlas_bootstrap_pre_split_recovery_v1' = 'address_atlas_bootstrap_pre_split_recovery_v1' AND CURRENT_USER = '${OWNER_USER}' AND EXISTS (SELECT 1 FROM pg_catalog.pg_roles role WHERE role.rolname = '${OWNER_USER}' AND role.oid = 10 AND role.rolsuper AND role.rolcreatedb AND role.rolcreaterole AND role.rolcanlogin AND role.rolreplication AND role.rolbypassrls AND role.rolinherit AND role.rolconnlimit = -1 AND role.rolconfig IS NULL) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles role WHERE role.rolname !~ '^pg_' AND role.rolname NOT IN ('${OWNER_USER}', 'address_atlas_role_bridge')) AND (NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles role WHERE role.rolname = 'address_atlas_role_bridge') OR EXISTS (SELECT 1 FROM pg_catalog.pg_roles role WHERE role.rolname = 'address_atlas_role_bridge' AND role.rolsuper AND role.rolcreaterole AND NOT role.rolcreatedb AND NOT role.rolreplication AND NOT role.rolbypassrls AND NOT role.rolinherit AND role.rolcanlogin AND role.rolconnlimit = -1 AND role.rolconfig IS NULL)) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members edge JOIN pg_catalog.pg_roles granted ON granted.oid = edge.roleid JOIN pg_catalog.pg_roles member ON member.oid = edge.member WHERE granted.rolname !~ '^pg_' OR member.rolname !~ '^pg_') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_db_role_setting) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_database database WHERE database.datname NOT IN ('template0', 'template1', 'postgres', '${DB_NAME}', '${staging_database}')) AND EXISTS (SELECT 1 FROM pg_catalog.pg_database database JOIN pg_catalog.pg_roles owner ON owner.oid = database.datdba WHERE database.datname = 'postgres' AND NOT database.datistemplate AND database.datallowconn AND database.datconnlimit = -1 AND database.datacl IS NULL AND pg_catalog.shobj_description(database.oid, 'pg_database') = 'default administrative connection database' AND owner.rolname = '${OWNER_USER}') AND EXISTS (SELECT 1 FROM pg_catalog.pg_database database JOIN pg_catalog.pg_roles owner ON owner.oid = database.datdba WHERE database.datname = 'template0' AND database.datistemplate AND NOT database.datallowconn AND database.datconnlimit = -1 AND database.datacl::pg_catalog.text = '{=c/${OWNER_USER},${OWNER_USER}=CTc/${OWNER_USER}}' AND pg_catalog.shobj_description(database.oid, 'pg_database') = 'unmodifiable empty database' AND owner.rolname = '${OWNER_USER}') AND EXISTS (SELECT 1 FROM pg_catalog.pg_database database JOIN pg_catalog.pg_roles owner ON owner.oid = database.datdba WHERE database.datname = 'template1' AND database.datistemplate AND database.datallowconn AND database.datconnlimit = -1 AND database.datacl::pg_catalog.text = '{=c/${OWNER_USER},${OWNER_USER}=CTc/${OWNER_USER}}' AND pg_catalog.shobj_description(database.oid, 'pg_database') = 'default template for new databases' AND owner.rolname = '${OWNER_USER}') AND EXISTS (SELECT 1 FROM pg_catalog.pg_database database JOIN pg_catalog.pg_roles owner ON owner.oid = database.datdba WHERE database.datname = '${DB_NAME}' AND NOT database.datistemplate AND database.datallowconn AND database.datconnlimit = -1 AND database.datacl IS NULL AND pg_catalog.shobj_description(database.oid, 'pg_database') IS NULL AND owner.rolname = '${OWNER_USER}') AND EXISTS (SELECT 1 FROM pg_catalog.pg_database database JOIN pg_catalog.pg_roles owner ON owner.oid = database.datdba WHERE database.datname = '${staging_database}' AND NOT database.datistemplate AND database.datallowconn AND database.datconnlimit = -1 AND database.datacl IS NULL AND pg_catalog.shobj_description(database.oid, 'pg_database') IS NULL AND owner.rolname = '${OWNER_USER}') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_database WHERE datname = '${quarantine_database}') AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_tablespace WHERE spcname NOT IN ('pg_default', 'pg_global')) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_replication_slots) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_prepared_xacts) THEN 'ok' ELSE 'invalid' END;"
  result="$(bootstrap_owner_psql "$container" postgres plain "$sql")" || return 1
  [[ "$result" == "ok" ]] \
    && bootstrap_database_has_pristine_system_content "$container" postgres owner \
    && bootstrap_database_has_pristine_system_content "$container" template1 owner \
    && run_restore_checks "$container" "$staging_database" "$OWNER_USER"
}

post_bootstrap_cutover_is_valid() {
  local container="$1" staging_database="$2" quarantine_database="$3"
  canonical_recovery_cluster_is_valid "$container" "$staging_database" \
    "$quarantine_database" post-cutover \
    && run_restore_checks "$container" "$DB_NAME" "$OWNER_USER" \
    && admin_and_owner_context_is_valid "$container" "$DB_NAME" true \
    && runtime_access_contract_is_valid "$container" "$DB_NAME" \
      "${POSTGRES_RUNTIME_PASSWORD:-}"
}

post_bootstrap_cutover_structure_is_valid() {
  local container="$1" staging_database="$2" quarantine_database="$3"
  canonical_recovery_cluster_is_valid "$container" "$staging_database" \
    "$quarantine_database" post-cutover \
    && run_restore_checks "$container" "$DB_NAME" "$OWNER_USER" \
    && admin_and_owner_context_is_valid "$container" "$DB_NAME" either
}

atomic_bootstrap_cutover() {
  local container="$1" staging_database="$2" production_database="$3"
  local quarantine_database="$4" sql
  printf -v sql 'SELECT pg_catalog.pg_advisory_xact_lock(1094992974);\nSELECT pg_catalog.pg_terminate_backend(pid) FROM pg_catalog.pg_stat_activity WHERE datname IN ('\''%s'\'', '\''%s'\'') AND pid <> pg_catalog.pg_backend_pid();\nALTER DATABASE "%s" RENAME TO "%s";\nALTER DATABASE "%s" ALLOW_CONNECTIONS false;\nALTER DATABASE "%s" RENAME TO "%s";' \
    "$production_database" "$staging_database" "$production_database" \
    "$quarantine_database" "$quarantine_database" "$staging_database" \
    "$production_database"
  admin_psql "$container" postgres transaction "$sql" >/dev/null
}

bootstrap_restore() {
  local source_backup="$1" confirmation="$2" container
  container="$(resolve_postgres_container)"
  BOOTSTRAP_RESTORE_CLEANUP_CONTAINER="$container"
  database_context "$container"
  [[ "$confirmation" == "BOOTSTRAP-RESTORE:${DB_NAME}" ]] \
    || die "Confirmation must exactly equal BOOTSTRAP-RESTORE:${DB_NAME}." 64
  [[ "${ADDRESS_ATLAS_ALLOW_BOOTSTRAP_RESTORE:-}" \
      == "YES_I_UNDERSTAND_FRESH_CLUSTER_ONLY" ]] \
    || die "Fresh-cluster bootstrap-restore authorization is missing." 77
  assert_web_service_stopped
  prepare_backup_directory
  local lock_file="${BACKUP_DIR}/.backup-operation.lock"
  local state_file="${BACKUP_DIR}/.bootstrap-restore.state"
  local source_staging_directory="${BACKUP_DIR}/.address-atlas-bootstrap-source.$$"
  BOOTSTRAP_RESTORE_CLEANUP_LOCK_FILE="$lock_file"
  BOOTSTRAP_RESTORE_CLEANUP_SOURCE_STAGING_DIRECTORY="$source_staging_directory"
  BOOTSTRAP_RESTORE_CLEANUP_OWNS_OPERATION_LOCK=false
  BOOTSTRAP_RESTORE_CLEANUP_RECOVERY_REQUIRED=false
  BOOTSTRAP_RESTORE_CLEANUP_PARENT_PRESERVATION_SIGNAL=false
  BOOTSTRAP_RESTORE_CLEANUP_RESTORE_SUCCEEDED=false
  local staging_database="" quarantine_database="" storage_identity=""
  BOOTSTRAP_RESTORE_CLEANUP_ROLES_MAY_BE_PROVISIONED=false
  cleanup_bootstrap_restore() {
    cleanup_staging_directory \
      "$BOOTSTRAP_RESTORE_CLEANUP_SOURCE_STAGING_DIRECTORY"
    if [[ "$BOOTSTRAP_RESTORE_CLEANUP_RECOVERY_REQUIRED" == "true" \
        && "$BOOTSTRAP_RESTORE_CLEANUP_RESTORE_SUCCEEDED" != "true" ]]; then
      if [[ "$BOOTSTRAP_RESTORE_CLEANUP_ROLES_MAY_BE_PROVISIONED" == "true" \
          && -n "${ADMIN_PASSWORD:-}" ]]; then
        if ! force_and_confirm_runtime_nologin \
            "$BOOTSTRAP_RESTORE_CLEANUP_CONTAINER" >/dev/null 2>&1; then
          printf 'CRITICAL The runtime database role could not be proven NOLOGIN after bootstrap failure.\n' >&2
        fi
      fi
      if ! preserve_operation_lock_for_recovery \
          "$BOOTSTRAP_RESTORE_CLEANUP_LOCK_FILE"; then
        printf 'CRITICAL Unable to write the bootstrap-restore recovery lock marker; do not start another operation.\n' >&2
        [[ -z "${ADDRESS_ATLAS_OPERATION_LOCK_OWNER_PID:-}" ]] \
          || BOOTSTRAP_RESTORE_CLEANUP_PARENT_PRESERVATION_SIGNAL=true
      fi
      printf 'CRITICAL Bootstrap restore requires recovery or resume; keep every application service stopped.\n' >&2
    elif [[ "$BOOTSTRAP_RESTORE_CLEANUP_OWNS_OPERATION_LOCK" == "true" ]]; then
      find "$BOOTSTRAP_RESTORE_CLEANUP_LOCK_FILE" -maxdepth 0 \
        -type f -delete 2>/dev/null || true
    fi
    if [[ "$BOOTSTRAP_RESTORE_CLEANUP_PARENT_PRESERVATION_SIGNAL" == "true" ]]; then
      trap - EXIT
      exit 78
    fi
  }
  if [[ -n "${ADDRESS_ATLAS_OPERATION_LOCK_OWNER_PID:-}" ]]; then
    inherited_operation_lock_is_valid "$lock_file"
  else
    acquire_backup_lock "$lock_file"
    BOOTSTRAP_RESTORE_CLEANUP_OWNS_OPERATION_LOCK=true
  fi
  BACKUP_OPERATION_LOCK_HELD=true
  trap cleanup_bootstrap_restore EXIT
  trap 'BOOTSTRAP_RESTORE_CLEANUP_RECOVERY_REQUIRED=true; exit 130' INT
  trap 'BOOTSTRAP_RESTORE_CLEANUP_RECOVERY_REQUIRED=true; exit 143' TERM

  source_backup="$(stage_backup_artifacts "$source_backup" "$source_staging_directory")"
  verify_backup "$source_backup" >/dev/null
  [[ "$MANIFEST_SCHEMA" == "4" ]] \
    || die "Fresh-cluster bootstrap restore requires a signed schema-v4 native-config receipt." 65
  local expected_backup_sha="${ADDRESS_ATLAS_EXPECTED_BACKUP_SHA256:-}"
  [[ "$expected_backup_sha" =~ ^[0-9a-f]{64}$ \
      && "$expected_backup_sha" == "$MANIFEST_SHA256" ]] \
    || die "ADDRESS_ATLAS_EXPECTED_BACKUP_SHA256 does not match the staged signed artifact." 65
  local receipt_version="$MANIFEST_NATIVE_CONFIG_VERSION"
  local receipt_digest="$MANIFEST_NATIVE_CONFIG_DIGEST"
  local receipt_updated_at="$MANIFEST_NATIVE_CONFIG_UPDATED_AT_EPOCH_MS"
  local receipt_revision="$MANIFEST_NATIVE_CONFIG_SERVING_REVISION"
  local receipt_image="$MANIFEST_WEB_IMAGE"
  local source_migration_head="$MANIFEST_MIGRATION_HEAD"
  local backup_digest="$MANIFEST_SHA256"
  local identity
  identity="$(validate_identity_file)"
  require_admin_password
  validate_restore_migration_contract
  validate_restore_provision_contract
  storage_identity="$(postgres_storage_identity "$container")"

  if [[ -e "$state_file" || -L "$state_file" ]]; then
    BOOTSTRAP_RESTORE_CLEANUP_RECOVERY_REQUIRED=true
    read_bootstrap_restore_state "$state_file"
    [[ "$BOOTSTRAP_STATE_DATABASE" == "$DB_NAME" \
        && "$BOOTSTRAP_STATE_BACKUP_SHA256" == "$backup_digest" \
        && "$BOOTSTRAP_STATE_STORAGE_IDENTITY" == "$storage_identity" \
        && "$BOOTSTRAP_STATE_NATIVE_CONFIG_VERSION" == "$receipt_version" \
        && "$BOOTSTRAP_STATE_NATIVE_CONFIG_DIGEST" == "$receipt_digest" \
        && "$BOOTSTRAP_STATE_NATIVE_CONFIG_UPDATED_AT" == "$receipt_updated_at" \
        && "$BOOTSTRAP_STATE_NATIVE_CONFIG_REVISION" == "$receipt_revision" \
        && "$BOOTSTRAP_STATE_WEB_IMAGE" == "$receipt_image" \
        && "$BOOTSTRAP_STATE_TARGET_REVISION" \
          == "${ADDRESS_ATLAS_RESTORE_BUILD_REVISION:-}" \
        && "$BOOTSTRAP_STATE_TARGET_WEB_IMAGE" == "$RESTORE_IMAGE_ID" \
        && "$BOOTSTRAP_STATE_TARGET_PROVISION_IMAGE" \
          == "$RESTORE_PROVISION_IMAGE_ID" \
        && "$BOOTSTRAP_STATE_TARGET_MIGRATION_HEAD" \
          == "$EXPECTED_MIGRATION_HEAD" \
        && "$BOOTSTRAP_STATE_MIGRATION_HOOK_DIGEST" \
          == "$RESTORE_MIGRATION_HOOK_DIGEST" \
        && "$BOOTSTRAP_STATE_PROVISION_HOOK_DIGEST" \
          == "$RESTORE_PROVISION_HOOK_DIGEST" \
        && "$BOOTSTRAP_STATE_PROVISION_SOURCE_DIGEST" \
          == "$RESTORE_PROVISION_SOURCE_DIGEST" \
        && "$BOOTSTRAP_STATE_BOOTSTRAP_SOURCE_DIGEST" \
          == "$RESTORE_BOOTSTRAP_SOURCE_DIGEST" ]] \
      || die "Bootstrap-restore recovery state does not match this cluster and signed artifact." 65
    staging_database="$BOOTSTRAP_STATE_STAGING_DATABASE"
    quarantine_database="$BOOTSTRAP_STATE_QUARANTINE_DATABASE"
    [[ "$BOOTSTRAP_STATE_PHASE" == "staging" ]] \
      || BOOTSTRAP_RESTORE_CLEANUP_ROLES_MAY_BE_PROVISIONED=true
  else
    bootstrap_cluster_is_pristine "$container" \
      || die "Bootstrap restore requires an exact pristine dedicated PostgreSQL cluster." 65
    local bootstrap_timestamp
    bootstrap_timestamp="$(date -u +%Y%m%d%H%M%S)"
    staging_database="atlas_bootstrap_${bootstrap_timestamp}_$$"
    quarantine_database="atlas_bootstrap_empty_${bootstrap_timestamp}_$$"
    validate_identifier "$staging_database" "Bootstrap-restore staging database"
    validate_identifier "$quarantine_database" "Bootstrap-restore quarantine database"
    write_bootstrap_restore_state "$state_file" staging "$DB_NAME" \
      "$backup_digest" "$storage_identity" "$staging_database" \
      "$quarantine_database"
    BOOTSTRAP_STATE_PHASE=staging
    BOOTSTRAP_RESTORE_CLEANUP_RECOVERY_REQUIRED=true
  fi

  if post_bootstrap_cutover_is_valid "$container" "$staging_database" \
      "$quarantine_database"; then
    write_bootstrap_restore_state "$state_file" cutover "$DB_NAME" \
      "$backup_digest" "$storage_identity" "$staging_database" \
      "$quarantine_database"
  elif post_bootstrap_cutover_structure_is_valid "$container" \
      "$staging_database" "$quarantine_database"; then
    BOOTSTRAP_RESTORE_CLEANUP_ROLES_MAY_BE_PROVISIONED=true
    provision_restored_database "$container" "$DB_NAME" restore
    post_bootstrap_cutover_is_valid "$container" "$staging_database" \
      "$quarantine_database" \
      || die "Bootstrap post-cutover runtime recovery failed validation." 74
  else
    if bootstrap_cluster_is_pristine "$container" "$staging_database"; then
      [[ "$BOOTSTRAP_STATE_PHASE" != "provisioned" \
          && "$BOOTSTRAP_STATE_PHASE" != "cutover" \
          && "$BOOTSTRAP_STATE_PHASE" != "awaiting-finalize" \
          && "$BOOTSTRAP_STATE_PHASE" != "finalized" ]] \
        || die "Bootstrap-restore state is ahead of the observed pristine control plane." 74
      bootstrap_owner_dropdb "$container" "$staging_database" >/dev/null \
        || die "Unable to reset the bootstrap staging database." 74
      bootstrap_owner_createdb "$container" "$staging_database"
      bootstrap_database_has_pristine_system_content \
        "$container" "$staging_database" owner \
        || die "Bootstrap staging database inherited non-pristine template content." 65
      decrypt_to_pg_restore "$container" "$source_backup" "$identity" \
        --exit-on-error --no-owner --no-privileges --username "$OWNER_USER" \
        --dbname "$staging_database"
      migrate_restored_database_if_needed "$container" "$staging_database" \
        "$source_migration_head"
      run_restore_checks "$container" "$staging_database" "$OWNER_USER"
      write_bootstrap_restore_state "$state_file" provisioning "$DB_NAME" \
        "$backup_digest" "$storage_identity" "$staging_database" \
        "$quarantine_database"
      BOOTSTRAP_STATE_PHASE=provisioning
      BOOTSTRAP_RESTORE_CLEANUP_ROLES_MAY_BE_PROVISIONED=true
    fi
    if ! post_split_pre_cutover_is_valid "$container" "$staging_database" \
        "$quarantine_database"; then
      [[ "$BOOTSTRAP_STATE_PHASE" == "provisioning" \
          || "$BOOTSTRAP_STATE_PHASE" == "provisioned" \
          || "$BOOTSTRAP_STATE_PHASE" == "cutover" ]] \
        || die "Unexpected control-plane state outside bootstrap provisioning." 74
      if post_split_pre_cutover_structure_is_valid "$container" \
          "$staging_database" "$quarantine_database" \
          || post_split_bridge_pre_cutover_structure_is_valid "$container" \
            "$staging_database" "$quarantine_database"; then
        provision_restored_database "$container" "$staging_database" restore
      elif pre_split_recovery_is_valid "$container" "$staging_database" \
          "$quarantine_database"; then
        provision_restored_database "$container" "$staging_database" bootstrap
      else
        die "Bootstrap provisioning recovery observed an unrecognized control-plane state; role split was refused." 74
      fi
    fi
    post_split_pre_cutover_is_valid "$container" "$staging_database" \
      "$quarantine_database" \
      || die "Bootstrap role split or populated staging validation is ambiguous." 74
    write_bootstrap_restore_state "$state_file" provisioned "$DB_NAME" \
      "$backup_digest" "$storage_identity" "$staging_database" \
      "$quarantine_database"
    assert_web_service_stopped
    write_bootstrap_restore_state "$state_file" cutover "$DB_NAME" \
      "$backup_digest" "$storage_identity" "$staging_database" \
      "$quarantine_database"
    atomic_bootstrap_cutover "$container" "$staging_database" "$DB_NAME" \
      "$quarantine_database" \
      || die "Bootstrap database cutover outcome is ambiguous." 74
    post_bootstrap_cutover_is_valid "$container" "$staging_database" \
      "$quarantine_database" \
      || die "Bootstrap database cutover validation failed." 74
  fi

  write_bootstrap_restore_state "$state_file" awaiting-finalize "$DB_NAME" \
    "$backup_digest" "$storage_identity" "$staging_database" \
    "$quarantine_database"
  BOOTSTRAP_RESTORE_CLEANUP_RESTORE_SUCCEEDED=true
  BOOTSTRAP_RESTORE_CLEANUP_RECOVERY_REQUIRED=false
  cleanup_staging_directory "$source_staging_directory"
  trap - EXIT INT TERM
  printf 'Fresh-cluster bootstrap restore completed for %s; empty database quarantined as %s.\n' \
    "$DB_NAME" "$quarantine_database"
  [[ "$BOOTSTRAP_RESTORE_CLEANUP_OWNS_OPERATION_LOCK" != "true" ]] \
    || printf 'Bootstrap state and operation lock remain until bootstrap-finalize acknowledges public smoke and receipt persistence.\n'
  printf 'BOOTSTRAP_RESTORE_RECEIPT|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$backup_digest" "$receipt_version" "$receipt_digest" \
    "$receipt_updated_at" "$receipt_revision" "$receipt_image" \
    "$DB_NAME" "$storage_identity" "$quarantine_database" \
    "${ADDRESS_ATLAS_RESTORE_BUILD_REVISION:-}" "$RESTORE_IMAGE_ID" \
    "$RESTORE_PROVISION_IMAGE_ID" "$EXPECTED_MIGRATION_HEAD" \
    "$RESTORE_MIGRATION_HOOK_DIGEST" "$RESTORE_PROVISION_HOOK_DIGEST" \
    "$RESTORE_PROVISION_SOURCE_DIGEST" "$RESTORE_BOOTSTRAP_SOURCE_DIGEST"
}

bootstrap_finalize() {
  local confirmation="$1" container
  container="$(resolve_postgres_container)"
  database_context "$container"
  [[ "$confirmation" == "BOOTSTRAP-FINALIZE:${DB_NAME}" ]] \
    || die "Confirmation must exactly equal BOOTSTRAP-FINALIZE:${DB_NAME}." 64
  [[ "${ADDRESS_ATLAS_BOOTSTRAP_FINALIZE_ACK:-}" \
      == "PUBLIC_SMOKE_AND_RECEIPT_PERSISTED" ]] \
    || die "Bootstrap finalize requires public-smoke and durable-receipt acknowledgement." 77
  local expected_backup_sha="${ADDRESS_ATLAS_EXPECTED_BACKUP_SHA256:-}"
  [[ "$expected_backup_sha" =~ ^[0-9a-f]{64}$ ]] \
    || die "ADDRESS_ATLAS_EXPECTED_BACKUP_SHA256 is required for bootstrap finalize." 65
  prepare_backup_directory
  local lock_file="${BACKUP_DIR}/.backup-operation.lock"
  local state_file="${BACKUP_DIR}/.bootstrap-restore.state"
  BOOTSTRAP_FINALIZE_CLEANUP_LOCK_FILE="$lock_file"
  BOOTSTRAP_FINALIZE_CLEANUP_OWNS_OPERATION_LOCK=false
  BOOTSTRAP_FINALIZE_CLEANUP_SUCCEEDED=false
  BOOTSTRAP_FINALIZE_CLEANUP_PARENT_PRESERVATION_SIGNAL=false
  cleanup_bootstrap_finalize() {
    if [[ "$BOOTSTRAP_FINALIZE_CLEANUP_SUCCEEDED" != "true" ]]; then
      if ! preserve_operation_lock_for_recovery \
          "$BOOTSTRAP_FINALIZE_CLEANUP_LOCK_FILE"; then
        [[ -z "${ADDRESS_ATLAS_OPERATION_LOCK_OWNER_PID:-}" ]] \
          || BOOTSTRAP_FINALIZE_CLEANUP_PARENT_PRESERVATION_SIGNAL=true
      fi
    elif [[ "$BOOTSTRAP_FINALIZE_CLEANUP_OWNS_OPERATION_LOCK" == "true" ]]; then
      find "$BOOTSTRAP_FINALIZE_CLEANUP_LOCK_FILE" -maxdepth 0 \
        -type f -delete 2>/dev/null || true
    fi
    if [[ "$BOOTSTRAP_FINALIZE_CLEANUP_PARENT_PRESERVATION_SIGNAL" == "true" ]]; then
      trap - EXIT
      exit 78
    fi
  }
  if [[ -n "${ADDRESS_ATLAS_OPERATION_LOCK_OWNER_PID:-}" ]]; then
    inherited_operation_lock_is_valid "$lock_file"
  else
    acquire_backup_lock "$lock_file"
    BOOTSTRAP_FINALIZE_CLEANUP_OWNS_OPERATION_LOCK=true
  fi
  trap cleanup_bootstrap_finalize EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [[ -f "$state_file" && ! -L "$state_file" ]] \
    || die "No bootstrap-restore recovery state is available to finalize." 66
  read_bootstrap_restore_state "$state_file"
  [[ "$BOOTSTRAP_STATE_DATABASE" == "$DB_NAME" \
      && "$BOOTSTRAP_STATE_BACKUP_SHA256" == "$expected_backup_sha" \
      && ( "$BOOTSTRAP_STATE_PHASE" == "cutover" \
        || "$BOOTSTRAP_STATE_PHASE" == "awaiting-finalize" \
        || "$BOOTSTRAP_STATE_PHASE" == "finalized" ) ]] \
    || die "Bootstrap finalize does not match the completed restore state." 65
  require_admin_password
  validate_restore_migration_contract
  validate_restore_provision_contract
  [[ "$BOOTSTRAP_STATE_TARGET_REVISION" \
        == "${ADDRESS_ATLAS_RESTORE_BUILD_REVISION:-}" \
      && "$BOOTSTRAP_STATE_TARGET_WEB_IMAGE" == "$RESTORE_IMAGE_ID" \
      && "$BOOTSTRAP_STATE_TARGET_PROVISION_IMAGE" \
        == "$RESTORE_PROVISION_IMAGE_ID" \
      && "$BOOTSTRAP_STATE_TARGET_MIGRATION_HEAD" \
        == "$EXPECTED_MIGRATION_HEAD" \
      && "$BOOTSTRAP_STATE_MIGRATION_HOOK_DIGEST" \
        == "$RESTORE_MIGRATION_HOOK_DIGEST" \
      && "$BOOTSTRAP_STATE_PROVISION_HOOK_DIGEST" \
        == "$RESTORE_PROVISION_HOOK_DIGEST" \
      && "$BOOTSTRAP_STATE_PROVISION_SOURCE_DIGEST" \
        == "$RESTORE_PROVISION_SOURCE_DIGEST" \
      && "$BOOTSTRAP_STATE_BOOTSTRAP_SOURCE_DIGEST" \
        == "$RESTORE_BOOTSTRAP_SOURCE_DIGEST" ]] \
    || die "Bootstrap finalize target toolchain differs from the recovered state." 65
  [[ "$(postgres_storage_identity "$container")" \
      == "$BOOTSTRAP_STATE_STORAGE_IDENTITY" ]] \
    || die "Bootstrap finalize storage identity changed." 65
  post_bootstrap_cutover_is_valid "$container" \
    "$BOOTSTRAP_STATE_STAGING_DATABASE" "$BOOTSTRAP_STATE_QUARANTINE_DATABASE" \
    || die "Bootstrap finalize could not verify the exact recovered database state." 74
  MANIFEST_NATIVE_CONFIG_VERSION="$BOOTSTRAP_STATE_NATIVE_CONFIG_VERSION"
  MANIFEST_NATIVE_CONFIG_DIGEST="$BOOTSTRAP_STATE_NATIVE_CONFIG_DIGEST"
  MANIFEST_NATIVE_CONFIG_UPDATED_AT_EPOCH_MS="$BOOTSTRAP_STATE_NATIVE_CONFIG_UPDATED_AT"
  MANIFEST_NATIVE_CONFIG_SERVING_REVISION="$BOOTSTRAP_STATE_NATIVE_CONFIG_REVISION"
  MANIFEST_WEB_IMAGE="$BOOTSTRAP_STATE_WEB_IMAGE"
  write_bootstrap_restore_state "$state_file" finalized "$DB_NAME" \
    "$BOOTSTRAP_STATE_BACKUP_SHA256" "$BOOTSTRAP_STATE_STORAGE_IDENTITY" \
    "$BOOTSTRAP_STATE_STAGING_DATABASE" "$BOOTSTRAP_STATE_QUARANTINE_DATABASE"
  sync_durably "$BACKUP_DIR"
  if [[ "$BOOTSTRAP_FINALIZE_CLEANUP_OWNS_OPERATION_LOCK" == "true" ]]; then
    find "$state_file" -maxdepth 0 -type f -delete \
      || die "Unable to remove finalized bootstrap-restore state." 74
    sync_durably "$BACKUP_DIR"
    BOOTSTRAP_FINALIZE_CLEANUP_SUCCEEDED=true
    find "$lock_file" -maxdepth 0 -type f -delete \
      || die "Unable to release the finalized bootstrap operation lock." 74
    BACKUP_OPERATION_LOCK_HELD=false
    sync_durably "$BACKUP_DIR"
  else
    BOOTSTRAP_FINALIZE_CLEANUP_SUCCEEDED=true
  fi
  trap - EXIT INT TERM
  printf 'Bootstrap restore finalized for %s at artifact %s.\n' \
    "$DB_NAME" "$expected_backup_sha"
}

drill_restore() {
  local backup="$1"
  prepare_backup_directory
  assert_no_unfinished_bootstrap_restore
  local lock_file="${BACKUP_DIR}/.backup-operation.lock"
  DRILL_CLEANUP_LOCK_FILE="$lock_file"
  DRILL_CLEANUP_OWNS_OPERATION_LOCK=false
  DRILL_CLEANUP_CONTAINER=""
  DRILL_CLEANUP_DATABASE=""
  DRILL_CLEANUP_UNCERTAIN=false
  DRILL_CLEANUP_PARENT_PRESERVATION_SIGNAL=false
  local source_staging_directory="${BACKUP_DIR}/.address-atlas-drill-source.$$"
  DRILL_CLEANUP_SOURCE_STAGING_DIRECTORY="$source_staging_directory"
  cleanup_drill() {
    if [[ -n "$DRILL_CLEANUP_CONTAINER" \
        && -n "$DRILL_CLEANUP_DATABASE" \
        && -n "${ADMIN_PASSWORD:-}" ]]; then
      if admin_dropdb "$DRILL_CLEANUP_CONTAINER" \
          "$DRILL_CLEANUP_DATABASE" >/dev/null 2>&1; then
        DRILL_CLEANUP_DATABASE=""
      else
        DRILL_CLEANUP_UNCERTAIN=true
        printf 'CRITICAL Unable to remove the restored drill database; treat it as sensitive production data.\n' >&2
      fi
    fi
    if [[ "$DRILL_CLEANUP_UNCERTAIN" == "true" ]]; then
      if ! preserve_operation_lock_for_recovery "$DRILL_CLEANUP_LOCK_FILE"; then
        printf 'CRITICAL Unable to write the manual-recovery lock marker; do not start another operation.\n' >&2
        [[ -z "${ADDRESS_ATLAS_OPERATION_LOCK_OWNER_PID:-}" ]] \
          || DRILL_CLEANUP_PARENT_PRESERVATION_SIGNAL=true
      fi
    elif [[ "$DRILL_CLEANUP_OWNS_OPERATION_LOCK" == "true" ]]; then
      find "$DRILL_CLEANUP_LOCK_FILE" -maxdepth 0 \
        -type f -delete 2>/dev/null || true
    fi
    cleanup_staging_directory "$DRILL_CLEANUP_SOURCE_STAGING_DIRECTORY"
    if [[ "$DRILL_CLEANUP_PARENT_PRESERVATION_SIGNAL" == "true" ]]; then
      trap - EXIT
      exit 78
    fi
  }
  if [[ -n "${ADDRESS_ATLAS_OPERATION_LOCK_OWNER_PID:-}" ]]; then
    inherited_operation_lock_is_valid "$lock_file"
    BACKUP_OPERATION_LOCK_HELD=true
  else
    acquire_backup_lock "$lock_file"
    BACKUP_OPERATION_LOCK_HELD=true
    DRILL_CLEANUP_OWNS_OPERATION_LOCK=true
  fi
  trap cleanup_drill EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  backup="$(stage_backup_artifacts "$backup" "$source_staging_directory")"
  verify_backup "$backup" >/dev/null
  local source_migration_head="$MANIFEST_MIGRATION_HEAD"
  local identity
  DRILL_CLEANUP_CONTAINER="$(resolve_postgres_container)"
  identity="$(validate_identity_file)"
  database_context "$DRILL_CLEANUP_CONTAINER"
  require_admin_password
  validate_restore_migration_contract
  validate_restore_provision_contract
  assert_admin_and_owner_context "$DRILL_CLEANUP_CONTAINER" "$DB_NAME" true
  DRILL_CLEANUP_DATABASE="atlas_drill_$(date -u +%Y%m%d%H%M%S)_$$"
  validate_identifier "$DRILL_CLEANUP_DATABASE" "Restore-drill database"
  admin_createdb "$DRILL_CLEANUP_CONTAINER" "$DRILL_CLEANUP_DATABASE"
  assert_admin_and_owner_context \
    "$DRILL_CLEANUP_CONTAINER" "$DRILL_CLEANUP_DATABASE" true
  decrypt_to_pg_restore "$DRILL_CLEANUP_CONTAINER" "$backup" "$identity" \
    --exit-on-error --no-owner --no-privileges --username "$DB_USER" \
    --dbname "$DRILL_CLEANUP_DATABASE"
  migrate_restored_database_if_needed "$DRILL_CLEANUP_CONTAINER" \
    "$DRILL_CLEANUP_DATABASE" "$source_migration_head"
  run_restore_checks \
    "$DRILL_CLEANUP_CONTAINER" "$DRILL_CLEANUP_DATABASE" "$DB_USER"
  provision_restored_database \
    "$DRILL_CLEANUP_CONTAINER" "$DRILL_CLEANUP_DATABASE" drill
  admin_dropdb "$DRILL_CLEANUP_CONTAINER" "$DRILL_CLEANUP_DATABASE" >/dev/null \
    || die "Unable to remove the restored drill database safely." 74
  local completed_drill_db="$DRILL_CLEANUP_DATABASE"
  DRILL_CLEANUP_DATABASE=""
  if [[ "$DRILL_CLEANUP_OWNS_OPERATION_LOCK" == "true" ]]; then
    find "$lock_file" -maxdepth 0 -type f -delete
    BACKUP_OPERATION_LOCK_HELD=false
    sync_durably "$BACKUP_DIR"
  fi
  cleanup_staging_directory "$source_staging_directory"
  trap - EXIT INT TERM
  printf 'Restore drill passed in fresh template0 database %s.\n' "$completed_drill_db"
}

atomic_cutover() {
  local container="$1" staging_database="$2" production_database="$3" quarantine_database="$4" sql
  printf -v sql 'SELECT pg_catalog.pg_advisory_xact_lock(1094992974);\nSELECT pg_catalog.pg_terminate_backend(pid) FROM pg_catalog.pg_stat_activity WHERE datname IN ('\''%s'\'', '\''%s'\'') AND pid <> pg_catalog.pg_backend_pid();\nALTER DATABASE "%s" RENAME TO "%s";\nALTER DATABASE "%s" ALLOW_CONNECTIONS false;\nALTER DATABASE "%s" RENAME TO "%s";' \
    "$production_database" "$staging_database" "$production_database" \
    "$quarantine_database" "$quarantine_database" "$staging_database" \
    "$production_database"
  admin_psql "$container" postgres transaction "$sql" >/dev/null
}

rollback_cutover() {
  local container="$1" production_database="$2" quarantine_database="$3" failed_database="$4" sql
  printf -v sql 'SELECT pg_catalog.pg_advisory_xact_lock(1094992974);\nSELECT pg_catalog.pg_terminate_backend(pid) FROM pg_catalog.pg_stat_activity WHERE datname = '\''%s'\'' AND pid <> pg_catalog.pg_backend_pid();\nALTER DATABASE "%s" RENAME TO "%s";\nALTER DATABASE "%s" ALLOW_CONNECTIONS false;\nALTER DATABASE "%s" RENAME TO "%s";\nALTER DATABASE "%s" ALLOW_CONNECTIONS true;' \
    "$production_database" "$production_database" "$failed_database" \
    "$failed_database" "$quarantine_database" "$production_database" \
    "$production_database"
  admin_psql "$container" postgres transaction "$sql" >/dev/null
}

restore_cutover_state() {
  local container="$1" candidate_database="$2" production_database="$3"
  local quarantine_database="$4" result sql
  printf -v sql '%s\n' \
    "WITH target AS (SELECT database.datname, database.datallowconn, owner.rolname AS owner_name FROM pg_catalog.pg_database AS database JOIN pg_catalog.pg_roles AS owner ON owner.oid = database.datdba WHERE database.datname IN ('${candidate_database}', '${production_database}', '${quarantine_database}')) SELECT CASE WHEN 'address_atlas_restore_cutover_state_v1' = 'address_atlas_restore_cutover_state_v1' AND EXISTS (SELECT 1 FROM target WHERE datname = '${production_database}' AND datallowconn AND owner_name = '${OWNER_USER}') AND EXISTS (SELECT 1 FROM target WHERE datname = '${candidate_database}' AND datallowconn AND owner_name = '${OWNER_USER}') AND NOT EXISTS (SELECT 1 FROM target WHERE datname = '${quarantine_database}') AND (SELECT pg_catalog.count(*) FROM target) = 2 THEN 'not-cut-over' WHEN EXISTS (SELECT 1 FROM target WHERE datname = '${production_database}' AND datallowconn AND owner_name = '${OWNER_USER}') AND NOT EXISTS (SELECT 1 FROM target WHERE datname = '${candidate_database}') AND EXISTS (SELECT 1 FROM target WHERE datname = '${quarantine_database}' AND NOT datallowconn AND owner_name = '${OWNER_USER}') AND (SELECT pg_catalog.count(*) FROM target) = 2 THEN 'cut-over' ELSE 'ambiguous' END;"
  result="$(admin_psql "$container" postgres plain "$sql")" || return 1
  [[ "$result" == "not-cut-over" || "$result" == "cut-over" \
      || "$result" == "ambiguous" ]] || return 1
  printf '%s\n' "$result"
}

production_restore() {
  local backup="$1" confirmation="$2" container
  container="$(resolve_postgres_container)"
  PRODUCTION_RESTORE_CLEANUP_CONTAINER="$container"
  database_context "$container"
  [[ "$confirmation" == "RESTORE:${DB_NAME}" ]] \
    || die "Confirmation must exactly equal RESTORE:${DB_NAME}." 64
  [[ "${ADDRESS_ATLAS_ALLOW_PRODUCTION_RESTORE:-}" == "YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED" ]] \
    || die "Production restore authorization environment value is missing." 77
  assert_web_service_stopped
  prepare_backup_directory
  assert_no_unfinished_bootstrap_restore
  local restore_lock_file="${BACKUP_DIR}/.backup-operation.lock"
  PRODUCTION_RESTORE_CLEANUP_LOCK_FILE="$restore_lock_file"
  PRODUCTION_RESTORE_CLEANUP_OWNS_OPERATION_LOCK=false
  if [[ -n "${ADDRESS_ATLAS_OPERATION_LOCK_OWNER_PID:-}" ]]; then
    inherited_operation_lock_is_valid "$restore_lock_file"
  else
    acquire_backup_lock "$restore_lock_file"
    PRODUCTION_RESTORE_CLEANUP_OWNS_OPERATION_LOCK=true
  fi
  BACKUP_OPERATION_LOCK_HELD=true
  local source_staging_directory="${BACKUP_DIR}/.address-atlas-restore-source.$$"
  PRODUCTION_RESTORE_CLEANUP_SOURCE_STAGING_DIRECTORY="$source_staging_directory"
  PRODUCTION_RESTORE_CLEANUP_STAGING_DATABASE=""
  PRODUCTION_RESTORE_CLEANUP_CUTOVER_CANDIDATE_DATABASE=""
  PRODUCTION_RESTORE_CLEANUP_QUARANTINE_DATABASE=""
  PRODUCTION_RESTORE_CLEANUP_FAILED_DATABASE=""
  PRODUCTION_RESTORE_CLEANUP_CUTOVER_ATTEMPTED=false
  PRODUCTION_RESTORE_CLEANUP_SUCCEEDED=false
  PRODUCTION_RESTORE_CLEANUP_RUNTIME_QUIESCED=false
  PRODUCTION_RESTORE_CLEANUP_RUNTIME_LOGIN_RESTORED=false
  PRODUCTION_RESTORE_CLEANUP_RECOVERY_UNCERTAIN=false
  PRODUCTION_RESTORE_CLEANUP_PARENT_PRESERVATION_SIGNAL=false
  cleanup_production_restore() {
    if [[ "$PRODUCTION_RESTORE_CLEANUP_RUNTIME_LOGIN_RESTORED" == "true" \
        && "$PRODUCTION_RESTORE_CLEANUP_SUCCEEDED" != "true" \
        && -n "${ADMIN_PASSWORD:-}" ]]; then
      if force_and_confirm_runtime_nologin \
          "$PRODUCTION_RESTORE_CLEANUP_CONTAINER" >/dev/null 2>&1; then
        PRODUCTION_RESTORE_CLEANUP_RUNTIME_LOGIN_RESTORED=false
      else
        PRODUCTION_RESTORE_CLEANUP_RECOVERY_UNCERTAIN=true
        printf 'CRITICAL The runtime database role could not be proven NOLOGIN after restore failure; keep the web service stopped.\n' >&2
      fi
    fi
    if [[ "$PRODUCTION_RESTORE_CLEANUP_CUTOVER_ATTEMPTED" == "true" \
        && -n "${ADMIN_PASSWORD:-}" \
        && -n "$PRODUCTION_RESTORE_CLEANUP_CUTOVER_CANDIDATE_DATABASE" \
        && -n "$PRODUCTION_RESTORE_CLEANUP_QUARANTINE_DATABASE" \
        && -n "$PRODUCTION_RESTORE_CLEANUP_FAILED_DATABASE" ]]; then
      local observed_cutover_state="ambiguous"
      observed_cutover_state="$(restore_cutover_state \
        "$PRODUCTION_RESTORE_CLEANUP_CONTAINER" \
        "$PRODUCTION_RESTORE_CLEANUP_CUTOVER_CANDIDATE_DATABASE" \
        "$DB_NAME" "$PRODUCTION_RESTORE_CLEANUP_QUARANTINE_DATABASE" \
        2>/dev/null)" \
        || observed_cutover_state="ambiguous"
      case "$observed_cutover_state" in
        not-cut-over)
          PRODUCTION_RESTORE_CLEANUP_CUTOVER_ATTEMPTED=false
          ;;
        cut-over)
          if rollback_cutover "$PRODUCTION_RESTORE_CLEANUP_CONTAINER" \
              "$DB_NAME" "$PRODUCTION_RESTORE_CLEANUP_QUARANTINE_DATABASE" \
              "$PRODUCTION_RESTORE_CLEANUP_FAILED_DATABASE" \
              >/dev/null 2>&1 \
              && run_restore_checks "$PRODUCTION_RESTORE_CLEANUP_CONTAINER" \
                "$DB_NAME" "$DB_USER" >/dev/null 2>&1 \
              && admin_and_owner_context_is_valid \
                "$PRODUCTION_RESTORE_CLEANUP_CONTAINER" "$DB_NAME" false; then
            PRODUCTION_RESTORE_CLEANUP_CUTOVER_ATTEMPTED=false
          else
            PRODUCTION_RESTORE_CLEANUP_RECOVERY_UNCERTAIN=true
            printf 'CRITICAL Automatic restore rollback failed; keep the web service stopped and recover from the safety backup.\n' >&2
          fi
          ;;
        *)
          PRODUCTION_RESTORE_CLEANUP_RECOVERY_UNCERTAIN=true
          printf 'CRITICAL Restore cutover state is ambiguous; keep the web service stopped and recover from the safety backup.\n' >&2
          ;;
      esac
    fi
    if [[ -n "$PRODUCTION_RESTORE_CLEANUP_STAGING_DATABASE" \
        && -n "${ADMIN_PASSWORD:-}" ]]; then
      if admin_dropdb "$PRODUCTION_RESTORE_CLEANUP_CONTAINER" \
          "$PRODUCTION_RESTORE_CLEANUP_STAGING_DATABASE" >/dev/null 2>&1; then
        PRODUCTION_RESTORE_CLEANUP_STAGING_DATABASE=""
      else
        PRODUCTION_RESTORE_CLEANUP_RECOVERY_UNCERTAIN=true
        printf 'CRITICAL Unable to remove the restore staging database; treat it as sensitive production data.\n' >&2
      fi
    fi
    if [[ "$PRODUCTION_RESTORE_CLEANUP_RECOVERY_UNCERTAIN" == "true" ]]; then
      if ! preserve_operation_lock_for_recovery \
          "$PRODUCTION_RESTORE_CLEANUP_LOCK_FILE"; then
        printf 'CRITICAL Unable to write the manual-recovery lock marker; do not start another operation.\n' >&2
        [[ -z "${ADDRESS_ATLAS_OPERATION_LOCK_OWNER_PID:-}" ]] \
          || PRODUCTION_RESTORE_CLEANUP_PARENT_PRESERVATION_SIGNAL=true
      fi
    elif [[ "$PRODUCTION_RESTORE_CLEANUP_OWNS_OPERATION_LOCK" == "true" ]]; then
      find "$PRODUCTION_RESTORE_CLEANUP_LOCK_FILE" -maxdepth 0 \
        -type f -delete 2>/dev/null || true
    fi
    cleanup_staging_directory \
      "$PRODUCTION_RESTORE_CLEANUP_SOURCE_STAGING_DIRECTORY"
    if [[ "$PRODUCTION_RESTORE_CLEANUP_RUNTIME_QUIESCED" == "true" \
        && "$PRODUCTION_RESTORE_CLEANUP_SUCCEEDED" != "true" ]]; then
      if [[ "$PRODUCTION_RESTORE_CLEANUP_RUNTIME_LOGIN_RESTORED" == "true" ]]; then
        printf 'CRITICAL The runtime database role login state is uncertain; keep the web service stopped.\n' >&2
      else
        printf 'WARNING The runtime database role remains NOLOGIN; rerun role provisioning only after recovery is verified.\n' >&2
      fi
    fi
    if [[ "$PRODUCTION_RESTORE_CLEANUP_PARENT_PRESERVATION_SIGNAL" == "true" ]]; then
      trap - EXIT
      exit 78
    fi
  }
  trap cleanup_production_restore EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  backup="$(stage_backup_artifacts "$backup" "$source_staging_directory")"
  verify_backup "$backup" >/dev/null
  local source_migration_head="$MANIFEST_MIGRATION_HEAD"
  require_admin_password
  validate_restore_migration_contract
  validate_restore_provision_contract
  assert_admin_and_owner_context "$container" "$DB_NAME" either
  quiesce_runtime_role "$container"
  assert_web_service_stopped
  local safety_backup
  # Retention is intentionally disabled inside restore so the selected recovery
  # point cannot be deleted while the fresh safety backup is being created.
  safety_backup="$(create_backup true true)"
  printf 'Created and verified pre-restore safety backup: %s\n' "$safety_backup"
  local identity timestamp
  identity="$(validate_identity_file)"
  timestamp="$(date -u +%Y%m%d%H%M%S)"
  PRODUCTION_RESTORE_CLEANUP_STAGING_DATABASE="atlas_restore_${timestamp}_$$"
  PRODUCTION_RESTORE_CLEANUP_CUTOVER_CANDIDATE_DATABASE="$PRODUCTION_RESTORE_CLEANUP_STAGING_DATABASE"
  PRODUCTION_RESTORE_CLEANUP_QUARANTINE_DATABASE="atlas_quarantine_${timestamp}_$$"
  PRODUCTION_RESTORE_CLEANUP_FAILED_DATABASE="atlas_failed_${timestamp}_$$"
  validate_identifier "$PRODUCTION_RESTORE_CLEANUP_STAGING_DATABASE" \
    "Restore staging database"
  validate_identifier "$PRODUCTION_RESTORE_CLEANUP_QUARANTINE_DATABASE" \
    "Restore quarantine database"
  validate_identifier "$PRODUCTION_RESTORE_CLEANUP_FAILED_DATABASE" \
    "Failed restore database"
  admin_createdb \
    "$container" "$PRODUCTION_RESTORE_CLEANUP_STAGING_DATABASE"
  assert_admin_and_owner_context \
    "$container" "$PRODUCTION_RESTORE_CLEANUP_STAGING_DATABASE" false
  decrypt_to_pg_restore "$container" "$backup" "$identity" \
    --exit-on-error --no-owner --no-privileges --username "$DB_USER" \
    --dbname "$PRODUCTION_RESTORE_CLEANUP_STAGING_DATABASE"
  migrate_restored_database_if_needed "$container" \
    "$PRODUCTION_RESTORE_CLEANUP_STAGING_DATABASE" "$source_migration_head"
  run_restore_checks \
    "$container" "$PRODUCTION_RESTORE_CLEANUP_STAGING_DATABASE" "$DB_USER"
  assert_web_service_stopped
  PRODUCTION_RESTORE_CLEANUP_CUTOVER_ATTEMPTED=true
  atomic_cutover "$container" "$PRODUCTION_RESTORE_CLEANUP_STAGING_DATABASE" \
    "$DB_NAME" "$PRODUCTION_RESTORE_CLEANUP_QUARANTINE_DATABASE"
  PRODUCTION_RESTORE_CLEANUP_STAGING_DATABASE=""
  assert_web_service_stopped
  if ! run_restore_checks "$container" "$DB_NAME" "$DB_USER" \
      || ! admin_and_owner_context_is_valid "$container" "$DB_NAME" false; then
    if ! rollback_cutover "$container" "$DB_NAME" \
        "$PRODUCTION_RESTORE_CLEANUP_QUARANTINE_DATABASE" \
        "$PRODUCTION_RESTORE_CLEANUP_FAILED_DATABASE"; then
      die "Post-cutover validation failed and automatic database rollback also failed; keep web stopped and recover from the safety backup." 74
    fi
    PRODUCTION_RESTORE_CLEANUP_CUTOVER_ATTEMPTED=false
    if ! run_restore_checks "$container" "$DB_NAME" "$DB_USER" \
        || ! admin_and_owner_context_is_valid "$container" "$DB_NAME" false; then
      PRODUCTION_RESTORE_CLEANUP_RECOVERY_UNCERTAIN=true
      die "Post-cutover validation failed; the old database name was restored but its validation also failed. Keep web stopped." 74
    fi
    die "Post-cutover validation failed; the previous production database was restored and the failed candidate was quarantined as ${PRODUCTION_RESTORE_CLEANUP_FAILED_DATABASE}." 74
  fi
  # The hook may enable LOGIN as its final transaction step. Mark this before
  # launch so any partial/failing hook is forced back to NOLOGIN by cleanup.
  PRODUCTION_RESTORE_CLEANUP_RUNTIME_LOGIN_RESTORED=true
  provision_restored_database "$container" "$DB_NAME" restore
  PRODUCTION_RESTORE_CLEANUP_SUCCEEDED=true
  PRODUCTION_RESTORE_CLEANUP_CUTOVER_ATTEMPTED=false
  if [[ "$PRODUCTION_RESTORE_CLEANUP_OWNS_OPERATION_LOCK" == "true" ]]; then
    find "$restore_lock_file" -maxdepth 0 -type f -delete
    BACKUP_OPERATION_LOCK_HELD=false
    sync_durably "$BACKUP_DIR"
  fi
  cleanup_staging_directory "$source_staging_directory"
  trap - EXIT INT TERM
  printf 'Production restore completed for %s; previous database quarantined as %s.\n' \
    "$DB_NAME" "$PRODUCTION_RESTORE_CLEANUP_QUARANTINE_DATABASE"
  printf 'Exact database privileges were provisioned and runtime role login was restored.\n'
}

bootstrap_recovery_lock_run() {
  [[ "$#" -ge 2 && "$1" == "--" ]] || usage
  [[ -z "${ADDRESS_ATLAS_OPERATION_LOCK_OWNER_PID:-}" ]] \
    || die "Bootstrap lock reclaim cannot run beneath another operation lock." 75
  [[ "${ADDRESS_ATLAS_ALLOW_BOOTSTRAP_LOCK_RECLAIM:-}" \
      == "YES_I_VERIFIED_STALE_OWNER" ]] \
    || die "Bootstrap lock reclaim authorization is missing." 77
  local expected_backup_sha="${ADDRESS_ATLAS_EXPECTED_BACKUP_SHA256:-}"
  [[ "$expected_backup_sha" =~ ^[0-9a-f]{64}$ ]] \
    || die "ADDRESS_ATLAS_EXPECTED_BACKUP_SHA256 is required for lock reclaim." 65
  prepare_backup_directory
  local state_file="${BACKUP_DIR}/.bootstrap-restore.state"
  local lock_file="${BACKUP_DIR}/.backup-operation.lock"
  local preserve_file="${lock_file}.preserve"
  local claim_file="${BACKUP_DIR}/.bootstrap-lock-reclaim"
  [[ -f "$state_file" && ! -L "$state_file" ]] \
    || die "Bootstrap lock reclaim requires durable recovery state." 66
  read_bootstrap_restore_state "$state_file"
  [[ "$BOOTSTRAP_STATE_BACKUP_SHA256" == "$expected_backup_sha" ]] \
    || die "Bootstrap lock reclaim artifact digest does not match recovery state." 65
  local container
  container="$(resolve_postgres_container)"
  database_context "$container"
  [[ "$BOOTSTRAP_STATE_DATABASE" == "$DB_NAME" ]] \
    || die "Bootstrap lock reclaim target database does not match recovery state." 65
  require_admin_password
  [[ "$(postgres_storage_identity "$container")" \
      == "$BOOTSTRAP_STATE_STORAGE_IDENTITY" ]] \
    || die "Bootstrap lock reclaim storage identity does not match recovery state." 65
  export ADDRESS_ATLAS_BOOTSTRAP_TARGET_REVISION="$BOOTSTRAP_STATE_TARGET_REVISION"
  if [[ -e "$claim_file" || -L "$claim_file" ]]; then
    validate_private_file "$claim_file" "The bootstrap lock-reclaim claim"
    lock_is_live "$claim_file" \
      && die "Another bootstrap lock-reclaim operation is active." 75
    find "$claim_file" -maxdepth 0 -type f -delete \
      || die "Unable to remove a stale bootstrap lock-reclaim claim." 75
  fi
  if [[ -e "$lock_file" || -L "$lock_file" ]]; then
    validate_private_file "$lock_file" "The stale bootstrap operation lock"
    lock_is_live "$lock_file" \
      && die "The bootstrap operation lock still has a live owner." 75
  fi
  if [[ -e "$preserve_file" || -L "$preserve_file" ]]; then
    validate_private_file "$preserve_file" "The bootstrap recovery lock marker"
    [[ "$(< "$preserve_file")" == "manual-recovery-required" ]] \
      || die "Bootstrap recovery lock marker is malformed." 65
  fi
  local claim_candidate="${claim_file}.candidate.$$"
  printf 'pid=%s\nboot=%s\nstart=%s\n' \
    "$$" "$(current_boot_identity)" "$(process_start_identity "$$")" \
    > "$claim_candidate"
  chmod 0600 "$claim_candidate"
  sync_durably "$claim_candidate"
  ln "$claim_candidate" "$claim_file" 2>/dev/null \
    || die "Unable to acquire the bootstrap lock-reclaim claim." 75
  find "$claim_candidate" -maxdepth 0 -type f -delete
  BOOTSTRAP_RECLAIM_CLAIM_FILE="$claim_file"
  BOOTSTRAP_LOCK_RECLAIM_ACTIVE=true
  trap cleanup_bootstrap_reclaim_claim EXIT
  lock_is_live "$lock_file" \
    && die "The bootstrap operation lock became live during reclaim." 75
  if [[ -e "$lock_file" ]]; then
    find "$lock_file" -maxdepth 0 -type f -delete \
      || die "Unable to remove the verified stale bootstrap operation lock." 75
  fi
  if [[ -e "$preserve_file" ]]; then
    find "$preserve_file" -maxdepth 0 -type f -delete \
      || die "Unable to remove the verified bootstrap recovery marker." 75
  fi
  sync_durably "$BACKUP_DIR"
  lock_run "$@"
  local status=$?
  cleanup_bootstrap_reclaim_claim
  return "$status"
}

lock_run() {
  [[ "$#" -ge 2 && "$1" == "--" ]] || usage
  shift
  [[ -z "${ADDRESS_ATLAS_OPERATION_LOCK_OWNER_PID:-}" ]] \
    || die "Nested external operation locks are not supported." 75
  local target="$1"
  [[ "$target" == /* && -f "$target" && -x "$target" && ! -L "$target" ]] \
    || die "lock-run target must be an absolute non-symlink executable file." 65
  validate_trusted_parent_components "$target" "The lock-run target"
  local mode owner permissions current_uid
  mode="$(file_mode "$target")"
  owner="$(file_owner_uid "$target")"
  current_uid="$(id -u)"
  [[ "$mode" =~ ^[0-7]{3,4}$ && "$owner" =~ ^[0-9]+$ ]] \
    || die "Unable to validate lock-run target metadata." 65
  permissions=$((8#$mode))
  [[ "$owner" -eq 0 || "$owner" -eq "$current_uid" ]] \
    || die "lock-run target must be owned by root or the effective user." 65
  (( (permissions & 8#022) == 0 )) \
    || die "lock-run target must not be writable by group or other users." 65
  prepare_backup_directory
  LOCK_RUN_CLEANUP_LOCK_FILE="${BACKUP_DIR}/.backup-operation.lock"
  LOCK_RUN_CLEANUP_CHILD_PID=""
  LOCK_RUN_CLEANUP_CHILD_PGID=""
  LOCK_RUN_CLEANUP_PRESERVE_LOCK=false
  LOCK_RUN_CLEANUP_PENDING_SIGNAL=""
  LOCK_RUN_CLEANUP_OWNER_PID="$$"
  LOCK_RUN_CLEANUP_START_GATE="${BACKUP_DIR}/.lock-run-start.$$"
  acquire_backup_lock "$LOCK_RUN_CLEANUP_LOCK_FILE"
  [[ ! -e "$LOCK_RUN_CLEANUP_START_GATE" \
      && ! -L "$LOCK_RUN_CLEANUP_START_GATE" ]] \
    || die "A stale lock-run start gate exists; the operation was not started." 73
  process_group_is_live() {
    [[ -n "$LOCK_RUN_CLEANUP_CHILD_PGID" ]] \
      && kill -0 -- "-${LOCK_RUN_CLEANUP_CHILD_PGID}" 2>/dev/null
  }
  wait_for_process_group_exit() {
    local attempt
    for attempt in {1..20}; do
      process_group_is_live || return 0
      sleep 0.1
    done
    return 1
  }
  cleanup_lock_run() {
    if [[ "$LOCK_RUN_CLEANUP_PRESERVE_LOCK" != "true" \
        && -n "$LOCK_RUN_CLEANUP_CHILD_PGID" ]] \
        && process_group_is_live; then
      kill -TERM -- "-${LOCK_RUN_CLEANUP_CHILD_PGID}" 2>/dev/null || true
      if ! wait_for_process_group_exit; then
        kill -KILL -- "-${LOCK_RUN_CLEANUP_CHILD_PGID}" 2>/dev/null || true
        wait_for_process_group_exit || LOCK_RUN_CLEANUP_PRESERVE_LOCK=true
      fi
      if [[ "$LOCK_RUN_CLEANUP_PRESERVE_LOCK" != "true" \
          && -n "$LOCK_RUN_CLEANUP_CHILD_PID" ]]; then
        wait "$LOCK_RUN_CLEANUP_CHILD_PID" 2>/dev/null || true
      fi
    fi
    if [[ "$LOCK_RUN_CLEANUP_PRESERVE_LOCK" != "true" ]]; then
      find "$LOCK_RUN_CLEANUP_LOCK_FILE" -maxdepth 0 \
        -type f -delete 2>/dev/null || true
    fi
    [[ ! -d "$LOCK_RUN_CLEANUP_START_GATE" \
        || -L "$LOCK_RUN_CLEANUP_START_GATE" ]] \
      || rmdir "$LOCK_RUN_CLEANUP_START_GATE" 2>/dev/null || true
    cleanup_bootstrap_reclaim_claim
  }
  forward_lock_run_signal() {
    local signal="$1" status="$2"
    trap - INT TERM
    if process_group_is_live; then
      kill -"$signal" -- "-${LOCK_RUN_CLEANUP_CHILD_PGID}" 2>/dev/null || true
      if ! wait_for_process_group_exit; then
        kill -KILL -- "-${LOCK_RUN_CLEANUP_CHILD_PGID}" 2>/dev/null || true
        wait_for_process_group_exit || LOCK_RUN_CLEANUP_PRESERVE_LOCK=true
      fi
      if [[ "$LOCK_RUN_CLEANUP_PRESERVE_LOCK" != "true" \
          && -n "$LOCK_RUN_CLEANUP_CHILD_PID" ]]; then
        wait "$LOCK_RUN_CLEANUP_CHILD_PID" 2>/dev/null || true
      fi
    fi
    LOCK_RUN_CLEANUP_CHILD_PID=""
    LOCK_RUN_CLEANUP_PRESERVE_LOCK=true
    printf 'WARNING lock-run was cancelled; the stale operation lock was preserved until Docker and service state are verified manually.\n' >&2
    exit "$status"
  }
  record_lock_run_startup_signal() {
    LOCK_RUN_CLEANUP_PENDING_SIGNAL="$1"
  }
  trap cleanup_lock_run EXIT
  # A dedicated process group lets cancellation reach the trusted wrapper and
  # every non-daemonized descendant before the global operation lock is freed.
  # The child waits behind an atomic directory gate until the parent has
  # observed that process group, eliminating the fast-exit PID/PGID race.
  trap 'record_lock_run_startup_signal INT' INT
  trap 'record_lock_run_startup_signal TERM' TERM
  set -m
  (
    trap - INT TERM
    while [[ ! -d "$LOCK_RUN_CLEANUP_START_GATE" ]]; do
      kill -0 "$LOCK_RUN_CLEANUP_OWNER_PID" 2>/dev/null || exit 75
      sleep 0.05
    done
    [[ ! -L "$LOCK_RUN_CLEANUP_START_GATE" ]] || exit 75
    export ADDRESS_ATLAS_OPERATION_LOCK_OWNER_PID="$LOCK_RUN_CLEANUP_OWNER_PID"
    exec "$@"
  ) &
  LOCK_RUN_CLEANUP_CHILD_PID=$!
  set +m
  LOCK_RUN_CLEANUP_CHILD_PGID="$LOCK_RUN_CLEANUP_CHILD_PID"
  local observed_child_pgid
  if ! observed_child_pgid="$(ps -o pgid= \
      -p "$LOCK_RUN_CLEANUP_CHILD_PID" 2>/dev/null \
      | tr -d '[:space:]')"; then
    observed_child_pgid=""
  fi
  if [[ "$observed_child_pgid" != "$LOCK_RUN_CLEANUP_CHILD_PID" ]]; then
    LOCK_RUN_CLEANUP_PRESERVE_LOCK=true
    kill -TERM -- "-${LOCK_RUN_CLEANUP_CHILD_PGID}" 2>/dev/null \
      || kill -TERM "$LOCK_RUN_CLEANUP_CHILD_PID" 2>/dev/null || true
    if ! wait_for_process_group_exit; then
      kill -KILL -- "-${LOCK_RUN_CLEANUP_CHILD_PGID}" 2>/dev/null \
        || kill -KILL "$LOCK_RUN_CLEANUP_CHILD_PID" 2>/dev/null || true
      wait_for_process_group_exit || true
    fi
    wait "$LOCK_RUN_CLEANUP_CHILD_PID" 2>/dev/null || true
    LOCK_RUN_CLEANUP_CHILD_PID=""
    die "Unable to prove lock-run process-group isolation; the stale lock was preserved for operator recovery." 75
  fi
  trap 'forward_lock_run_signal INT 130' INT
  trap 'forward_lock_run_signal TERM 143' TERM
  case "$LOCK_RUN_CLEANUP_PENDING_SIGNAL" in
    INT) forward_lock_run_signal INT 130 ;;
    TERM) forward_lock_run_signal TERM 143 ;;
  esac
  if ! mkdir -m 0700 "$LOCK_RUN_CLEANUP_START_GATE"; then
    LOCK_RUN_CLEANUP_PRESERVE_LOCK=true
    kill -TERM -- "-${LOCK_RUN_CLEANUP_CHILD_PGID}" 2>/dev/null || true
    if ! wait_for_process_group_exit; then
      kill -KILL -- "-${LOCK_RUN_CLEANUP_CHILD_PGID}" 2>/dev/null || true
      wait_for_process_group_exit || true
    fi
    wait "$LOCK_RUN_CLEANUP_CHILD_PID" 2>/dev/null || true
    LOCK_RUN_CLEANUP_CHILD_PID=""
    die "Unable to release the trusted child start gate; the stale lock was preserved." 75
  fi
  local child_status
  if wait "$LOCK_RUN_CLEANUP_CHILD_PID"; then
    child_status=0
  else
    child_status=$?
  fi
  LOCK_RUN_CLEANUP_CHILD_PID=""
  if ! wait_for_process_group_exit; then
    LOCK_RUN_CLEANUP_PRESERVE_LOCK=true
    die "A lock-run descendant outlived its trusted parent; the stale lock was preserved for operator recovery." 75
  fi
  if [[ -e "${LOCK_RUN_CLEANUP_LOCK_FILE}.preserve" \
      || -L "${LOCK_RUN_CLEANUP_LOCK_FILE}.preserve" ]]; then
    LOCK_RUN_CLEANUP_PRESERVE_LOCK=true
    die "The child requested manual recovery; the operation lock and recovery marker were preserved." 75
  fi
  if [[ "$child_status" -eq 78 ]]; then
    LOCK_RUN_CLEANUP_PRESERVE_LOCK=true
    die "The child could not persist its recovery marker; the operation lock was preserved." 75
  fi
  local bootstrap_state_file="${BACKUP_DIR}/.bootstrap-restore.state"
  local close_finalized_bootstrap=false
  if [[ -e "$bootstrap_state_file" || -L "$bootstrap_state_file" ]]; then
    read_bootstrap_restore_state "$bootstrap_state_file"
    if [[ "$child_status" -eq 0 && "$BOOTSTRAP_STATE_PHASE" == "finalized" ]]; then
      close_finalized_bootstrap=true
    else
      LOCK_RUN_CLEANUP_PRESERVE_LOCK=true
      preserve_operation_lock_for_recovery "$LOCK_RUN_CLEANUP_LOCK_FILE" \
        || die "An unfinished bootstrap restore exists and its recovery marker could not be written." 75
      die "An unfinished bootstrap restore prevented operation-lock release." 75
    fi
  fi
  if [[ "$close_finalized_bootstrap" == "true" ]]; then
    LOCK_RUN_CLEANUP_PRESERVE_LOCK=true
    find "$bootstrap_state_file" -maxdepth 0 -type f -delete \
      || die "Finalized bootstrap state could not be removed while the operation lock was held." 74
    sync_durably "$BACKUP_DIR"
    LOCK_RUN_CLEANUP_PRESERVE_LOCK=false
  fi
  find "$LOCK_RUN_CLEANUP_LOCK_FILE" -maxdepth 0 -type f -delete \
    || die "Unable to release the completed operation lock." 74
  sync_durably "$BACKUP_DIR"
  cleanup_bootstrap_reclaim_claim
  trap - EXIT INT TERM
  return "$child_status"
}

assert_inherited_operation_lock() {
  [[ -n "${ADDRESS_ATLAS_OPERATION_LOCK_OWNER_PID:-}" ]] \
    || die "No inherited backup operation lock owner was provided." 75
  prepare_backup_directory
  inherited_operation_lock_is_valid "${BACKUP_DIR}/.backup-operation.lock"
  printf 'Validated inherited backup operation lock.\n'
}

[[ "$#" -ge 1 ]] || usage
command="$1"
shift
case "$command" in
  create)
    [[ "$#" -eq 0 ]] || usage
    create_backup
    ;;
  create-predeploy)
    [[ "$#" -eq 0 ]] || usage
    create_predeploy_backup
    ;;
  classify-source)
    [[ "$#" -eq 0 ]] || usage
    classify_source_database
    ;;
  verify)
    [[ "$#" -eq 1 ]] || usage
    verify_external_backup "$1"
    ;;
  inspect)
    [[ "$#" -eq 1 ]] || usage
    inspect_external_backup "$1"
    ;;
  latest)
    [[ "$#" -eq 0 ]] || usage
    latest_backup
    ;;
  drill)
    [[ "$#" -eq 1 ]] || usage
    drill_restore "$1"
    ;;
  restore)
    [[ "$#" -eq 3 && "$2" == "--confirm" ]] || usage
    production_restore "$1" "$3"
    ;;
  bootstrap-restore)
    [[ "$#" -eq 3 && "$2" == "--confirm" ]] || usage
    bootstrap_restore "$1" "$3"
    ;;
  bootstrap-finalize)
    [[ "$#" -eq 2 && "$1" == "--confirm" ]] || usage
    bootstrap_finalize "$2"
    ;;
  bootstrap-lock-run)
    bootstrap_recovery_lock_run "$@"
    ;;
  lock-run)
    lock_run "$@"
    ;;
  assert-lock)
    [[ "$#" -eq 0 ]] || usage
    assert_inherited_operation_lock
    ;;
  *)
    usage
    ;;
esac
