import { performance } from "node:perf_hooks";
import { Pool, type PoolClient } from "pg";
import { getSyncDatabaseConfig } from "./config";

let pool: Pool | null = null;
let schemaReady: Promise<void> | null = null;
let nextUsagePruneAt = 0;
let usagePruneInFlight: Promise<void> | null = null;

const USAGE_RETENTION_DAYS = 35;
const USAGE_PRUNE_BATCH_SIZE = 10_000;
const USAGE_PRUNE_MAX_BATCHES = 100;
const USAGE_PRUNE_MAX_RUNTIME_MS = 2_000;
const USAGE_PRUNE_INTERVAL_MS = 60 * 60 * 1_000;
const USAGE_PRUNE_RETRY_MS = 60 * 1_000;
const SYNC_SCHEMA_CONTRACT_VERSION = 1;

const SNAPSHOT_USAGE_TRIGGER_BODY = `
DECLARE
  updated_rows bigint;
BEGIN
  EXECUTE pg_catalog.format(
    'UPDATE %I.sync_storage_usage
     SET total_snapshot_bytes = total_snapshot_bytes - $1,
         updated_at = pg_catalog.now()
     WHERE singleton = true
       AND total_snapshot_bytes >= $1',
    TG_TABLE_SCHEMA
  ) USING OLD.byte_size;
  GET DIAGNOSTICS updated_rows = ROW_COUNT;
  IF updated_rows <> 1 THEN
    RAISE EXCEPTION 'Address Atlas snapshot usage counter is missing or inconsistent.'
      USING ERRCODE = '23514';
  END IF;
  RETURN OLD;
END;
`.trim();

const SNAPSHOT_USAGE_TRIGGER_MATCH_SQL = `
  SELECT trigger_row.oid
  FROM pg_catalog.pg_namespace AS namespace
  JOIN pg_catalog.pg_class AS relation
    ON relation.relnamespace = namespace.oid
   AND relation.relname = 'vault_snapshots'
  JOIN pg_catalog.pg_trigger AS trigger_row
    ON trigger_row.tgrelid = relation.oid
  JOIN pg_catalog.pg_proc AS trigger_proc
    ON trigger_proc.oid = trigger_row.tgfoid
  JOIN pg_catalog.pg_language AS proc_language
    ON proc_language.oid = trigger_proc.prolang
  WHERE namespace.nspname = current_schema()
    AND trigger_row.tgname = 'address_atlas_snapshot_delete_usage'
    AND NOT trigger_row.tgisinternal
    AND trigger_row.tgenabled = 'O'
    -- PostgreSQL's trigger bitmask for AFTER DELETE FOR EACH ROW:
    -- ROW (1) + DELETE (8), with no BEFORE/INSTEAD/other-event bits.
    AND trigger_row.tgtype = 9
    AND trigger_row.tgqual IS NULL
    AND trigger_row.tgconstraint = 0::oid
    AND trigger_row.tgparentid = 0::oid
    AND NOT trigger_row.tgdeferrable
    AND NOT trigger_row.tginitdeferred
    AND trigger_row.tgnargs = 0
    AND octet_length(trigger_row.tgargs) = 0
    AND trigger_row.tgoldtable IS NULL
    AND trigger_row.tgnewtable IS NULL
    AND trigger_proc.proname = 'address_atlas_decrement_snapshot_usage'
    AND trigger_proc.pronamespace = namespace.oid
    AND trigger_proc.prokind = 'f'
    AND trigger_proc.pronargs = 0
    AND trigger_proc.pronargdefaults = 0
    AND trigger_proc.provariadic = 0::oid
    AND trigger_proc.proallargtypes IS NULL
    AND trigger_proc.prorettype = 'trigger'::regtype
    AND NOT trigger_proc.proretset
    AND proc_language.lanname = 'plpgsql'
    AND trigger_proc.provolatile = 'v'
    AND NOT trigger_proc.proisstrict
    AND NOT trigger_proc.prosecdef
    AND NOT trigger_proc.proleakproof
    AND trigger_proc.proparallel = 'u'
    AND trigger_proc.proconfig IS NULL
    AND btrim(regexp_replace(trigger_proc.prosrc, '[[:space:]]+', ' ', 'g')) =
        btrim(regexp_replace($address_atlas_body$${SNAPSHOT_USAGE_TRIGGER_BODY}$address_atlas_body$, '[[:space:]]+', ' ', 'g'))
`;

/**
 * This is deliberately stricter than an existence probe. Every item below is
 * relied on by a runtime query: exact column types determine node-postgres
 * decoding, defaults feed partial INSERTs, non-deferrable unique keys are
 * inferred by ON CONFLICT, checks/FKs preserve quota and account semantics,
 * and the trigger function keeps the global byte counter correct after deletes.
 *
 * The "address-atlas-sync-schema-contract-v2" marker on the first line of the
 * SQL below versions the SQL TEXT only — it is a cache-buster that makes a
 * revised probe distinguishable in prepared-statement caches, logs, and
 * pg_stat_statements. It is unrelated to SYNC_SCHEMA_CONTRACT_VERSION
 * (currently 1), which tracks the reconciled on-disk schema contract; the two
 * advance independently and must not be kept in lockstep.
 */
