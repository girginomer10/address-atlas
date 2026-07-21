import { performance } from "node:perf_hooks";
import type { PoolClient } from "pg";
import {
  generatedDiagnostics,
  OperationalError,
  operationalErrorCode,
  recordSecurityEvent,
  type RequestDiagnostics
} from "./diagnostics";
import { STORAGE_RECONCILIATION_VERSION } from "./postgres-migrations";
import { getSyncPool } from "./postgres-pool";

const VALID_AUDIT_INTERVAL_MS = 5 * 60_000;
const MAX_VALID_AUDIT_AGE_MS = 10 * 60_000;
const FAILED_AUDIT_RETRY_MS = 60_000;

let auditInFlight: Promise<void> | null = null;
let nextAuditAt = 0;
export type StorageLedgerAuditState = "pending" | "valid" | "invalid" | "unavailable";
let lastAuditState: StorageLedgerAuditState = "pending";
let lastSuccessfulAuditAt: number | null = null;

function ledgerError() {
  return new OperationalError(
    "storage_ledger_invalid",
    "Address Atlas sync storage accounting differs from durable vault rows."
  );
}

/**
 * Start the exact ledger audit without putting its table scan on /healthz's
 * latency path. The database transaction bounds both lock wait and statement
 * execution. A repeatable-read snapshot compares the ledger and durable rows
 * without holding the singleton write lock through the table scan. A confirmed
 * drift persists a write-blocking marker; a concurrent writer instead causes a
 * serialization retry. Pending or unavailable audits fail closed for health
 * and vault writes while reads and authentication stay available.
 */
export function scheduleStorageLedgerIntegrityAudit(
  diagnostics: RequestDiagnostics = generatedDiagnostics("storage-ledger-audit")
) {
  if (auditInFlight || performance.now() < nextAuditAt) return false;

  const previousAuditState = lastAuditState;
  const attempt = checkStorageLedgerIntegrity();
  auditInFlight = attempt;
  void attempt.then(() => {
    nextAuditAt = performance.now() + VALID_AUDIT_INTERVAL_MS;
    if (previousAuditState === "invalid" || previousAuditState === "unavailable") {
      recordSecurityEvent("storage.ledger_integrity_restored", diagnostics, {
        status: 200,
        reason: "exact_ledger_audit_passed",
        severity: "info"
      });
    }
    lastAuditState = "valid";
    lastSuccessfulAuditAt = performance.now();
  }, (error: unknown) => {
    nextAuditAt = performance.now() + FAILED_AUDIT_RETRY_MS;
    const errorCode = operationalErrorCode(error, "database_query_failed");
    if (errorCode === "storage_ledger_invalid") {
      if (previousAuditState !== "invalid") {
        recordSecurityEvent("storage.ledger_drift_detected", diagnostics, {
          status: 503,
          reason: "vault_writes_blocked",
          errorCode,
          severity: "error"
        });
      }
      lastAuditState = "invalid";
    } else {
      recordSecurityEvent("storage.ledger_audit_failed", diagnostics, {
        status: 503,
        reason: "exact_ledger_audit_unavailable",
        errorCode,
        severity: "error"
      });
      lastAuditState = "unavailable";
    }
  }).finally(() => {
    if (auditInFlight === attempt) auditInFlight = null;
  });
  return true;
}

export function getStorageLedgerAuditState() {
  if (
    lastAuditState === "valid"
    && (lastSuccessfulAuditAt === null
      || performance.now() - lastSuccessfulAuditAt > MAX_VALID_AUDIT_AGE_MS)
  ) {
    return "unavailable" as const;
  }
  return lastAuditState;
}

export function assertStorageLedgerAuditReady() {
  if (getStorageLedgerAuditState() !== "valid") throw ledgerError();
}

/**
 * Run one exact, time-bounded audit. This is exported for owner/recovery tools
 * and tests; request readiness must schedule it rather than await it.
 */
export async function checkStorageLedgerIntegrity() {
  const client = await getSyncPool().connect();
  let transactionOpen = false;
  let discardClient = false;
  try {
    transactionOpen = true;
    await client.query("BEGIN ISOLATION LEVEL REPEATABLE READ");
    await client.query("SET LOCAL lock_timeout = '1000ms'");
    await client.query("SET LOCAL statement_timeout = '5000ms'");

    const ledger = await client.query<{
      recorded_bytes: string;
      reconciled_contract_version: number;
      reconcile_required: boolean;
    }>(
      `SELECT total_snapshot_bytes::text AS recorded_bytes,
              reconciled_contract_version,
              reconcile_required
       FROM sync_storage_usage
       WHERE singleton = true
       LIMIT 2`
    );
    const row = ledger.rows[0];
    if (
      ledger.rows.length !== 1
      || !row
      || !isCanonicalCount(row.recorded_bytes)
      || !Number.isInteger(row.reconciled_contract_version)
      || typeof row.reconcile_required !== "boolean"
    ) {
      throw ledgerError();
    }

    const total = await client.query<{ actual_bytes: string }>(
      `SELECT COALESCE(sum(byte_size), 0)::text AS actual_bytes
       FROM vault_snapshots`
    );
    const actualBytes = total.rows[0]?.actual_bytes;
    const invalid = total.rows.length !== 1
      || !isCanonicalCount(actualBytes)
      || BigInt(row.recorded_bytes) !== BigInt(actualBytes)
      || row.reconciled_contract_version !== STORAGE_RECONCILIATION_VERSION
      || row.reconcile_required;

    if (invalid) {
      if (!row.reconcile_required) {
        await client.query(
          `UPDATE sync_storage_usage
           SET reconcile_required = true, updated_at = now()
           WHERE singleton = true`
        );
      }
      await client.query("COMMIT");
      transactionOpen = false;
      throw ledgerError();
    }

    await client.query("COMMIT");
    transactionOpen = false;
  } catch (error) {
    if (transactionOpen) discardClient = !(await rollbackQuietly(client));
    throw error;
  } finally {
    if (discardClient) client.release(true);
    else client.release();
  }
}

function isCanonicalCount(value: unknown): value is string {
  return typeof value === "string" && /^(0|[1-9][0-9]*)$/.test(value);
}

async function rollbackQuietly(client: PoolClient) {
  try {
    await client.query("ROLLBACK");
    return true;
  } catch {
    return false;
  }
}

export function resetStorageLedgerIntegrityForTests() {
  auditInFlight = null;
  nextAuditAt = 0;
  lastAuditState = "pending";
  lastSuccessfulAuditAt = null;
}

export function setStorageLedgerAuditStateForTests(state: StorageLedgerAuditState) {
  lastAuditState = state;
  lastSuccessfulAuditAt = state === "valid" ? performance.now() : null;
  nextAuditAt = performance.now() + VALID_AUDIT_INTERVAL_MS;
}
