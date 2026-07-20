#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "${script_dir}/../.." && pwd)
provision_script="${script_dir}/provision-runtime-role.sh"

if [[ -n "${POSTGRES_BIN_DIR:-}" ]]; then
  postgres_bin_dir="$POSTGRES_BIN_DIR"
elif [[ -x /opt/homebrew/opt/postgresql@16/bin/postgres ]]; then
  postgres_bin_dir=/opt/homebrew/opt/postgresql@16/bin
elif command -v pg_config >/dev/null 2>&1 \
  && pg_config --version | grep -Eq '^PostgreSQL 16\.'; then
  postgres_bin_dir=$(pg_config --bindir)
else
  echo 'PostgreSQL 16 server binaries are required for database-role-tests.sh.' >&2
  exit 77
fi

for utility in initdb pg_ctl createdb psql postgres; do
  if [[ ! -x "${postgres_bin_dir}/${utility}" ]]; then
    echo "Missing PostgreSQL 16 utility: ${postgres_bin_dir}/${utility}" >&2
    exit 77
  fi
done
if ! "${postgres_bin_dir}/postgres" --version | grep -Eq '^postgres \(PostgreSQL\) 16\.'; then
  echo 'database-role-tests.sh refuses to run against a non-PostgreSQL-16 server.' >&2
  exit 77
fi

if [[ ! -x "$provision_script" ]]; then
  echo "Provision script is not executable: ${provision_script}" >&2
  exit 1
fi

umask 077
test_root=$(mktemp -d "${TMPDIR:-/tmp}/address-atlas-role-tests.XXXXXX")
socket_dir="${test_root}/socket"
mkdir -p "$socket_dir"

if [[ -n "${DATABASE_ROLE_TEST_PORT:-}" ]]; then
  test_port="$DATABASE_ROLE_TEST_PORT"
elif command -v python3 >/dev/null 2>&1; then
  test_port=$(python3 - <<'PY'
import socket
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
)
else
  test_port=$((55000 + ($$ % 1000)))
fi

database_name=address_atlas_sync
owner_password='OwnerBootstrapSecret_7Gm2Qv9Lx4Np8Yk6'
admin_password_a='AdminControlSecret_4Fx8Lm2Qs7Vz9Tr5'
admin_password_b='AdminRotatedSecret_9Hw3Kp6Jx8Nc2Vm7'
runtime_password_a='RuntimeServiceSecret_3Ld8Qw5Nz7Rx2Km9'
runtime_password_b='RuntimeRotatedSecret_8Jq2Vn6Gy4Ws9Pc3'
wrong_admin_password='WrongAdminCredential_2Qx7Nv4Ls8Jm5Tk9'
active_data_dir=''

cleanup() {
  if [[ -n "$active_data_dir" && -f "${active_data_dir}/postmaster.pid" ]]; then
    "${postgres_bin_dir}/pg_ctl" -D "$active_data_dir" -m immediate -w stop >/dev/null 2>&1 || true
  fi
  rm -rf "$test_root"
}
trap cleanup EXIT INT TERM

start_cluster() {
  local name="$1"
  local password_file="${test_root}/${name}.pw"
  active_data_dir="${test_root}/${name}-data"
  printf '%s\n' "$owner_password" >"$password_file"
  "${postgres_bin_dir}/initdb" \
    -D "$active_data_dir" \
    --username=address_atlas \
    --pwfile="$password_file" \
    --auth-host=scram-sha-256 \
    --auth-local=trust \
    --encoding=UTF8 \
    --no-locale \
    --no-sync >/dev/null
  rm -f "$password_file"
  "${postgres_bin_dir}/pg_ctl" \
    -D "$active_data_dir" \
    -o "-F -p ${test_port} -h 127.0.0.1 -k ${socket_dir} -c password_encryption=scram-sha-256 -c ssl=off" \
    -w start >/dev/null
  PGPASSWORD="$owner_password" "${postgres_bin_dir}/createdb" \
    -h 127.0.0.1 -p "$test_port" -U address_atlas "$database_name"
}

