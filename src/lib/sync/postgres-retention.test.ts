import { performance } from "node:perf_hooks";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  resetUsageRetentionState,
  scheduleOldVaultWriteUsagePrune
} from "./postgres-retention";

describe("usage retention maintenance", () => {
  let monotonicNow: number;
  const query = vi.fn();
  const pool = { query };

  beforeEach(() => {
    vi.restoreAllMocks();
    vi.clearAllMocks();
    monotonicNow = 1_000;
    vi.spyOn(performance, "now").mockImplementation(() => monotonicNow);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.spyOn(console, "info").mockImplementation(() => undefined);
    resetUsageRetentionState();
    query.mockResolvedValue({ rowCount: 0, rows: [] });
  });

  it("prunes both bounded retention tables and waits an hour after success", async () => {
    scheduleOldVaultWriteUsagePrune(() => pool as never);
    await vi.waitFor(() => expect(query).toHaveBeenCalledTimes(2));

    expect(String(query.mock.calls[0]?.[0])).toContain("DELETE FROM vault_write_usage");
    expect(query.mock.calls[0]?.[1]).toEqual([35, 10_000]);
    expect(String(query.mock.calls[1]?.[0])).toContain("DELETE FROM vault_global_ingress_usage");
    scheduleOldVaultWriteUsagePrune(() => pool as never);
    expect(query).toHaveBeenCalledTimes(2);
    monotonicNow += 60 * 60 * 1_000 + 1;
    scheduleOldVaultWriteUsagePrune(() => pool as never);
    await vi.waitFor(() => expect(query).toHaveBeenCalledTimes(4));
  });

  it("emits a privacy-safe error and retries with bounded exponential backoff", async () => {
    query.mockRejectedValue(new Error("postgres://admin:secret@private-db.internal failed"));

    scheduleOldVaultWriteUsagePrune(() => pool as never);
    await vi.waitFor(() => expect(console.error).toHaveBeenCalledTimes(1));
    const firstRecord = String(vi.mocked(console.error).mock.calls[0]?.[0]);
    expect(JSON.parse(firstRecord)).toMatchObject({
      event: "storage.usage_retention_failed",
      reason: "usage_retention_prune_failed",
      errorCode: "database_query_failed"
    });
    expect(firstRecord).not.toContain("secret");
    expect(firstRecord).not.toContain("private-db.internal");

    monotonicNow += 59_999;
    scheduleOldVaultWriteUsagePrune(() => pool as never);
    expect(query).toHaveBeenCalledTimes(1);
    monotonicNow += 2;
    scheduleOldVaultWriteUsagePrune(() => pool as never);
    await vi.waitFor(() => expect(console.error).toHaveBeenCalledTimes(2));

    monotonicNow += 119_999;
    scheduleOldVaultWriteUsagePrune(() => pool as never);
    expect(query).toHaveBeenCalledTimes(2);
    monotonicNow += 2;
    scheduleOldVaultWriteUsagePrune(() => pool as never);
    await vi.waitFor(() => expect(console.error).toHaveBeenCalledTimes(3));
  });

  it("emits one privacy-safe recovery edge after failures and not on steady success", async () => {
    query.mockRejectedValueOnce(new Error("postgres://admin:secret@private-db.internal failed"));

    scheduleOldVaultWriteUsagePrune(() => pool as never);
    await vi.waitFor(() => expect(console.error).toHaveBeenCalledOnce());

    monotonicNow += 60_001;
    scheduleOldVaultWriteUsagePrune(() => pool as never);
    await vi.waitFor(() => expect(console.info).toHaveBeenCalledOnce());
    const restoredRecord = String(vi.mocked(console.info).mock.calls[0]?.[0]);
    expect(JSON.parse(restoredRecord)).toMatchObject({
      event: "storage.usage_retention_restored",
      reason: "usage_retention_prune_restored",
      severity: "info"
    });
    expect(restoredRecord).not.toContain("secret");
    expect(restoredRecord).not.toContain("private-db.internal");

    monotonicNow += 60 * 60 * 1_000 + 1;
    scheduleOldVaultWriteUsagePrune(() => pool as never);
    await vi.waitFor(() => expect(query).toHaveBeenCalledTimes(5));
    expect(console.info).toHaveBeenCalledOnce();
  });
});
