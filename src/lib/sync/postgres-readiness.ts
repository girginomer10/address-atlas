import type { PoolClient } from "pg";
import { OperationalError } from "./diagnostics";
import {
  LATEST_SYNC_MIGRATION_VERSION,
  STORAGE_RECONCILIATION_VERSION,
  SYNC_MIGRATIONS
} from "./postgres-migrations";
import {
  LEGACY_SYNC_TABLES,
  PRE_LEDGER_SYNC_TABLES,
  SYNC_COLUMN_CONTRACT,
  SYNC_CONSTRAINT_CONTRACT,
  SYNC_IMPLICIT_RELATION_TYPE_CONTRACT,
  SYNC_INDEX_CONTRACT,
  SYNC_RELATION_CONTRACT,
  SYNC_ROUTINE_CONTRACT,
  SYNC_RUNTIME_PRIVILEGES,
  SYNC_TABLES,
  SYNC_TABLES_BY_MIGRATION_VERSION
} from "./postgres-schema-model";

type Queryable = Pick<PoolClient, "query">;

interface MigrationRow {
  version: number;
  name: string;
  checksum: string;
}

export interface RuntimeDatabaseIdentity {
  readonly database: string;
  readonly schema: string;
  readonly runtimeRole: string;
  readonly ownerRole: string;
  readonly adminRole: string;
}

export interface SyncSchemaReadinessOptions {
  readonly verifyRuntimePrivileges?: boolean;
  /** Test-only seam for isolated database roles/schemas. Production uses the fixed contract. */
  readonly expectedRuntimeIdentity?: RuntimeDatabaseIdentity;
}

export type UnversionedSchemaBaseline = "empty" | "legacy" | "pre-ledger";

const PRODUCTION_RUNTIME_IDENTITY: RuntimeDatabaseIdentity = Object.freeze({
  database: "address_atlas_sync",
  schema: "public",
  runtimeRole: "address_atlas_runtime",
  ownerRole: "address_atlas",
  adminRole: "address_atlas_admin"
});

const VAULT_ACCOUNTING_FUNCTION_BODY = `
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
`;

export async function migrationLedgerExists(database: Queryable) {
  const result = await database.query<{ exists: boolean }>(
    `SELECT to_regclass(format('%I.sync_schema_migrations', current_schema())) IS NOT NULL AS exists`
  );
  return result.rows[0]?.exists === true;
}

export async function assertAppliedMigrationHistory(
  database: Queryable,
  options: { allowPending: boolean }
) {
  const result = await database.query<MigrationRow>(
    `SELECT version, name, checksum
     FROM sync_schema_migrations
     ORDER BY version`
  );
  const rows = result.rows;
  if (rows.length === 0) {
    throw schemaError("migration ledger is empty");
  }
  if (rows.length > SYNC_MIGRATIONS.length
      || rows.some((row) => row.version > LATEST_SYNC_MIGRATION_VERSION)) {
    throw new Error("Address Atlas sync database schema is newer than this server supports.");
  }

  for (let index = 0; index < rows.length; index += 1) {
    const applied = rows[index];
    const expected = SYNC_MIGRATIONS[index];
    if (!applied || !expected
        || applied.version !== expected.version
        || applied.name !== expected.name
        || applied.checksum !== expected.checksum) {
      throw schemaError("migration history is unknown or modified");
    }
  }
  if (!options.allowPending && rows.length !== SYNC_MIGRATIONS.length) {
    throw schemaError("database migrations are pending");
  }
  return rows.length;
}

export async function assertKnownUnversionedSchema(
  database: Queryable
): Promise<UnversionedSchemaBaseline> {
  const relationResult = await database.query<{ table_name: string }>(
    `SELECT relation.relname AS table_name
     FROM pg_catalog.pg_class AS relation
     JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
     WHERE namespace.nspname = current_schema()
       AND relation.relname = ANY($1::text[])
     ORDER BY relation.relname`,
    [[...SYNC_TABLES]]
  );
  const present = relationResult.rows.map((row) => row.table_name);
  if (present.length === 0) return "empty";

  const knownLegacy = sameMembers(present, LEGACY_SYNC_TABLES);
  const knownPreLedger = sameMembers(present, PRE_LEDGER_SYNC_TABLES);
  if (!knownLegacy && !knownPreLedger) {
    throw schemaError("unversioned schema is not a recognized release baseline");
  }
  await assertSchemaSurface(database, present, null);
  await assertStorageState(database, true);
  return knownLegacy ? "legacy" : "pre-ledger";
}

export async function assertSyncSchemaReady(
  database: Queryable,
  options: SyncSchemaReadinessOptions = {}
) {
  if (options.expectedRuntimeIdentity && process.env.NODE_ENV !== "test") {
    throw schemaError("runtime identity overrides are reserved for isolated tests");
  }
  const runtimeIdentity = options.verifyRuntimePrivileges === false
    ? null
    : options.expectedRuntimeIdentity ?? PRODUCTION_RUNTIME_IDENTITY;
  if (runtimeIdentity) await assertRuntimeIdentity(database, runtimeIdentity);
  if (!(await migrationLedgerExists(database))) {
    throw schemaError("migration ledger is missing");
  }
  await assertAppliedMigrationHistory(database, { allowPending: false });
  await assertSchemaSurface(database, [...SYNC_TABLES], runtimeIdentity);
  await assertStorageState(database, false);
}

/** Validate the exact durable surface produced by one applied migration. */
export async function assertSyncSchemaVersionReady(
  database: Queryable,
  appliedVersion: number
) {
  const tableNames = Number.isInteger(appliedVersion) && appliedVersion > 0
    ? SYNC_TABLES_BY_MIGRATION_VERSION[appliedVersion]
    : null;
  if (!tableNames) {
    throw schemaError(`migration version ${appliedVersion} has no schema contract`);
  }
  await assertSchemaSurface(database, tableNames, null);
  await assertStorageState(database, true);
}