stop_cluster() {
  "${postgres_bin_dir}/pg_ctl" -D "$active_data_dir" -m fast -w stop >/dev/null
  active_data_dir=''
}

owner_psql() {
  PGPASSWORD="$owner_password" "${postgres_bin_dir}/psql" \
    -X -v ON_ERROR_STOP=1 -q \
    -h 127.0.0.1 -p "$test_port" -U address_atlas -d "$database_name" "$@"
}

admin_psql() {
  local password="$1"
  shift
  PGPASSWORD="$password" "${postgres_bin_dir}/psql" \
    -X -v ON_ERROR_STOP=1 -q \
    -h 127.0.0.1 -p "$test_port" -U address_atlas_admin -d "$database_name" "$@"
}

runtime_psql() {
  local password="$1"
  shift
  PGPASSWORD="$password" "${postgres_bin_dir}/psql" \
    -X -v ON_ERROR_STOP=1 -q \
    -h 127.0.0.1 -p "$test_port" -U address_atlas_runtime -d "$database_name" "$@"
}

role_password_verifiers() {
  local password="$1"
  admin_psql "$password" -Atc \
    "SELECT rolname || '|' || rolpassword FROM pg_catalog.pg_authid WHERE rolname IN ('address_atlas_admin', 'address_atlas_runtime') ORDER BY rolname"
}

bootstrap_schema() {
  (
    cd "$repo_root"
    NODE_ENV=production \
      SYNC_SCHEMA_MODE=bootstrap \
      SYNC_SCHEMA_DATABASE_URL="postgresql://address_atlas:${owner_password}@127.0.0.1:${test_port}/${database_name}" \
      npm run --silent sync:schema:bootstrap
  )
}

provision_roles() {
  local mode="$1"
  local current_admin_password="$2"
  local desired_admin_password="$3"
  local desired_runtime_password="$4"
  env \
    ADDRESS_ATLAS_DATABASE_ROLE_MODE="$mode" \
    PGHOST=127.0.0.1 \
    PGPORT="$test_port" \
    POSTGRES_DB="$database_name" \
    POSTGRES_PASSWORD="$owner_password" \
    POSTGRES_ADMIN_CURRENT_PASSWORD="$current_admin_password" \
    POSTGRES_ADMIN_PASSWORD="$desired_admin_password" \
    POSTGRES_RUNTIME_PASSWORD="$desired_runtime_password" \
    PSQL_BIN="${postgres_bin_dir}/psql" \
    "$provision_script"
}

expect_auth_failure() {
  local role="$1"
  local password="$2"
  if PGPASSWORD="$password" "${postgres_bin_dir}/psql" \
      -X -v ON_ERROR_STOP=1 -qAt \
      -h 127.0.0.1 -p "$test_port" -U "$role" -d "$database_name" \
      -c 'SELECT 1' >/dev/null 2>&1; then
    echo "Expected authentication to fail for ${role}." >&2
    exit 1
  fi
}

