#!/bin/sh
set +x
set -eu

mode="${ADDRESS_ATLAS_DATABASE_ROLE_MODE:-steady}"
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

case "$mode" in
  bootstrap)
    exec "$script_dir/bootstrap-database-roles.sh"
    ;;
  steady|restore|drill) ;;
  *)
    echo 'ADDRESS_ATLAS_DATABASE_ROLE_MODE must be bootstrap, steady, restore, or drill.' >&2
    exit 64
    ;;
esac

# Steady mode never reads or falls back to POSTGRES_PASSWORD. A bad admin
# credential must stop the deployment even when an owner secret is present in
# the environment.
unset POSTGRES_PASSWORD PGPASSWORD

database_host="${PGHOST:-postgres}"
database_port="${PGPORT:-5432}"
database_name="${POSTGRES_DB:-address_atlas_sync}"
psql_bin="${PSQL_BIN:-psql}"
admin_password="${POSTGRES_ADMIN_PASSWORD:-}"
admin_current_password="${POSTGRES_ADMIN_CURRENT_PASSWORD:-$admin_password}"
runtime_password="${POSTGRES_RUNTIME_PASSWORD:-}"

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
if [ "$admin_current_password" != "$admin_password" ]; then
  echo 'Steady deployment does not rotate database credentials; use a separately reviewed maintenance procedure.' >&2
  exit 65
fi

# Prove the desired runtime credential already works before the administrative
# transaction can alter any role or ACL. This makes normal deployment a pure
# convergence operation rather than a hidden credential rotation with a crash
# window that could strand the still-running web container.
if [ "$mode" = steady ] || [ "$mode" = drill ]; then
  if ! runtime_identity="$({
    PGPASSWORD="$runtime_password" "$psql_bin" \
      --host "$database_host" \
      --port "$database_port" \
      --username address_atlas_runtime \
      --dbname "$database_name" \
      --no-psqlrc \
      --tuples-only \
      --no-align \
      --set ON_ERROR_STOP=1 \
      --command 'SELECT current_user;' \
      2>/dev/null
  })"; then
    printf 'ROLE_PROVISION_FAILED mode=%s stage=runtime-auth\n' "$mode" >&2
    echo 'The desired runtime credential is not already active; refusing implicit rotation.' >&2
    exit 65
  fi
  if [ "$runtime_identity" != "address_atlas_runtime" ]; then
    printf 'ROLE_PROVISION_FAILED mode=%s stage=runtime-auth\n' "$mode" >&2
    echo 'Runtime credential preflight authenticated as an unexpected role.' >&2
    exit 65
  fi
fi

export PGPASSWORD="$admin_current_password"