const SYNC_SCHEMA_READINESS_SQL = `
  /* address-atlas-sync-schema-contract-v2 */
  WITH required_relations(relation_name) AS (
    VALUES
      ('users'),
      ('passkey_credentials'),
      ('consumed_challenges'),
      ('vault_write_usage'),
      ('sync_storage_usage'),
      ('vault_snapshots')
  ),
  required_columns(relation_name, column_name, type_name, default_expression) AS (
    VALUES
      ('users', 'id', 'uuid', NULL::text),
      ('users', 'created_at', 'timestamptz', 'now()'),
      ('users', 'updated_at', 'timestamptz', 'now()'),
      ('passkey_credentials', 'id', 'text', NULL),
      ('passkey_credentials', 'user_id', 'uuid', NULL),
      ('passkey_credentials', 'public_key_base64url', 'text', NULL),
      ('passkey_credentials', 'counter', 'int8', '0'),
      ('passkey_credentials', 'transports', 'jsonb', '''[]''::jsonb'),
      ('passkey_credentials', 'created_at', 'timestamptz', 'now()'),
      ('passkey_credentials', 'updated_at', 'timestamptz', 'now()'),
      ('consumed_challenges', 'challenge', 'text', NULL),
      ('consumed_challenges', 'consumed_at', 'timestamptz', 'now()'),
      ('vault_write_usage', 'user_id', 'uuid', NULL),
      ('vault_write_usage', 'usage_date', 'date', NULL),
      ('vault_write_usage', 'write_count', 'int4', NULL),
      ('vault_write_usage', 'byte_count', 'int8', NULL),
      ('vault_write_usage', 'updated_at', 'timestamptz', 'now()'),
      ('sync_storage_usage', 'singleton', 'bool', 'true'),
      ('sync_storage_usage', 'total_snapshot_bytes', 'int8', NULL),
      ('sync_storage_usage', 'reconciled_contract_version', 'int4', '0'),
      ('sync_storage_usage', 'reconcile_required', 'bool', 'true'),
      ('sync_storage_usage', 'updated_at', 'timestamptz', 'now()'),
      ('vault_snapshots', 'user_id', 'uuid', NULL),
      ('vault_snapshots', 'version', 'int4', NULL),
      ('vault_snapshots', 'envelope', 'jsonb', NULL),
      ('vault_snapshots', 'byte_size', 'int4', NULL),
      ('vault_snapshots', 'checksum', 'text', NULL),
      ('vault_snapshots', 'created_at', 'timestamptz', 'now()'),
      ('vault_snapshots', 'updated_at', 'timestamptz', 'now()')
  ),
  expected_constraints(
    contract_key,
    relation_name,
    constraint_type,
    local_columns,
    foreign_relation_name,
    foreign_columns,
    foreign_update_action,
    foreign_delete_action,
    foreign_match_type,
    check_expression,
    must_be_validated
  ) AS (
    VALUES
      ('users conflict key', 'users', 'k', ARRAY['id']::text[], NULL::text, ARRAY[]::text[], NULL::text, NULL::text, NULL::text, NULL::text, true),
      ('passkey credential conflict key', 'passkey_credentials', 'k', ARRAY['id'], NULL, ARRAY[]::text[], NULL, NULL, NULL, NULL, true),
      ('passkey account foreign key', 'passkey_credentials', 'f', ARRAY['user_id'], 'users', ARRAY['id'], 'a', 'c', 's', NULL, true),
      ('passkey transport bound', 'passkey_credentials', 'c', ARRAY['transports'], NULL, ARRAY[]::text[], NULL, NULL, NULL, '((jsonb_typeof(transports) = ''array''::text) AND (octet_length((transports)::text) <= 2048))', false),
      ('passkey counter uint32 check', 'passkey_credentials', 'c', ARRAY['counter'], NULL, ARRAY[]::text[], NULL, NULL, NULL, '((counter >= 0) AND (counter <= ''4294967295''::bigint))', true),
      ('challenge conflict key', 'consumed_challenges', 'k', ARRAY['challenge'], NULL, ARRAY[]::text[], NULL, NULL, NULL, NULL, true),
      ('vault usage conflict key', 'vault_write_usage', 'k', ARRAY['user_id', 'usage_date'], NULL, ARRAY[]::text[], NULL, NULL, NULL, NULL, true),
      ('vault usage account foreign key', 'vault_write_usage', 'f', ARRAY['user_id'], 'users', ARRAY['id'], 'a', 'c', 's', NULL, true),
      ('vault usage write count check', 'vault_write_usage', 'c', ARRAY['write_count'], NULL, ARRAY[]::text[], NULL, NULL, NULL, '(write_count >= 0)', true),
      ('vault usage byte count check', 'vault_write_usage', 'c', ARRAY['byte_count'], NULL, ARRAY[]::text[], NULL, NULL, NULL, '(byte_count >= 0)', true),
      ('storage singleton conflict key', 'sync_storage_usage', 'k', ARRAY['singleton'], NULL, ARRAY[]::text[], NULL, NULL, NULL, NULL, true),
      ('storage singleton check', 'sync_storage_usage', 'c', ARRAY['singleton'], NULL, ARRAY[]::text[], NULL, NULL, NULL, 'singleton', true),
      ('storage byte count check', 'sync_storage_usage', 'c', ARRAY['total_snapshot_bytes'], NULL, ARRAY[]::text[], NULL, NULL, NULL, '(total_snapshot_bytes >= 0)', true),
      ('storage contract version check', 'sync_storage_usage', 'c', ARRAY['reconciled_contract_version'], NULL, ARRAY[]::text[], NULL, NULL, NULL, '(reconciled_contract_version >= 0)', true),
      ('vault snapshot conflict key', 'vault_snapshots', 'k', ARRAY['user_id'], NULL, ARRAY[]::text[], NULL, NULL, NULL, NULL, true),
      ('vault snapshot account foreign key', 'vault_snapshots', 'f', ARRAY['user_id'], 'users', ARRAY['id'], 'a', 'c', 's', NULL, true),
      ('vault snapshot version bound', 'vault_snapshots', 'c', ARRAY['version'], NULL, ARRAY[]::text[], NULL, NULL, NULL, '((version >= 1) AND (version <= 2000000000))', true),
      ('vault snapshot byte size bound', 'vault_snapshots', 'c', ARRAY['byte_size'], NULL, ARRAY[]::text[], NULL, NULL, NULL, '((byte_size >= 1) AND (byte_size <= 8000000))', true)
  ),
  constraint_matches AS (
    SELECT expected.contract_key, present.oid
    FROM expected_constraints AS expected
    JOIN pg_catalog.pg_namespace AS namespace
      ON namespace.nspname = current_schema()
    JOIN pg_catalog.pg_class AS relation
      ON relation.relnamespace = namespace.oid
     AND relation.relname = expected.relation_name
    JOIN pg_catalog.pg_constraint AS present
      ON present.conrelid = relation.oid
     AND (
       (expected.constraint_type = 'k' AND present.contype IN ('p', 'u'))
       OR present.contype::text = expected.constraint_type
     )
    LEFT JOIN pg_catalog.pg_class AS foreign_relation
      ON foreign_relation.oid = present.confrelid
    LEFT JOIN pg_catalog.pg_namespace AS foreign_namespace
      ON foreign_namespace.oid = foreign_relation.relnamespace
    WHERE ARRAY(
      SELECT attribute.attname::text
      FROM unnest(present.conkey) WITH ORDINALITY AS key(attnum, position)
      JOIN pg_catalog.pg_attribute AS attribute
        ON attribute.attrelid = present.conrelid
       AND attribute.attnum = key.attnum
      ORDER BY key.position
    ) = expected.local_columns
      AND NOT present.condeferrable
      AND NOT present.condeferred
      AND present.conparentid = 0::oid
      AND present.coninhcount = 0
      AND present.conislocal
      AND (NOT expected.must_be_validated OR present.convalidated)
      AND (
        expected.foreign_relation_name IS NULL
        OR (
          foreign_namespace.nspname = current_schema()
          AND foreign_relation.relname = expected.foreign_relation_name
          AND ARRAY(
            SELECT attribute.attname::text
            FROM unnest(present.confkey) WITH ORDINALITY AS key(attnum, position)
            JOIN pg_catalog.pg_attribute AS attribute
              ON attribute.attrelid = present.confrelid
             AND attribute.attnum = key.attnum
            ORDER BY key.position
          ) = expected.foreign_columns
          AND present.confupdtype::text = expected.foreign_update_action
          AND present.confdeltype::text = expected.foreign_delete_action
          AND present.confmatchtype::text = expected.foreign_match_type
        )
      )
      AND (
        expected.check_expression IS NULL
        OR (
          NOT present.connoinherit
          AND regexp_replace(
            btrim(pg_catalog.pg_get_expr(present.conbin, present.conrelid)),
            '[[:space:]]+',
            ' ',
            'g'
          ) = expected.check_expression
        )
      )
      AND (
        expected.constraint_type <> 'f'
        OR (
          SELECT count(*) = 4
             AND bool_and(internal_trigger.tgisinternal)
             AND bool_and(internal_trigger.tgenabled = 'O')
          FROM pg_catalog.pg_trigger AS internal_trigger
          WHERE internal_trigger.tgconstraint = present.oid
        )
      )
      AND (
        expected.constraint_type <> 'k'
        OR EXISTS (
          SELECT 1
          FROM pg_catalog.pg_index AS backing_index
          WHERE backing_index.indexrelid = present.conindid
            AND backing_index.indisunique
            AND backing_index.indisvalid
            AND backing_index.indisready
            AND backing_index.indislive
            AND backing_index.indimmediate
            AND backing_index.indpred IS NULL
            AND backing_index.indexprs IS NULL
        )
      )
  ),
  expected_indexes(index_name, relation_name, column_name) AS (
    VALUES
      ('consumed_challenges_consumed_at_idx', 'consumed_challenges', 'consumed_at'),
      ('vault_write_usage_date_idx', 'vault_write_usage', 'usage_date')
  ),
  matching_indexes AS (
    SELECT expected.index_name
    FROM expected_indexes AS expected
    JOIN pg_catalog.pg_namespace AS namespace
      ON namespace.nspname = current_schema()
    JOIN pg_catalog.pg_class AS relation
      ON relation.relnamespace = namespace.oid
     AND relation.relname = expected.relation_name
    JOIN pg_catalog.pg_class AS index_relation
      ON index_relation.relnamespace = namespace.oid
     AND index_relation.relname = expected.index_name
    JOIN pg_catalog.pg_index AS present
      ON present.indexrelid = index_relation.oid
     AND present.indrelid = relation.oid
    JOIN pg_catalog.pg_am AS access_method
      ON access_method.oid = index_relation.relam
    WHERE index_relation.relkind = 'i'
      AND index_relation.relpersistence = 'p'
      AND access_method.amname = 'btree'
      AND NOT present.indisunique
      AND NOT present.indisexclusion
      AND present.indisvalid
      AND present.indisready
      AND present.indislive
      AND NOT present.indcheckxmin
      AND present.indnkeyatts = 1
      AND present.indnatts = 1
      AND present.indpred IS NULL
      AND present.indexprs IS NULL
      AND ARRAY(
        SELECT attribute.attname::text
        FROM unnest(present.indkey::smallint[]) WITH ORDINALITY AS key(attnum, position)
        JOIN pg_catalog.pg_attribute AS attribute
          ON attribute.attrelid = present.indrelid
         AND attribute.attnum = key.attnum
        WHERE key.position <= present.indnkeyatts
        ORDER BY key.position
      ) = ARRAY[expected.column_name]
      AND (
        SELECT count(*)
        FROM unnest(present.indkey::smallint[], present.indclass::oid[])
          WITH ORDINALITY AS key(attnum, opclass_oid, position)
        WHERE key.position <= present.indnkeyatts
      ) = present.indnkeyatts
      AND NOT EXISTS (
        SELECT 1
        FROM unnest(present.indkey::smallint[], present.indclass::oid[])
          WITH ORDINALITY AS key(attnum, opclass_oid, position)
        LEFT JOIN pg_catalog.pg_attribute AS indexed_attribute
          ON indexed_attribute.attrelid = present.indrelid
         AND indexed_attribute.attnum = key.attnum
        LEFT JOIN pg_catalog.pg_opclass AS operator_class
          ON operator_class.oid = key.opclass_oid
        LEFT JOIN pg_catalog.pg_namespace AS operator_namespace
          ON operator_namespace.oid = operator_class.opcnamespace
        WHERE key.position <= present.indnkeyatts
          AND (
            key.attnum <= 0
            OR indexed_attribute.attnum IS NULL
            OR indexed_attribute.attlen <= 0
            OR operator_class.oid IS NULL
            OR NOT operator_class.opcdefault
            OR operator_class.opcmethod <> index_relation.relam
            OR operator_class.opcintype <> indexed_attribute.atttypid
            OR operator_namespace.nspname <> 'pg_catalog'
          )
      )
  ),
  matching_snapshot_trigger AS (
    ${SNAPSHOT_USAGE_TRIGGER_MATCH_SQL}
  )
  SELECT
    -- A complete catalog is not writable when this session is read-only, and
    -- ordinary/FK triggers are bypassed under replica mode. Readiness must
    -- describe the behavior of this connection, not just static metadata.
    current_setting('transaction_read_only') = 'off'
    AND current_setting('session_replication_role') <> 'replica'
    AND has_schema_privilege(current_schema(), 'USAGE')
    AND NOT EXISTS (
      SELECT 1
      FROM required_relations AS required
      LEFT JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.nspname = current_schema()
      LEFT JOIN pg_catalog.pg_class AS relation
        ON relation.relnamespace = namespace.oid
       AND relation.relname = required.relation_name
      WHERE relation.oid IS NULL
         OR relation.relkind <> 'r'
         OR relation.relpersistence <> 'p'
         OR relation.relispartition
         OR relation.reloftype <> 0::oid
         OR relation.relrowsecurity
         OR relation.relforcerowsecurity
         OR relation.relhasrules
         OR EXISTS (
           SELECT 1
           FROM pg_catalog.pg_inherits AS inheritance
           WHERE inheritance.inhrelid = relation.oid
              OR inheritance.inhparent = relation.oid
         )
         OR NOT EXISTS (
           SELECT 1
           FROM pg_catalog.pg_am AS table_access_method
           WHERE table_access_method.oid = relation.relam
             AND table_access_method.amname = 'heap'
         )
         OR NOT has_table_privilege(relation.oid, 'SELECT')
         OR NOT has_table_privilege(relation.oid, 'INSERT')
         OR NOT has_table_privilege(relation.oid, 'UPDATE')
         OR NOT has_table_privilege(relation.oid, 'DELETE')
    )
    AND NOT EXISTS (
      SELECT 1
      FROM required_columns AS required
      LEFT JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.nspname = current_schema()
      LEFT JOIN pg_catalog.pg_class AS relation
        ON relation.relnamespace = namespace.oid
       AND relation.relname = required.relation_name
      LEFT JOIN pg_catalog.pg_attribute AS attribute
        ON attribute.attrelid = relation.oid
       AND attribute.attname = required.column_name
       AND attribute.attnum > 0
       AND NOT attribute.attisdropped
      LEFT JOIN pg_catalog.pg_type AS type
        ON type.oid = attribute.atttypid
      LEFT JOIN pg_catalog.pg_namespace AS type_namespace
        ON type_namespace.oid = type.typnamespace
      LEFT JOIN pg_catalog.pg_attrdef AS default_value
        ON default_value.adrelid = attribute.attrelid
       AND default_value.adnum = attribute.attnum
      WHERE attribute.attnum IS NULL
         OR type.typname <> required.type_name
         OR type_namespace.nspname <> 'pg_catalog'
         OR attribute.atttypmod <> -1
         OR attribute.attndims <> 0
         OR NOT attribute.attnotnull
         OR attribute.attidentity <> ''
         OR attribute.attgenerated <> ''
         OR NOT attribute.attislocal
         OR attribute.attinhcount <> 0
         OR attribute.attcollation <> type.typcollation
         OR pg_catalog.pg_get_expr(default_value.adbin, default_value.adrelid)
              IS DISTINCT FROM required.default_expression
    )
    AND NOT EXISTS (
      SELECT 1
      FROM required_relations AS required_relation
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.nspname = current_schema()
      JOIN pg_catalog.pg_class AS relation
        ON relation.relnamespace = namespace.oid
       AND relation.relname = required_relation.relation_name
      JOIN pg_catalog.pg_attribute AS attribute
        ON attribute.attrelid = relation.oid
       AND attribute.attnum > 0
       AND NOT attribute.attisdropped
      LEFT JOIN required_columns AS required_column
        ON required_column.relation_name = required_relation.relation_name
       AND required_column.column_name = attribute.attname
      LEFT JOIN pg_catalog.pg_attrdef AS extra_default
        ON extra_default.adrelid = attribute.attrelid
       AND extra_default.adnum = attribute.attnum
      JOIN pg_catalog.pg_type AS extra_type
        ON extra_type.oid = attribute.atttypid
      JOIN pg_catalog.pg_namespace AS extra_type_namespace
        ON extra_type_namespace.oid = extra_type.typnamespace
      WHERE required_column.column_name IS NULL
        -- A plain nullable built-in column with no default cannot affect the
        -- explicit-column runtime INSERT/UPDATE statements and is safe during
        -- an additive rolling deployment. Everything capable of executing or
        -- requiring behavior on write remains fail-closed.
        AND (
          attribute.attnotnull
          OR extra_default.oid IS NOT NULL
          OR attribute.attidentity <> ''
          OR attribute.attgenerated <> ''
          OR NOT attribute.attislocal
          OR attribute.attinhcount <> 0
          OR extra_type_namespace.nspname <> 'pg_catalog'
          OR extra_type.typtype <> 'b'
        )
    )
    AND NOT EXISTS (
      SELECT expected.contract_key
      FROM expected_constraints AS expected
      LEFT JOIN constraint_matches AS present
        ON present.contract_key = expected.contract_key
      GROUP BY expected.contract_key
      HAVING count(present.oid) <> 1
    )
    AND NOT EXISTS (
      SELECT 1
      FROM required_relations AS required
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.nspname = current_schema()
      JOIN pg_catalog.pg_class AS relation
        ON relation.relnamespace = namespace.oid
       AND relation.relname = required.relation_name
      JOIN pg_catalog.pg_constraint AS present
        ON present.conrelid = relation.oid
       AND present.contype IN ('p', 'u', 'f', 'c', 'x')
      LEFT JOIN constraint_matches AS expected
        ON expected.oid = present.oid
      WHERE expected.oid IS NULL
    )
    AND NOT EXISTS (
      SELECT 1
      FROM required_relations AS required
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.nspname = current_schema()
      JOIN pg_catalog.pg_class AS relation
        ON relation.relnamespace = namespace.oid
       AND relation.relname = required.relation_name
      JOIN pg_catalog.pg_index AS present
        ON present.indrelid = relation.oid
      JOIN pg_catalog.pg_class AS index_relation
        ON index_relation.oid = present.indexrelid
      JOIN pg_catalog.pg_am AS access_method
        ON access_method.oid = index_relation.relam
      LEFT JOIN pg_catalog.pg_constraint AS owning_constraint
        ON owning_constraint.conindid = present.indexrelid
       AND owning_constraint.contype IN ('p', 'u', 'x')
      LEFT JOIN constraint_matches AS expected_constraint
        ON expected_constraint.oid = owning_constraint.oid
      LEFT JOIN matching_indexes AS expected_index
        ON expected_index.index_name = index_relation.relname
      WHERE expected_constraint.oid IS NULL
        AND expected_index.index_name IS NULL
        -- Permit only demonstrably inert tuning indexes: a persistent, valid,
        -- simple default-btree index over fixed-width required built-in columns.
        -- Varlena values can exceed PostgreSQL's per-index-entry limit; partial,
        -- expression, custom-opclass, unique, and exclusion indexes can execute
        -- provider code or reject an otherwise-valid runtime write.
        AND NOT (
          index_relation.relkind = 'i'
          AND index_relation.relpersistence = 'p'
          AND access_method.amname = 'btree'
          AND NOT present.indisunique
          AND NOT present.indisexclusion
          AND present.indisvalid
          AND present.indisready
          AND present.indislive
          AND NOT present.indcheckxmin
          AND present.indnkeyatts > 0
          AND present.indnkeyatts = present.indnatts
          AND present.indpred IS NULL
          AND present.indexprs IS NULL
          AND (
            SELECT count(*)
            FROM unnest(present.indkey::smallint[], present.indclass::oid[])
              WITH ORDINALITY AS key(attnum, opclass_oid, position)
            WHERE key.position <= present.indnkeyatts
          ) = present.indnkeyatts
          AND NOT EXISTS (
            SELECT 1
            FROM unnest(present.indkey::smallint[], present.indclass::oid[])
              WITH ORDINALITY AS key(attnum, opclass_oid, position)
            LEFT JOIN pg_catalog.pg_attribute AS indexed_attribute
              ON indexed_attribute.attrelid = present.indrelid
             AND indexed_attribute.attnum = key.attnum
            LEFT JOIN required_columns AS required_column
              ON required_column.relation_name = required.relation_name
             AND required_column.column_name = indexed_attribute.attname
            LEFT JOIN pg_catalog.pg_opclass AS operator_class
              ON operator_class.oid = key.opclass_oid
            LEFT JOIN pg_catalog.pg_namespace AS operator_namespace
              ON operator_namespace.oid = operator_class.opcnamespace
            WHERE key.position <= present.indnkeyatts
              AND (
                key.attnum <= 0
                OR indexed_attribute.attnum IS NULL
                OR required_column.column_name IS NULL
                OR indexed_attribute.attlen <= 0
                OR operator_class.oid IS NULL
                OR NOT operator_class.opcdefault
                OR operator_class.opcmethod <> index_relation.relam
                OR operator_class.opcintype <> indexed_attribute.atttypid
                OR operator_namespace.oid IS NULL
                OR operator_namespace.nspname <> 'pg_catalog'
              )
          )
        )
    )
    AND NOT EXISTS (
      SELECT 1
      FROM expected_indexes AS expected
      LEFT JOIN matching_indexes AS present
        ON present.index_name = expected.index_name
      WHERE present.index_name IS NULL
    )
    AND EXISTS (SELECT 1 FROM matching_snapshot_trigger)
    AND NOT EXISTS (
      SELECT 1
      FROM required_relations AS required
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.nspname = current_schema()
      JOIN pg_catalog.pg_class AS relation
        ON relation.relnamespace = namespace.oid
       AND relation.relname = required.relation_name
      JOIN pg_catalog.pg_trigger AS present
        ON present.tgrelid = relation.oid
       AND NOT present.tgisinternal
      LEFT JOIN matching_snapshot_trigger AS expected
        ON expected.oid = present.oid
      WHERE expected.oid IS NULL
    )
    AND (
      SELECT count(*) = 1
         AND COALESCE(bool_and(singleton = true AND total_snapshot_bytes >= 0), false)
         AND COALESCE(bool_and(NOT reconcile_required), false)
         AND COALESCE(max(reconciled_contract_version), -1) = ${SYNC_SCHEMA_CONTRACT_VERSION}
      FROM (
        SELECT singleton,
               total_snapshot_bytes,
               reconciled_contract_version,
               reconcile_required
        FROM sync_storage_usage
        LIMIT 2
      ) AS bounded_storage_rows
    ) AS ready
`;

