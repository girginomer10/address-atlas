#!/bin/sh
set +x
set -eu

if [ "$#" -ne 4 ]; then
  echo 'Usage: migrate-restored-database.sh <postgres-container> <database> <source-head> <current-head>' >&2
  exit 64
fi

container="$1"
database="$2"
source_head="$3"
current_head="$4"
docker_bin="${DOCKER_BIN:-}"
image="${ADDRESS_ATLAS_RESTORE_IMAGE:-}"
revision="${ADDRESS_ATLAS_RESTORE_BUILD_REVISION:-}"
owner_password="${POSTGRES_PASSWORD:-}"

case "$container" in ''|*[!A-Za-z0-9_.-]*) echo 'Restore PostgreSQL container name is invalid.' >&2; exit 65 ;; esac
case "$database" in ''|*[!A-Za-z0-9_]*) echo 'Restore database name is invalid.' >&2; exit 65 ;; esac
case "$database" in
  atlas_drill_?*|atlas_restore_?*|atlas_bootstrap_?*) ;;
  *) echo 'Restore database name is outside the isolated migration contract.' >&2; exit 65 ;;
esac
case "$source_head:$current_head" in
  *[!0-9:]*|:*|*:) echo 'Restore migration heads are invalid.' >&2; exit 65 ;;
esac
[ "$source_head" -ge 1 ] && [ "$current_head" -ge 1 ] || {
  echo 'Restore migration heads must be positive.' >&2
  exit 65
}
[ "$source_head" -le "$current_head" ] || {
  echo 'Restore source migration head is newer than this build.' >&2
  exit 65
}
case "$docker_bin" in /*) ;; *) echo 'DOCKER_BIN must be an absolute executable path.' >&2; exit 65 ;; esac
[ -x "$docker_bin" ] || { echo 'DOCKER_BIN is not executable.' >&2; exit 69; }
case "$revision" in *[!0-9a-f]*) echo 'Restore build revision is invalid.' >&2; exit 65 ;; esac
[ "${#revision}" -eq 40 ] || { echo 'Restore build revision is invalid.' >&2; exit 65; }
case "$image" in *[!A-Za-z0-9._/:@-]*) echo 'Restore image name is invalid.' >&2; exit 65 ;; esac
case "$image" in
  *:"$revision") ;;
  *) echo 'Restore image tag is not bound to the exact build revision.' >&2; exit 65 ;;
esac
case "$owner_password" in
  ''|*[!A-Za-z0-9_-]*) echo 'Restore owner password is invalid.' >&2; exit 65 ;;
esac
[ "${#owner_password}" -ge 32 ] && [ "${#owner_password}" -le 128 ] || {
  echo 'Restore owner password length is invalid.' >&2
  exit 65
}

metadata="$($docker_bin image inspect --format '{{.Id}}|{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image" 2>/dev/null)" || {
  echo 'Unable to inspect the immutable restore image.' >&2
  exit 69
}
image_id=${metadata%%|*}
image_revision=${metadata#*|}
case "$image_id" in
  sha256:*) image_digest=${image_id#sha256:} ;;
  *) echo 'Restore image ID is malformed.' >&2; exit 67 ;;
esac
case "$image_digest" in *[!0-9a-f]*) echo 'Restore image ID is malformed.' >&2; exit 67 ;; esac
[ "${#image_digest}" -eq 64 ] && [ "$image_revision" = "$revision" ] || {
  echo 'Restore image provenance does not match the requested revision.' >&2
  exit 67
}
[ "$($docker_bin inspect --format '{{.State.Running}}' "$container" 2>/dev/null)" = true ] || {
  echo 'Restore PostgreSQL container is not running.' >&2
  exit 69
}

database_url="postgresql://address_atlas:${owner_password}@127.0.0.1:5432/${database}"
SYNC_SCHEMA_DATABASE_URL="$database_url"
export SYNC_SCHEMA_DATABASE_URL
exec "$docker_bin" run --rm \
  --network "container:${container}" \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=32m \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --env NODE_ENV=production \
  --env SYNC_SCHEMA_MODE=bootstrap \
  --env ADDRESS_ATLAS_RESTORE_MIGRATION=1 \
  --env SYNC_SCHEMA_DATABASE_URL \
  --env SYNC_DB_CONNECT_TIMEOUT_MS=5000 \
  --env SYNC_DB_IDLE_TIMEOUT_MS=30000 \
  --env SYNC_DB_STATEMENT_TIMEOUT_MS=10000 \
  --env SYNC_DB_QUERY_TIMEOUT_MS=12000 \
  "$image_id" node dist/sync-restore.cjs