async function assertSchemaSurface(
  database: Queryable,
  tableNames: readonly string[],
  runtimeIdentity: RuntimeDatabaseIdentity | null
) {
  const expectedTables = new Set(tableNames);
  const relations = await database.query<{
    table_name: string;
    relation_kind: string;
    persistence: string;
    row_security: boolean;
    force_row_security: boolean;
    is_partition: boolean;
    has_rules: boolean;
    has_inheritance_parent: boolean;
    has_inheritance_child: boolean;
  }>(
    `SELECT relation.relname AS table_name,
            relation.relkind AS relation_kind,
            relation.relpersistence AS persistence,
            relation.relrowsecurity AS row_security,
            relation.relforcerowsecurity AS force_row_security,
            relation.relispartition AS is_partition,
            EXISTS (
              SELECT 1
              FROM pg_catalog.pg_rewrite AS rewrite_rule
              WHERE rewrite_rule.ev_class = relation.oid
            ) AS has_rules,
            EXISTS (
              SELECT 1 FROM pg_catalog.pg_inherits AS inheritance
              WHERE inheritance.inhrelid = relation.oid
            ) AS has_inheritance_parent,
            EXISTS (
              SELECT 1 FROM pg_catalog.pg_inherits AS inheritance
              WHERE inheritance.inhparent = relation.oid
            ) AS has_inheritance_child
     FROM pg_catalog.pg_class AS relation
     JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
     WHERE namespace.nspname = current_schema()
       AND relation.relname = ANY($1::text[])
     ORDER BY relation.relname`,
    [[...tableNames]]
  );
  if (!sameMembers(relations.rows.map((row) => row.table_name), tableNames)) {
    throw schemaError("required table set differs from the migration contract");
  }
  const unsafeRelation = relations.rows.find((row) => row.relation_kind !== "r"
    || row.persistence !== "p"
    || row.row_security
    || row.force_row_security
    || row.is_partition
    || row.has_rules
    || row.has_inheritance_parent
    || row.has_inheritance_child);
  if (unsafeRelation) throw schemaError(`table ${unsafeRelation.table_name} has unsupported behavior`);

  const expectedColumns = SYNC_COLUMN_CONTRACT.filter((item) => expectedTables.has(item.table));
  const columns = await database.query<{
    table_name: string;
    column_name: string;
    type_namespace: string;
    type_name: string;
    type_oid: number;
    type_kind: string;
    type_modifier: number;
    not_null: boolean;
    default_expression: string | null;
    default_collation: boolean;
    identity_kind: string;
    generated_kind: string;
    dimensions: number;
  }>(
    `SELECT relation.relname AS table_name,
            attribute.attname AS column_name,
            type_namespace.nspname AS type_namespace,
            type.typname AS type_name,
            type.oid AS type_oid,
            type.typtype AS type_kind,
            attribute.atttypmod AS type_modifier,
            attribute.attnotnull AS not_null,
            pg_catalog.pg_get_expr(
              default_value.adbin,
              default_value.adrelid,
              false
            ) AS default_expression,
            attribute.attcollation = type.typcollation AS default_collation,
            attribute.attidentity AS identity_kind,
            attribute.attgenerated AS generated_kind,
            attribute.attndims AS dimensions
     FROM pg_catalog.pg_class AS relation
     JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
     JOIN pg_catalog.pg_attribute AS attribute
       ON attribute.attrelid = relation.oid
      AND attribute.attnum > 0
      AND NOT attribute.attisdropped
     JOIN pg_catalog.pg_type AS type ON type.oid = attribute.atttypid
     JOIN pg_catalog.pg_namespace AS type_namespace ON type_namespace.oid = type.typnamespace
     LEFT JOIN pg_catalog.pg_attrdef AS default_value
       ON default_value.adrelid = attribute.attrelid
      AND default_value.adnum = attribute.attnum
     WHERE namespace.nspname = current_schema()
       AND relation.relname = ANY($1::text[])
     ORDER BY relation.relname, attribute.attnum`,
    [[...tableNames]]
  );
  const actualColumns = new Map(columns.rows.map((row) => [
    `${row.table_name}.${row.column_name}`,
    row
  ]));
  if (actualColumns.size !== expectedColumns.length) {
    throw schemaError("column set differs from the migration contract");
  }
  for (const expected of expectedColumns) {
    const actual = actualColumns.get(`${expected.table}.${expected.column}`);
    if (!actual
        || actual.type_namespace !== expected.typeNamespace
        || actual.type_name !== expected.type
        || actual.type_oid !== expected.typeOID
        || actual.type_kind !== "b"
        || actual.type_modifier !== expected.typeModifier
        || !actual.not_null
        || actual.default_expression !== expected.defaultExpression
        || !actual.default_collation
        || actual.identity_kind !== ""
        || actual.generated_kind !== ""
        || actual.dimensions !== 0) {
      throw schemaError(`column ${expected.table}.${expected.column} differs from the migration contract`);
    }
  }

  const expectedConstraints = SYNC_CONSTRAINT_CONTRACT.filter((item) => expectedTables.has(item.table));
  const constraints = await database.query<{
    table_name: string;
    constraint_name: string;
    constraint_type: "p" | "f" | "c" | "u" | "x";
    columns: string[];
    referenced_table: string | null;
    referenced_columns: string[];
    reference_in_current_schema: boolean;
    foreign_update_action: string;
    foreign_match_type: string;
    validated: boolean;
    deferrable: boolean;
    initially_deferred: boolean;
    no_inherit: boolean;
    foreign_delete_action: string;
    check_expression: string | null;
  }>(
    `SELECT relation.relname AS table_name,
            constraint_row.conname AS constraint_name,
            constraint_row.contype AS constraint_type,
            ARRAY(
              SELECT attribute.attname
              FROM unnest(constraint_row.conkey) WITH ORDINALITY AS key_column(attnum, ordinal)
              JOIN pg_catalog.pg_attribute AS attribute
                ON attribute.attrelid = constraint_row.conrelid
               AND attribute.attnum = key_column.attnum
              ORDER BY key_column.ordinal
            )::text[] AS columns,
            referenced_relation.relname AS referenced_table,
            ARRAY(
              SELECT attribute.attname
              FROM unnest(constraint_row.confkey) WITH ORDINALITY AS key_column(attnum, ordinal)
              JOIN pg_catalog.pg_attribute AS attribute
                ON attribute.attrelid = constraint_row.confrelid
               AND attribute.attnum = key_column.attnum
              ORDER BY key_column.ordinal
            )::text[] AS referenced_columns,
            constraint_row.confrelid = 0
              OR referenced_namespace.nspname = current_schema() AS reference_in_current_schema,
            constraint_row.confupdtype AS foreign_update_action,
            constraint_row.convalidated AS validated,
            constraint_row.condeferrable AS deferrable,
            constraint_row.condeferred AS initially_deferred,
            constraint_row.connoinherit AS no_inherit,
            constraint_row.confdeltype AS foreign_delete_action,
            constraint_row.confmatchtype AS foreign_match_type,
            pg_catalog.pg_get_expr(
              constraint_row.conbin,
              constraint_row.conrelid,
              false
            ) AS check_expression
     FROM pg_catalog.pg_constraint AS constraint_row
     JOIN pg_catalog.pg_class AS relation ON relation.oid = constraint_row.conrelid
     JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
     LEFT JOIN pg_catalog.pg_class AS referenced_relation
       ON referenced_relation.oid = constraint_row.confrelid
     LEFT JOIN pg_catalog.pg_namespace AS referenced_namespace
       ON referenced_namespace.oid = referenced_relation.relnamespace
     WHERE namespace.nspname = current_schema()
       AND relation.relname = ANY($1::text[])
       AND constraint_row.contype IN ('p', 'u', 'f', 'c', 'x')
     ORDER BY relation.relname, constraint_row.conname`,
    [[...tableNames]]
  );
  const actualConstraints = new Map(constraints.rows.map((row) => [
    `${row.table_name}.${row.constraint_name}`,
    row
  ]));
  if (constraints.rows.length !== expectedConstraints.length
      || actualConstraints.size !== expectedConstraints.length) {
    throw schemaError("constraint set differs from the migration contract");
  }
  for (const expected of expectedConstraints) {
    const actual = actualConstraints.get(`${expected.table}.${expected.name}`);
    if (!actual
        || actual.constraint_type !== expected.type
        || !sameOrderedValues(actual.columns, expected.columns)
        || !actual.validated
        || actual.deferrable
        || actual.initially_deferred
        || actual.no_inherit !== (expected.type !== "c")
        || (expected.type === "c" && actual.check_expression !== expected.checkExpression)
        || (expected.type === "f" && (
          actual.referenced_table !== expected.referencedTable
          || !sameOrderedValues(actual.referenced_columns, expected.referencedColumns ?? [])
          || !actual.reference_in_current_schema
          || actual.foreign_update_action !== expected.updateAction
          || actual.foreign_delete_action !== expected.deleteAction
          || actual.foreign_match_type !== expected.matchType
        ))) {
      throw schemaError(`constraint ${expected.name} differs from the migration contract`);
    }
  }

  const expectedIndexes = SYNC_INDEX_CONTRACT.filter((item) => expectedTables.has(item.table));
  const indexes = await database.query<{
    table_name: string;
    index_name: string;
    access_method: string;
    columns: string[];
    unique_index: boolean;
    primary_index: boolean;
    exclusion_index: boolean;
    immediate: boolean;
    clustered: boolean;
    replica_identity: boolean;
    valid: boolean;
    ready: boolean;
    live: boolean;
    nulls_not_distinct: boolean;
    key_attribute_count: number;
    attribute_count: number;
    partial: boolean;
    expression: boolean;
    nondefault_column_options: boolean;
    default_operator_classes: boolean;
    default_collations: boolean;
    attribute_options: boolean;
    relation_options: string[] | null;
  }>(
    `SELECT relation.relname AS table_name,
            index_relation.relname AS index_name,
            access_method.amname AS access_method,
            ARRAY(
              SELECT attribute.attname
              FROM unnest(index_row.indkey::smallint[])
                WITH ORDINALITY AS key_column(attnum, ordinal)
              JOIN pg_catalog.pg_attribute AS attribute
                ON attribute.attrelid = index_row.indrelid
               AND attribute.attnum = key_column.attnum
              WHERE key_column.ordinal <= index_row.indnkeyatts
              ORDER BY key_column.ordinal
            )::text[] AS columns,
            index_row.indisunique AS unique_index,
            index_row.indisprimary AS primary_index,
            index_row.indisexclusion AS exclusion_index,
            index_row.indimmediate AS immediate,
            index_row.indisclustered AS clustered,
            index_row.indisreplident AS replica_identity,
            index_row.indisvalid AS valid,
            index_row.indisready AS ready,
            index_row.indislive AS live,
            index_row.indnullsnotdistinct AS nulls_not_distinct,
            index_row.indnkeyatts AS key_attribute_count,
            index_row.indnatts AS attribute_count,
            index_row.indpred IS NOT NULL AS partial,
            index_row.indexprs IS NOT NULL AS expression,
            EXISTS (
              SELECT 1
              FROM unnest(index_row.indoption::smallint[]) AS column_option(value)
              WHERE column_option.value <> 0
            ) AS nondefault_column_options,
            NOT EXISTS (
              SELECT 1
              FROM unnest(index_row.indclass::oid[])
                WITH ORDINALITY AS operator_class(oid, ordinal)
              LEFT JOIN pg_catalog.pg_opclass AS operator_class_row
                ON operator_class_row.oid = operator_class.oid
              WHERE operator_class.ordinal <= index_row.indnkeyatts
                AND (operator_class_row.oid IS NULL
                  OR operator_class_row.opcmethod <> index_relation.relam
                  OR NOT operator_class_row.opcdefault)
            ) AS default_operator_classes,
            NOT EXISTS (
              SELECT 1
              FROM unnest(index_row.indcollation::oid[])
                WITH ORDINALITY AS index_collation(oid, ordinal)
              JOIN unnest(index_row.indkey::smallint[])
                WITH ORDINALITY AS key_column(attnum, ordinal)
                ON key_column.ordinal = index_collation.ordinal
              JOIN pg_catalog.pg_attribute AS table_attribute
                ON table_attribute.attrelid = index_row.indrelid
               AND table_attribute.attnum = key_column.attnum
              WHERE index_collation.ordinal <= index_row.indnkeyatts
                AND index_collation.oid <> table_attribute.attcollation
            ) AS default_collations,
            EXISTS (
              SELECT 1
              FROM pg_catalog.pg_attribute AS index_attribute
              WHERE index_attribute.attrelid = index_relation.oid
                AND index_attribute.attnum BETWEEN 1 AND index_row.indnkeyatts
                AND index_attribute.attoptions IS NOT NULL
            ) AS attribute_options,
            index_relation.reloptions AS relation_options
     FROM pg_catalog.pg_index AS index_row
     JOIN pg_catalog.pg_class AS relation ON relation.oid = index_row.indrelid
     JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
     JOIN pg_catalog.pg_class AS index_relation ON index_relation.oid = index_row.indexrelid
     JOIN pg_catalog.pg_am AS access_method ON access_method.oid = index_relation.relam
     WHERE namespace.nspname = current_schema()
       AND relation.relname = ANY($1::text[])
     ORDER BY index_relation.relname`,
    [[...tableNames]]
  );
  const actualIndexes = new Map(indexes.rows.map((row) => [row.index_name, row]));
  if (indexes.rows.length !== expectedIndexes.length || actualIndexes.size !== expectedIndexes.length) {
    throw schemaError("index set differs from the migration contract");
  }
  for (const expected of expectedIndexes) {
    const actual = actualIndexes.get(expected.name);
    if (!actual
        || actual.table_name !== expected.table
        || actual.access_method !== "btree"
        || !sameOrderedValues(actual.columns, expected.columns)
        || actual.unique_index !== expected.unique
        || actual.primary_index !== expected.primary
        || actual.exclusion_index
        || !actual.immediate
        || actual.clustered
        || actual.replica_identity
        || !actual.valid
        || !actual.ready
        || !actual.live
        || actual.nulls_not_distinct
        || actual.key_attribute_count !== expected.columns.length
        || actual.attribute_count !== expected.columns.length
        || actual.partial
        || actual.expression
        || actual.nondefault_column_options
        || !actual.default_operator_classes
        || !actual.default_collations
        || actual.attribute_options
        || (actual.relation_options !== null && actual.relation_options.length !== 0)) {
      throw schemaError(`index ${expected.name} differs from the migration contract`);
    }
  }

  const triggers = await database.query<{
    trigger_name: string;
    table_name: string;
    enabled: string;
    trigger_type: number;
    trigger_argument_count: number;
    trigger_argument_bytes: number;
    trigger_columns: string;
    conditional: boolean;
    function_name: string;
    function_in_current_schema: boolean;
    function_owner_matches: boolean;
    language_name: string;
    volatility: string;
    strict: boolean;
    security_definer: boolean;
    leakproof: boolean;
    parallel_safety: string;
    function_config: string[] | null;
    function_kind: string;
    function_argument_count: number;
    function_identity_arguments: string;
    return_type: string;
    function_source: string;
  }>(
    `SELECT trigger_row.tgname AS trigger_name,
            relation.relname AS table_name,
            trigger_row.tgenabled AS enabled,
            trigger_row.tgtype AS trigger_type,
            trigger_row.tgnargs AS trigger_argument_count,
            octet_length(trigger_row.tgargs) AS trigger_argument_bytes,
            trigger_row.tgattr::text AS trigger_columns,
            trigger_row.tgqual IS NOT NULL AS conditional,
            function_row.proname AS function_name,
            function_namespace.nspname = current_schema() AS function_in_current_schema,
            function_row.proowner = relation.relowner AS function_owner_matches,
            language_row.lanname AS language_name,
            function_row.provolatile AS volatility,
            function_row.proisstrict AS strict,
            function_row.prosecdef AS security_definer,
            function_row.proleakproof AS leakproof,
            function_row.proparallel AS parallel_safety,
            function_row.proconfig AS function_config,
            function_row.prokind AS function_kind,
            function_row.pronargs AS function_argument_count,
            pg_catalog.pg_get_function_identity_arguments(function_row.oid)
              AS function_identity_arguments,
            pg_catalog.format_type(function_row.prorettype, NULL) AS return_type,
            function_row.prosrc AS function_source
     FROM pg_catalog.pg_trigger AS trigger_row
     JOIN pg_catalog.pg_class AS relation ON relation.oid = trigger_row.tgrelid
     JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
     JOIN pg_catalog.pg_proc AS function_row ON function_row.oid = trigger_row.tgfoid
     JOIN pg_catalog.pg_namespace AS function_namespace
       ON function_namespace.oid = function_row.pronamespace
     JOIN pg_catalog.pg_language AS language_row ON language_row.oid = function_row.prolang
     WHERE namespace.nspname = current_schema()
       AND relation.relname = ANY($1::text[])
       AND NOT trigger_row.tgisinternal`,
    [[...tableNames]]
  );
  const expectsVaultTrigger = expectedTables.has("vault_snapshots");
  if (triggers.rows.length !== (expectsVaultTrigger ? 1 : 0)) {
    throw schemaError("trigger set differs from the migration contract");
  }
  if (expectsVaultTrigger) {
    const trigger = triggers.rows[0];
    if (!trigger
        || trigger.trigger_name !== "address_atlas_snapshot_delete_usage"
        || trigger.table_name !== "vault_snapshots"
        || trigger.enabled !== "O"
        || trigger.trigger_type !== 9
        || trigger.trigger_argument_count !== 0
        || trigger.trigger_argument_bytes !== 0
        || trigger.trigger_columns !== ""
        || trigger.conditional
        || trigger.function_name !== "address_atlas_decrement_snapshot_usage"
        || !trigger.function_in_current_schema
        || !trigger.function_owner_matches
        || trigger.language_name !== "plpgsql"
        || trigger.volatility !== "v"
        || trigger.strict
        || trigger.security_definer
        || trigger.leakproof
        || trigger.parallel_safety !== "u"
        || trigger.function_config !== null
        || trigger.function_kind !== "f"
        || trigger.function_argument_count !== 0
        || trigger.function_identity_arguments !== ""
        || trigger.return_type !== "trigger"
        || normalizeSQL(trigger.function_source) !== normalizeSQL(VAULT_ACCOUNTING_FUNCTION_BODY)) {
      throw schemaError("vault accounting trigger differs from the migration contract");
    }
  }

  if (runtimeIdentity) await assertRuntimePrivileges(database, runtimeIdentity);
  await assertExactSchemaObjectSurface(database, expectedTables);
}

