import type { PoolClient } from "pg";
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
  SYNC_INDEX_CONTRACT,
  SYNC_RUNTIME_PRIVILEGES,
  SYNC_TABLES
} from "./postgres-schema-model";

type Queryable = Pick<PoolClient, "query">;

interface MigrationRow {
  version: number;
  name: string;
  checksum: string;
}

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

export async function assertKnownUnversionedSchema(database: Queryable) {
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
  if (present.length === 0) return;

  const knownLegacy = sameMembers(present, LEGACY_SYNC_TABLES);
  const knownPreLedger = sameMembers(present, PRE_LEDGER_SYNC_TABLES);
  if (!knownLegacy && !knownPreLedger) {
    throw schemaError("unversioned schema is not a recognized release baseline");
  }
  await assertSchemaSurface(database, present, false);
  await assertStorageState(database, true);
}

export async function assertSyncSchemaReady(database: Queryable) {
  if (!(await migrationLedgerExists(database))) {
    throw schemaError("migration ledger is missing");
  }
  await assertAppliedMigrationHistory(database, { allowPending: false });
  await assertSchemaSurface(database, [...SYNC_TABLES], true);
  await assertStorageState(database, false);
}

async function assertSchemaSurface(
  database: Queryable,
  tableNames: readonly string[],
  verifyPrivileges: boolean
) {
  const expectedTables = new Set(tableNames);
  const relations = await database.query<{
    table_name: string;
    relation_kind: string;
    persistence: string;
    row_security: boolean;
    force_row_security: boolean;
    is_partition: boolean;
  }>(
    `SELECT relation.relname AS table_name,
            relation.relkind AS relation_kind,
            relation.relpersistence AS persistence,
            relation.relrowsecurity AS row_security,
            relation.relforcerowsecurity AS force_row_security,
            relation.relispartition AS is_partition
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
    || row.is_partition);
  if (unsafeRelation) throw schemaError(`table ${unsafeRelation.table_name} has unsupported behavior`);

  const expectedColumns = SYNC_COLUMN_CONTRACT.filter((item) => expectedTables.has(item.table));
  const columns = await database.query<{
    table_name: string;
    column_name: string;
    type_name: string;
    not_null: boolean;
    has_default: boolean;
    identity_kind: string;
    generated_kind: string;
    dimensions: number;
  }>(
    `SELECT relation.relname AS table_name,
            attribute.attname AS column_name,
            type.typname AS type_name,
            attribute.attnotnull AS not_null,
            default_value.oid IS NOT NULL AS has_default,
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
        || actual.type_name !== expected.type
        || !actual.not_null
        || actual.has_default !== expected.hasDefault
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
    validated: boolean;
    deferrable: boolean;
    foreign_delete_action: string;
  }>(
    `SELECT relation.relname AS table_name,
            constraint_row.conname AS constraint_name,
            constraint_row.contype AS constraint_type,
            constraint_row.convalidated AS validated,
            constraint_row.condeferrable AS deferrable,
            constraint_row.confdeltype AS foreign_delete_action
     FROM pg_catalog.pg_constraint AS constraint_row
     JOIN pg_catalog.pg_class AS relation ON relation.oid = constraint_row.conrelid
     JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
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
  if (actualConstraints.size !== expectedConstraints.length) {
    throw schemaError("constraint set differs from the migration contract");
  }
  for (const expected of expectedConstraints) {
    const actual = actualConstraints.get(`${expected.table}.${expected.name}`);
    if (!actual
        || actual.constraint_type !== expected.type
        || !actual.validated
        || actual.deferrable
        || (expected.cascadeDelete && actual.foreign_delete_action !== "c")) {
      throw schemaError(`constraint ${expected.name} differs from the migration contract`);
    }
  }

  const expectedIndexes = new Set(SYNC_INDEX_CONTRACT.filter((name) => {
    const constraintOwner = expectedConstraints.find((item) => item.name === name);
    if (constraintOwner) return true;
    return expectedIndexTable(name) ? expectedTables.has(expectedIndexTable(name)!) : false;
  }));
  const indexes = await database.query<{
    index_name: string;
    valid: boolean;
    ready: boolean;
    live: boolean;
    partial: boolean;
    expression: boolean;
  }>(
    `SELECT index_relation.relname AS index_name,
            index_row.indisvalid AS valid,
            index_row.indisready AS ready,
            index_row.indislive AS live,
            index_row.indpred IS NOT NULL AS partial,
            index_row.indexprs IS NOT NULL AS expression
     FROM pg_catalog.pg_index AS index_row
     JOIN pg_catalog.pg_class AS relation ON relation.oid = index_row.indrelid
     JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
     JOIN pg_catalog.pg_class AS index_relation ON index_relation.oid = index_row.indexrelid
     WHERE namespace.nspname = current_schema()
       AND relation.relname = ANY($1::text[])
     ORDER BY index_relation.relname`,
    [[...tableNames]]
  );
  if (!sameMembers(indexes.rows.map((row) => row.index_name), expectedIndexes)) {
    throw schemaError("index set differs from the migration contract");
  }
  const unsafeIndex = indexes.rows.find((row) => !row.valid || !row.ready || !row.live
    || row.partial || row.expression);
  if (unsafeIndex) throw schemaError(`index ${unsafeIndex.index_name} is not ready`);

  const triggers = await database.query<{
    trigger_name: string;
    table_name: string;
    enabled: string;
    trigger_type: number;
    function_name: string;
    language_name: string;
    security_definer: boolean;
  }>(
    `SELECT trigger_row.tgname AS trigger_name,
            relation.relname AS table_name,
            trigger_row.tgenabled AS enabled,
            trigger_row.tgtype AS trigger_type,
            function_row.proname AS function_name,
            language_row.lanname AS language_name,
            function_row.prosecdef AS security_definer
     FROM pg_catalog.pg_trigger AS trigger_row
     JOIN pg_catalog.pg_class AS relation ON relation.oid = trigger_row.tgrelid
     JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
     JOIN pg_catalog.pg_proc AS function_row ON function_row.oid = trigger_row.tgfoid
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
        || trigger.function_name !== "address_atlas_decrement_snapshot_usage"
        || trigger.language_name !== "plpgsql"
        || trigger.security_definer) {
      throw schemaError("vault accounting trigger differs from the migration contract");
    }
  }

  if (verifyPrivileges) await assertRuntimePrivileges(database);
}

