import type { Pool, PoolClient } from "pg";
import {
  LATEST_SYNC_MIGRATION_VERSION,
  STORAGE_RECONCILIATION_VERSION,
  SYNC_MIGRATIONS,
  type SyncMigration
} from "./postgres-migrations";
import {
  assertAppliedMigrationHistory,
  assertKnownUnversionedSchema,
  assertPasskeyCredentialStoragePolicies,
  assertPasskeyStoredValueStorageSafety,
  assertSyncSchemaReady,
  assertSyncSchemaVersionReady,
  assertVaultEnvelopeStoragePolicy,
  assertVaultStoredValueStorageSafety,
  getPasskeyCredentialStoragePolicies,
  getVaultEnvelopeStoragePolicy,
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
      // Arbitrary drift is reported, never silently repaired. Existing
      // pre-ledger baselines already contain the version-2 vault surface, so
      // record versions 1 and 2 atomically instead of exposing a false v1
      // ledger between separately committed migrations.
      appliedCount = await applyUnversionedBaseline(client);
    }

    for (const migration of SYNC_MIGRATIONS.slice(appliedCount)) {
      await applyPendingMigration(client, migration, migration.version - 1);
    }

    const durableVersion = Math.max(appliedCount, LATEST_SYNC_MIGRATION_VERSION);
    await convergeProjectionSafeStoragePolicies(client, durableVersion);
    await reconcileStorageUsageIfNeeded(client, durableVersion);
    await assertSyncSchemaReady(client, { verifyRuntimePrivileges: false });
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

/**
 * Metadata-only expand step for the prepared v4/v5 bounds. PostgreSQL does not
 * rewrite existing values for SET STORAGE, and the v3 application ignores
 * these catalog attributes, so the currently serving N-1 image remains
 * compatible. New writes become uncompressed immediately; guarded reads
 * additionally reject any legacy compressed value before detoasting it.
 */
async function convergeProjectionSafeStoragePolicies(
  client: PoolClient,
  appliedVersion: number
) {
  if (appliedVersion < 1) return;
  await client.query("BEGIN");
  await assertSyncSchemaVersionReady(client, appliedVersion);
  const passkeyPolicies = await getPasskeyCredentialStoragePolicies(client);
  if (passkeyPolicies?.id !== "e") {
    await client.query(
      "ALTER TABLE passkey_credentials ALTER COLUMN id SET STORAGE EXTERNAL"
    );
  }
  if (passkeyPolicies?.publicKeyBase64url !== "e") {
    await client.query(
      "ALTER TABLE passkey_credentials ALTER COLUMN public_key_base64url SET STORAGE EXTERNAL"
    );
  }
  await assertPasskeyCredentialStoragePolicies(client);
  if (appliedVersion >= 2 && await getVaultEnvelopeStoragePolicy(client) !== "e") {
    await client.query(
      "ALTER TABLE vault_snapshots ALTER COLUMN envelope SET STORAGE EXTERNAL"
    );
  }
  if (appliedVersion >= 2) await assertVaultEnvelopeStoragePolicy(client);
  await client.query("COMMIT");

  // Keep the expand-only catalog convergence even when legacy rows need
  // operator repair. The still-serving N-1 binary tolerates this attribute,
  // and every subsequent write is now uncompressed while cutover stays blocked.
  await assertPasskeyStoredValueStorageSafety(client);
  if (appliedVersion >= 2) await assertVaultStoredValueStorageSafety(client);
}

async function applyUnversionedBaseline(client: PoolClient) {
  await client.query("BEGIN");
  const baseline = await assertKnownUnversionedSchema(client);
  const migrations = baseline === "empty"
    ? SYNC_MIGRATIONS.slice(0, 1)
    : SYNC_MIGRATIONS.slice(0, 2);
  for (const migration of migrations) await executeMigration(client, migration);
  const appliedVersion = migrations.at(-1)?.version;
  if (!appliedVersion) {
    throw new Error("Address Atlas sync migration baseline is empty.");
  }
  await assertSyncSchemaVersionReady(client, appliedVersion);
  await client.query("COMMIT");
  return appliedVersion;
}

async function applyPendingMigration(
  client: PoolClient,
  migration: SyncMigration,
  appliedVersion: number
) {
  await client.query("BEGIN");
  // Validate before the first mutating statement and validate the resulting
  // surface again before commit. A drifted predecessor or broken migration can
  // therefore never become a durable partially upgraded release.
  const durableVersion = await assertAppliedMigrationHistory(client, { allowPending: true });
  if (durableVersion !== appliedVersion) {
    throw new Error(
      "Address Atlas sync database schema is not ready: "
      + "applied migration version changed while upgrade was in progress."
    );
  }
  await assertSyncSchemaVersionReady(client, appliedVersion);
  await executeMigration(client, migration);
  await assertSyncSchemaVersionReady(client, migration.version);
  await client.query("COMMIT");
}

async function executeMigration(client: PoolClient, migration: SyncMigration) {
  for (const statement of migration.statements) await client.query(statement);
  await client.query(
    `INSERT INTO sync_schema_migrations (version, name, checksum)
     VALUES ($1, $2, $3)`,
    [migration.version, migration.name, migration.checksum]
  );
}

async function reconcileStorageUsageIfNeeded(
  client: PoolClient,
  appliedVersion: number
) {
  await client.query("BEGIN");
  // Owner bootstrap reconciliation is itself mutating. Revalidate the final
  // versioned surface in this transaction so drift cannot be altered before
  // the later diagnostic readiness pass rejects it.
  await assertSyncSchemaVersionReady(client, appliedVersion);
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

  // Recompute on every owner bootstrap, even when the persisted marker claims
  // the current contract. A logically stale counter must never survive a
  // restore/bootstrap merely because its metadata was stale in the same dump.
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