assert_catalog_contract() {
  local admin_password="$1"
  admin_psql "$admin_password" <<'SQL'
DO $test$
DECLARE
  owner_oid oid;
  admin_oid oid;
  runtime_oid oid;
  schema_oid oid;
BEGIN
  IF current_setting('server_version_num')::integer < 160000
     OR current_setting('server_version_num')::integer >= 170000 THEN
    RAISE EXCEPTION 'test is not running on PostgreSQL 16';
  END IF;

  SELECT oid INTO owner_oid FROM pg_catalog.pg_roles WHERE rolname = 'address_atlas';
  SELECT oid INTO admin_oid FROM pg_catalog.pg_roles WHERE rolname = 'address_atlas_admin';
  SELECT oid INTO runtime_oid FROM pg_catalog.pg_roles WHERE rolname = 'address_atlas_runtime';
  SELECT oid INTO schema_oid FROM pg_catalog.pg_namespace WHERE nspname = 'public';

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_roles
    WHERE rolname = 'address_atlas'
      AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls
           OR rolinherit OR NOT rolcanlogin OR rolconnlimit <> -1)
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.pg_roles
    WHERE rolname = 'address_atlas_admin'
      AND (NOT rolsuper OR rolcreatedb OR NOT rolcreaterole OR rolreplication OR rolbypassrls
           OR rolinherit OR NOT rolcanlogin OR rolconnlimit <> -1)
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.pg_roles
    WHERE rolname = 'address_atlas_runtime'
      AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls
           OR rolinherit OR NOT rolcanlogin OR rolconnlimit <> -1)
  ) THEN
    RAISE EXCEPTION 'role attributes differ from the independent test contract';
  END IF;

  IF (SELECT count(*) FROM pg_catalog.pg_roles
      WHERE rolname IN ('address_atlas', 'address_atlas_admin', 'address_atlas_runtime')) <> 3
     OR EXISTS (
       SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'address_atlas_role_bridge'
     )
     OR EXISTS (
       SELECT 1
       FROM pg_catalog.pg_auth_members AS edge
       JOIN pg_catalog.pg_roles AS granted ON granted.oid = edge.roleid
       JOIN pg_catalog.pg_roles AS member ON member.oid = edge.member
       WHERE granted.rolname IN ('address_atlas', 'address_atlas_admin', 'address_atlas_runtime')
          OR member.rolname IN ('address_atlas', 'address_atlas_admin', 'address_atlas_runtime')
     ) THEN
    RAISE EXCEPTION 'protected role set or memberships differ';
  END IF;

  IF (SELECT datdba FROM pg_catalog.pg_database WHERE datname = current_database()) <> owner_oid
     OR (SELECT nspowner FROM pg_catalog.pg_namespace WHERE nspname = 'public') <> owner_oid
     OR EXISTS (
       SELECT 1 FROM pg_catalog.pg_class AS relation
       JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
       WHERE namespace.nspname = 'public'
         AND relation.relkind IN ('r', 'p', 'v', 'm', 'S', 'f', 'i', 'I')
         AND relation.relowner <> owner_oid
     ) OR EXISTS (
       SELECT 1 FROM pg_catalog.pg_proc
       WHERE pronamespace = schema_oid AND proowner <> owner_oid
     ) OR EXISTS (
       SELECT 1
       FROM pg_catalog.pg_type AS item
       LEFT JOIN pg_catalog.pg_class AS relation ON relation.oid = item.typrelid
       WHERE item.typnamespace = schema_oid
         AND (item.typtype IN ('d', 'e', 'r', 'm')
              OR (item.typtype = 'c' AND relation.relkind = 'c'))
         AND item.typowner <> owner_oid
     ) THEN
    RAISE EXCEPTION 'object ownership differs';
  END IF;

  IF EXISTS (
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
    ), actual AS (
      SELECT table_name, privilege_type
      FROM information_schema.table_privileges
      WHERE table_schema = 'public' AND grantee = 'address_atlas_runtime'
    )
    SELECT 1 FROM (
      (SELECT * FROM actual EXCEPT SELECT * FROM expected)
      UNION ALL
      (SELECT * FROM expected EXCEPT SELECT * FROM actual)
    ) AS difference
  ) THEN
    RAISE EXCEPTION 'runtime grants are not exact';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.table_privileges
    WHERE table_schema = 'public' AND grantee IN ('PUBLIC', 'address_atlas_admin')
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class AS relation
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
    CROSS JOIN LATERAL pg_catalog.aclexplode(
      COALESCE(relation.relacl, pg_catalog.acldefault('S', relation.relowner))
    ) AS grant_row
    WHERE namespace.nspname = 'public'
      AND relation.relkind = 'S'
      AND (grant_row.grantee = 0 OR grant_row.grantee IN (
        SELECT oid FROM pg_catalog.pg_roles
        WHERE rolname IN ('address_atlas_admin', 'address_atlas_runtime')
      ))
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS routine
    CROSS JOIN LATERAL pg_catalog.aclexplode(
      COALESCE(routine.proacl, pg_catalog.acldefault('f', routine.proowner))
    ) AS grant_row
    WHERE routine.pronamespace = schema_oid
      AND (grant_row.grantee = 0 OR grant_row.grantee IN (
        SELECT oid FROM pg_catalog.pg_roles
        WHERE rolname IN ('address_atlas_admin', 'address_atlas_runtime')
      ))
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.pg_type AS item
    LEFT JOIN pg_catalog.pg_class AS relation ON relation.oid = item.typrelid
    CROSS JOIN LATERAL pg_catalog.aclexplode(
      COALESCE(item.typacl, pg_catalog.acldefault('T', item.typowner))
    ) AS grant_row
    WHERE item.typnamespace = schema_oid
      AND (item.typtype IN ('d', 'e', 'r', 'm')
           OR (item.typtype = 'c' AND relation.relkind = 'c'))
      AND (grant_row.grantee = 0 OR grant_row.grantee IN (
        SELECT oid FROM pg_catalog.pg_roles
        WHERE rolname IN ('address_atlas_admin', 'address_atlas_runtime')
      ))
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.pg_default_acl AS defaults
    CROSS JOIN LATERAL pg_catalog.aclexplode(defaults.defaclacl) AS grant_row
    WHERE defaults.defaclrole IN (owner_oid, admin_oid)
      AND (defaults.defaclnamespace = 0 OR defaults.defaclnamespace = schema_oid)
      AND (
        grant_row.grantee = 0
        OR (defaults.defaclrole = owner_oid AND grant_row.grantee IN (admin_oid, runtime_oid))
        OR (defaults.defaclrole = admin_oid AND grant_row.grantee IN (owner_oid, runtime_oid))
      )
  ) OR EXISTS (
    SELECT required.role_oid, required.object_type
    FROM (VALUES
      (owner_oid, 'f'::"char"), (owner_oid, 'T'::"char"),
      (admin_oid, 'f'::"char"), (admin_oid, 'T'::"char")
    ) AS required(role_oid, object_type)
    WHERE NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_default_acl AS defaults
      WHERE defaults.defaclrole = required.role_oid
        AND defaults.defaclnamespace = 0
        AND defaults.defaclobjtype = required.object_type
    )
  ) THEN
    RAISE EXCEPTION 'ambient table, routine, or default grants remain';
  END IF;

  IF NOT pg_catalog.has_database_privilege('address_atlas_runtime', current_database(), 'CONNECT')
     OR pg_catalog.has_database_privilege('address_atlas_runtime', current_database(), 'CREATE')
     OR pg_catalog.has_database_privilege('address_atlas_runtime', current_database(), 'TEMPORARY')
     OR NOT pg_catalog.has_schema_privilege('address_atlas_runtime', 'public', 'USAGE')
     OR pg_catalog.has_schema_privilege('address_atlas_runtime', 'public', 'CREATE')
     OR pg_catalog.has_function_privilege(
       'address_atlas_runtime',
       'public.address_atlas_decrement_snapshot_usage()',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'runtime effective privilege boundary differs';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_authid
    WHERE rolname IN ('address_atlas_admin', 'address_atlas_runtime')
      AND rolpassword NOT LIKE 'SCRAM-SHA-256$%'
  ) THEN
    RAISE EXCEPTION 'role passwords are not SCRAM verifiers';
  END IF;
