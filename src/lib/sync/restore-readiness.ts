import { SyncConfigurationError } from "./config";
import {
  generatedDiagnostics,
  operationalErrorCode,
  type OperationalErrorCode,
  recordSecurityEvent
} from "./diagnostics";
import { getSyncSchemaPool } from "./postgres-pool";
import {
  assertSafeRestoreDatabaseContext,
  RESTORE_DATABASE_CONTEXT_QUERY,
  type RestoreDatabaseContext
} from "./postgres-search-path";
import { bootstrapSyncSchema, closeSyncPools } from "./postgres";
import { assertStoredVaultIntegrity } from "./vault-integrity";

async function main() {
  const diagnostics = generatedDiagnostics("restore.readiness");
  let failureCode: OperationalErrorCode = "database_query_failed";
  try {
    const pool = getSyncSchemaPool();
    const context = await pool.query<RestoreDatabaseContext>(
      RESTORE_DATABASE_CONTEXT_QUERY
    );
    failureCode = "restore_context_invalid";
    assertSafeRestoreDatabaseContext(context.rows[0], context.rowCount);
    failureCode = "migration_failed";
    await bootstrapSyncSchema();
    failureCode = "vault_snapshot_invalid";
    await assertStoredVaultIntegrity(pool);
    recordSecurityEvent("restore.readiness_succeeded", diagnostics, {
      status: 200,
      reason: "restored_schema_ready",
      severity: "info"
    });
  } catch (error) {
    recordSecurityEvent("restore.readiness_failed", diagnostics, {
      status: 503,
      reason: error instanceof SyncConfigurationError
        ? "configuration_invalid"
        : "restored_schema_invalid",
      errorCode: operationalErrorCode(error, failureCode),
      severity: "error"
    });
    process.exitCode = 1;
  } finally {
    await closeSyncPools();
  }
}

void main();
