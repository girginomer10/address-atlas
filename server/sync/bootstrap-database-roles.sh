#!/bin/sh
set +x
set -eu

# This is the only database-role path that accepts the historical owner
# credential. It is intentionally one-way: after ownership is normalized, the
# owner is demoted and all later role maintenance authenticates as the separate
# administrative role.

database_host="${PGHOST:-postgres}"
database_port="${PGPORT:-5432}"
database_name="${POSTGRES_DB:-address_atlas_sync}"
psql_bin="${PSQL_BIN:-psql}"
admin_password="${POSTGRES_ADMIN_PASSWORD:-}"
runtime_password="${POSTGRES_RUNTIME_PASSWORD:-}"

case "${ADDRESS_ATLAS_DATABASE_ROLE_MODE:-bootstrap}" in
  bootstrap) ;;
  *)
    echo 'bootstrap-database-roles.sh requires ADDRESS_ATLAS_DATABASE_ROLE_MODE=bootstrap.' >&2
    exit 64
    ;;
esac

case "$database_name" in
  ''|*[!A-Za-z0-9_]* )
    echo 'POSTGRES_DB must contain only letters, digits, or underscore.' >&2
    exit 65
    ;;
esac

validate_new_password() {
  password_name="$1"
  password_value="$2"
  case "$password_value" in
    ''|*[!A-Za-z0-9_-]*)
      echo "$password_name must contain only URL-safe letters, digits, underscore, or hyphen." >&2
      exit 65
      ;;
  esac
  if [ "${#password_value}" -lt 32 ] || [ "${#password_value}" -gt 128 ]; then
    echo "$password_name must be 32 through 128 characters." >&2
    exit 65
  fi
  if printf '%s' "$password_value" | grep -Eiq '(replace|change[_-]?me|example|password)'; then
    echo "$password_name must not be a placeholder." >&2
    exit 65
  fi
}

validate_new_password POSTGRES_ADMIN_PASSWORD "$admin_password"
validate_new_password POSTGRES_RUNTIME_PASSWORD "$runtime_password"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required for bootstrap mode}"

# PostgreSQL requires its bootstrap role (OID 10) to remain a superuser. The
# production cluster historically initialized that role as address_atlas, so a
# safe split must preserve its OID as address_atlas_admin and create a new,
# demotable owner. Hex encoding transports the arbitrary historical owner
# password over stdin without interpreting it as psql or SQL syntax.
owner_password_hex=$(printf '%s' "$POSTGRES_PASSWORD" | od -An -v -tx1 | tr -d ' \n')
if [ -z "$owner_password_hex" ]; then
  echo 'POSTGRES_PASSWORD must not be empty.' >&2
  exit 65
fi
bridge_password=$(od -An -N32 -v -tx1 /dev/urandom | tr -d ' \n')
if [ "${#bridge_password}" -ne 64 ]; then
  echo 'Could not generate an isolated bootstrap-bridge credential.' >&2
  exit 70
fi

export PGPASSWORD="$POSTGRES_PASSWORD"