async function assertStorageState(database: Queryable, allowPendingReconcile: boolean) {
  const result = await database.query<{
    total_snapshot_bytes: string | number;
    reconciled_contract_version: number;
    reconcile_required: boolean;
  }>(
    `SELECT total_snapshot_bytes, reconciled_contract_version, reconcile_required
     FROM sync_storage_usage
     WHERE singleton = true
     LIMIT 2`
  );
  const state = result.rows[0];
  if (result.rows.length !== 1
      || !state
      || Number(state.total_snapshot_bytes) < 0
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

async function assertRuntimePrivileges(database: Queryable) {
  const schema = await database.query<{ allowed: boolean }>(
    `SELECT has_schema_privilege(current_user, current_schema(), 'USAGE') AS allowed`
  );
  if (schema.rows[0]?.allowed !== true) throw schemaError("runtime role lacks schema usage");

  const tableNames: string[] = [];
  const privileges: string[] = [];
  for (const [tableName, required] of Object.entries(SYNC_RUNTIME_PRIVILEGES)) {
    for (const privilege of required) {
      tableNames.push(tableName);
      privileges.push(privilege);
    }
  }
  const result = await database.query<{ table_name: string; privilege: string; allowed: boolean }>(
    `SELECT requested.table_name,
            requested.privilege,
            has_table_privilege(
              current_user,
              format('%I.%I', current_schema(), requested.table_name),
              requested.privilege
            ) AS allowed
     FROM unnest($1::text[], $2::text[]) AS requested(table_name, privilege)`,
    [tableNames, privileges]
  );
  const denied = result.rows.find((row) => !row.allowed);
  if (denied) throw schemaError(`runtime role lacks ${denied.privilege} on ${denied.table_name}`);
}

function expectedIndexTable(indexName: string) {
  if (indexName === "consumed_challenges_consumed_at_idx") return "consumed_challenges";
  if (indexName.startsWith("session_grants_")) return "session_grants";
  if (indexName === "vault_write_usage_date_idx") return "vault_write_usage";
  return undefined;
}

function sameMembers(actual: Iterable<string>, expected: Iterable<string>) {
  const actualSet = new Set(actual);
  const expectedSet = new Set(expected);
  return actualSet.size === expectedSet.size
    && [...expectedSet].every((item) => actualSet.has(item));
}

function schemaError(reason: string) {
  return new Error(`Address Atlas sync database schema is not ready: ${reason}.`);
}
