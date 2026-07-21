import { performance } from "node:perf_hooks";
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
import {
  assertStoredVaultIntegrity,
} from "./vault-integrity";
import {
  RESTORE_INTEGRITY_SCAN_DEADLINE_MS,
  type RestoreIntegrityScanProgress
} from "./restore-integrity-scan";
import { assertStoredPasskeyCredentialIntegrity } from "./passkey-credential-integrity";

async function main() {
  const diagnostics = generatedDiagnostics("restore.readiness");
  const recoveryDeadlineAt = performance.now() + RESTORE_INTEGRITY_SCAN_DEADLINE_MS;
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
    await assertStoredVaultIntegrity(pool, {
      deadlineAt: recoveryDeadlineAt,
      onProgress: restoreProgressReporter("vault", diagnostics)
    });
    failureCode = "passkey_credential_invalid";
    await assertStoredPasskeyCredentialIntegrity(pool, {
      deadlineAt: recoveryDeadlineAt,
      onProgress: restoreProgressReporter("passkey", diagnostics)
    });
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

function restoreProgressReporter(
  phase: "vault" | "passkey",
  diagnostics: ReturnType<typeof generatedDiagnostics>
) {
  let nextReportAt = 100_000;
  return (progress: RestoreIntegrityScanProgress) => {
    if (!progress.done && progress.rowsScanned < nextReportAt) return;
    while (nextReportAt <= progress.rowsScanned) nextReportAt += 100_000;
    recordSecurityEvent("restore.integrity_progress", diagnostics, {
      status: 200,
      reason: progress.done ? "integrity_scan_complete" : "integrity_scan_progress",
      phase,
      progressRows: progress.rowsScanned,
      severity: "info"
    });
  };
}

void main();