export function getSyncPool() {
  if (!pool) {
    const config = getSyncDatabaseConfig();
    const created = new Pool({
      connectionString: config.connectionString,
      application_name: "address-atlas-sync",
      max: config.poolSize,
      connectionTimeoutMillis: config.connectTimeoutMs,
      idleTimeoutMillis: config.idleTimeoutMs,
      statement_timeout: config.statementTimeoutMs,
      query_timeout: config.queryTimeoutMs
    });
    // node-postgres emits pool-level errors for idle clients that lose their
    // backend connection. Always consume the event so a DB restart cannot turn
    // into an uncaught EventEmitter error and terminate the process.
    created.on("error", () => {
      console.error("An idle Address Atlas Postgres connection failed; readiness checks will retry.");
    });
    pool = created;
  }
  return pool;
}

export async function ensureSyncSchema() {
  if (!schemaReady) {
    const attempt = initializeSchema();
    schemaReady = attempt;
    // A transient startup failure must not permanently poison this process.
    // Clear only our own attempt so a later caller can retry safely.
    void attempt.catch(() => {
      if (schemaReady === attempt) schemaReady = null;
    });
  }
  await schemaReady;
  scheduleOldVaultWriteUsagePrune();
}

/**
 * Probes the schema features every public readiness check depends on. Schema
 * initialization is intentionally cached, so a lightweight independent probe
 * is required to detect operator drift (for example, a dropped table) after
 * startup instead of reporting a false-positive health status.
 */
export async function checkSyncSchemaReadiness() {
  await assertSyncSchemaReadiness(() => getSyncPool().query<{ ready: boolean }>(SYNC_SCHEMA_READINESS_SQL));
}