# Credentials are copied as data into transaction-scoped temporary tables and
# consumed only by server-side code. Built-in statement logging remains useful
# for audit while error context and nested statement/parameter collectors are
# redacted before COPY begins.
if ! {
  cat <<'SQL'
\set ON_ERROR_STOP on
SET SESSION log_error_verbosity = 'terse';
SET SESSION log_parameter_max_length_on_error = 0;
SET SESSION debug_print_parse = off;
SET SESSION debug_print_rewritten = off;
SET SESSION debug_print_plan = off;
SET SESSION pgaudit.log_statement = off;
SET SESSION pgaudit.log_parameter = off;
SET SESSION pg_stat_statements.track = 'none';
SET SESSION pg_stat_statements.track_utility = off;
SET SESSION pg_stat_statements.track_planning = off;
DO $extension_logging$
BEGIN
  IF pg_catalog.current_setting('log_error_verbosity') <> 'terse'
     OR pg_catalog.current_setting('log_parameter_max_length_on_error') <> '0'
     OR pg_catalog.current_setting('debug_print_parse') <> 'off'
     OR pg_catalog.current_setting('debug_print_rewritten') <> 'off'
     OR pg_catalog.current_setting('debug_print_plan') <> 'off'
     OR pg_catalog.current_setting('pgaudit.log_statement') <> 'off'
     OR pg_catalog.current_setting('pgaudit.log_parameter') <> 'off' THEN
    RAISE EXCEPTION 'audit statement redaction could not be enabled';
  END IF;
  IF pg_catalog.current_setting('pg_stat_statements.track') <> 'none'
     OR pg_catalog.current_setting('pg_stat_statements.track_utility') <> 'off'
     OR pg_catalog.current_setting('pg_stat_statements.track_planning') <> 'off' THEN
    RAISE EXCEPTION 'statement-statistics redaction could not be enabled';
  END IF;
  IF pg_catalog.current_setting('auto_explain.log_min_duration', true) IS NOT NULL THEN
    PERFORM pg_catalog.set_config('auto_explain.log_min_duration', '-1', false);
    IF pg_catalog.current_setting('auto_explain.log_min_duration') <> '-1' THEN
      RAISE EXCEPTION 'automatic explain logging could not be disabled';
    END IF;
  END IF;
END
$extension_logging$;

BEGIN;
SET LOCAL password_encryption = 'scram-sha-256';
CREATE TEMP TABLE address_atlas_bootstrap_secrets (
  secret_name text PRIMARY KEY CHECK (secret_name = 'bridge_password'),
  secret_value text NOT NULL
) ON COMMIT DROP;
COPY pg_temp.address_atlas_bootstrap_secrets (secret_name, secret_value) FROM STDIN;
SQL
  printf 'bridge_password\t%s\n' "$bridge_password"
  printf '\\.\n'
  cat <<'SQL'

DO $guard$
DECLARE
  bootstrap_is_superuser boolean;
BEGIN
  SELECT role.rolsuper INTO bootstrap_is_superuser
  FROM pg_catalog.pg_roles AS role
  WHERE role.rolname = current_user;

  IF current_user <> 'address_atlas' OR bootstrap_is_superuser IS DISTINCT FROM true THEN
    RAISE EXCEPTION
      'bootstrap must authenticate directly as the current address_atlas owner-superuser';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'address_atlas_admin') THEN
    RAISE EXCEPTION 'address_atlas_admin already exists; use steady mode instead';
  END IF;
END
$guard$;

SELECT 'DROP ROLE address_atlas_role_bridge'
WHERE EXISTS (
  SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'address_atlas_role_bridge'
) \gexec
DO $bridge_role$
DECLARE
  desired_bridge_password text;
BEGIN
  BEGIN
    SELECT secret_value INTO STRICT desired_bridge_password
    FROM pg_temp.address_atlas_bootstrap_secrets
    WHERE secret_name = 'bridge_password';
    EXECUTE pg_catalog.format(
      'CREATE ROLE address_atlas_role_bridge '
      'WITH LOGIN SUPERUSER NOCREATEDB CREATEROLE NOREPLICATION NOBYPASSRLS '
      'NOINHERIT CONNECTION LIMIT -1 PASSWORD %L VALID UNTIL %L',
      desired_bridge_password,
      'infinity'
    );
  EXCEPTION
    WHEN query_canceled OR assert_failure THEN
      RAISE EXCEPTION USING
        MESSAGE = 'sanitized bootstrap bridge credential mutation failed',
        ERRCODE = '55000';
    WHEN OTHERS THEN
      RAISE EXCEPTION USING
        MESSAGE = 'sanitized bootstrap bridge credential mutation failed',
        ERRCODE = '55000';
  END;
END
$bridge_role$;
COMMIT;
SQL
} | "$psql_bin" \
  --host "$database_host" \
  --port "$database_port" \
  --username address_atlas \
  --dbname "$database_name" \
  --no-psqlrc \
  --quiet \
  2>/dev/null
then
  printf '%s\n' 'ROLE_PROVISION_FAILED mode=bootstrap stage=bridge-create' >&2
  exit 74
fi

# Best-effort crash cleanup covers both sides of the transactional rename: the
# old owner can remove the bridge before the split commits, while the new admin
# can remove it afterwards. SIGKILL/power-loss recovery is also handled by the
# steady provisioner's reserved-role check.
bridge_cleanup_pending=true
cleanup_role_bridge() {
  cleanup_status=$?
  trap - EXIT HUP INT TERM
  if [ "$bridge_cleanup_pending" = true ]; then
    printf '%s\n' 'DROP ROLE IF EXISTS address_atlas_role_bridge;' \
      | PGPASSWORD="$admin_password" "$psql_bin" \
        --host "$database_host" --port "$database_port" \
        --username address_atlas_admin --dbname "$database_name" \
        --no-psqlrc --set ON_ERROR_STOP=1 --quiet >/dev/null 2>&1 \
      || printf '%s\n' 'DROP ROLE IF EXISTS address_atlas_role_bridge;' \
        | PGPASSWORD="$POSTGRES_PASSWORD" "$psql_bin" \
          --host "$database_host" --port "$database_port" \
          --username address_atlas --dbname "$database_name" \
          --no-psqlrc --set ON_ERROR_STOP=1 --quiet >/dev/null 2>&1 \
      || true
  fi
  exit "$cleanup_status"
}
trap cleanup_role_bridge EXIT HUP INT TERM