async function assertExactSchemaObjectSurface(
  database: Queryable,
  expectedTables: ReadonlySet<string>
) {
  const expectedRelations = SYNC_RELATION_CONTRACT.filter((item) =>
    expectedTables.has(item.table)
  );
  const relations = await database.query<{ relation_name: string; relation_kind: string }>(
    `SELECT relation.relname AS relation_name,
            relation.relkind AS relation_kind
     FROM pg_catalog.pg_class AS relation
     JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
     WHERE namespace.nspname = current_schema()
     ORDER BY relation.relname`
  );
  const expectedRelationKeys = new Set(expectedRelations.map((item) =>
    catalogObjectKey(item.name, item.kind)
  ));
  const actualRelationKeys = relations.rows.map((row) =>
    catalogObjectKey(row.relation_name, row.relation_kind)
  );
  if (actualRelationKeys.length !== expectedRelationKeys.size
      || !sameMembers(actualRelationKeys, expectedRelationKeys)) {
    const unexpected = relations.rows.find((row) =>
      !expectedRelationKeys.has(catalogObjectKey(row.relation_name, row.relation_kind))
    );
    throw schemaError(
      `relation set differs from the migration contract${unexpected
        ? ` (unexpected relation ${unexpected.relation_name})`
        : ""}`
    );
  }

  const expectedRoutines = SYNC_ROUTINE_CONTRACT.filter((item) =>
    expectedTables.has(item.requiredTable)
  );
  const routines = await database.query<{
    routine_name: string;
    routine_kind: string;
    identity_arguments: string;
  }>(
    `SELECT routine.proname AS routine_name,
            routine.prokind AS routine_kind,
            pg_catalog.pg_get_function_identity_arguments(routine.oid)
              AS identity_arguments
     FROM pg_catalog.pg_proc AS routine
     JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
     WHERE namespace.nspname = current_schema()
     ORDER BY routine.proname, routine.prokind, routine.oid`
  );
  const expectedRoutineKeys = new Set(expectedRoutines.map((item) =>
    catalogRoutineKey(item.name, item.kind, item.identityArguments)
  ));
  const actualRoutineKeys = routines.rows.map((row) =>
    catalogRoutineKey(row.routine_name, row.routine_kind, row.identity_arguments)
  );
  if (actualRoutineKeys.length !== expectedRoutineKeys.size
      || !sameMembers(actualRoutineKeys, expectedRoutineKeys)) {
    const unexpected = routines.rows.find((row) =>
      !expectedRoutineKeys.has(catalogRoutineKey(
        row.routine_name,
        row.routine_kind,
        row.identity_arguments
      ))
    );
    throw schemaError(
      `routine set differs from the migration contract${unexpected
        ? ` (unexpected routine ${unexpected.routine_name})`
        : ""}`
    );
  }

  const expectedTypes = SYNC_IMPLICIT_RELATION_TYPE_CONTRACT.filter((item) =>
    expectedTables.has(item.table)
  );
  const types = await database.query<{
    type_oid: string;
    type_name: string;
    type_kind: string;
    type_category: string;
    defined: boolean;
    relation_oid: string;
    element_type_oid: string;
    array_type_oid: string;
    base_type_oid: string;
    type_modifier: number;
    dimensions: number;
    not_null: boolean;
    collation_oid: string;
    relation_name: string | null;
    relation_kind: string | null;
    relation_type_oid: string | null;
  }>(
    `SELECT item.oid::text AS type_oid,
            item.typname AS type_name,
            item.typtype AS type_kind,
            item.typcategory AS type_category,
            item.typisdefined AS defined,
            item.typrelid::text AS relation_oid,
            item.typelem::text AS element_type_oid,
            item.typarray::text AS array_type_oid,
            item.typbasetype::text AS base_type_oid,
            item.typtypmod AS type_modifier,
            item.typndims AS dimensions,
            item.typnotnull AS not_null,
            item.typcollation::text AS collation_oid,
            relation.relname AS relation_name,
            relation.relkind AS relation_kind,
            relation.reltype::text AS relation_type_oid
     FROM pg_catalog.pg_type AS item
     JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = item.typnamespace
     LEFT JOIN pg_catalog.pg_class AS relation ON relation.oid = item.typrelid
     WHERE namespace.nspname = current_schema()
     ORDER BY item.typname`
  );
  const expectedTypeNames = new Set(expectedTypes.flatMap((item) => [
    item.rowType,
    item.arrayType
  ]));
  const actualTypes = new Map(types.rows.map((row) => [row.type_name, row]));
  if (types.rows.length !== expectedTypeNames.size
      || actualTypes.size !== expectedTypeNames.size
      || !sameMembers(actualTypes.keys(), expectedTypeNames)) {
    const unexpected = types.rows.find((row) => !expectedTypeNames.has(row.type_name));
    throw schemaError(
      `type set differs from the migration contract${unexpected
        ? ` (unexpected type ${unexpected.type_name})`
        : ""}`
    );
  }
  for (const expected of expectedTypes) {
    const rowType = actualTypes.get(expected.rowType);
    const arrayType = actualTypes.get(expected.arrayType);
    if (!rowType
        || !arrayType
        || rowType.type_kind !== "c"
        || rowType.type_category !== "C"
        || !rowType.defined
        || rowType.relation_oid === "0"
        || rowType.element_type_oid !== "0"
        || rowType.array_type_oid !== arrayType.type_oid
        || rowType.base_type_oid !== "0"
        || rowType.type_modifier !== -1
        || rowType.dimensions !== 0
        || rowType.not_null
        || rowType.collation_oid !== "0"
        || rowType.relation_name !== expected.table
        || rowType.relation_kind !== "r"
        || rowType.relation_type_oid !== rowType.type_oid
        || arrayType.type_kind !== "b"
        || arrayType.type_category !== "A"
        || !arrayType.defined
        || arrayType.relation_oid !== "0"
        || arrayType.element_type_oid !== rowType.type_oid
        || arrayType.array_type_oid !== "0"
        || arrayType.base_type_oid !== "0"
        || arrayType.type_modifier !== -1
        || arrayType.dimensions !== 0
        || arrayType.not_null
        || arrayType.collation_oid !== "0"
        || arrayType.relation_name !== null
        || arrayType.relation_kind !== null
        || arrayType.relation_type_oid !== null) {
      throw schemaError(
        `implicit types for table ${expected.table} differ from the migration contract`
      );
    }
  }
}