# Desired credentials never appear in client-submitted SQL statement text.
# Restore mode copies them as data into a transaction-scoped temporary table,
# then server-side code consumes them. Built-in statement logging remains
# available for audit; error context, nested-statement collectors, and audit
# statement/parameter capture are redacted before COPY starts.
if ! {
  if [ "$mode" = restore ]; then
    printf '\\set mutate_global_roles true\n'
  else
    printf '\\set mutate_global_roles false\n'
  fi
  if [ "$mode" = drill ]; then
    printf '\\set cleanup_bridge false\n'
  else
    printf '\\set cleanup_bridge true\n'
  fi
  if [ "$mode" = restore ] || [ "$mode" = drill ]; then
    printf '\\set normalize_restored_schema_owner true\n'
  else
    printf '\\set normalize_restored_schema_owner false\n'
  fi
  cat <<'SQL'
\set ON_ERROR_STOP on
SQL
  if [ "$mode" = restore ]; then
    cat <<'SQL'

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
SQL
  fi
  cat <<'SQL'

BEGIN;
SET LOCAL password_encryption = 'scram-sha-256';
SQL
  if [ "$mode" = restore ]; then
    cat <<'SQL'
CREATE TEMP TABLE address_atlas_role_secrets (
  secret_name text PRIMARY KEY
    CHECK (secret_name IN ('admin_password', 'runtime_password')),
  secret_value text NOT NULL
) ON COMMIT DROP;
COPY pg_temp.address_atlas_role_secrets (secret_name, secret_value) FROM STDIN;
SQL
    printf 'admin_password\t%s\n' "$admin_password"
    printf 'runtime_password\t%s\n' "$runtime_password"
    printf '\\.\n'
  fi
  cat <<'SQL'

-- Reject a drifted control plane before changing anything. In particular,
-- steady mode cannot silently regain the historical owner's authority through
-- membership, inherited settings, or a fallback credential.
DO $preflight$
DECLARE
  admin_role pg_catalog.pg_roles%ROWTYPE;
  owner_role pg_catalog.pg_roles%ROWTYPE;
BEGIN
  IF current_user <> 'address_atlas_admin' THEN
    RAISE EXCEPTION 'steady provisioning must authenticate directly as address_atlas_admin';
  END IF;

  SELECT * INTO admin_role
  FROM pg_catalog.pg_roles
  WHERE rolname = 'address_atlas_admin';
  SELECT * INTO owner_role
  FROM pg_catalog.pg_roles
  WHERE rolname = 'address_atlas';

  IF admin_role.oid IS NULL
     OR NOT admin_role.rolcanlogin
     OR NOT admin_role.rolsuper
     OR NOT admin_role.rolcreaterole
     OR admin_role.rolcreatedb
     OR admin_role.rolreplication
     OR admin_role.rolbypassrls
     OR admin_role.rolinherit
     OR admin_role.rolconnlimit <> -1 THEN
    RAISE EXCEPTION 'address_atlas_admin attributes are outside the control-plane contract';
  END IF;

  IF owner_role.oid IS NULL
     OR NOT owner_role.rolcanlogin
     OR owner_role.rolsuper
     OR owner_role.rolcreaterole
     OR owner_role.rolcreatedb
     OR owner_role.rolreplication
     OR owner_role.rolbypassrls
     OR owner_role.rolinherit
     OR owner_role.rolconnlimit <> -1 THEN
    RAISE EXCEPTION 'address_atlas owner is not safely demoted';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_auth_members AS edge
    JOIN pg_catalog.pg_roles AS granted ON granted.oid = edge.roleid
    JOIN pg_catalog.pg_roles AS member ON member.oid = edge.member
    WHERE granted.rolname IN ('address_atlas', 'address_atlas_admin', 'address_atlas_runtime')
       OR member.rolname IN ('address_atlas', 'address_atlas_admin', 'address_atlas_runtime')
  ) THEN
    RAISE EXCEPTION 'protected database roles must not have membership edges';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_roles
    WHERE rolname = 'address_atlas_role_bridge'
      AND (NOT rolsuper OR NOT rolcreaterole OR rolcreatedb OR rolreplication
           OR rolbypassrls OR rolinherit OR NOT rolcanlogin OR rolconnlimit <> -1
           OR rolconfig IS NOT NULL)
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.pg_auth_members AS edge
    JOIN pg_catalog.pg_roles AS granted ON granted.oid = edge.roleid
    JOIN pg_catalog.pg_roles AS member ON member.oid = edge.member
    WHERE granted.rolname = 'address_atlas_role_bridge'
       OR member.rolname = 'address_atlas_role_bridge'
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.pg_db_role_setting AS setting
    JOIN pg_catalog.pg_roles AS role ON role.oid = setting.setrole
    WHERE role.rolname = 'address_atlas_role_bridge'
  ) THEN
    RAISE EXCEPTION 'reserved bootstrap bridge has unexpected authority or settings';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_roles
    WHERE rolname IN ('address_atlas', 'address_atlas_admin', 'address_atlas_runtime')
      AND rolconfig IS NOT NULL
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.pg_db_role_setting AS setting
    JOIN pg_catalog.pg_roles AS role ON role.oid = setting.setrole
    WHERE role.rolname IN ('address_atlas', 'address_atlas_admin', 'address_atlas_runtime')
  ) THEN
    RAISE EXCEPTION 'protected database roles must not carry session-setting overrides';
  END IF;