export PGPASSWORD="$bridge_password"

# This second session repeats the logging guard before receiving the long-lived
# owner, administrator, and runtime credentials.
if ! {
  cat <<'SQL'
\set ON_ERROR_STOP on
SET SESSION log_error_verbosity = 'terse';
SET SESSION log_parameter_max_length_on_error = 0;
SET SESSION debug_print_parse = off;
SET SESSION debug_print_rewritten = off;
SET SESSION debug_print_plan = off;
SET SESSION pgaudit.log_statement = off;
SET SESSION pgaudit.log_parameter = off;
SET SESSION pg_stat_statements.track = 'none';
SET SESSION pg_stat_statements.track_utility = off;
SET SESSION pg_stat_statements.track_planning = off;
DO $extension_logging$
BEGIN
  IF pg_catalog.current_setting('log_error_verbosity') <> 'terse'
     OR pg_catalog.current_setting('log_parameter_max_length_on_error') <> '0'
     OR pg_catalog.current_setting('debug_print_parse') <> 'off'
     OR pg_catalog.current_setting('debug_print_rewritten') <> 'off'
     OR pg_catalog.current_setting('debug_print_plan') <> 'off'
     OR pg_catalog.current_setting('pgaudit.log_statement') <> 'off'
     OR pg_catalog.current_setting('pgaudit.log_parameter') <> 'off' THEN
    RAISE EXCEPTION 'audit statement redaction could not be enabled';
  END IF;
  IF pg_catalog.current_setting('pg_stat_statements.track') <> 'none'
     OR pg_catalog.current_setting('pg_stat_statements.track_utility') <> 'off'
     OR pg_catalog.current_setting('pg_stat_statements.track_planning') <> 'off' THEN
    RAISE EXCEPTION 'statement-statistics redaction could not be enabled';
  END IF;
  IF pg_catalog.current_setting('auto_explain.log_min_duration', true) IS NOT NULL THEN
    PERFORM pg_catalog.set_config('auto_explain.log_min_duration', '-1', false);
    IF pg_catalog.current_setting('auto_explain.log_min_duration') <> '-1' THEN
      RAISE EXCEPTION 'automatic explain logging could not be disabled';
    END IF;
  END IF;
END
$extension_logging$;

BEGIN;
SET LOCAL password_encryption = 'scram-sha-256';
CREATE TEMP TABLE address_atlas_bootstrap_secrets (
  secret_name text PRIMARY KEY CHECK (
    secret_name IN ('admin_password', 'runtime_password', 'owner_password_hex')
  ),
  secret_value text NOT NULL
) ON COMMIT DROP;
COPY pg_temp.address_atlas_bootstrap_secrets (secret_name, secret_value) FROM STDIN;
SQL
  printf 'admin_password\t%s\n' "$admin_password"
  printf 'runtime_password\t%s\n' "$runtime_password"
  printf 'owner_password_hex\t%s\n' "$owner_password_hex"
  printf '\\.\n'
  cat <<'SQL'

DO $guard$
DECLARE
  bootstrap_is_superuser boolean;
BEGIN
  SELECT role.rolsuper
  INTO bootstrap_is_superuser
  FROM pg_catalog.pg_roles AS role
  WHERE role.rolname = current_user;

  IF current_user <> 'address_atlas_role_bridge'
     OR bootstrap_is_superuser IS DISTINCT FROM true THEN
    RAISE EXCEPTION
      'role split must run through the isolated bootstrap bridge';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'address_atlas_admin')
     OR NOT EXISTS (
       SELECT 1 FROM pg_catalog.pg_roles
       WHERE rolname = 'address_atlas' AND rolsuper
     ) THEN
    RAISE EXCEPTION 'legacy owner/admin role state is not safe to split';
  END IF;
END
$guard$;

ALTER ROLE address_atlas RENAME TO address_atlas_admin;

DO $split_roles$
DECLARE
  desired_owner_password text;
  desired_admin_password text;
  desired_runtime_password text;