END
$test$;
SQL
}

assert_runtime_behavior() {
  local runtime_password="$1"
  runtime_psql "$runtime_password" <<'SQL'
BEGIN;

SELECT version, name, checksum FROM sync_schema_migrations ORDER BY version;

INSERT INTO users (id) VALUES ('00000000-0000-4000-8000-000000000101')
ON CONFLICT (id) DO NOTHING;
SELECT count(*) FROM users WHERE id = '00000000-0000-4000-8000-000000000101';
SELECT id FROM users WHERE id = '00000000-0000-4000-8000-000000000101' FOR UPDATE;

INSERT INTO passkey_credentials (id, user_id, public_key_base64url, counter)
VALUES ('role-smoke-credential', '00000000-0000-4000-8000-000000000101', 'AQID', 0)
ON CONFLICT (id) DO NOTHING;
SELECT counter FROM passkey_credentials WHERE id = 'role-smoke-credential' FOR UPDATE;
UPDATE passkey_credentials SET counter = 1, updated_at = now()
WHERE id = 'role-smoke-credential';

DELETE FROM consumed_challenges WHERE consumed_at < now() - interval '15 minutes';
INSERT INTO consumed_challenges (challenge) VALUES ('role-smoke-challenge')
ON CONFLICT (challenge) DO NOTHING;
SELECT challenge FROM consumed_challenges WHERE challenge = 'role-smoke-challenge';

WITH pruned AS (
  DELETE FROM registration_usage WHERE window_started_at < now() - interval '48 hours'
)
INSERT INTO registration_usage (window_started_at, admission_count)
VALUES (date_trunc('hour', now()), 1)
ON CONFLICT (window_started_at) DO UPDATE SET
  admission_count = registration_usage.admission_count + 1,
  updated_at = now()
WHERE registration_usage.admission_count < 10
RETURNING admission_count;

WITH pruned AS (
  DELETE FROM session_grants
  WHERE ctid IN (
    SELECT ctid FROM session_grants
    WHERE expires_at <= now()
    ORDER BY expires_at FOR UPDATE SKIP LOCKED LIMIT 1000
  )
)
INSERT INTO session_grants (id, user_id, expires_at)
VALUES (
  '00000000-0000-4000-8000-000000000102',
  '00000000-0000-4000-8000-000000000101',
  now() + interval '1 hour'
);
SELECT id FROM session_grants
WHERE id = '00000000-0000-4000-8000-000000000102';

INSERT INTO vault_global_ingress_usage (usage_date, byte_count)
VALUES ((now() AT TIME ZONE 'UTC')::date, 9)
ON CONFLICT (usage_date) DO UPDATE SET
  byte_count = vault_global_ingress_usage.byte_count + excluded.byte_count,
  updated_at = now()
WHERE vault_global_ingress_usage.byte_count + excluded.byte_count <= 1000
RETURNING byte_count;

INSERT INTO vault_write_usage (user_id, usage_date, write_count, byte_count)
VALUES ('00000000-0000-4000-8000-000000000101', (now() AT TIME ZONE 'UTC')::date, 1, 9)
ON CONFLICT (user_id, usage_date) DO UPDATE SET
  write_count = vault_write_usage.write_count + 1,
  byte_count = vault_write_usage.byte_count + excluded.byte_count,
  updated_at = now()
WHERE vault_write_usage.write_count + 1 <= 100
RETURNING write_count, byte_count;

DELETE FROM vault_write_usage
WHERE ctid IN (
  SELECT ctid FROM vault_write_usage
  WHERE usage_date < (now() AT TIME ZONE 'UTC')::date - 35
  ORDER BY usage_date FOR UPDATE SKIP LOCKED LIMIT 10000
);
DELETE FROM vault_global_ingress_usage
WHERE usage_date < (now() AT TIME ZONE 'UTC')::date - 35;

SELECT total_snapshot_bytes FROM sync_storage_usage WHERE singleton = true FOR UPDATE;
UPDATE sync_storage_usage
SET total_snapshot_bytes = total_snapshot_bytes + 9, updated_at = now()
WHERE singleton = true
RETURNING total_snapshot_bytes;

INSERT INTO vault_snapshots (user_id, version, envelope, byte_size, checksum)
VALUES (
  '00000000-0000-4000-8000-000000000101',
  1,
  '{"ciphertext":"smoke"}'::jsonb,
  9,
  'role-smoke-checksum'
)
ON CONFLICT (user_id) DO UPDATE SET
  version = excluded.version + 1,
  envelope = excluded.envelope,
  byte_size = excluded.byte_size,
  checksum = excluded.checksum,
  updated_at = now()
WHERE vault_snapshots.version <= excluded.version
RETURNING version;
SELECT version, checksum FROM vault_snapshots
WHERE user_id = '00000000-0000-4000-8000-000000000101' FOR UPDATE;

INSERT INTO account_deletion_receipts (idempotency_key_digest)
VALUES (decode(repeat('ab', 32), 'hex'))
ON CONFLICT (idempotency_key_digest) DO NOTHING
RETURNING idempotency_key_digest;
SELECT created_at FROM account_deletion_receipts
WHERE idempotency_key_digest = decode(repeat('ab', 32), 'hex');

-- Cascades must be usable without direct DELETE on child tables. The
-- SECURITY INVOKER accounting trigger must also work without a public EXECUTE
-- grant because the runtime has only the table UPDATE privilege it needs.
DELETE FROM users
WHERE id = '00000000-0000-4000-8000-000000000101'
RETURNING id;
DO $assertions$
BEGIN
  IF EXISTS (
    SELECT 1 FROM vault_snapshots
    WHERE user_id = '00000000-0000-4000-8000-000000000101'
  ) OR EXISTS (
    SELECT 1 FROM session_grants
    WHERE user_id = '00000000-0000-4000-8000-000000000101'
  ) OR EXISTS (
    SELECT 1 FROM vault_write_usage
    WHERE user_id = '00000000-0000-4000-8000-000000000101'
  ) OR (SELECT total_snapshot_bytes FROM sync_storage_usage WHERE singleton = true) <> 0 THEN
    RAISE EXCEPTION 'runtime cascade or accounting trigger smoke failed';
  END IF;
END
$assertions$;

ROLLBACK;
SQL
}

