import { performance } from "node:perf_hooks";
import type { Pool } from "pg";

const USAGE_RETENTION_DAYS = 35;
const USAGE_PRUNE_BATCH_SIZE = 10_000;
const USAGE_PRUNE_MAX_BATCHES = 100;
const USAGE_PRUNE_MAX_RUNTIME_MS = 2_000;
const USAGE_PRUNE_INTERVAL_MS = 60 * 60 * 1_000;
const USAGE_PRUNE_RETRY_MS = 60 * 1_000;

let nextUsagePruneAt = 0;
let usagePruneInFlight: Promise<void> | null = null;

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
  } catch {
    // Retention is best effort and must not make an otherwise healthy request
    // unavailable. Retry soon instead of waiting for the normal hourly window.
    nextUsagePruneAt = performance.now() + USAGE_PRUNE_RETRY_MS;
  }
}

export function resetUsageRetentionState() {
  nextUsagePruneAt = 0;
  usagePruneInFlight = null;
}