BEGIN
  BEGIN
    SELECT pg_catalog.convert_from(
             pg_catalog.decode(secret_value, 'hex'),
             'UTF8'
           )
    INTO STRICT desired_owner_password
    FROM pg_temp.address_atlas_bootstrap_secrets
    WHERE secret_name = 'owner_password_hex';
    SELECT secret_value INTO STRICT desired_admin_password
    FROM pg_temp.address_atlas_bootstrap_secrets
    WHERE secret_name = 'admin_password';
    SELECT secret_value INTO STRICT desired_runtime_password
    FROM pg_temp.address_atlas_bootstrap_secrets
    WHERE secret_name = 'runtime_password';

    EXECUTE pg_catalog.format(
      'CREATE ROLE address_atlas LOGIN SUPERUSER NOCREATEDB NOCREATEROLE '
      'NOREPLICATION NOBYPASSRLS NOINHERIT CONNECTION LIMIT -1 PASSWORD %L VALID UNTIL %L',
      desired_owner_password,
      'infinity'
    );
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'address_atlas_runtime'
    ) THEN
      EXECUTE pg_catalog.format(
        'CREATE ROLE address_atlas_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE '
        'NOREPLICATION NOBYPASSRLS NOINHERIT CONNECTION LIMIT -1 PASSWORD %L VALID UNTIL %L',
        desired_runtime_password,
        'infinity'
      );
    END IF;
    EXECUTE pg_catalog.format(
      'ALTER ROLE address_atlas_admin '
      'WITH LOGIN SUPERUSER NOCREATEDB CREATEROLE NOREPLICATION NOBYPASSRLS '
      'NOINHERIT CONNECTION LIMIT -1 PASSWORD %L VALID UNTIL %L',
      desired_admin_password,
      'infinity'
    );
    EXECUTE pg_catalog.format(
      'ALTER ROLE address_atlas_runtime '
      'WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS '
      'NOINHERIT CONNECTION LIMIT -1 PASSWORD %L VALID UNTIL %L',
      desired_runtime_password,
      'infinity'
    );
  EXCEPTION
    WHEN query_canceled OR assert_failure THEN
      RAISE EXCEPTION USING
        MESSAGE = 'sanitized bootstrap role credential mutation failed',
        ERRCODE = '55000';
    WHEN OTHERS THEN
      RAISE EXCEPTION USING
        MESSAGE = 'sanitized bootstrap role credential mutation failed',
        ERRCODE = '55000';
  END;
END
$split_roles$;

-- Protected roles never inherit from, grant to, or SET ROLE through another
-- role. Bootstrap converges legacy installations by removing both directions.
DO $memberships$
DECLARE
  membership record;
BEGIN
  FOR membership IN
    SELECT granted.rolname AS granted_role, member.rolname AS member_role
    FROM pg_catalog.pg_auth_members AS edge
    JOIN pg_catalog.pg_roles AS granted ON granted.oid = edge.roleid
    JOIN pg_catalog.pg_roles AS member ON member.oid = edge.member
    WHERE granted.rolname IN ('address_atlas', 'address_atlas_admin', 'address_atlas_runtime')
       OR member.rolname IN ('address_atlas', 'address_atlas_admin', 'address_atlas_runtime')
  LOOP
    EXECUTE pg_catalog.format(
      'REVOKE %I FROM %I',
      membership.granted_role,
      membership.member_role
    );
  END LOOP;
END
$memberships$;

ALTER ROLE address_atlas RESET ALL;
ALTER ROLE address_atlas_admin RESET ALL;
ALTER ROLE address_atlas_runtime RESET ALL;

DO $database_settings$
DECLARE
  setting record;
BEGIN
  FOR setting IN
    SELECT DISTINCT role.rolname, database.datname
    FROM pg_catalog.pg_db_role_setting AS configured
    JOIN pg_catalog.pg_roles AS role ON role.oid = configured.setrole
    JOIN pg_catalog.pg_database AS database ON database.oid = configured.setdatabase
    WHERE role.rolname IN ('address_atlas', 'address_atlas_admin', 'address_atlas_runtime')
  LOOP
    EXECUTE pg_catalog.format(
      'ALTER ROLE %I IN DATABASE %I RESET ALL',
      setting.rolname,
      setting.datname
    );
  END LOOP;
END
$database_settings$;