expect_runtime_denied() {
  local runtime_password="$1"
  local statement="$2"
  if runtime_psql "$runtime_password" -c "$statement" >/dev/null 2>&1; then
    echo "Runtime statement unexpectedly succeeded: ${statement}" >&2
    exit 1
  fi
}

assert_runtime_denials() {
  local runtime_password="$1"
  expect_runtime_denied "$runtime_password" \
    "UPDATE account_deletion_receipts SET created_at = now()"
  expect_runtime_denied "$runtime_password" \
    "DELETE FROM account_deletion_receipts"
  expect_runtime_denied "$runtime_password" \
    "DELETE FROM vault_snapshots"
  expect_runtime_denied "$runtime_password" \
    "DELETE FROM passkey_credentials"
  expect_runtime_denied "$runtime_password" \
    "INSERT INTO sync_schema_migrations (version, name, checksum) VALUES (99, 'forbidden', repeat('a', 64))"
  expect_runtime_denied "$runtime_password" \
    "TRUNCATE users"
  expect_runtime_denied "$runtime_password" \
    "CREATE TABLE public.forbidden_runtime_table (id integer)"
  expect_runtime_denied "$runtime_password" \
    "CREATE TEMP TABLE forbidden_runtime_temp (id integer)"
  if runtime_psql "$runtime_password" -Atc \
      "SELECT to_regclass('public.role_test_sequence') IS NOT NULL" | grep -qx 't'; then
    expect_runtime_denied "$runtime_password" \
      "SELECT nextval('public.role_test_sequence')"
    expect_runtime_denied "$runtime_password" \
      "SELECT public.role_test_function()"
  fi
}