async function assertSyncSchemaReadiness(
  execute: () => Promise<{ rows: Array<{ ready: boolean }> }>
) {
  const result = await execute();
  if (result.rows[0]?.ready !== true) {
    throw new Error("Address Atlas sync database schema is not ready.");
  }
}

const CORE_SCHEMA_REPAIR_SQL = `
  DO $address_atlas_core_contract$
  DECLARE
    expected record;
    actual_type text;
    actual_type_modifier integer;
    actual_dimensions integer;
    actual_identity "char";
    actual_generated "char";
    actual_not_null boolean;
    actual_default text;
  BEGIN
    -- Defaults and NOT NULL are metadata-only or validation-only repairs. Do
    -- not guess at missing columns, generated/identity state, or type casts:
    -- those require an operator to decide how existing data should migrate.
    FOR expected IN
      SELECT *
      FROM (VALUES
        ('users', 'id', 'uuid', NULL::text, NULL::text),
        ('users', 'created_at', 'timestamptz', 'now()', 'now()'),
        ('users', 'updated_at', 'timestamptz', 'now()', 'now()'),
        ('passkey_credentials', 'id', 'text', NULL, NULL),
        ('passkey_credentials', 'user_id', 'uuid', NULL, NULL),
        ('passkey_credentials', 'public_key_base64url', 'text', NULL, NULL),
        ('passkey_credentials', 'counter', 'int8', '0', '0'),
        ('passkey_credentials', 'transports', 'jsonb', '''[]''::jsonb', '''[]''::jsonb'),
        ('passkey_credentials', 'created_at', 'timestamptz', 'now()', 'now()'),
        ('passkey_credentials', 'updated_at', 'timestamptz', 'now()', 'now()'),
        ('consumed_challenges', 'challenge', 'text', NULL, NULL),
        ('consumed_challenges', 'consumed_at', 'timestamptz', 'now()', 'now()'),
        ('vault_write_usage', 'user_id', 'uuid', NULL, NULL),
        ('vault_write_usage', 'usage_date', 'date', NULL, NULL),
        ('vault_write_usage', 'write_count', 'int4', NULL, NULL),
        ('vault_write_usage', 'byte_count', 'int8', NULL, NULL),
        ('vault_write_usage', 'updated_at', 'timestamptz', 'now()', 'now()'),
        ('sync_storage_usage', 'singleton', 'bool', 'true', 'true'),
        ('sync_storage_usage', 'total_snapshot_bytes', 'int8', NULL, NULL),
        ('sync_storage_usage', 'reconciled_contract_version', 'int4', '0', '0'),
        ('sync_storage_usage', 'reconcile_required', 'bool', 'true', 'true'),
        ('sync_storage_usage', 'updated_at', 'timestamptz', 'now()', 'now()')
      ) AS contract(relation_name, column_name, type_name, default_expression, default_ddl)
    LOOP
      SELECT
        type.typname,
        attribute.atttypmod,
        attribute.attndims,
        attribute.attidentity,
        attribute.attgenerated,
        attribute.attnotnull,
        pg_catalog.pg_get_expr(default_value.adbin, default_value.adrelid)
      INTO
        actual_type,
        actual_type_modifier,
        actual_dimensions,
        actual_identity,
        actual_generated,
        actual_not_null,
        actual_default
      FROM pg_catalog.pg_namespace AS namespace
      JOIN pg_catalog.pg_class AS relation
        ON relation.relnamespace = namespace.oid
       AND relation.relname = expected.relation_name
      JOIN pg_catalog.pg_attribute AS attribute
        ON attribute.attrelid = relation.oid
       AND attribute.attname = expected.column_name
       AND attribute.attnum > 0
       AND NOT attribute.attisdropped
      JOIN pg_catalog.pg_type AS type
        ON type.oid = attribute.atttypid
      LEFT JOIN pg_catalog.pg_attrdef AS default_value
        ON default_value.adrelid = attribute.attrelid
       AND default_value.adnum = attribute.attnum
      WHERE namespace.nspname = current_schema();

      IF FOUND
         AND actual_type = expected.type_name
         AND actual_type_modifier = -1
         AND actual_dimensions = 0
         AND actual_identity = ''
         AND actual_generated = '' THEN
        IF NOT actual_not_null THEN
          EXECUTE format(
            'ALTER TABLE %I.%I ALTER COLUMN %I SET NOT NULL',
            current_schema(), expected.relation_name, expected.column_name
          );
        END IF;
        IF actual_default IS DISTINCT FROM expected.default_expression THEN
          IF expected.default_ddl IS NULL THEN
            EXECUTE format(
              'ALTER TABLE %I.%I ALTER COLUMN %I DROP DEFAULT',
              current_schema(), expected.relation_name, expected.column_name
            );
          ELSE
            EXECUTE format(
              'ALTER TABLE %I.%I ALTER COLUMN %I SET DEFAULT %s',
              current_schema(), expected.relation_name, expected.column_name, expected.default_ddl
            );
          END IF;
        END IF;
      END IF;
    END LOOP;

    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_constraint
      WHERE conrelid = 'users'::regclass
        AND contype IN ('p', 'u')
        AND NOT condeferrable
        AND conkey = ARRAY[(
          SELECT attnum FROM pg_catalog.pg_attribute
          WHERE attrelid = 'users'::regclass AND attname = 'id'
        )]::smallint[]
    ) THEN
      ALTER TABLE users ADD CONSTRAINT users_pkey PRIMARY KEY (id);
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_constraint
      WHERE conrelid = 'passkey_credentials'::regclass
        AND contype IN ('p', 'u')
        AND NOT condeferrable
        AND conkey = ARRAY[(
          SELECT attnum FROM pg_catalog.pg_attribute
          WHERE attrelid = 'passkey_credentials'::regclass AND attname = 'id'
        )]::smallint[]
    ) THEN
      ALTER TABLE passkey_credentials ADD CONSTRAINT passkey_credentials_pkey PRIMARY KEY (id);
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_constraint
      WHERE conrelid = 'consumed_challenges'::regclass
        AND contype IN ('p', 'u')
        AND NOT condeferrable
        AND conkey = ARRAY[(
          SELECT attnum FROM pg_catalog.pg_attribute
          WHERE attrelid = 'consumed_challenges'::regclass AND attname = 'challenge'
        )]::smallint[]
    ) THEN
      ALTER TABLE consumed_challenges ADD CONSTRAINT consumed_challenges_pkey PRIMARY KEY (challenge);
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_constraint
      WHERE conrelid = 'vault_write_usage'::regclass
        AND contype IN ('p', 'u')
        AND NOT condeferrable
        AND conkey = ARRAY[
          (SELECT attnum FROM pg_catalog.pg_attribute WHERE attrelid = 'vault_write_usage'::regclass AND attname = 'user_id'),
          (SELECT attnum FROM pg_catalog.pg_attribute WHERE attrelid = 'vault_write_usage'::regclass AND attname = 'usage_date')
        ]::smallint[]
    ) THEN
      ALTER TABLE vault_write_usage
        ADD CONSTRAINT vault_write_usage_pkey PRIMARY KEY (user_id, usage_date);
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_constraint
      WHERE conrelid = 'sync_storage_usage'::regclass
        AND contype IN ('p', 'u')
        AND NOT condeferrable
        AND conkey = ARRAY[(
          SELECT attnum FROM pg_catalog.pg_attribute
          WHERE attrelid = 'sync_storage_usage'::regclass AND attname = 'singleton'
        )]::smallint[]
    ) THEN
      ALTER TABLE sync_storage_usage ADD CONSTRAINT sync_storage_usage_pkey PRIMARY KEY (singleton);
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_constraint
      WHERE conrelid = 'passkey_credentials'::regclass
        AND contype = 'f'
        AND conkey = ARRAY[(
          SELECT attnum FROM pg_catalog.pg_attribute
          WHERE attrelid = 'passkey_credentials'::regclass AND attname = 'user_id'
        )]::smallint[]
        AND confrelid = 'users'::regclass
        AND confkey = ARRAY[(
          SELECT attnum FROM pg_catalog.pg_attribute
          WHERE attrelid = 'users'::regclass AND attname = 'id'
        )]::smallint[]
        AND confupdtype = 'a'
        AND confdeltype = 'c'
        AND confmatchtype = 's'
        AND NOT condeferrable
        AND NOT condeferred
        AND conparentid = 0::oid
        AND coninhcount = 0
        AND conislocal
    ) THEN
      ALTER TABLE passkey_credentials
        ADD CONSTRAINT passkey_credentials_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE NOT VALID;
      ALTER TABLE passkey_credentials VALIDATE CONSTRAINT passkey_credentials_user_id_fkey;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_constraint
      WHERE conrelid = 'vault_write_usage'::regclass
        AND contype = 'f'
        AND conkey = ARRAY[(
          SELECT attnum FROM pg_catalog.pg_attribute
          WHERE attrelid = 'vault_write_usage'::regclass AND attname = 'user_id'
        )]::smallint[]
        AND confrelid = 'users'::regclass
        AND confkey = ARRAY[(
          SELECT attnum FROM pg_catalog.pg_attribute
          WHERE attrelid = 'users'::regclass AND attname = 'id'
        )]::smallint[]
        AND confupdtype = 'a'
        AND confdeltype = 'c'
        AND confmatchtype = 's'
        AND NOT condeferrable
        AND NOT condeferred
        AND conparentid = 0::oid
        AND coninhcount = 0
        AND conislocal
    ) THEN
      ALTER TABLE vault_write_usage
        ADD CONSTRAINT vault_write_usage_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE NOT VALID;
      ALTER TABLE vault_write_usage VALIDATE CONSTRAINT vault_write_usage_user_id_fkey;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_constraint
      WHERE conrelid = 'passkey_credentials'::regclass
        AND contype = 'c'
        AND NOT connoinherit
        AND conparentid = 0::oid
        AND coninhcount = 0
        AND conislocal
        AND regexp_replace(
          btrim(pg_catalog.pg_get_expr(conbin, conrelid)),
          '[[:space:]]+', ' ', 'g'
        ) = '((jsonb_typeof(transports) = ''array''::text) AND (octet_length((transports)::text) <= 2048))'
    ) THEN
      ALTER TABLE passkey_credentials
        ADD CONSTRAINT passkey_credentials_transports_bounded
        CHECK (jsonb_typeof(transports) = 'array' AND octet_length(transports::text) <= 2048)
        NOT VALID;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_constraint
      WHERE conrelid = 'passkey_credentials'::regclass
        AND contype = 'c'
        AND NOT connoinherit
        AND conparentid = 0::oid
        AND coninhcount = 0
        AND conislocal
        AND regexp_replace(
          btrim(pg_catalog.pg_get_expr(conbin, conrelid)),
          '[[:space:]]+', ' ', 'g'
        ) = '((counter >= 0) AND (counter <= ''4294967295''::bigint))'
    ) THEN
      ALTER TABLE passkey_credentials
        ADD CONSTRAINT passkey_credentials_counter_uint32_check
        CHECK (counter BETWEEN 0 AND 4294967295) NOT VALID;
      ALTER TABLE passkey_credentials
        VALIDATE CONSTRAINT passkey_credentials_counter_uint32_check;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_constraint
      WHERE conrelid = 'vault_write_usage'::regclass
        AND contype = 'c'
        AND NOT connoinherit
        AND conparentid = 0::oid
        AND coninhcount = 0
        AND conislocal
        AND regexp_replace(
          btrim(pg_catalog.pg_get_expr(conbin, conrelid)),
          '[[:space:]]+', ' ', 'g'
        ) = '(write_count >= 0)'
    ) THEN
      ALTER TABLE vault_write_usage
        ADD CONSTRAINT vault_write_usage_write_count_check CHECK (write_count >= 0) NOT VALID;
      ALTER TABLE vault_write_usage VALIDATE CONSTRAINT vault_write_usage_write_count_check;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_constraint
      WHERE conrelid = 'vault_write_usage'::regclass
        AND contype = 'c'
        AND NOT connoinherit
        AND conparentid = 0::oid
        AND coninhcount = 0
        AND conislocal
        AND regexp_replace(
          btrim(pg_catalog.pg_get_expr(conbin, conrelid)),
          '[[:space:]]+', ' ', 'g'
        ) = '(byte_count >= 0)'
    ) THEN
      ALTER TABLE vault_write_usage
        ADD CONSTRAINT vault_write_usage_byte_count_check CHECK (byte_count >= 0) NOT VALID;
      ALTER TABLE vault_write_usage VALIDATE CONSTRAINT vault_write_usage_byte_count_check;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_constraint
      WHERE conrelid = 'sync_storage_usage'::regclass
        AND contype = 'c'
        AND NOT connoinherit
        AND conparentid = 0::oid
        AND coninhcount = 0
        AND conislocal
        AND regexp_replace(
          btrim(pg_catalog.pg_get_expr(conbin, conrelid)),
          '[[:space:]]+', ' ', 'g'
        ) = 'singleton'
    ) THEN
      ALTER TABLE sync_storage_usage
        ADD CONSTRAINT sync_storage_usage_singleton_check CHECK (singleton) NOT VALID;
      ALTER TABLE sync_storage_usage VALIDATE CONSTRAINT sync_storage_usage_singleton_check;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_constraint
      WHERE conrelid = 'sync_storage_usage'::regclass
        AND contype = 'c'
        AND NOT connoinherit
        AND conparentid = 0::oid
        AND coninhcount = 0
        AND conislocal
        AND regexp_replace(
          btrim(pg_catalog.pg_get_expr(conbin, conrelid)),
          '[[:space:]]+', ' ', 'g'
        ) = '(total_snapshot_bytes >= 0)'
    ) THEN
      ALTER TABLE sync_storage_usage
        ADD CONSTRAINT sync_storage_usage_total_snapshot_bytes_check
        CHECK (total_snapshot_bytes >= 0) NOT VALID;
      ALTER TABLE sync_storage_usage
        VALIDATE CONSTRAINT sync_storage_usage_total_snapshot_bytes_check;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_constraint
      WHERE conrelid = 'sync_storage_usage'::regclass
        AND contype = 'c'
        AND NOT connoinherit
        AND conparentid = 0::oid
        AND coninhcount = 0
        AND conislocal
        AND regexp_replace(
          btrim(pg_catalog.pg_get_expr(conbin, conrelid)),
          '[[:space:]]+', ' ', 'g'
        ) = '(reconciled_contract_version >= 0)'
    ) THEN
      ALTER TABLE sync_storage_usage
        ADD CONSTRAINT sync_storage_usage_reconciled_contract_version_check
        CHECK (reconciled_contract_version >= 0) NOT VALID;
    END IF;

    -- A semantically exact renamed constraint is safe to validate in place.
    -- Do not require canonical names and do not add a duplicate merely because
    -- an interrupted migration left the object NOT VALID.
    FOR expected IN
      SELECT relation.relname AS relation_name, present.conname AS constraint_name
      FROM pg_catalog.pg_namespace AS namespace
      JOIN pg_catalog.pg_class AS relation
        ON relation.relnamespace = namespace.oid
      JOIN pg_catalog.pg_constraint AS present
        ON present.conrelid = relation.oid
      WHERE namespace.nspname = current_schema()
        AND NOT present.convalidated
        AND NOT present.condeferrable
        AND NOT present.condeferred
        AND present.conparentid = 0::oid
        AND present.coninhcount = 0
        AND present.conislocal
        AND (
          (
            present.contype = 'f'
            AND relation.relname IN ('passkey_credentials', 'vault_write_usage')
            AND present.conkey = ARRAY[(
              SELECT attnum FROM pg_catalog.pg_attribute
              WHERE attrelid = relation.oid AND attname = 'user_id'
            )]::smallint[]
            AND present.confrelid = 'users'::regclass
            AND present.confkey = ARRAY[(
              SELECT attnum FROM pg_catalog.pg_attribute
              WHERE attrelid = 'users'::regclass AND attname = 'id'
            )]::smallint[]
            AND present.confupdtype = 'a'
            AND present.confdeltype = 'c'
            AND present.confmatchtype = 's'
          )
          OR (
            present.contype = 'c'
            AND NOT present.connoinherit
            AND (
              (
                relation.relname = 'passkey_credentials'
                AND present.conkey = ARRAY[(
                  SELECT attnum FROM pg_catalog.pg_attribute
                  WHERE attrelid = relation.oid AND attname = 'counter'
                )]::smallint[]
                AND regexp_replace(
                  btrim(pg_catalog.pg_get_expr(present.conbin, present.conrelid)),
                  '[[:space:]]+', ' ', 'g'
                ) = '((counter >= 0) AND (counter <= ''4294967295''::bigint))'
              )
              OR (
                relation.relname = 'vault_write_usage'
                AND present.conkey = ARRAY[(
                  SELECT attnum FROM pg_catalog.pg_attribute
                  WHERE attrelid = relation.oid AND attname = 'write_count'
                )]::smallint[]
                AND regexp_replace(
                  btrim(pg_catalog.pg_get_expr(present.conbin, present.conrelid)),
                  '[[:space:]]+', ' ', 'g'
                ) = '(write_count >= 0)'
              )
              OR (
                relation.relname = 'vault_write_usage'
                AND present.conkey = ARRAY[(
                  SELECT attnum FROM pg_catalog.pg_attribute
                  WHERE attrelid = relation.oid AND attname = 'byte_count'
                )]::smallint[]
                AND regexp_replace(
                  btrim(pg_catalog.pg_get_expr(present.conbin, present.conrelid)),
                  '[[:space:]]+', ' ', 'g'
                ) = '(byte_count >= 0)'
              )
              OR (
                relation.relname = 'sync_storage_usage'
                AND present.conkey = ARRAY[(
                  SELECT attnum FROM pg_catalog.pg_attribute
                  WHERE attrelid = relation.oid AND attname = 'singleton'
                )]::smallint[]
                AND regexp_replace(
                  btrim(pg_catalog.pg_get_expr(present.conbin, present.conrelid)),
                  '[[:space:]]+', ' ', 'g'
                ) = 'singleton'
              )
              OR (
                relation.relname = 'sync_storage_usage'
                AND present.conkey = ARRAY[(
                  SELECT attnum FROM pg_catalog.pg_attribute
                  WHERE attrelid = relation.oid AND attname = 'total_snapshot_bytes'
                )]::smallint[]
                AND regexp_replace(
                  btrim(pg_catalog.pg_get_expr(present.conbin, present.conrelid)),
                  '[[:space:]]+', ' ', 'g'
                ) = '(total_snapshot_bytes >= 0)'
              )
              OR (
                relation.relname = 'sync_storage_usage'
                AND present.conkey = ARRAY[(
                  SELECT attnum FROM pg_catalog.pg_attribute
                  WHERE attrelid = relation.oid AND attname = 'reconciled_contract_version'
                )]::smallint[]
                AND regexp_replace(
                  btrim(pg_catalog.pg_get_expr(present.conbin, present.conrelid)),
                  '[[:space:]]+', ' ', 'g'
                ) = '(reconciled_contract_version >= 0)'
              )
            )
          )
        )
    LOOP
      EXECUTE format(
        'ALTER TABLE %I.%I VALIDATE CONSTRAINT %I',
        current_schema(), expected.relation_name, expected.constraint_name
      );
    END LOOP;
  END;
  $address_atlas_core_contract$;
`;

