import { SyncConfigurationError } from "./config";
import { generatedDiagnostics, recordSecurityEvent } from "./diagnostics";
import { getSyncSchemaPool } from "./postgres-pool";
import { bootstrapSyncSchema, closeSyncPools } from "./postgres";

async function main() {
  const diagnostics = generatedDiagnostics("restore.readiness");
  try {
    const pool = getSyncSchemaPool();
    const context = await pool.query<{
      current_user: string;
      search_path: string;
      spoof_schema_count: number;
    }>(`
      SELECT
        current_user,
        current_setting('search_path') AS search_path,
        (
          SELECT count(*)::integer
          FROM pg_catalog.pg_namespace
          WHERE nspname = 'address_atlas'
        ) AS spoof_schema_count
    `);
    const row = context.rows[0];
    if (
      context.rowCount !== 1
      || row?.current_user !== "address_atlas"
      || row.search_path.replaceAll(" ", "") !== "public,pg_catalog"
      || row.spoof_schema_count !== 0
    ) {
      throw new Error("Restored database owner/search-path context is unsafe.");
    }
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
