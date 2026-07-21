import { SyncConfigurationError } from "./config";
import {
  generatedDiagnostics,
  operationalErrorCode,
  recordSecurityEvent
} from "./diagnostics";
import { bootstrapSyncSchema, closeSyncPools } from "./postgres";

async function main() {
  const diagnostics = generatedDiagnostics("schema.bootstrap");
  try {
    await bootstrapSyncSchema();
    recordSecurityEvent("schema.bootstrap_succeeded", diagnostics, {
      status: 200,
      reason: "schema_ready",
      severity: "info"
    });
  } catch (error) {
    recordSecurityEvent("schema.bootstrap_failed", diagnostics, {
      status: 503,
      reason: error instanceof SyncConfigurationError ? "configuration_invalid" : "migration_failed",
      errorCode: operationalErrorCode(error, "migration_failed"),
      severity: "error"
    });
    process.exitCode = 1;
  } finally {
    await closeSyncPools();
  }
}

void main();