const VAULT_SCHEMA_REPAIR_SQL = `
  DO $address_atlas_vault_contract$
  DECLARE
    expected record;
    actual_type text;
    actual_type_modifier integer;
    actual_dimensions integer;
    actual_identity "char";
    actual_generated "char";
    actual_not_null boolean;
    actual_default text;
  BEGIN
    FOR expected IN
      SELECT *
      FROM (VALUES
        ('user_id', 'uuid', NULL::text, NULL::text),
        ('version', 'int4', NULL, NULL),
        ('envelope', 'jsonb', NULL, NULL),
        ('byte_size', 'int4', NULL, NULL),
        ('checksum', 'text', NULL, NULL),
        ('created_at', 'timestamptz', 'now()', 'now()'),
        ('updated_at', 'timestamptz', 'now()', 'now()')
      ) AS contract(column_name, type_name, default_expression, default_ddl)
    LOOP
      SELECT
        type.typname,
        attribute.atttypmod,
        attribute.attndims,
        attribute.attidentity,
        attribute.attgenerated,
        attribute.attnotnull,
        pg_catalog.pg_get_expr(default_value.adbin, default_value.adrelid)
      INTO
        actual_type,
        actual_type_modifier,
        actual_dimensions,
        actual_identity,
        actual_generated,
        actual_not_null,
        actual_default
      FROM pg_catalog.pg_namespace AS namespace
      JOIN pg_catalog.pg_class AS relation
        ON relation.relnamespace = namespace.oid
       AND relation.relname = 'vault_snapshots'
      JOIN pg_catalog.pg_attribute AS attribute
        ON attribute.attrelid = relation.oid
       AND attribute.attname = expected.column_name
       AND attribute.attnum > 0
       AND NOT attribute.attisdropped
      JOIN pg_catalog.pg_type AS type
        ON type.oid = attribute.atttypid
      LEFT JOIN pg_catalog.pg_attrdef AS default_value
        ON default_value.adrelid = attribute.attrelid
       AND default_value.adnum = attribute.attnum
      WHERE namespace.nspname = current_schema();

      IF FOUND
         AND actual_type = expected.type_name
         AND actual_type_modifier = -1
         AND actual_dimensions = 0
         AND actual_identity = ''
         AND actual_generated = '' THEN
        IF NOT actual_not_null THEN
          EXECUTE format(
            'ALTER TABLE %I.vault_snapshots ALTER COLUMN %I SET NOT NULL',
            current_schema(), expected.column_name
          );
        END IF;
        IF actual_default IS DISTINCT FROM expected.default_expression THEN
          IF expected.default_ddl IS NULL THEN
            EXECUTE format(
              'ALTER TABLE %I.vault_snapshots ALTER COLUMN %I DROP DEFAULT',
              current_schema(), expected.column_name
            );
          ELSE
            EXECUTE format(
              'ALTER TABLE %I.vault_snapshots ALTER COLUMN %I SET DEFAULT %s',
              current_schema(), expected.column_name, expected.default_ddl
            );
          END IF;
        END IF;
      END IF;
    END LOOP;

    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_constraint
      WHERE conrelid = 'vault_snapshots'::regclass
        AND contype IN ('p', 'u')
        AND NOT condeferrable
        AND conkey = ARRAY[(
          SELECT attnum FROM pg_catalog.pg_attribute
          WHERE attrelid = 'vault_snapshots'::regclass AND attname = 'user_id'
        )]::smallint[]
    ) THEN
      ALTER TABLE vault_snapshots ADD CONSTRAINT vault_snapshots_pkey PRIMARY KEY (user_id);
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_constraint
      WHERE conrelid = 'vault_snapshots'::regclass
        AND contype = 'f'
        AND conkey = ARRAY[(
          SELECT attnum FROM pg_catalog.pg_attribute
          WHERE attrelid = 'vault_snapshots'::regclass AND attname = 'user_id'
        )]::smallint[]
        AND confrelid = 'users'::regclass
        AND confkey = ARRAY[(
          SELECT attnum FROM pg_catalog.pg_attribute
          WHERE attrelid = 'users'::regclass AND attname = 'id'
        )]::smallint[]
        AND confupdtype = 'a'
        AND confdeltype = 'c'
        AND confmatchtype = 's'
        AND NOT condeferrable
        AND NOT condeferred
        AND conparentid = 0::oid
        AND coninhcount = 0
        AND conislocal
    ) THEN
      ALTER TABLE vault_snapshots
        ADD CONSTRAINT vault_snapshots_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE NOT VALID;
      ALTER TABLE vault_snapshots VALIDATE CONSTRAINT vault_snapshots_user_id_fkey;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_constraint
      WHERE conrelid = 'vault_snapshots'::regclass
        AND contype = 'c'
        AND conkey = ARRAY[(
          SELECT attnum FROM pg_catalog.pg_attribute
          WHERE attrelid = 'vault_snapshots'::regclass AND attname = 'version'
        )]::smallint[]
        AND NOT connoinherit
        AND conparentid = 0::oid
        AND coninhcount = 0
        AND conislocal
        AND regexp_replace(
          btrim(pg_catalog.pg_get_expr(conbin, conrelid)),
          '[[:space:]]+', ' ', 'g'
        ) = '((version >= 1) AND (version <= 2000000000))'
    ) THEN
      ALTER TABLE vault_snapshots
        ADD CONSTRAINT vault_snapshots_version_bound_check
        CHECK (version BETWEEN 1 AND 2000000000) NOT VALID;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_constraint
      WHERE conrelid = 'vault_snapshots'::regclass
        AND contype = 'c'
        AND conkey = ARRAY[(
          SELECT attnum FROM pg_catalog.pg_attribute
          WHERE attrelid = 'vault_snapshots'::regclass AND attname = 'byte_size'
        )]::smallint[]
        AND NOT connoinherit
        AND conparentid = 0::oid
        AND coninhcount = 0
        AND conislocal
        AND regexp_replace(
          btrim(pg_catalog.pg_get_expr(conbin, conrelid)),
          '[[:space:]]+', ' ', 'g'
        ) = '((byte_size >= 1) AND (byte_size <= 8000000))'
    ) THEN
      ALTER TABLE vault_snapshots
        ADD CONSTRAINT vault_snapshots_byte_size_bound_check
        CHECK (byte_size BETWEEN 1 AND 8000000) NOT VALID;
    END IF;

    -- Validate semantically exact renamed objects left by an interrupted
    -- migration. A weaker same-name object is deliberately not replaced.
    FOR expected IN
      SELECT present.conname AS constraint_name
      FROM pg_catalog.pg_constraint AS present
      WHERE present.conrelid = 'vault_snapshots'::regclass
        AND NOT present.convalidated
        AND NOT present.condeferrable
        AND NOT present.condeferred
        AND present.conparentid = 0::oid
        AND present.coninhcount = 0
        AND present.conislocal
        AND (
          (
            present.contype = 'f'
            AND present.conkey = ARRAY[(
              SELECT attnum FROM pg_catalog.pg_attribute
              WHERE attrelid = 'vault_snapshots'::regclass AND attname = 'user_id'
            )]::smallint[]
            AND present.confrelid = 'users'::regclass
            AND present.confkey = ARRAY[(
              SELECT attnum FROM pg_catalog.pg_attribute
              WHERE attrelid = 'users'::regclass AND attname = 'id'
            )]::smallint[]
            AND present.confupdtype = 'a'
            AND present.confdeltype = 'c'
            AND present.confmatchtype = 's'
          )
          OR (
            present.contype = 'c'
            AND NOT present.connoinherit
            AND (
              (
                present.conkey = ARRAY[(
                  SELECT attnum FROM pg_catalog.pg_attribute
                  WHERE attrelid = 'vault_snapshots'::regclass AND attname = 'version'
                )]::smallint[]
                AND regexp_replace(
                  btrim(pg_catalog.pg_get_expr(present.conbin, present.conrelid)),
                  '[[:space:]]+', ' ', 'g'
                ) = '((version >= 1) AND (version <= 2000000000))'
              )
              OR (
                present.conkey = ARRAY[(
                  SELECT attnum FROM pg_catalog.pg_attribute
                  WHERE attrelid = 'vault_snapshots'::regclass AND attname = 'byte_size'
                )]::smallint[]
                AND regexp_replace(
                  btrim(pg_catalog.pg_get_expr(present.conbin, present.conrelid)),
                  '[[:space:]]+', ' ', 'g'
                ) = '((byte_size >= 1) AND (byte_size <= 8000000))'
              )
            )
          )
        )
    LOOP
      EXECUTE format(
        'ALTER TABLE %I.vault_snapshots VALIDATE CONSTRAINT %I',
        current_schema(), expected.constraint_name
      );
    END LOOP;
  END;
  $address_atlas_vault_contract$;
`;