END
$preflight$;

-- PostgreSQL 16's template0 intentionally gives public to the dynamic
-- pg_database_owner role. Restored databases retain that owner because restore
-- runs with --no-owner. Only the isolated restore paths may converge this
-- expected template state; steady deployment must continue to reject ownership
-- drift instead of repairing it implicitly.
\if :normalize_restored_schema_owner
DO $restored_schema_owner_preflight$
DECLARE
  public_schema_owner text;
BEGIN
  SELECT pg_catalog.pg_get_userbyid(namespace.nspowner)
  INTO public_schema_owner
  FROM pg_catalog.pg_namespace AS namespace
  WHERE namespace.nspname = 'public';

  IF public_schema_owner IS NULL
     OR public_schema_owner NOT IN ('pg_database_owner', 'address_atlas') THEN
    RAISE EXCEPTION 'restored public schema owner is outside the expected template or application contract';
  END IF;
END
$restored_schema_owner_preflight$;

ALTER SCHEMA public OWNER TO address_atlas;
\endif

\if :cleanup_bridge
  SELECT 'DROP ROLE address_atlas_role_bridge'
  WHERE EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'address_atlas_role_bridge'
  ) \gexec
\endif

-- Only production restore may change cluster-global role state. Steady deploys
-- already proved both desired credentials, while drills must be side-effect
-- free outside their isolated temporary database (including password hashes).
\if :mutate_global_roles
  DO $global_roles$
  DECLARE
    desired_admin_password text;
    desired_runtime_password text;
  BEGIN
    BEGIN
      SELECT secret_value INTO STRICT desired_admin_password
      FROM pg_temp.address_atlas_role_secrets
      WHERE secret_name = 'admin_password';
      SELECT secret_value INTO STRICT desired_runtime_password
      FROM pg_temp.address_atlas_role_secrets
      WHERE secret_name = 'runtime_password';

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
          MESSAGE = 'sanitized role credential mutation failed',
          ERRCODE = '55000';
      WHEN OTHERS THEN
      RAISE EXCEPTION USING
        MESSAGE = 'sanitized role credential mutation failed',
        ERRCODE = '55000';
    END;
  END
  $global_roles$;
  ALTER ROLE address_atlas_runtime RESET ALL;
\endif
SELECT pg_catalog.format(
  'ALTER ROLE address_atlas_runtime IN DATABASE %I RESET ALL',
  current_database()
) \gexec

DO $required_tables$
DECLARE
  table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'sync_schema_migrations',
    'users',
    'passkey_credentials',
    'consumed_challenges',
    'registration_usage',
    'session_grants',
    'vault_global_ingress_usage',
    'vault_write_usage',
    'sync_storage_usage',
    'vault_snapshots',
    'account_deletion_receipts'
  ] LOOP
    IF pg_catalog.to_regclass(pg_catalog.format('%I.%I', 'public', table_name)) IS NULL THEN
      RAISE EXCEPTION 'required application table is missing: %', table_name;
    END IF;
  END LOOP;
END
$required_tables$;

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

-- Table-level REVOKE does not remove independently granted column ACLs.
DO $column_acl$
DECLARE
  column_grant record;
BEGIN
  FOR column_grant IN
    SELECT DISTINCT grant_row.table_schema, grant_row.table_name,
           grant_row.column_name, grant_row.grantee
    FROM information_schema.column_privileges AS grant_row
    WHERE grant_row.table_schema = 'public'
      AND grant_row.grantee IN ('PUBLIC', 'address_atlas_admin', 'address_atlas_runtime')
  LOOP
    EXECUTE pg_catalog.format(
      'REVOKE ALL PRIVILEGES (%I) ON TABLE %I.%I FROM %s',
      column_grant.column_name,
      column_grant.table_schema,
      column_grant.table_name,
      CASE column_grant.grantee
        WHEN 'PUBLIC' THEN 'PUBLIC'
        ELSE pg_catalog.quote_ident(column_grant.grantee)
      END
    );
  END LOOP;
END
$column_acl$;