async function assertStorageState(database: Queryable, allowPendingReconcile: boolean) {
  const result = await database.query<{
    total_snapshot_bytes: string | number;
    reconciled_contract_version: number;
    reconcile_required: boolean;
  }>(
    `SELECT usage.total_snapshot_bytes,
            usage.reconciled_contract_version,
            usage.reconcile_required
     FROM sync_storage_usage AS usage
     WHERE usage.singleton = true
     LIMIT 2`
  );
  const state = result.rows[0];
  const recordedBytes = state ? nonnegativeBigInt(state.total_snapshot_bytes) : null;
  if (result.rows.length !== 1
      || !state
      || recordedBytes === null
      || !Number.isInteger(state.reconciled_contract_version)
      || typeof state.reconcile_required !== "boolean") {
    throw schemaError("storage accounting singleton is invalid");
  }
  if (state.reconciled_contract_version > STORAGE_RECONCILIATION_VERSION) {
    throw new Error("Address Atlas sync database schema is newer than this server supports.");
  }
  if (!allowPendingReconcile
      && (state.reconcile_required
        || state.reconciled_contract_version !== STORAGE_RECONCILIATION_VERSION)) {
    throw schemaError("storage accounting reconciliation is pending");
  }
}

async function assertRuntimeIdentity(
  database: Queryable,
  identity: RuntimeDatabaseIdentity
) {
  const protectedRoles = [identity.ownerRole, identity.adminRole, identity.runtimeRole];
  if (new Set(protectedRoles).size !== protectedRoles.length) {
    throw schemaError("runtime database identity contract is invalid");
  }
  const result = await database.query<{
    database_name: string;
    schema_name: string | null;
    current_user_name: string;
    session_user_name: string;
    explicit_schemas: string[];
    active_schemas: string[];
    protected_role_count: number;
    protected_membership_count: number;
  }>(
    `SELECT current_database()::text AS database_name,
            current_schema()::text AS schema_name,
            current_user::text AS current_user_name,
            session_user::text AS session_user_name,
            pg_catalog.current_schemas(false)::text[] AS explicit_schemas,
            pg_catalog.current_schemas(true)::text[] AS active_schemas,
            (
              SELECT count(*)::integer
              FROM pg_catalog.pg_roles AS protected_role
              WHERE protected_role.rolname = ANY($1::text[])
            ) AS protected_role_count,
            (
              SELECT count(*)::integer
              FROM pg_catalog.pg_auth_members AS membership
              JOIN pg_catalog.pg_roles AS member_role ON member_role.oid = membership.member
              JOIN pg_catalog.pg_roles AS granted_role ON granted_role.oid = membership.roleid
              WHERE member_role.rolname = ANY($1::text[])
                 OR granted_role.rolname = ANY($1::text[])
            ) AS protected_membership_count`,
    [protectedRoles]
  );
  const actual = result.rows[0];
  if (result.rows.length !== 1
      || !actual
      || actual.database_name !== identity.database
      || actual.schema_name !== identity.schema
      || actual.current_user_name !== identity.runtimeRole
      || actual.session_user_name !== identity.runtimeRole
      || !sameOrderedValues(actual.explicit_schemas, [identity.schema])
      || !sameOrderedValues(actual.active_schemas, ["pg_catalog", identity.schema])
      || actual.protected_role_count !== protectedRoles.length
      || actual.protected_membership_count !== 0) {
    throw schemaError("runtime database identity or search path differs from the production contract");
  }
}

