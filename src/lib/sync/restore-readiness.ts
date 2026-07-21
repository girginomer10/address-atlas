import { SyncConfigurationError } from "./config";
import { generatedDiagnostics, recordSecurityEvent } from "./diagnostics";
import { getSyncSchemaPool } from "./postgres-pool";
import {
  assertSafeRestoreDatabaseContext,
  RESTORE_DATABASE_CONTEXT_QUERY,
  type RestoreDatabaseContext
} from "./postgres-search-path";
import { bootstrapSyncSchema, closeSyncPools } from "./postgres";

async function main() {
  const diagnostics = generatedDiagnostics("restore.readiness");
  try {
    const pool = getSyncSchemaPool();
    const context = await pool.query<RestoreDatabaseContext>(
      RESTORE_DATABASE_CONTEXT_QUERY
    );
    assertSafeRestoreDatabaseContext(context.rows[0], context.rowCount);
    await bootstrapSyncSchema();
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
      severity: "error"
    });
    process.exitCode = 1;
  } finally {
    await closeSyncPools();
  }
}

void main();