echo 'database-role-tests: fresh PostgreSQL 16 bootstrap'
start_cluster fresh
bootstrap_schema
owner_psql <<'SQL'
CREATE SEQUENCE role_test_sequence;
CREATE TYPE role_test_enum AS ENUM ('alpha', 'beta');
CREATE DOMAIN role_test_domain AS text CHECK (length(VALUE) <= 20);
CREATE FUNCTION role_test_function() RETURNS integer
LANGUAGE sql IMMUTABLE AS 'SELECT 1';
GRANT ALL PRIVILEGES ON SEQUENCE role_test_sequence TO PUBLIC;
GRANT EXECUTE ON FUNCTION role_test_function() TO PUBLIC;
GRANT USAGE ON TYPE role_test_enum TO PUBLIC;
GRANT USAGE ON DOMAIN role_test_domain TO PUBLIC;
SQL
provision_roles bootstrap "$admin_password_a" "$admin_password_a" "$runtime_password_a"
# The renamed bootstrap superuser is no longer the schema credential. Prove
# that the newly created, non-superuser owner retained the historical password
# and can execute the next deployment's no-op schema bootstrap.
bootstrap_schema
assert_catalog_contract "$admin_password_a"
assert_runtime_behavior "$runtime_password_a"
assert_runtime_denials "$runtime_password_a"