async function assertRuntimePrivileges(
  database: Queryable,
  identity: RuntimeDatabaseIdentity
) {
  const authority = await database.query<{
    current_user_name: string;
    session_user_name: string;
    can_login: boolean;
    superuser: boolean;
    create_database: boolean;
    create_role: boolean;
    replication: boolean;
    bypass_row_security: boolean;
    inherits_roles: boolean;
    connection_limit: number;
    password_never_expires: boolean;
    role_config: string[] | null;
    database_owner: string;
    schema_owner: string;
    database_connect: boolean;
    database_create: boolean;
    database_temporary: boolean;
    schema_usage: boolean;
    schema_create: boolean;
    has_memberships: boolean;
    has_runtime_settings: boolean;
  }>(
    `SELECT current_user::text AS current_user_name,
            session_user::text AS session_user_name,
            role_row.rolcanlogin AS can_login,
            role_row.rolsuper AS superuser,
            role_row.rolcreatedb AS create_database,
            role_row.rolcreaterole AS create_role,
            role_row.rolreplication AS replication,
            role_row.rolbypassrls AS bypass_row_security,
            role_row.rolinherit AS inherits_roles,
            role_row.rolconnlimit AS connection_limit,
            role_row.rolvaliduntil IS NULL
              OR role_row.rolvaliduntil = 'infinity'::pg_catalog.timestamptz
              AS password_never_expires,
            role_row.rolconfig AS role_config,
            database_owner.rolname AS database_owner,
            schema_owner.rolname AS schema_owner,
            pg_catalog.has_database_privilege(current_user, current_database(), 'CONNECT')
              AS database_connect,
            pg_catalog.has_database_privilege(current_user, current_database(), 'CREATE')
              AS database_create,
            pg_catalog.has_database_privilege(current_user, current_database(), 'TEMPORARY')
              AS database_temporary,
            pg_catalog.has_schema_privilege(current_user, current_schema(), 'USAGE')
              AS schema_usage,
            pg_catalog.has_schema_privilege(current_user, current_schema(), 'CREATE')
              AS schema_create,
            EXISTS (
              SELECT 1
              FROM pg_catalog.pg_auth_members AS membership
              WHERE membership.member = role_row.oid OR membership.roleid = role_row.oid
            ) AS has_memberships,
            EXISTS (
              SELECT 1
              FROM pg_catalog.pg_db_role_setting AS setting
              WHERE setting.setrole = role_row.oid
                 OR (setting.setrole = 0 AND setting.setdatabase = database_row.oid)
            ) AS has_runtime_settings
     FROM pg_catalog.pg_roles AS role_row
     JOIN pg_catalog.pg_database AS database_row
       ON database_row.datname = current_database()
     JOIN pg_catalog.pg_roles AS database_owner ON database_owner.oid = database_row.datdba
     JOIN pg_catalog.pg_namespace AS namespace
       ON namespace.nspname = current_schema()
     JOIN pg_catalog.pg_roles AS schema_owner ON schema_owner.oid = namespace.nspowner
     WHERE role_row.rolname = current_user`
  );
  const role = authority.rows[0];
  if (authority.rows.length !== 1
      || !role
      || role.current_user_name !== role.session_user_name
      || !role.can_login
      || role.superuser
      || role.create_database
      || role.create_role
      || role.replication
      || role.bypass_row_security
      || role.inherits_roles
      || role.connection_limit !== -1
      || !role.password_never_expires
      || role.role_config !== null
      || role.database_owner !== identity.ownerRole
      || role.schema_owner !== identity.ownerRole
      || !role.database_connect
      || role.database_create
      || role.database_temporary
      || !role.schema_usage
      || role.schema_create
      || role.has_memberships
      || role.has_runtime_settings) {
    throw schemaError("runtime role authority exceeds the application contract");
  }

  const allTablePrivileges = [
    "SELECT",
    "INSERT",
    "UPDATE",
    "DELETE",
    "TRUNCATE",
    "REFERENCES",
    "TRIGGER"
  ];
  const result = await database.query<{ table_name: string; privilege: string; allowed: boolean }>(
    `SELECT relation.relname AS table_name,
            requested.privilege,
            has_table_privilege(
              current_user,
              format('%I.%I', current_schema(), relation.relname),
              requested.privilege
            ) AS allowed
     FROM pg_catalog.pg_class AS relation
     JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
     CROSS JOIN unnest($1::text[]) AS requested(privilege)
     WHERE namespace.nspname = current_schema()
       AND relation.relkind IN ('r', 'p')
     ORDER BY relation.relname, requested.privilege`,
    [allTablePrivileges]
  );
  const privilegeDrift = result.rows.find((row) => {
    const expected = SYNC_RUNTIME_PRIVILEGES[row.table_name as keyof typeof SYNC_RUNTIME_PRIVILEGES] ?? [];
    return row.allowed !== expected.includes(row.privilege);
  });
  if (privilegeDrift) {
    throw schemaError(
      `runtime role ${privilegeDrift.allowed ? "has unexpected" : "lacks"} `
      + `${privilegeDrift.privilege} on ${privilegeDrift.table_name}`
    );
  }

  const tableACLs = await database.query<{
    table_name: string;
    owner_name: string;
    grantee_name: string | null;
    privilege: string | null;
    grantable: boolean | null;
  }>(
    `SELECT relation.relname AS table_name,
            owner_role.rolname AS owner_name,
            CASE
              WHEN grant_row.grantee IS NULL THEN NULL
              WHEN grant_row.grantee = 0 THEN 'PUBLIC'
              ELSE COALESCE(grantee_role.rolname, pg_catalog.format('oid:%s', grant_row.grantee))
            END AS grantee_name,
            grant_row.privilege_type AS privilege,
            grant_row.is_grantable AS grantable
     FROM pg_catalog.pg_class AS relation
     JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
     JOIN pg_catalog.pg_roles AS owner_role ON owner_role.oid = relation.relowner
     LEFT JOIN LATERAL pg_catalog.aclexplode(
       COALESCE(relation.relacl, pg_catalog.acldefault('r', relation.relowner))
     ) AS grant_row ON true
     LEFT JOIN pg_catalog.pg_roles AS grantee_role ON grantee_role.oid = grant_row.grantee
     WHERE namespace.nspname = current_schema()
       AND relation.relkind IN ('r', 'p')
     ORDER BY relation.relname, grantee_name, grant_row.privilege_type`
  );
  const expectedTableACLs: string[] = [];
  for (const table of new Set(tableACLs.rows.map((row) => row.table_name))) {
    for (const privilege of allTablePrivileges) {
      expectedTableACLs.push(aclKey(table, identity.ownerRole, identity.ownerRole, privilege, false));
    }
    const runtimePrivileges = SYNC_RUNTIME_PRIVILEGES[
      table as keyof typeof SYNC_RUNTIME_PRIVILEGES
    ] ?? [];
    for (const privilege of runtimePrivileges) {
      expectedTableACLs.push(aclKey(table, identity.ownerRole, identity.runtimeRole, privilege, false));
    }
  }
  assertExactACL(
    tableACLs.rows.flatMap((row) => row.grantee_name && row.privilege && row.grantable !== null
      ? [aclKey(
        row.table_name,
        row.owner_name,
        row.grantee_name,
        row.privilege,
        row.grantable
      )]
      : []),
    expectedTableACLs,
    "table ACLs"
  );

  const columnGrants = await database.query<{ grant_count: number }>(
    `SELECT count(*)::integer AS grant_count
     FROM pg_catalog.pg_attribute AS attribute
     JOIN pg_catalog.pg_class AS relation ON relation.oid = attribute.attrelid
     JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
     WHERE namespace.nspname = current_schema()
       AND attribute.attnum > 0
       AND NOT attribute.attisdropped
       AND attribute.attacl IS NOT NULL`
  );
  if (columnGrants.rows[0]?.grant_count !== 0) {
    throw schemaError("column ACLs differ from the application contract");
  }

  await assertDatabaseAndSchemaACLs(database, identity);
  await assertOwnedObjectACLs(database, identity);
  await assertDefaultACLs(database, identity);
}

