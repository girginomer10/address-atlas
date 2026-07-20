import type { Pool, PoolClient } from "pg";
import {
  STORAGE_RECONCILIATION_VERSION,
  SYNC_MIGRATIONS,
  type SyncMigration
} from "./postgres-migrations";
import {
  assertAppliedMigrationHistory,
  assertKnownUnversionedSchema,
  assertSyncSchemaReady,
  migrationLedgerExists
} from "./postgres-readiness";

const SCHEMA_MIGRATION_ADVISORY_LOCK = 1_094_992_973;

/**
 * Apply immutable migrations with the schema-owner connection. The session
 * advisory lock spans separately committed migrations so interrupted upgrades
 * resume from their durable ledger without allowing two binaries to race.
 */
export async function initializeSyncSchema(targetPool: Pool) {
  const client = await targetPool.connect();
  let discardClient = false;
  let migrationLockHeld = false;
  let lockAcquisitionAmbiguous = true;
  try {
    await client.query("SELECT pg_advisory_lock($1)", [SCHEMA_MIGRATION_ADVISORY_LOCK]);
    migrationLockHeld = true;
    lockAcquisitionAmbiguous = false;

    let appliedCount: number;
    if (await migrationLedgerExists(client)) {
      appliedCount = await assertAppliedMigrationHistory(client, { allowPending: true });
    } else {
      // Adoption is intentionally narrow: only a fresh database, the exact
      // six-table HEAD baseline, or this branch's exact nine-table baseline.
      // Arbitrary drift is reported, never silently repaired.
      await assertKnownUnversionedSchema(client);
      await applyMigration(client, SYNC_MIGRATIONS[0]!);
      appliedCount = 1;
    }

    for (const migration of SYNC_MIGRATIONS.slice(appliedCount)) {
      await applyMigration(client, migration);
    }

    await reconcileStorageUsageIfNeeded(client);
    await assertSyncSchemaReady(client);
  } catch (error) {
    discardClient = lockAcquisitionAmbiguous || !(await rollbackQuietly(client));
    throw error;
  } finally {
    if (migrationLockHeld && !discardClient) {
      try {
        await client.query("SELECT pg_advisory_unlock($1)", [SCHEMA_MIGRATION_ADVISORY_LOCK]);
      } catch {
        // A session lock must never return to the pool after an ambiguous unlock.
        discardClient = true;
      }
    }
    if (discardClient) client.release(true);
    else client.release();
  }
}

async function applyMigration(client: PoolClient, migration: SyncMigration) {
  await client.query("BEGIN");
  for (const statement of migration.statements) await client.query(statement);
  await client.query(
    `INSERT INTO sync_schema_migrations (version, name, checksum)
     VALUES ($1, $2, $3)`,
    [migration.version, migration.name, migration.checksum]
  );
  await client.query("COMMIT");
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
  if (!state
      || !Number.isInteger(state.reconciled_contract_version)
      || state.reconciled_contract_version < 0
      || typeof state.reconcile_required !== "boolean") {
    throw new Error("Address Atlas sync storage reconciliation state is invalid.");
  }
  if (state.reconciled_contract_version > STORAGE_RECONCILIATION_VERSION) {
    throw new Error("Address Atlas sync database schema is newer than this server supports.");
  }

  if (state.reconcile_required
      || state.reconciled_contract_version < STORAGE_RECONCILIATION_VERSION) {
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
      [STORAGE_RECONCILIATION_VERSION]
    );
  }
  await client.query("COMMIT");
}

async function rollbackQuietly(client: PoolClient) {
  try {
    await client.query("ROLLBACK");
    return true;
  } catch {
    // A timed-out statement may still be running server-side. Never return an
    // ambiguous transaction or advisory lock to the connection pool.
    return false;
  }
}
