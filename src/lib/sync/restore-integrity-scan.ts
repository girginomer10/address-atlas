import { performance } from "node:perf_hooks";
import { OperationalError } from "./diagnostics";

export const RESTORE_INTEGRITY_SCAN_DEADLINE_MS = 30 * 60_000;

export interface RestoreIntegrityScanProgress {
  rowsScanned: number;
  pagesScanned: number;
  done: boolean;
}

export interface RestoreIntegrityScanOptions {
  deadlineMs?: number;
  deadlineAt?: number;
  onProgress?: (progress: RestoreIntegrityScanProgress) => void;
}

export function resolveRestoreIntegrityDeadline(
  { deadlineMs, deadlineAt }: RestoreIntegrityScanOptions
) {
  if (deadlineMs !== undefined && deadlineAt !== undefined) {
    throw new Error("Restore integrity deadline is ambiguous.");
  }
  if (deadlineAt !== undefined) {
    const now = performance.now();
    if (
      !Number.isFinite(deadlineAt)
      || deadlineAt < 0
      || deadlineAt > now + RESTORE_INTEGRITY_SCAN_DEADLINE_MS
    ) {
      throw new Error("Restore integrity deadline is invalid.");
    }
    return deadlineAt;
  }
  const duration = deadlineMs ?? RESTORE_INTEGRITY_SCAN_DEADLINE_MS;
  if (
    !Number.isSafeInteger(duration)
    || duration < 1
    || duration > RESTORE_INTEGRITY_SCAN_DEADLINE_MS
  ) {
    throw new Error("Restore integrity deadline is invalid.");
  }
  return performance.now() + duration;
}

export function assertWithinRestoreIntegrityDeadline(deadlineAt: number) {
  if (performance.now() > deadlineAt) {
    throw new OperationalError(
      "database_query_failed",
      "Restore integrity scan exceeded its recovery deadline."
    );
  }
}