async function assertDatabaseAndSchemaACLs(
  database: Queryable,
  identity: RuntimeDatabaseIdentity
) {
  const databaseACLs = await database.query<{
    object_name: string;
    owner_name: string;
    grantee_name: string;
    privilege: string;
    grantable: boolean;
  }>(
    `SELECT database_row.datname AS object_name,
            owner_role.rolname AS owner_name,
            CASE
              WHEN grant_row.grantee = 0 THEN 'PUBLIC'
              ELSE COALESCE(grantee_role.rolname, pg_catalog.format('oid:%s', grant_row.grantee))
            END AS grantee_name,
            grant_row.privilege_type AS privilege,
            grant_row.is_grantable AS grantable
     FROM pg_catalog.pg_database AS database_row
     JOIN pg_catalog.pg_roles AS owner_role ON owner_role.oid = database_row.datdba
     CROSS JOIN LATERAL pg_catalog.aclexplode(
       COALESCE(database_row.datacl, pg_catalog.acldefault('d', database_row.datdba))
     ) AS grant_row
     LEFT JOIN pg_catalog.pg_roles AS grantee_role ON grantee_role.oid = grant_row.grantee
     WHERE database_row.datname = current_database()`
  );
  const expectedDatabaseACLs = [
    ...["CONNECT", "CREATE", "TEMPORARY"].map((privilege) =>
      aclKey(identity.database, identity.ownerRole, identity.ownerRole, privilege, false)),
    aclKey(identity.database, identity.ownerRole, identity.adminRole, "CONNECT", false),
    aclKey(identity.database, identity.ownerRole, identity.runtimeRole, "CONNECT", false)
  ];
  assertExactACL(
    databaseACLs.rows.map((row) => aclKey(
      row.object_name,
      row.owner_name,
      row.grantee_name,
      row.privilege,
      row.grantable
    )),
    expectedDatabaseACLs,
    "database ACLs"
  );

  const schemaACLs = await database.query<{
    object_name: string;
    owner_name: string;
    grantee_name: string;
    privilege: string;
    grantable: boolean;
  }>(
    `SELECT namespace.nspname AS object_name,
            owner_role.rolname AS owner_name,
            CASE
              WHEN grant_row.grantee = 0 THEN 'PUBLIC'
              ELSE COALESCE(grantee_role.rolname, pg_catalog.format('oid:%s', grant_row.grantee))
            END AS grantee_name,
            grant_row.privilege_type AS privilege,
            grant_row.is_grantable AS grantable
     FROM pg_catalog.pg_namespace AS namespace
     JOIN pg_catalog.pg_roles AS owner_role ON owner_role.oid = namespace.nspowner
     CROSS JOIN LATERAL pg_catalog.aclexplode(
       COALESCE(namespace.nspacl, pg_catalog.acldefault('n', namespace.nspowner))
     ) AS grant_row
     LEFT JOIN pg_catalog.pg_roles AS grantee_role ON grantee_role.oid = grant_row.grantee
     WHERE namespace.nspname = current_schema()`
  );
  const expectedSchemaACLs = [
    aclKey(identity.schema, identity.ownerRole, identity.ownerRole, "CREATE", false),
    aclKey(identity.schema, identity.ownerRole, identity.ownerRole, "USAGE", false),
    aclKey(identity.schema, identity.ownerRole, identity.adminRole, "USAGE", false),
    aclKey(identity.schema, identity.ownerRole, identity.runtimeRole, "USAGE", false)
  ];
  assertExactACL(
    schemaACLs.rows.map((row) => aclKey(
      row.object_name,
      row.owner_name,
      row.grantee_name,
      row.privilege,
      row.grantable
    )),
    expectedSchemaACLs,
    "schema ACLs"
  );
}