echo 'database-role-tests: implicit credential rotation is refused and steady provisioning is idempotent'
if provision_roles steady "$admin_password_a" "$admin_password_b" "$runtime_password_a" \
    >/dev/null 2>&1; then
  echo 'Steady provisioning unexpectedly rotated the admin credential.' >&2
  exit 1
fi
if provision_roles steady "$admin_password_a" "$admin_password_a" "$runtime_password_b" \
    >/dev/null 2>&1; then
  echo 'Steady provisioning unexpectedly rotated the runtime credential.' >&2
  exit 1
fi
admin_psql "$admin_password_a" -Atc 'SELECT 1' | grep -qx '1'
runtime_psql "$runtime_password_a" -Atc 'SELECT 1' | grep -qx '1'
expect_auth_failure address_atlas_admin "$admin_password_b"
expect_auth_failure address_atlas_runtime "$runtime_password_b"
admin_psql "$admin_password_a" <<'SQL'
CREATE ROLE address_atlas_role_bridge
  WITH LOGIN SUPERUSER NOCREATEDB CREATEROLE NOREPLICATION NOBYPASSRLS
  NOINHERIT CONNECTION LIMIT -1;
SQL
provision_roles steady "$admin_password_a" "$admin_password_a" "$runtime_password_a"
assert_catalog_contract "$admin_password_a"
assert_runtime_behavior "$runtime_password_a"

echo 'database-role-tests: steady and drill convergence preserve global password verifiers'
verifiers_before="$(role_password_verifiers "$admin_password_a")"
provision_roles steady "$admin_password_a" "$admin_password_a" "$runtime_password_a"
verifiers_after_steady="$(role_password_verifiers "$admin_password_a")"
[[ "$verifiers_after_steady" == "$verifiers_before" ]] || {
  echo 'Steady provisioning unexpectedly rewrote a global password verifier.' >&2
  exit 1
}
provision_roles drill "$admin_password_a" "$admin_password_a" "$runtime_password_a"
verifiers_after_drill="$(role_password_verifiers "$admin_password_a")"
[[ "$verifiers_after_drill" == "$verifiers_before" ]] || {
  echo 'Restore drill provisioning unexpectedly rewrote a global password verifier.' >&2
  exit 1
}
assert_catalog_contract "$admin_password_a"
assert_runtime_behavior "$runtime_password_a"

echo 'database-role-tests: invalid admin credential cannot fall back to owner'
if provision_roles steady "$wrong_admin_password" "$wrong_admin_password" "$runtime_password_a" \
    >/dev/null 2>&1; then
  echo 'Steady provisioning unexpectedly accepted a bad admin credential.' >&2
  exit 1
fi
admin_psql "$admin_password_a" -Atc 'SELECT 1' | grep -qx '1'
stop_cluster

echo 'database-role-tests: recognized six-table legacy upgrade'
start_cluster legacy
bootstrap_schema
owner_psql <<'SQL'
DROP TABLE account_deletion_receipts;
DROP TABLE registration_usage;
DROP TABLE session_grants;
DROP TABLE vault_global_ingress_usage;
DROP TABLE sync_schema_migrations;
SQL
bootstrap_schema
owner_psql <<'SQL'
CREATE ROLE address_atlas_runtime LOGIN INHERIT PASSWORD 'legacy-runtime-password';
CREATE ROLE legacy_runtime_parent NOLOGIN;
GRANT legacy_runtime_parent TO address_atlas_runtime;
GRANT CREATE, TEMPORARY ON DATABASE address_atlas_sync TO address_atlas_runtime;
GRANT CREATE ON SCHEMA public TO address_atlas_runtime;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO address_atlas_runtime;
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA public TO address_atlas_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE address_atlas
  GRANT ALL PRIVILEGES ON TABLES TO address_atlas_runtime;
SQL
provision_roles bootstrap "$admin_password_a" "$admin_password_a" "$runtime_password_a"
bootstrap_schema
assert_catalog_contract "$admin_password_a"
assert_runtime_behavior "$runtime_password_a"
assert_runtime_denials "$runtime_password_a"
stop_cluster

echo 'database-role-tests: PostgreSQL 16 role boundary checks passed.'