-- Normalize every application-owned object before revoking ambient access.
SELECT pg_catalog.format('ALTER DATABASE %I OWNER TO address_atlas', current_database())
\gexec
ALTER SCHEMA public OWNER TO address_atlas;

DO $relations$
DECLARE
  relation record;
BEGIN
  FOR relation IN
    SELECT item.relkind, item.relname
    FROM pg_catalog.pg_class AS item
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = item.relnamespace
    WHERE namespace.nspname = 'public'
      AND item.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
    ORDER BY item.oid
  LOOP
    EXECUTE pg_catalog.format(
      'ALTER %s %I.%I OWNER TO address_atlas',
      CASE relation.relkind
        WHEN 'S' THEN 'SEQUENCE'
        WHEN 'v' THEN 'VIEW'
        WHEN 'm' THEN 'MATERIALIZED VIEW'
        WHEN 'f' THEN 'FOREIGN TABLE'
        ELSE 'TABLE'
      END,
      'public',
      relation.relname
    );
  END LOOP;
END
$relations$;

DO $routines$
DECLARE
  routine record;
BEGIN
  FOR routine IN
    SELECT item.oid, item.proname, item.prokind,
           pg_catalog.pg_get_function_identity_arguments(item.oid) AS arguments
    FROM pg_catalog.pg_proc AS item
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = item.pronamespace
    WHERE namespace.nspname = 'public'
    ORDER BY item.oid
  LOOP
    EXECUTE pg_catalog.format(
      'ALTER %s %I.%I(%s) OWNER TO address_atlas',
      CASE routine.prokind WHEN 'p' THEN 'PROCEDURE' WHEN 'a' THEN 'AGGREGATE' ELSE 'FUNCTION' END,
      'public',
      routine.proname,
      routine.arguments
    );
  END LOOP;
END
$routines$;

DO $types$
DECLARE
  type_row record;
BEGIN
  FOR type_row IN
    SELECT item.typname, item.typtype
    FROM pg_catalog.pg_type AS item
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = item.typnamespace
    LEFT JOIN pg_catalog.pg_class AS relation ON relation.oid = item.typrelid
    WHERE namespace.nspname = 'public'
      AND (
        item.typtype IN ('d', 'e', 'r', 'm')
        OR (item.typtype = 'c' AND relation.relkind = 'c')
      )
    ORDER BY item.oid
  LOOP
    EXECUTE pg_catalog.format(
      'ALTER %s %I.%I OWNER TO address_atlas',
      CASE type_row.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END,
      'public',
      type_row.typname
    );
  END LOOP;
END
$types$;

-- Remove legacy/default ambient access. Named runtime grants are installed by
-- the steady-state provisioner after this transaction commits.
SELECT pg_catalog.format(
  'REVOKE ALL PRIVILEGES ON DATABASE %I FROM PUBLIC, address_atlas_admin, address_atlas_runtime',
  current_database()
) \gexec
SELECT pg_catalog.format(
  'GRANT CONNECT ON DATABASE %I TO address_atlas, address_atlas_admin, address_atlas_runtime',
  current_database()
) \gexec

REVOKE ALL PRIVILEGES ON SCHEMA public
  FROM PUBLIC, address_atlas_admin, address_atlas_runtime;
GRANT USAGE ON SCHEMA public
  TO address_atlas, address_atlas_admin, address_atlas_runtime;

REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public
  FROM PUBLIC, address_atlas_admin, address_atlas_runtime;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public
  FROM PUBLIC, address_atlas_admin, address_atlas_runtime;
REVOKE ALL PRIVILEGES ON ALL ROUTINES IN SCHEMA public
  FROM PUBLIC, address_atlas_admin, address_atlas_runtime;
DO $type_privileges$
DECLARE
  type_row record;
BEGIN
  FOR type_row IN
    SELECT item.typname, item.typtype
    FROM pg_catalog.pg_type AS item
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = item.typnamespace
    LEFT JOIN pg_catalog.pg_class AS relation ON relation.oid = item.typrelid
    WHERE namespace.nspname = 'public'
      AND (item.typtype IN ('d', 'e', 'r', 'm')
           OR (item.typtype = 'c' AND relation.relkind = 'c'))
  LOOP
    EXECUTE pg_catalog.format(
      'REVOKE ALL PRIVILEGES ON %s %I.%I FROM PUBLIC, address_atlas_admin, address_atlas_runtime',
      CASE type_row.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END,
      'public',
      type_row.typname
    );
  END LOOP;
END
$type_privileges$;