async function assertOwnedObjectACLs(
  database: Queryable,
  identity: RuntimeDatabaseIdentity
) {
  const relationOwners = await database.query<{ object_name: string; owner_name: string }>(
    `SELECT relation.relname AS object_name, owner_role.rolname AS owner_name
     FROM pg_catalog.pg_class AS relation
     JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
     JOIN pg_catalog.pg_roles AS owner_role ON owner_role.oid = relation.relowner
     WHERE namespace.nspname = current_schema()
       AND relation.relkind IN ('r', 'p', 'i', 'I', 'S', 'v', 'm', 'f', 'c')`
  );
  const wrongRelationOwner = relationOwners.rows.find((row) => row.owner_name !== identity.ownerRole);
  if (wrongRelationOwner) {
    throw schemaError(`object ${wrongRelationOwner.object_name} has an unexpected owner`);
  }

  const routineACLs = await database.query<{
    object_name: string;
    owner_name: string;
    grantee_name: string | null;
    privilege: string | null;
    grantable: boolean | null;
  }>(
    `SELECT routine.oid::text AS object_name,
            owner_role.rolname AS owner_name,
            CASE
              WHEN grant_row.grantee IS NULL THEN NULL
              WHEN grant_row.grantee = 0 THEN 'PUBLIC'
              ELSE COALESCE(grantee_role.rolname, pg_catalog.format('oid:%s', grant_row.grantee))
            END AS grantee_name,
            grant_row.privilege_type AS privilege,
            grant_row.is_grantable AS grantable
     FROM pg_catalog.pg_proc AS routine
     JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
     JOIN pg_catalog.pg_roles AS owner_role ON owner_role.oid = routine.proowner
     LEFT JOIN LATERAL pg_catalog.aclexplode(
       COALESCE(routine.proacl, pg_catalog.acldefault('f', routine.proowner))
     ) AS grant_row ON true
     LEFT JOIN pg_catalog.pg_roles AS grantee_role ON grantee_role.oid = grant_row.grantee
     WHERE namespace.nspname = current_schema()`
  );
  assertOwnerOnlyACL(routineACLs.rows, identity.ownerRole, ["EXECUTE"], "routine ACLs");

  const sequenceACLs = await database.query<{
    object_name: string;
    owner_name: string;
    grantee_name: string | null;
    privilege: string | null;
    grantable: boolean | null;
  }>(
    `SELECT relation.oid::text AS object_name,
            owner_role.rolname AS owner_name,
            CASE
              WHEN grant_row.grantee IS NULL THEN NULL
              WHEN grant_row.grantee = 0 THEN 'PUBLIC'
              ELSE COALESCE(grantee_role.rolname, pg_catalog.format('oid:%s', grant_row.grantee))
            END AS grantee_name,
            grant_row.privilege_type AS privilege,
            grant_row.is_grantable AS grantable
     FROM pg_catalog.pg_class AS relation
     JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
     JOIN pg_catalog.pg_roles AS owner_role ON owner_role.oid = relation.relowner
     LEFT JOIN LATERAL pg_catalog.aclexplode(
       COALESCE(relation.relacl, pg_catalog.acldefault('S', relation.relowner))
     ) AS grant_row ON true
     LEFT JOIN pg_catalog.pg_roles AS grantee_role ON grantee_role.oid = grant_row.grantee
     WHERE namespace.nspname = current_schema() AND relation.relkind = 'S'`
  );
  assertOwnerOnlyACL(
    sequenceACLs.rows,
    identity.ownerRole,
    ["SELECT", "UPDATE", "USAGE"],
    "sequence ACLs"
  );

  const typeACLs = await database.query<{
    object_name: string;
    owner_name: string;
    grantee_name: string | null;
    privilege: string | null;
    grantable: boolean | null;
  }>(
    `SELECT item.oid::text AS object_name,
            owner_role.rolname AS owner_name,
            CASE
              WHEN grant_row.grantee IS NULL THEN NULL
              WHEN grant_row.grantee = 0 THEN 'PUBLIC'
              ELSE COALESCE(grantee_role.rolname, pg_catalog.format('oid:%s', grant_row.grantee))
            END AS grantee_name,
            grant_row.privilege_type AS privilege,
            grant_row.is_grantable AS grantable
     FROM pg_catalog.pg_type AS item
     JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = item.typnamespace
     JOIN pg_catalog.pg_roles AS owner_role ON owner_role.oid = item.typowner
     LEFT JOIN pg_catalog.pg_class AS relation ON relation.oid = item.typrelid
     LEFT JOIN LATERAL pg_catalog.aclexplode(
       COALESCE(item.typacl, pg_catalog.acldefault('T', item.typowner))
     ) AS grant_row ON true
     LEFT JOIN pg_catalog.pg_roles AS grantee_role ON grantee_role.oid = grant_row.grantee
     WHERE namespace.nspname = current_schema()
       AND (item.typtype IN ('d', 'e', 'r', 'm')
            OR (item.typtype = 'c' AND relation.relkind = 'c'))`
  );
  assertOwnerOnlyACL(typeACLs.rows, identity.ownerRole, ["USAGE"], "type ACLs");
}

