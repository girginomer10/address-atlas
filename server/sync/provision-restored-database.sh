#!/bin/sh
set +x
set -eu
umask 077

if [ "$#" -ne 2 ]; then
  echo 'Usage: provision-restored-database.sh <postgres-container> <database>' >&2
  exit 64
fi

container="$1"
database="$2"
docker_bin="${DOCKER_BIN:-}"
image="${ADDRESS_ATLAS_RESTORE_PROVISION_IMAGE:-}"
admin_password="${POSTGRES_ADMIN_PASSWORD:-}"
runtime_password="${POSTGRES_RUNTIME_PASSWORD:-}"
owner_password="${POSTGRES_PASSWORD:-}"
provision_mode="${ADDRESS_ATLAS_RESTORE_PROVISION_MODE:-}"
staging_root="${ADDRESS_ATLAS_RESTORE_STAGING_ROOT:-}"
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
source_script="$script_dir/provision-runtime-role.sh"
bootstrap_source_script="$script_dir/bootstrap-database-roles.sh"

case "$container" in ''|*[!A-Za-z0-9_.-]*) echo 'Restore PostgreSQL container name is invalid.' >&2; exit 65 ;; esac
case "$database" in ''|*[!A-Za-z0-9_]*) echo 'Restore database name is invalid.' >&2; exit 65 ;; esac
case "$docker_bin" in /*) ;; *) echo 'DOCKER_BIN must be an absolute executable path.' >&2; exit 65 ;; esac
[ -x "$docker_bin" ] || { echo 'DOCKER_BIN is not executable.' >&2; exit 69; }
case "$image" in
  postgres:16.14-alpine3.24@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777) ;;
  *) echo 'Restore provision image must equal the reviewed immutable PostgreSQL image.' >&2; exit 65 ;;
esac
for secret_name in POSTGRES_ADMIN_PASSWORD POSTGRES_RUNTIME_PASSWORD; do
  eval "secret_value=\${$secret_name:-}"
  case "$secret_value" in ''|*[!A-Za-z0-9_-]*) echo "$secret_name is invalid." >&2; exit 65 ;; esac
  [ "${#secret_value}" -ge 32 ] && [ "${#secret_value}" -le 128 ] || {
    echo "$secret_name length is invalid." >&2
    exit 65
  }
done
case "$provision_mode" in
  bootstrap) database_role_mode=bootstrap ;;
  drill) database_role_mode=drill ;;
  restore) database_role_mode=restore ;;
  *) echo 'ADDRESS_ATLAS_RESTORE_PROVISION_MODE must be bootstrap, drill, or restore.' >&2; exit 65 ;;
esac
if [ "$provision_mode" = bootstrap ]; then
  case "$owner_password" in ''|*[!A-Za-z0-9_-]*) echo 'POSTGRES_PASSWORD is invalid.' >&2; exit 65 ;; esac
  [ "${#owner_password}" -ge 32 ] && [ "${#owner_password}" -le 128 ] || {
    echo 'POSTGRES_PASSWORD length is invalid.' >&2
    exit 65
  }
fi
case "$staging_root" in
  /*) ;;
  *) echo 'ADDRESS_ATLAS_RESTORE_STAGING_ROOT must be an absolute daemon-visible directory.' >&2; exit 65 ;;
esac
[ "$staging_root" != / ] && [ -d "$staging_root" ] && [ ! -L "$staging_root" ] || {
  echo 'Restore staging root must be an existing non-symlink directory other than root.' >&2
  exit 66
}
canonical_staging_root=$(CDPATH= cd -- "$staging_root" && pwd -P) || exit 66
[ "$canonical_staging_root" = "$staging_root" ] || {
  echo 'Restore staging root must be canonical.' >&2
  exit 66
}
staging_owner=$(stat -c %u "$staging_root" 2>/dev/null || stat -f %u "$staging_root")
staging_mode=$(stat -c %a "$staging_root" 2>/dev/null || stat -f %Lp "$staging_root")
case "$staging_owner:$staging_mode" in
  ''|*[!0-9:]*) echo 'Unable to validate restore staging root metadata.' >&2; exit 66 ;;
esac
staging_permissions=$((0$staging_mode))
[ "$staging_owner" -eq "$(id -u)" ] && [ $((staging_permissions & 077)) -eq 0 ] || {
  echo 'Restore staging root must be operator-owned and private.' >&2
  exit 66
}

file_identity() {
  stat -c '%d:%i:%s:%Y:%Z' "$1" 2>/dev/null \
    || stat -f '%d:%i:%z:%m:%c' "$1" 2>/dev/null
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

[ -f "$source_script" ] && [ ! -L "$source_script" ] || {
  echo 'Canonical restore provision script is unavailable or symbolic.' >&2
  exit 66
}
if [ "$provision_mode" = bootstrap ]; then
  [ -f "$bootstrap_source_script" ] && [ ! -L "$bootstrap_source_script" ] || {
    echo 'Canonical bootstrap role script is unavailable or symbolic.' >&2
    exit 66
  }
fi
source_owner=$(stat -c %u "$source_script" 2>/dev/null || stat -f %u "$source_script")
source_mode=$(stat -c %a "$source_script" 2>/dev/null || stat -f %Lp "$source_script")
case "$source_owner:$source_mode" in
  ''|*[!0-9:]*) echo 'Unable to validate restore provision script metadata.' >&2; exit 66 ;;
esac
source_permissions=$((0$source_mode))
[ "$source_owner" -eq 0 ] || [ "$source_owner" -eq "$(id -u)" ] || {
  echo 'Restore provision script has an untrusted owner.' >&2
  exit 66
}
[ $((source_permissions & 022)) -eq 0 ] || {
  echo 'Restore provision script must not be writable by group or other users.' >&2
  exit 66
}
if [ "$provision_mode" = bootstrap ]; then
  bootstrap_source_owner=$(stat -c %u "$bootstrap_source_script" 2>/dev/null || stat -f %u "$bootstrap_source_script")
  bootstrap_source_mode=$(stat -c %a "$bootstrap_source_script" 2>/dev/null || stat -f %Lp "$bootstrap_source_script")
  case "$bootstrap_source_owner:$bootstrap_source_mode" in
    ''|*[!0-9:]*) echo 'Unable to validate bootstrap role script metadata.' >&2; exit 66 ;;
  esac
  bootstrap_source_permissions=$((0$bootstrap_source_mode))
  [ "$bootstrap_source_owner" -eq 0 ] || [ "$bootstrap_source_owner" -eq "$(id -u)" ] || {
    echo 'Bootstrap role script has an untrusted owner.' >&2
    exit 66
  }
  [ $((bootstrap_source_permissions & 022)) -eq 0 ] || {
    echo 'Bootstrap role script must not be writable by group or other users.' >&2
    exit 66
  }
fi

staging_directory=$(mktemp -d "${staging_root%/}/.address-atlas-restore-provision.XXXXXX") || exit 74
staged_script="$staging_directory/provision-runtime-role.sh"
staged_bootstrap_script="$staging_directory/bootstrap-database-roles.sh"
cleanup() {
  if [ -f "$staged_script" ] && [ ! -L "$staged_script" ]; then
    find "$staged_script" -maxdepth 0 -type f -delete 2>/dev/null || true
  fi
  if [ -f "$staged_bootstrap_script" ] && [ ! -L "$staged_bootstrap_script" ]; then
    find "$staged_bootstrap_script" -maxdepth 0 -type f -delete 2>/dev/null || true
  fi
  if [ -d "$staging_directory" ] && [ ! -L "$staging_directory" ]; then
    rmdir "$staging_directory" 2>/dev/null || true
  fi
}
trap cleanup EXIT HUP INT TERM
chmod 0700 "$staging_directory"
before_identity=$(file_identity "$source_script")
before_digest=$(sha256_file "$source_script")
cp "$source_script" "$staged_script"
chmod 0500 "$staged_script"
after_identity=$(file_identity "$source_script")
after_digest=$(sha256_file "$source_script")
[ "$before_identity" = "$after_identity" ] && [ "$before_digest" = "$after_digest" ] \
  && [ "$(sha256_file "$staged_script")" = "$before_digest" ] || {
  echo 'Canonical restore provision script changed while it was snapshotted.' >&2
    exit 73
}
if [ "$provision_mode" = bootstrap ]; then
  bootstrap_before_identity=$(file_identity "$bootstrap_source_script")
  bootstrap_before_digest=$(sha256_file "$bootstrap_source_script")
  cp "$bootstrap_source_script" "$staged_bootstrap_script"
  chmod 0500 "$staged_bootstrap_script"
  bootstrap_after_identity=$(file_identity "$bootstrap_source_script")
  bootstrap_after_digest=$(sha256_file "$bootstrap_source_script")
  [ "$bootstrap_before_identity" = "$bootstrap_after_identity" ] \
    && [ "$bootstrap_before_digest" = "$bootstrap_after_digest" ] \
    && [ "$(sha256_file "$staged_bootstrap_script")" = "$bootstrap_before_digest" ] || {
      echo 'Canonical bootstrap role script changed while it was snapshotted.' >&2
      exit 73
    }
fi

image_id=$($docker_bin image inspect --format '{{.Id}}' "$image" 2>/dev/null) || {
  echo 'Unable to inspect the immutable restore provision image.' >&2
  exit 69
}
case "$image_id" in sha256:????????????????????????????????????????????????????????????????) ;; *) echo 'Restore provision image ID is malformed.' >&2; exit 67 ;; esac
image_digest=${image_id#sha256:}
case "$image_digest" in *[!0-9a-f]*) echo 'Restore provision image ID is malformed.' >&2; exit 67 ;; esac
[ "$($docker_bin inspect --format '{{.State.Running}}' "$container" 2>/dev/null)" = true ] || {
  echo 'Restore PostgreSQL container is not running.' >&2
  exit 69
}

POSTGRES_ADMIN_PASSWORD="$admin_password"
POSTGRES_RUNTIME_PASSWORD="$runtime_password"
export POSTGRES_ADMIN_PASSWORD POSTGRES_RUNTIME_PASSWORD
if [ "$provision_mode" = bootstrap ]; then
  POSTGRES_PASSWORD="$owner_password"
  export POSTGRES_PASSWORD
fi

exec_status=0
set --
if [ "$provision_mode" = bootstrap ]; then
  set -- --env POSTGRES_PASSWORD \
    --volume "${staged_bootstrap_script}:/opt/address-atlas/bootstrap-database-roles.sh:ro"
fi
$docker_bin run --rm \
  --network "container:${container}" \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=32m \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --env PGHOST=127.0.0.1 \
  --env "POSTGRES_DB=${database}" \
  --env "ADDRESS_ATLAS_DATABASE_ROLE_MODE=${database_role_mode}" \
  --env POSTGRES_ADMIN_PASSWORD \
  --env POSTGRES_RUNTIME_PASSWORD \
  "$@" \
  --volume "${staged_script}:/opt/address-atlas/provision-runtime-role.sh:ro" \
  "$image_id" /bin/sh /opt/address-atlas/provision-runtime-role.sh || exec_status=$?
[ "$exec_status" -eq 0 ] || exit "$exec_status"

trap - EXIT HUP INT TERM
cleanup