-- Remove both global and public-schema defaults. PostgreSQL combines those
-- layers, so revoking only the schema-local layer would not neutralize a
-- historical global grant.
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

GRANT SELECT ON TABLE public.sync_schema_migrations TO address_atlas_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.users TO address_atlas_runtime;
GRANT SELECT, INSERT, UPDATE ON TABLE public.passkey_credentials TO address_atlas_runtime;
GRANT SELECT, INSERT, DELETE ON TABLE public.consumed_challenges TO address_atlas_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.registration_usage TO address_atlas_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.session_grants TO address_atlas_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.vault_global_ingress_usage TO address_atlas_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.vault_write_usage TO address_atlas_runtime;
GRANT SELECT, UPDATE ON TABLE public.sync_storage_usage TO address_atlas_runtime;
GRANT SELECT, INSERT, UPDATE ON TABLE public.vault_snapshots TO address_atlas_runtime;
GRANT SELECT, INSERT ON TABLE public.account_deletion_receipts TO address_atlas_runtime;

DO $contract$
DECLARE
  role_row record;
  owner_oid oid;
  admin_oid oid;
  runtime_oid oid;
  public_schema_oid oid;
BEGIN
  SELECT oid INTO owner_oid FROM pg_catalog.pg_roles WHERE rolname = 'address_atlas';
  SELECT oid INTO admin_oid FROM pg_catalog.pg_roles WHERE rolname = 'address_atlas_admin';
  SELECT oid INTO runtime_oid FROM pg_catalog.pg_roles WHERE rolname = 'address_atlas_runtime';
  SELECT oid INTO public_schema_oid FROM pg_catalog.pg_namespace WHERE nspname = 'public';

  FOR role_row IN
    SELECT * FROM pg_catalog.pg_roles
    WHERE rolname IN ('address_atlas', 'address_atlas_admin', 'address_atlas_runtime')
  LOOP
    IF NOT role_row.rolcanlogin
       OR role_row.rolcreatedb
       OR role_row.rolreplication
       OR role_row.rolbypassrls
       OR role_row.rolinherit
       OR role_row.rolconnlimit <> -1
       OR role_row.rolconfig IS NOT NULL THEN
      RAISE EXCEPTION 'role attributes drifted for %', role_row.rolname;
    END IF;
    IF role_row.rolname = 'address_atlas_admin' THEN
      IF NOT role_row.rolsuper OR NOT role_row.rolcreaterole THEN
        RAISE EXCEPTION 'administrative role lacks its isolated control-plane attributes';
      END IF;
    ELSIF role_row.rolsuper OR role_row.rolcreaterole THEN
      RAISE EXCEPTION 'owner/runtime role has administrative attributes: %', role_row.rolname;
    END IF;
  END LOOP;

  IF (SELECT pg_catalog.count(*) FROM pg_catalog.pg_roles
      WHERE rolname IN ('address_atlas', 'address_atlas_admin', 'address_atlas_runtime')) <> 3 THEN
    RAISE EXCEPTION 'required role set is incomplete';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_auth_members AS edge
    JOIN pg_catalog.pg_roles AS granted ON granted.oid = edge.roleid
    JOIN pg_catalog.pg_roles AS member ON member.oid = edge.member
    WHERE granted.rolname IN ('address_atlas', 'address_atlas_admin', 'address_atlas_runtime')
       OR member.rolname IN ('address_atlas', 'address_atlas_admin', 'address_atlas_runtime')
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.pg_db_role_setting AS setting
    JOIN pg_catalog.pg_roles AS role ON role.oid = setting.setrole
    WHERE role.rolname IN ('address_atlas', 'address_atlas_admin', 'address_atlas_runtime')
  ) THEN
    RAISE EXCEPTION 'protected roles have inherited authority or settings';
  END IF;

  IF (SELECT datdba FROM pg_catalog.pg_database WHERE datname = current_database()) <> owner_oid
     OR (SELECT nspowner FROM pg_catalog.pg_namespace WHERE nspname = 'public') <> owner_oid
     OR EXISTS (
       SELECT 1
       FROM pg_catalog.pg_class AS relation
       JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
       WHERE namespace.nspname = 'public'
         AND relation.relkind IN ('r', 'p', 'v', 'm', 'S', 'f', 'i', 'I')
         AND relation.relowner <> owner_oid
     ) OR EXISTS (
       SELECT 1
       FROM pg_catalog.pg_proc AS routine
       WHERE routine.pronamespace = public_schema_oid
         AND routine.proowner <> owner_oid
     ) OR EXISTS (
       SELECT 1
       FROM pg_catalog.pg_type AS item
       LEFT JOIN pg_catalog.pg_class AS relation ON relation.oid = item.typrelid
       WHERE item.typnamespace = public_schema_oid
         AND (item.typtype IN ('d', 'e', 'r', 'm')
              OR (item.typtype = 'c' AND relation.relkind = 'c'))
         AND item.typowner <> owner_oid
     ) THEN
    RAISE EXCEPTION 'database, schema, or application object ownership is not address_atlas';
  END IF;

  IF NOT pg_catalog.has_database_privilege('address_atlas_runtime', current_database(), 'CONNECT')
     OR pg_catalog.has_database_privilege('address_atlas_runtime', current_database(), 'CREATE')
     OR pg_catalog.has_database_privilege('address_atlas_runtime', current_database(), 'TEMPORARY')
     OR NOT pg_catalog.has_schema_privilege('address_atlas_runtime', 'public', 'USAGE')
     OR pg_catalog.has_schema_privilege('address_atlas_runtime', 'public', 'CREATE') THEN
    RAISE EXCEPTION 'runtime database/schema boundary is invalid';
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
      SELECT grant_row.table_name, grant_row.privilege_type
      FROM information_schema.table_privileges AS grant_row
      WHERE grant_row.table_schema = 'public'
        AND grant_row.grantee = 'address_atlas_runtime'
    )
    SELECT 1
    FROM (
      (SELECT * FROM actual EXCEPT SELECT * FROM expected)
      UNION ALL
      (SELECT * FROM expected EXCEPT SELECT * FROM actual)
    ) AS difference
  ) THEN
    RAISE EXCEPTION 'runtime table privileges differ from the exact application contract';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.table_privileges AS grant_row
    WHERE grant_row.table_schema = 'public'
      AND grant_row.grantee IN ('PUBLIC', 'address_atlas_admin')
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.pg_attribute AS attribute
    JOIN pg_catalog.pg_class AS relation ON relation.oid = attribute.attrelid
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
    CROSS JOIN LATERAL pg_catalog.aclexplode(attribute.attacl) AS grant_row
    WHERE namespace.nspname = 'public'
      AND attribute.attnum > 0
      AND NOT attribute.attisdropped
      AND (grant_row.grantee = 0 OR grant_row.grantee IN (
        SELECT oid FROM pg_catalog.pg_roles
        WHERE rolname IN ('address_atlas_admin', 'address_atlas_runtime')
      ))
  ) THEN
    RAISE EXCEPTION 'public/admin table grants or protected column grants remain';
  END IF;

  IF EXISTS (
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
    WHERE routine.pronamespace = public_schema_oid
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
    WHERE item.typnamespace = public_schema_oid
      AND (item.typtype IN ('d', 'e', 'r', 'm')
           OR (item.typtype = 'c' AND relation.relkind = 'c'))
      AND (grant_row.grantee = 0 OR grant_row.grantee IN (
        SELECT oid FROM pg_catalog.pg_roles
        WHERE rolname IN ('address_atlas_admin', 'address_atlas_runtime')
      ))
  ) THEN
    RAISE EXCEPTION 'runtime/public/admin sequence, routine, or type privileges remain';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_default_acl AS defaults
    CROSS JOIN LATERAL pg_catalog.aclexplode(defaults.defaclacl) AS grant_row
    WHERE defaults.defaclrole IN (owner_oid, admin_oid)
      AND (defaults.defaclnamespace = 0 OR defaults.defaclnamespace = public_schema_oid)
      AND (
        grant_row.grantee = 0
        OR (defaults.defaclrole = owner_oid AND grant_row.grantee IN (admin_oid, runtime_oid))
        OR (defaults.defaclrole = admin_oid AND grant_row.grantee IN (owner_oid, runtime_oid))
      )
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_default_acl
    WHERE defaclrole = owner_oid AND defaclnamespace = 0 AND defaclobjtype = 'f'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_default_acl
    WHERE defaclrole = owner_oid AND defaclnamespace = 0 AND defaclobjtype = 'T'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_default_acl
    WHERE defaclrole = admin_oid AND defaclnamespace = 0 AND defaclobjtype = 'f'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_default_acl
    WHERE defaclrole = admin_oid AND defaclnamespace = 0 AND defaclobjtype = 'T'
  ) THEN
    RAISE EXCEPTION 'owner/admin default privileges retain ambient access';
  END IF;

  IF EXISTS (
    WITH actual AS (
      SELECT COALESCE(role.rolname, 'PUBLIC') AS grantee, grant_row.privilege_type
      FROM pg_catalog.pg_database AS database
      CROSS JOIN LATERAL pg_catalog.aclexplode(
        COALESCE(database.datacl, pg_catalog.acldefault('d', database.datdba))
      ) AS grant_row
      LEFT JOIN pg_catalog.pg_roles AS role ON role.oid = grant_row.grantee
      WHERE database.datname = current_database()
        AND (grant_row.grantee = 0 OR role.rolname IN ('address_atlas_admin', 'address_atlas_runtime'))
    ), expected(grantee, privilege_type) AS (
      VALUES ('address_atlas_admin', 'CONNECT'), ('address_atlas_runtime', 'CONNECT')
    )
    SELECT 1 FROM (
      (SELECT * FROM actual EXCEPT SELECT * FROM expected)
      UNION ALL
      (SELECT * FROM expected EXCEPT SELECT * FROM actual)
    ) AS difference
  ) OR EXISTS (
    WITH actual AS (
      SELECT COALESCE(role.rolname, 'PUBLIC') AS grantee, grant_row.privilege_type
      FROM pg_catalog.pg_namespace AS namespace
      CROSS JOIN LATERAL pg_catalog.aclexplode(
        COALESCE(namespace.nspacl, pg_catalog.acldefault('n', namespace.nspowner))
      ) AS grant_row
      LEFT JOIN pg_catalog.pg_roles AS role ON role.oid = grant_row.grantee
      WHERE namespace.nspname = 'public'
        AND (grant_row.grantee = 0 OR role.rolname IN ('address_atlas_admin', 'address_atlas_runtime'))
    ), expected(grantee, privilege_type) AS (
      VALUES ('address_atlas_admin', 'USAGE'), ('address_atlas_runtime', 'USAGE')
    )
    SELECT 1 FROM (
      (SELECT * FROM actual EXCEPT SELECT * FROM expected)
      UNION ALL
      (SELECT * FROM expected EXCEPT SELECT * FROM actual)
    ) AS difference
  ) THEN
    RAISE EXCEPTION 'database or schema ACLs differ from the exact contract';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_authid
    WHERE rolname IN ('address_atlas_admin', 'address_atlas_runtime')
      AND rolpassword NOT LIKE 'SCRAM-SHA-256$%'
  ) THEN
    RAISE EXCEPTION 'administrative/runtime role passwords must use SCRAM-SHA-256';
  END IF;
END
$contract$;

COMMIT;
SQL
} | "$psql_bin" \
  --host "$database_host" \
  --port "$database_port" \
  --username address_atlas_admin \
  --dbname "$database_name" \
  --no-psqlrc \
  --quiet \
  2>/dev/null
then
  printf 'ROLE_PROVISION_FAILED mode=%s stage=convergence-transaction\n' \
    "$mode" >&2
  exit 74
fi

unset PGPASSWORD POSTGRES_ADMIN_CURRENT_PASSWORD
echo 'Validated isolated admin/owner roles and the exact address_atlas_runtime privilege contract.'