async function assertDefaultACLs(
  database: Queryable,
  identity: RuntimeDatabaseIdentity
) {
  const result = await database.query<{
    grantor_name: string;
    namespace_name: string;
    object_type: string;
    grantee_name: string | null;
    privilege: string | null;
    grantable: boolean | null;
  }>(
    `SELECT grantor_role.rolname AS grantor_name,
            COALESCE(default_namespace.nspname, '<global>') AS namespace_name,
            defaults.defaclobjtype AS object_type,
            CASE
              WHEN grant_row.grantee IS NULL THEN NULL
              WHEN grant_row.grantee = 0 THEN 'PUBLIC'
              ELSE COALESCE(grantee_role.rolname, pg_catalog.format('oid:%s', grant_row.grantee))
            END AS grantee_name,
            grant_row.privilege_type AS privilege,
            grant_row.is_grantable AS grantable
     FROM pg_catalog.pg_default_acl AS defaults
     JOIN pg_catalog.pg_roles AS grantor_role ON grantor_role.oid = defaults.defaclrole
     LEFT JOIN pg_catalog.pg_namespace AS default_namespace
       ON default_namespace.oid = defaults.defaclnamespace
     LEFT JOIN LATERAL pg_catalog.aclexplode(defaults.defaclacl) AS grant_row ON true
     LEFT JOIN pg_catalog.pg_roles AS grantee_role ON grantee_role.oid = grant_row.grantee
     WHERE grantor_role.rolname = ANY($1::text[])
        OR default_namespace.nspname = current_schema()`,
    [[identity.ownerRole, identity.adminRole, identity.runtimeRole]]
  );
  const expected = [identity.ownerRole, identity.adminRole].flatMap((role) => [
    aclKey(role, "<global>", role, "f:EXECUTE", false),
    aclKey(role, "<global>", role, "T:USAGE", false)
  ]);
  assertExactACL(
    result.rows.map((row) => aclKey(
      row.grantor_name,
      row.namespace_name,
      row.grantee_name ?? "<none>",
      `${row.object_type}:${row.privilege ?? "<none>"}`,
      row.grantable ?? false
    )),
    expected,
    "default ACLs"
  );
}

function assertOwnerOnlyACL(
  rows: Array<{
    object_name: string;
    owner_name: string;
    grantee_name: string | null;
    privilege: string | null;
    grantable: boolean | null;
  }>,
  ownerRole: string,
  privileges: readonly string[],
  label: string
) {
  const expected = [...new Set(rows.map((row) => row.object_name))].flatMap((objectName) =>
    privileges.map((privilege) => aclKey(
      objectName,
      ownerRole,
      ownerRole,
      privilege,
      false
    ))
  );
  assertExactACL(
    rows.flatMap((row) => row.grantee_name && row.privilege && row.grantable !== null
      ? [aclKey(
        row.object_name,
        row.owner_name,
        row.grantee_name,
        row.privilege,
        row.grantable
      )]
      : []),
    expected,
    label
  );
}

function aclKey(
  objectName: string,
  ownerName: string,
  granteeName: string,
  privilege: string,
  grantable: boolean
) {
  return JSON.stringify([objectName, ownerName, granteeName, privilege, grantable]);
}

function catalogObjectKey(name: string, kind: string) {
  return JSON.stringify([name, kind]);
}

function catalogRoutineKey(name: string, kind: string, identityArguments: string) {
  return JSON.stringify([name, kind, identityArguments]);
}

function assertExactACL(actual: string[], expected: string[], label: string) {
  if (actual.length !== expected.length || !sameMembers(actual, expected)) {
    throw schemaError(`${label} differ from the application contract`);
  }
}

function sameMembers(actual: Iterable<string>, expected: Iterable<string>) {
  const actualSet = new Set(actual);
  const expectedSet = new Set(expected);
  return actualSet.size === expectedSet.size
    && [...expectedSet].every((item) => actualSet.has(item));
}

function sameOrderedValues(actual: readonly string[], expected: readonly string[]) {
  return actual.length === expected.length
    && expected.every((value, index) => actual[index] === value);
}

function normalizeSQL(value: string) {
  return value.replace(/\s+/g, " ").trim();
}

function nonnegativeBigInt(value: string | number) {
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value) || value < 0) return null;
    return BigInt(value);
  }
  if (!/^\d+$/.test(value)) return null;
  try {
    return BigInt(value);
  } catch {
    return null;
  }
}

function schemaError(reason: string) {
  return new OperationalError(
    "schema_contract_invalid",
    `Address Atlas sync database schema is not ready: ${reason}.`
  );
}
