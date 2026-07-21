import { performance } from "node:perf_hooks";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  connect: vi.fn(),
  query: vi.fn(),
  release: vi.fn()
}));

vi.mock("./postgres-pool", () => ({
  getSyncPool: () => ({ connect: mocks.connect })
}));

import {
  checkStorageLedgerIntegrity,
  resetStorageLedgerIntegrityForTests,
  scheduleStorageLedgerIntegrityAudit
} from "./storage-ledger-integrity";

describe("storage ledger integrity audit", () => {
  let monotonicNow: number;

  beforeEach(() => {
    vi.restoreAllMocks();
    vi.clearAllMocks();
    monotonicNow = 1_000;
    vi.spyOn(performance, "now").mockImplementation(() => monotonicNow);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.spyOn(console, "info").mockImplementation(() => undefined);
    resetStorageLedgerIntegrityForTests();
    mocks.connect.mockResolvedValue({ query: mocks.query, release: mocks.release });
    installAuditResult({ recorded: "321", actual: "321" });
  });

  it("compares one canonical ledger row and exact sum in a non-blocking snapshot", async () => {
    await expect(checkStorageLedgerIntegrity()).resolves.toBeUndefined();

    const statements = mocks.query.mock.calls.map(([sql]) => String(sql));
    expect(statements).toContain("SET LOCAL lock_timeout = '1000ms'");
    expect(statements).toContain("SET LOCAL statement_timeout = '5000ms'");
    expect(statements[0]).toBe("BEGIN ISOLATION LEVEL REPEATABLE READ");
    expect(statements.find((sql) => sql.includes("FROM sync_storage_usage")))
      .not.toContain("FOR UPDATE");
    expect(statements.find((sql) => sql.includes("sum(byte_size)"))).toBeTruthy();
    expect(statements).toContain("COMMIT");
    expect(mocks.release).toHaveBeenCalledWith();
  });

  it("persists a write-blocking marker before reporting confirmed drift", async () => {
    installAuditResult({ recorded: "320", actual: "321" });

    await expect(checkStorageLedgerIntegrity()).rejects.toMatchObject({
      operationalCode: "storage_ledger_invalid"
    });

    const statements = mocks.query.mock.calls.map(([sql]) => String(sql));
    expect(statements.find((sql) => sql.includes("SET reconcile_required = true"))).toBeTruthy();
    expect(statements).toContain("COMMIT");
    expect(statements).not.toContain("ROLLBACK");
  });

  it.each([
    { ledgerRows: [], recorded: "321", actual: "321" },
    { ledgerRows: [{ recorded_bytes: "3.21e2", reconciled_contract_version: 1, reconcile_required: false }], recorded: "321", actual: "321" },
    { ledgerRows: [{ recorded_bytes: "321", reconciled_contract_version: 2, reconcile_required: false }], recorded: "321", actual: "321" },
    { ledgerRows: [{ recorded_bytes: "321", reconciled_contract_version: 1, reconcile_required: true }], recorded: "321", actual: "321" }
  ])("fails closed for invalid ledger state %#", async ({ ledgerRows, actual }) => {
    installAuditResult({ recorded: "321", actual, ledgerRows });

    await expect(checkStorageLedgerIntegrity()).rejects.toMatchObject({
      operationalCode: "storage_ledger_invalid"
    });
  });

  it("coalesces scheduled audits and keeps the exact scan off the caller's await path", async () => {
    let resolveTotal: ((value: unknown) => void) | undefined;
    installAuditResult({
      recorded: "321",
      actual: "321",
      totalResult: () => new Promise((resolve) => { resolveTotal = resolve; })
    });

    expect(scheduleStorageLedgerIntegrityAudit()).toBe(true);
    expect(scheduleStorageLedgerIntegrityAudit()).toBe(false);
    await vi.waitFor(() => expect(resolveTotal).toBeTypeOf("function"));
    resolveTotal!({ rowCount: 1, rows: [{ actual_bytes: "321" }] });
    await vi.waitFor(() => expect(mocks.release).toHaveBeenCalledOnce());

    expect(scheduleStorageLedgerIntegrityAudit()).toBe(false);
    monotonicNow += 5 * 60_000 + 1;
    expect(scheduleStorageLedgerIntegrityAudit()).toBe(true);
  });

  it("logs semantic drift once while retrying it independently of readiness", async () => {
    installAuditResult({ recorded: "320", actual: "321" });

    expect(scheduleStorageLedgerIntegrityAudit()).toBe(true);
    await vi.waitFor(() => expect(console.error).toHaveBeenCalledOnce());
    const record = JSON.parse(String(vi.mocked(console.error).mock.calls[0]?.[0]));
    expect(record).toMatchObject({
      event: "storage.ledger_drift_detected",
      errorCode: "storage_ledger_invalid",
      reason: "vault_writes_blocked"
    });

    monotonicNow += 60_001;
    expect(scheduleStorageLedgerIntegrityAudit()).toBe(true);
    await vi.waitFor(() => expect(mocks.release).toHaveBeenCalledTimes(2));
    expect(console.error).toHaveBeenCalledOnce();
  });

  it("rolls back transient audit failures without persisting a false drift marker", async () => {
    installAuditResult({ recorded: "321", actual: "321", totalError: new Error("timed out") });

    await expect(checkStorageLedgerIntegrity()).rejects.toThrow("timed out");
    const statements = mocks.query.mock.calls.map(([sql]) => String(sql));
    expect(statements).toContain("ROLLBACK");
    expect(statements.some((sql) => sql.includes("SET reconcile_required = true"))).toBe(false);
  });
});

function installAuditResult({
  recorded,
  actual,
  ledgerRows,
  totalError,
  totalResult
}: {
  recorded: string;
  actual: string;
  ledgerRows?: unknown[];
  totalError?: Error;
  totalResult?: () => Promise<unknown>;
}) {
  mocks.query.mockImplementation(async (sql: string) => {
    if (sql.includes("FROM sync_storage_usage") && sql.includes("recorded_bytes")) {
      const rows = ledgerRows ?? [{
        recorded_bytes: recorded,
        reconciled_contract_version: 1,
        reconcile_required: false
      }];
      return { rowCount: rows.length, rows };
    }
    if (sql.includes("sum(byte_size)")) {
      if (totalError) throw totalError;
      if (totalResult) return totalResult();
      return { rowCount: 1, rows: [{ actual_bytes: actual }] };
    }
    return { rowCount: 1, rows: [] };
  });
}
