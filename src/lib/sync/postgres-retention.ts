import { performance } from "node:perf_hooks";
import type { Pool } from "pg";
import {
  generatedDiagnostics,
  operationalErrorCode,
  recordSecurityEvent
} from "./diagnostics";

const USAGE_RETENTION_DAYS = 35;
const USAGE_PRUNE_BATCH_SIZE = 10_000;
const USAGE_PRUNE_MAX_BATCHES = 100;
const USAGE_PRUNE_MAX_RUNTIME_MS = 2_000;
const USAGE_PRUNE_INTERVAL_MS = 60 * 60 * 1_000;
const USAGE_PRUNE_RETRY_MS = 60 * 1_000;
const USAGE_PRUNE_MAX_RETRY_MS = 15 * 60 * 1_000;

let nextUsagePruneAt = 0;
let usagePruneInFlight: Promise<void> | null = null;
let consecutiveUsagePruneFailures = 0;

export function scheduleOldVaultWriteUsagePrune(getPool: () => Pool) {
  const now = performance.now();
  if (usagePruneInFlight || now < nextUsagePruneAt) return;

  nextUsagePruneAt = now + USAGE_PRUNE_INTERVAL_MS;
  const attempt = pruneOldVaultWriteUsage(getPool);
  usagePruneInFlight = attempt;
  void attempt.finally(() => {
    if (usagePruneInFlight === attempt) usagePruneInFlight = null;
  });
}

async function pruneOldVaultWriteUsage(getPool: () => Pool) {
  const deadline = performance.now() + USAGE_PRUNE_MAX_RUNTIME_MS;
  const recoveringFromFailure = consecutiveUsagePruneFailures > 0;
  try {
    for (let batch = 0; batch < USAGE_PRUNE_MAX_BATCHES && performance.now() < deadline; batch += 1) {
      const result = await getPool().query(
        `DELETE FROM vault_write_usage
         WHERE ctid IN (
           SELECT ctid
           FROM vault_write_usage
           WHERE usage_date < (now() AT TIME ZONE 'UTC')::date - $1
           ORDER BY usage_date
           FOR UPDATE SKIP LOCKED
           LIMIT $2
         )`,
        [USAGE_RETENTION_DAYS, USAGE_PRUNE_BATCH_SIZE]
      );
      if ((result.rowCount ?? 0) < USAGE_PRUNE_BATCH_SIZE) break;
    }
    await getPool().query(
      `DELETE FROM vault_global_ingress_usage
       WHERE usage_date < (now() AT TIME ZONE 'UTC')::date - $1`,
      [USAGE_RETENTION_DAYS]
    );
    consecutiveUsagePruneFailures = 0;
    if (recoveringFromFailure) {
      recordSecurityEvent(
        "storage.usage_retention_restored",
        generatedDiagnostics("postgres.retention"),
        {
          status: 200,
          reason: "usage_retention_prune_restored",
          severity: "info"
        }
      );
    }
  } catch (error) {
    // Retention is best effort and must not make an otherwise healthy request
    // unavailable. Retry soon instead of waiting for the normal hourly window.
    const retryMs = Math.min(
      USAGE_PRUNE_RETRY_MS * (2 ** Math.min(consecutiveUsagePruneFailures, 4)),
      USAGE_PRUNE_MAX_RETRY_MS
    );
    consecutiveUsagePruneFailures = Math.min(consecutiveUsagePruneFailures + 1, 5);
    nextUsagePruneAt = performance.now() + retryMs;
    recordSecurityEvent(
      "storage.usage_retention_failed",
      generatedDiagnostics("postgres.retention"),
      {
        status: 500,
        reason: "usage_retention_prune_failed",
        errorCode: operationalErrorCode(error, "database_query_failed"),
        severity: "error"
      }
    );
  }
}

export function resetUsageRetentionState() {
  nextUsagePruneAt = 0;
  usagePruneInFlight = null;
  consecutiveUsagePruneFailures = 0;
}