-- The historical owner OID is now address_atlas_admin, so legacy default ACLs
-- follow that rename and must be cleared as well as the new owner's defaults.
ALTER DEFAULT PRIVILEGES FOR ROLE address_atlas_admin
  REVOKE ALL PRIVILEGES ON TABLES FROM PUBLIC, address_atlas, address_atlas_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE address_atlas_admin
  REVOKE ALL PRIVILEGES ON SEQUENCES FROM PUBLIC, address_atlas, address_atlas_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE address_atlas_admin
  REVOKE ALL PRIVILEGES ON ROUTINES FROM PUBLIC, address_atlas, address_atlas_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE address_atlas_admin
  REVOKE ALL PRIVILEGES ON TYPES FROM PUBLIC, address_atlas, address_atlas_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE address_atlas_admin IN SCHEMA public
  REVOKE ALL PRIVILEGES ON TABLES FROM PUBLIC, address_atlas, address_atlas_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE address_atlas_admin IN SCHEMA public
  REVOKE ALL PRIVILEGES ON SEQUENCES FROM PUBLIC, address_atlas, address_atlas_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE address_atlas_admin IN SCHEMA public
  REVOKE ALL PRIVILEGES ON ROUTINES FROM PUBLIC, address_atlas, address_atlas_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE address_atlas_admin IN SCHEMA public
  REVOKE ALL PRIVILEGES ON TYPES FROM PUBLIC, address_atlas, address_atlas_runtime;

ALTER DEFAULT PRIVILEGES FOR ROLE address_atlas
  REVOKE ALL PRIVILEGES ON TABLES FROM PUBLIC, address_atlas_admin, address_atlas_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE address_atlas
  REVOKE ALL PRIVILEGES ON SEQUENCES FROM PUBLIC, address_atlas_admin, address_atlas_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE address_atlas
  REVOKE ALL PRIVILEGES ON ROUTINES FROM PUBLIC, address_atlas_admin, address_atlas_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE address_atlas
  REVOKE ALL PRIVILEGES ON TYPES FROM PUBLIC, address_atlas_admin, address_atlas_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE address_atlas IN SCHEMA public
  REVOKE ALL PRIVILEGES ON TABLES FROM PUBLIC, address_atlas_admin, address_atlas_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE address_atlas IN SCHEMA public
  REVOKE ALL PRIVILEGES ON SEQUENCES FROM PUBLIC, address_atlas_admin, address_atlas_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE address_atlas IN SCHEMA public
  REVOKE ALL PRIVILEGES ON ROUTINES FROM PUBLIC, address_atlas_admin, address_atlas_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE address_atlas IN SCHEMA public
  REVOKE ALL PRIVILEGES ON TYPES FROM PUBLIC, address_atlas_admin, address_atlas_runtime;

-- Owner demotion is deliberately the final state mutation. Once committed,
-- only address_atlas_admin can perform role and ACL maintenance.
ALTER ROLE address_atlas
  WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  NOINHERIT CONNECTION LIMIT -1 VALID UNTIL 'infinity';

DO $final_guard$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_roles
    WHERE rolname = 'address_atlas'
      AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls
           OR rolinherit OR NOT rolcanlogin OR rolconnlimit <> -1)
  ) THEN
    RAISE EXCEPTION 'address_atlas owner demotion failed';
  END IF;
END
$final_guard$;

COMMIT;
SQL
} | "$psql_bin" \
  --host "$database_host" \
  --port "$database_port" \
  --username address_atlas_role_bridge \
  --dbname "$database_name" \
  --no-psqlrc \
  --quiet \
  2>/dev/null
then
  printf '%s\n' 'ROLE_PROVISION_FAILED mode=bootstrap stage=role-split' >&2
  exit 74
fi

export PGPASSWORD="$admin_password"
printf '%s\n' 'DROP ROLE address_atlas_role_bridge;' | "$psql_bin" \
  --host "$database_host" \
  --port "$database_port" \
  --username address_atlas_admin \
  --dbname "$database_name" \
  --no-psqlrc \
  --set ON_ERROR_STOP=1 \
  --quiet

bridge_cleanup_pending=false
trap - EXIT HUP INT TERM
unset bridge_password

# Never make the historical owner credential available to steady-state code.
unset POSTGRES_PASSWORD PGPASSWORD
export ADDRESS_ATLAS_DATABASE_ROLE_MODE=steady
export POSTGRES_ADMIN_CURRENT_PASSWORD="$admin_password"

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$script_dir/provision-runtime-role.sh"
