import { getSyncSchemaMode } from "./config";
import { closeSyncDatabasePools, getSyncPool, getSyncSchemaPool } from "./postgres-pool";
import { scheduleOldVaultWriteUsagePrune, resetUsageRetentionState } from "./postgres-retention";
import { assertSyncSchemaReady } from "./postgres-readiness";
import { initializeSyncSchema } from "./postgres-schema";

let schemaReady: Promise<void> | null = null;

export { getSyncPool } from "./postgres-pool";

export async function ensureSyncSchema() {
  if (!schemaReady) {
    // The production request-serving role defaults to validation-only and
    // never needs CREATE/ALTER/TRIGGER privileges. Local development retains
    // convenient bootstrap behavior through its explicit mode default.
    const attempt = getSyncSchemaMode() === "bootstrap"
      ? initializeSyncSchema(getSyncPool())
      : assertSyncSchemaReady(getSyncPool());
    schemaReady = attempt;
    // A transient startup failure must not permanently poison this process.
    // Clear only our own attempt so a later caller can retry safely.
    void attempt.catch(() => {
      if (schemaReady === attempt) schemaReady = null;
    });
  }
  await schemaReady;
  scheduleOldVaultWriteUsagePrune(getSyncPool);
}

/** Run schema DDL once with the separately configured schema-owner role. */
export async function bootstrapSyncSchema() {
  await initializeSyncSchema(getSyncSchemaPool());
}

/** Probe current runtime readiness independently of the cached startup path. */
export async function checkSyncSchemaReadiness() {
  await assertSyncSchemaReady(getSyncPool());
}

export async function closeSyncPools() {
  await closeSyncDatabasePools();
  schemaReady = null;
  resetUsageRetentionState();
}

export const closeSyncPoolForTests = closeSyncPools;