async function initializeSchema() {
  const client = await getSyncPool().connect();
  let discardClient = false;
  let migrationLockHeld = false;
  let lockAcquisitionAmbiguous = true;
  try {
    // Hold a session-level lock across separately committed phases so replicas
    // cannot race the migration. Treat a timed-out acquisition as ambiguous and
    // discard that connection: the server may acquire the lock after pg's client
    // callback has already timed out.
    await client.query("SELECT pg_advisory_lock(1094992973)");
    migrationLockHeld = true;
    lockAcquisitionAmbiguous = false;

    // A binary from an older release must not partially rewrite a schema that
    // a newer release has already migrated. Probe the marker before any DDL.
    await assertNoNewerSchemaContract(client);

    await runTransaction(client, [
      `
      CREATE TABLE IF NOT EXISTS users (
        id uuid PRIMARY KEY,
        created_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now()
      )
      `,
      `
      CREATE TABLE IF NOT EXISTS passkey_credentials (
        id text PRIMARY KEY,
        user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        public_key_base64url text NOT NULL,
        counter bigint NOT NULL DEFAULT 0,
        transports jsonb NOT NULL DEFAULT '[]'::jsonb,
        created_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now(),
        CONSTRAINT passkey_credentials_counter_uint32_check
          CHECK (counter BETWEEN 0 AND 4294967295)
      )
      `,
      // Keep the legacy column during rolling deploys, but new code neither
      // reads nor writes authenticator-controlled transport hints. Restore it
      // if a partial deployment already dropped it and bound old-node writes.
      `
      ALTER TABLE passkey_credentials
        ADD COLUMN IF NOT EXISTS transports jsonb NOT NULL DEFAULT '[]'::jsonb
      `,
      `
      CREATE TABLE IF NOT EXISTS consumed_challenges (
        challenge text PRIMARY KEY,
        consumed_at timestamptz NOT NULL DEFAULT now()
      )
      `,
      `
      CREATE INDEX IF NOT EXISTS consumed_challenges_consumed_at_idx
        ON consumed_challenges (consumed_at)
      `,
      `
      CREATE TABLE IF NOT EXISTS vault_write_usage (
        user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        usage_date date NOT NULL,
        write_count integer NOT NULL CHECK (write_count >= 0),
        byte_count bigint NOT NULL CHECK (byte_count >= 0),
        updated_at timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY (user_id, usage_date)
      )
      `,
      `
      CREATE INDEX IF NOT EXISTS vault_write_usage_date_idx
        ON vault_write_usage (usage_date)
      `,
      `
      CREATE TABLE IF NOT EXISTS sync_storage_usage (
        singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
        total_snapshot_bytes bigint NOT NULL CHECK (total_snapshot_bytes >= 0),
        reconciled_contract_version integer NOT NULL DEFAULT 0
          CHECK (reconciled_contract_version >= 0),
        reconcile_required boolean NOT NULL DEFAULT true,
        updated_at timestamptz NOT NULL DEFAULT now()
      )
      `,
      `
      ALTER TABLE sync_storage_usage
        ADD COLUMN IF NOT EXISTS reconciled_contract_version integer NOT NULL DEFAULT 0
      `,
      `
      ALTER TABLE sync_storage_usage
        ADD COLUMN IF NOT EXISTS reconcile_required boolean NOT NULL DEFAULT true
      `,
      CORE_SCHEMA_REPAIR_SQL,
      `
      INSERT INTO sync_storage_usage (singleton, total_snapshot_bytes)
      VALUES (true, 0)
      ON CONFLICT (singleton) DO NOTHING
      `
    ]);

    // Keep vault-table DDL in a different transaction from the singleton insert.
    // Old app versions lock these resources in the opposite order, so no
    // migration transaction may hold both during a rolling deployment.
    await runTransaction(client, [
      `
      CREATE TABLE IF NOT EXISTS vault_snapshots (
        user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
        version integer NOT NULL
          CONSTRAINT vault_snapshots_version_bound_check
          CHECK (version BETWEEN 1 AND 2000000000),
        envelope jsonb NOT NULL,
        byte_size integer NOT NULL
          CONSTRAINT vault_snapshots_byte_size_bound_check
          CHECK (byte_size BETWEEN 1 AND 8000000),
        checksum text NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now()
      )
      `,
      VAULT_SCHEMA_REPAIR_SQL
    ]);

    // Record whether deletes may have run without the exact counter trigger.
    // Keep this transaction separate from vault DDL to avoid holding the global
    // counter row together with a vault-table lock during rolling deployments.
    await runTransaction(client, [
      `
      UPDATE sync_storage_usage
      SET reconcile_required = true,
          updated_at = now()
      WHERE singleton = true
        AND reconciled_contract_version <= ${SYNC_SCHEMA_CONTRACT_VERSION}
        AND NOT EXISTS (
          ${SNAPSHOT_USAGE_TRIGGER_MATCH_SQL}
        )
      `
    ]);

    await runTransaction(client, [
      `
      CREATE OR REPLACE FUNCTION address_atlas_decrement_snapshot_usage()
      RETURNS trigger
      LANGUAGE plpgsql
      VOLATILE
      CALLED ON NULL INPUT
      SECURITY INVOKER
      PARALLEL UNSAFE
      NOT LEAKPROOF
      AS $address_atlas_function$
      ${SNAPSHOT_USAGE_TRIGGER_BODY}
      $address_atlas_function$
      `,
      `ALTER FUNCTION address_atlas_decrement_snapshot_usage() RESET ALL`,
      `
      DO $$
      BEGIN
        IF NOT EXISTS (
          ${SNAPSHOT_USAGE_TRIGGER_MATCH_SQL}
        ) THEN
          DROP TRIGGER IF EXISTS address_atlas_snapshot_delete_usage ON vault_snapshots;
          CREATE TRIGGER address_atlas_snapshot_delete_usage
          AFTER DELETE ON vault_snapshots
          FOR EACH ROW EXECUTE FUNCTION address_atlas_decrement_snapshot_usage();
        END IF;
      END;
      $$
      `
    ]);

    await reconcileStorageUsageIfNeeded(client);

    // Initialization itself must fail closed. Public request handlers cache
    // this promise, so accepting an unrepairable type/constraint drift here
    // would let runtime SQL execute against a schema readiness already rejects.
    await assertSyncSchemaReadiness(
      () => client.query<{ ready: boolean }>(SYNC_SCHEMA_READINESS_SQL)
    );
  } catch (error) {
    discardClient = lockAcquisitionAmbiguous || !(await rollbackQuietly(client));
    throw error;
  } finally {
    if (migrationLockHeld && !discardClient) {
      try {
        await client.query("SELECT pg_advisory_unlock(1094992973)");
      } catch {
        // A session lock must never return to the pool after an ambiguous unlock.
        discardClient = true;
      }
    }
    if (discardClient) client.release(true);
    else client.release();
  }
}

async function runTransaction(client: PoolClient, statements: string[]) {
  await client.query("BEGIN");
  for (const statement of statements) {
    await client.query(statement);
  }
  await client.query("COMMIT");
}

async function assertNoNewerSchemaContract(client: PoolClient) {
  const metadata = await client.query<{
    schema_name: string;
    relation_oid: string;
    relation_shape_safe: boolean;
    marker_exists: boolean;
    marker_shape_safe: boolean;
  }>(
    `/* address-atlas-schema-version-probe */
     SELECT namespace.nspname AS schema_name,
            relation.oid::text AS relation_oid,
            (
              relation.relkind = 'r'
              AND relation.relpersistence = 'p'
              AND NOT relation.relispartition
              AND relation.reloftype = 0::oid
              AND NOT relation.relrowsecurity
              AND NOT relation.relforcerowsecurity
              AND NOT relation.relhasrules
              AND table_access_method.amname = 'heap'
              AND NOT EXISTS (
                SELECT 1
                FROM pg_catalog.pg_inherits AS inheritance
                WHERE inheritance.inhrelid = relation.oid
                   OR inheritance.inhparent = relation.oid
              )
            ) AS relation_shape_safe,
            marker.attnum IS NOT NULL AS marker_exists,
            COALESCE(
              type_namespace.nspname = 'pg_catalog'
              AND type.typname = 'int4'
              AND marker.atttypmod = -1
              AND marker.attndims = 0
              AND marker.attnotnull
              AND marker.attislocal
              AND marker.attinhcount = 0
              AND marker.attidentity = ''
              AND marker.attgenerated = ''
              AND marker.attcollation = type.typcollation
              AND pg_catalog.pg_get_expr(marker_default.adbin, marker_default.adrelid) = '0',
              false
            ) AS marker_shape_safe
     FROM pg_catalog.pg_namespace AS namespace
     JOIN pg_catalog.pg_class AS relation
       ON relation.relnamespace = namespace.oid
      AND relation.relname = 'sync_storage_usage'
     LEFT JOIN pg_catalog.pg_attribute AS marker
       ON marker.attrelid = relation.oid
      AND marker.attname = 'reconciled_contract_version'
      AND marker.attnum > 0
      AND NOT marker.attisdropped
     LEFT JOIN pg_catalog.pg_type AS type
       ON type.oid = marker.atttypid
     LEFT JOIN pg_catalog.pg_namespace AS type_namespace
       ON type_namespace.oid = type.typnamespace
     LEFT JOIN pg_catalog.pg_attrdef AS marker_default
       ON marker_default.adrelid = marker.attrelid
      AND marker_default.adnum = marker.attnum
     LEFT JOIN pg_catalog.pg_am AS table_access_method
       ON table_access_method.oid = relation.relam
     WHERE namespace.nspname = current_schema()
     LIMIT 1`
  );
  const marker = metadata.rows[0];
  if (!marker) return;
  if (!marker.relation_shape_safe) {
    throw new Error("Address Atlas sync database has an unsafe or unsupported schema marker relation.");
  }

  if (!marker.marker_exists) {
    await assertStorageBootstrapSurfaceSafe(client, marker.relation_oid, false);
    return;
  }
  if (!marker.marker_shape_safe) {
    throw new Error("Address Atlas sync database schema marker is unsafe or unsupported.");
  }
  await assertStorageBootstrapSurfaceSafe(client, marker.relation_oid, true);

  const qualifiedTable = `${quotePostgresIdentifier(marker.schema_name)}.sync_storage_usage`;
  const newer = await client.query(
    `SELECT 1
     FROM ${qualifiedTable}
     WHERE reconciled_contract_version > $1
     LIMIT 1`,
    [SYNC_SCHEMA_CONTRACT_VERSION]
  );
  if ((newer.rowCount ?? newer.rows.length) > 0) {
    throw new Error("Address Atlas sync database schema is newer than this server supports.");
  }
}

function quotePostgresIdentifier(identifier: string) {
  return `"${identifier.replaceAll('"', '""')}"`;
}

async function assertStorageBootstrapSurfaceSafe(
  client: PoolClient,
  relationOID: string,
  versioned: boolean
) {
  const columns = await client.query<{
    column_name: string;
    type_name: string;
    type_namespace: string;
    type_modifier: number;
    dimensions: number;
    not_null: boolean;
    identity_kind: string;
    generated_kind: string;
    is_local: boolean;
    inheritance_count: number;
    default_expression: string | null;
    default_collation: boolean;
  }>(
    `SELECT attribute.attname AS column_name,
            type.typname AS type_name,
            type_namespace.nspname AS type_namespace,
            attribute.atttypmod AS type_modifier,
            attribute.attndims AS dimensions,
            attribute.attnotnull AS not_null,
            attribute.attidentity AS identity_kind,
            attribute.attgenerated AS generated_kind,
            attribute.attislocal AS is_local,
            attribute.attinhcount AS inheritance_count,
            pg_catalog.pg_get_expr(default_value.adbin, default_value.adrelid) AS default_expression,
            attribute.attcollation = type.typcollation AS default_collation
     FROM pg_catalog.pg_attribute AS attribute
     JOIN pg_catalog.pg_type AS type ON type.oid = attribute.atttypid
     JOIN pg_catalog.pg_namespace AS type_namespace ON type_namespace.oid = type.typnamespace
     LEFT JOIN pg_catalog.pg_attrdef AS default_value
       ON default_value.adrelid = attribute.attrelid
      AND default_value.adnum = attribute.attnum
     WHERE attribute.attrelid = $1::oid
       AND attribute.attnum > 0
       AND NOT attribute.attisdropped
     ORDER BY attribute.attnum`,
    [relationOID]
  );
  const expectedColumns = new Map<string, { type: string; defaultExpression: string | null }>([
    ["singleton", { type: "bool", defaultExpression: "true" }],
    ["total_snapshot_bytes", { type: "int8", defaultExpression: null }],
    ["updated_at", { type: "timestamptz", defaultExpression: "now()" }]
  ]);
  if (versioned) {
    expectedColumns.set("reconciled_contract_version", { type: "int4", defaultExpression: "0" });
    expectedColumns.set("reconcile_required", { type: "bool", defaultExpression: "true" });
  }
  const columnsAreExact = columns.rows.length === expectedColumns.size
    && columns.rows.every((column) => {
      const expected = expectedColumns.get(column.column_name);
      return expected !== undefined
        && column.type_name === expected.type
        && column.type_namespace === "pg_catalog"
        && column.type_modifier === -1
        && column.dimensions === 0
        && column.not_null
        && column.identity_kind === ""
        && column.generated_kind === ""
        && column.is_local
        && column.inheritance_count === 0
        && column.default_expression === expected.defaultExpression
        && column.default_collation;
    });
  if (!columnsAreExact) {
    throw new Error("Address Atlas sync database has an unrecognized storage bootstrap schema.");
  }

  const constraintsAndIndexes = await client.query<{ safe: boolean }>(
    `WITH matching_constraints AS (
       SELECT present.oid,
              present.conindid,
              CASE
                WHEN present.contype IN ('p', 'u') THEN 'singleton key'
                WHEN pg_catalog.pg_get_expr(present.conbin, present.conrelid) = 'singleton'
                  THEN 'singleton check'
                WHEN pg_catalog.pg_get_expr(present.conbin, present.conrelid) = '(total_snapshot_bytes >= 0)'
                  THEN 'storage check'
                WHEN $2::boolean
                 AND pg_catalog.pg_get_expr(present.conbin, present.conrelid) = '(reconciled_contract_version >= 0)'
                  THEN 'version check'
              END AS contract_key
       FROM pg_catalog.pg_constraint AS present
       WHERE present.conrelid = $1::oid
         AND NOT present.condeferrable
         AND NOT present.condeferred
         AND present.convalidated
         AND present.conparentid = 0::oid
         AND present.coninhcount = 0
         AND present.conislocal
         AND (
           (
             present.contype IN ('p', 'u')
             AND present.conkey = ARRAY[(
               SELECT attnum FROM pg_catalog.pg_attribute
               WHERE attrelid = $1::oid AND attname = 'singleton'
             )]::smallint[]
             AND EXISTS (
               SELECT 1
               FROM pg_catalog.pg_index AS backing_index
               JOIN pg_catalog.pg_class AS index_relation
                 ON index_relation.oid = backing_index.indexrelid
               JOIN pg_catalog.pg_am AS access_method
                 ON access_method.oid = index_relation.relam
               WHERE backing_index.indexrelid = present.conindid
                 AND index_relation.relkind = 'i'
                 AND index_relation.relpersistence = 'p'
                 AND access_method.amname = 'btree'
                 AND backing_index.indisunique
                 AND backing_index.indisvalid
                 AND backing_index.indisready
                 AND backing_index.indislive
                 AND backing_index.indimmediate
                 AND NOT backing_index.indisexclusion
                 AND NOT backing_index.indcheckxmin
                 AND backing_index.indnkeyatts = 1
                 AND backing_index.indnatts = 1
                 AND backing_index.indpred IS NULL
                 AND backing_index.indexprs IS NULL
                 AND (
                   SELECT count(*) = 1
                      AND bool_and(operator_class.opcdefault)
                      AND bool_and(operator_class.opcmethod = index_relation.relam)
                      AND bool_and(operator_class.opcintype = 'boolean'::regtype)
                      AND bool_and(operator_namespace.nspname = 'pg_catalog')
                   FROM unnest(backing_index.indclass::oid[]) AS key(opclass_oid)
                   JOIN pg_catalog.pg_opclass AS operator_class
                     ON operator_class.oid = key.opclass_oid
                   JOIN pg_catalog.pg_namespace AS operator_namespace
                     ON operator_namespace.oid = operator_class.opcnamespace
                 )
             )
           )
           OR (
             present.contype = 'c'
             AND NOT present.connoinherit
             AND present.conkey = ARRAY[(
               SELECT attnum FROM pg_catalog.pg_attribute
               WHERE attrelid = $1::oid AND attname = 'singleton'
             )]::smallint[]
             AND pg_catalog.pg_get_expr(present.conbin, present.conrelid) = 'singleton'
           )
           OR (
             present.contype = 'c'
             AND NOT present.connoinherit
             AND present.conkey = ARRAY[(
               SELECT attnum FROM pg_catalog.pg_attribute
               WHERE attrelid = $1::oid AND attname = 'total_snapshot_bytes'
             )]::smallint[]
             AND pg_catalog.pg_get_expr(present.conbin, present.conrelid) = '(total_snapshot_bytes >= 0)'
           )
           OR (
             $2::boolean
             AND present.contype = 'c'
             AND NOT present.connoinherit
             AND present.conkey = ARRAY[(
               SELECT attnum FROM pg_catalog.pg_attribute
               WHERE attrelid = $1::oid AND attname = 'reconciled_contract_version'
             )]::smallint[]
             AND pg_catalog.pg_get_expr(present.conbin, present.conrelid) = '(reconciled_contract_version >= 0)'
           )
         )
     ),
     relevant_constraints AS (
       SELECT oid
       FROM pg_catalog.pg_constraint
       WHERE conrelid = $1::oid
         AND contype IN ('p', 'u', 'f', 'c', 'x')
     )
     SELECT
       -- A MISSING contract constraint is tolerated here: the bootstrap repair
       -- SQL re-adds every sync_storage_usage constraint (pkey, singleton,
       -- storage, version checks) and final readiness still enforces the full
       -- contract. What must not exist before bootstrap DDL touches this table
       -- is anything unexpected: a constraint outside the known-safe shapes
       -- (e.g. a same-name but weaker check), any trigger, or a stray index.
       (SELECT count(*) FROM relevant_constraints) = (SELECT count(*) FROM matching_constraints)
       AND NOT EXISTS (
         SELECT 1 FROM pg_catalog.pg_trigger WHERE tgrelid = $1::oid
       )
       AND NOT EXISTS (
         SELECT 1
         FROM pg_catalog.pg_index AS present_index
         LEFT JOIN matching_constraints AS owning_contract
           ON owning_contract.conindid = present_index.indexrelid
          AND owning_contract.contract_key = 'singleton key'
         WHERE present_index.indrelid = $1::oid
           AND owning_contract.oid IS NULL
       ) AS safe`,
    [relationOID, versioned]
  );
  if (constraintsAndIndexes.rows[0]?.safe !== true) {
    throw new Error("Address Atlas sync storage bootstrap surface contains unsafe behavior.");
  }
}

async function reconcileStorageUsageIfNeeded(client: PoolClient) {
  await client.query("BEGIN");
  const result = await client.query<{
    reconciled_contract_version: number;
    reconcile_required: boolean;
  }>(
    `SELECT reconciled_contract_version, reconcile_required
     FROM sync_storage_usage
     WHERE singleton = true
     FOR UPDATE`
  );
  const state = result.rows[0];
  if (!state) {
    throw new Error("Address Atlas sync storage usage singleton is missing.");
  }
  if (!Number.isInteger(state.reconciled_contract_version)
      || state.reconciled_contract_version < 0
      || typeof state.reconcile_required !== "boolean") {
    throw new Error("Address Atlas sync storage reconciliation state is invalid.");
  }
  if (state.reconciled_contract_version > SYNC_SCHEMA_CONTRACT_VERSION) {
    throw new Error("Address Atlas sync database schema is newer than this server supports.");
  }

  if (state.reconcile_required
      || state.reconciled_contract_version < SYNC_SCHEMA_CONTRACT_VERSION) {
    await client.query(
      `UPDATE sync_storage_usage
       SET total_snapshot_bytes = totals.total_snapshot_bytes,
           reconciled_contract_version = $1,
           reconcile_required = false,
           updated_at = now()
       FROM (
         SELECT COALESCE(sum(byte_size), 0)::bigint AS total_snapshot_bytes
         FROM vault_snapshots
       ) AS totals
       WHERE singleton = true`,
      [SYNC_SCHEMA_CONTRACT_VERSION]
    );
  }
  await client.query("COMMIT");
}

function scheduleOldVaultWriteUsagePrune() {
  const now = performance.now();
  if (usagePruneInFlight) return;
  if (now < nextUsagePruneAt) return;

  nextUsagePruneAt = now + USAGE_PRUNE_INTERVAL_MS;
  const attempt = pruneOldVaultWriteUsage();
  usagePruneInFlight = attempt;
  void attempt.finally(() => {
    if (usagePruneInFlight === attempt) usagePruneInFlight = null;
  });
}

async function pruneOldVaultWriteUsage() {
  const deadline = performance.now() + USAGE_PRUNE_MAX_RUNTIME_MS;
  try {
    for (let batch = 0; batch < USAGE_PRUNE_MAX_BATCHES && performance.now() < deadline; batch += 1) {
      const result = await getSyncPool().query(
        `DELETE FROM vault_write_usage
         WHERE ctid IN (
           SELECT ctid
           FROM vault_write_usage
           WHERE usage_date < (now() AT TIME ZONE 'UTC')::date - $1
           ORDER BY usage_date
           FOR UPDATE SKIP LOCKED
           LIMIT $2
         )`,
        [USAGE_RETENTION_DAYS, USAGE_PRUNE_BATCH_SIZE]
      );
      if ((result.rowCount ?? 0) < USAGE_PRUNE_BATCH_SIZE) break;
    }
  } catch {
    // Retention is best effort and must not make an otherwise healthy request
    // unavailable. Retry soon instead of waiting for the normal hourly window.
    nextUsagePruneAt = performance.now() + USAGE_PRUNE_RETRY_MS;
  }
}

async function rollbackQuietly(client: PoolClient) {
  try {
    await client.query("ROLLBACK");
    return true;
  } catch {
    // The server may still be executing a client-timed-out statement. Returning
    // this connection to the pool could leak a live transaction to a new caller.
    return false;
  }
}

export async function closeSyncPoolForTests() {
  if (pool) await pool.end();
  pool = null;
  schemaReady = null;
  nextUsagePruneAt = 0;
  usagePruneInFlight = null;
}
