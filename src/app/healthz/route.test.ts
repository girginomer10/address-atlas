import { performance } from "node:perf_hooks";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  validateSyncRuntimeConfig: vi.fn(),
  getNativeEndpointConfig: vi.fn(),
  ensureSyncSchema: vi.fn(),
  checkSyncSchemaReadiness: vi.fn()
}));

vi.mock("@/lib/sync/config", () => ({
  validateSyncRuntimeConfig: mocks.validateSyncRuntimeConfig
}));

vi.mock("@/lib/sync/native-config", () => ({
  getNativeEndpointConfig: mocks.getNativeEndpointConfig
}));

vi.mock("@/lib/sync/postgres", () => ({
  ensureSyncSchema: mocks.ensureSyncSchema,
  checkSyncSchemaReadiness: mocks.checkSyncSchemaReadiness
}));

import { GET, resetHealthReadinessForTests } from "./route";

describe("sync readiness", () => {
  let monotonicNow: number;

  beforeEach(() => {
    vi.restoreAllMocks();
    monotonicNow = 1_000;
    vi.spyOn(performance, "now").mockImplementation(() => monotonicNow);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    resetHealthReadinessForTests();
    vi.clearAllMocks();
    mocks.validateSyncRuntimeConfig.mockReturnValue({});
    mocks.getNativeEndpointConfig.mockReturnValue({});
    mocks.ensureSyncSchema.mockResolvedValue(undefined);
    mocks.checkSyncSchemaReadiness.mockResolvedValue(undefined);
  });

  it("reports ready only after schema and database checks succeed", async () => {
    const response = await GET();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, service: "address-atlas-sync" });
    expect(mocks.checkSyncSchemaReadiness).toHaveBeenCalledOnce();
    expect(mocks.ensureSyncSchema).toHaveBeenCalledOnce();
    expect(mocks.validateSyncRuntimeConfig).toHaveBeenCalledOnce();
    expect(mocks.getNativeEndpointConfig).toHaveBeenCalledOnce();
    expect(response.headers.get("cache-control")).toBe("no-store");
  });

  it("coalesces concurrent schema probes", async () => {
    let resolveProbe: (() => void) | undefined;
    mocks.checkSyncSchemaReadiness.mockImplementation(() => new Promise<void>((resolve) => {
      resolveProbe = resolve;
    }));
    const firstPromise = GET();
    const secondPromise = GET();
    await vi.waitFor(() => expect(mocks.checkSyncSchemaReadiness).toHaveBeenCalledOnce());
    resolveProbe!();
    const [first, second] = await Promise.all([firstPromise, secondPromise]);

    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(mocks.checkSyncSchemaReadiness).toHaveBeenCalledOnce();
    expect(first.headers.get("cache-control")).toBe("no-store");
    expect(second.headers.get("cache-control")).toBe("no-store");
  });

  it("caches successful readiness briefly and detects drift after monotonic expiry", async () => {
    const first = await GET();
    mocks.checkSyncSchemaReadiness.mockRejectedValueOnce(new Error("vault_snapshots is missing"));
    const second = await GET();
    monotonicNow += 10_001;
    const third = await GET();

    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(third.status).toBe(503);
    expect(mocks.checkSyncSchemaReadiness).toHaveBeenCalledTimes(2);
    const record = JSON.parse(String(vi.mocked(console.error).mock.calls[0]?.[0]));
    expect(record.errorCode).toBe("schema_contract_invalid");
    expect(JSON.stringify(record)).not.toContain("vault_snapshots is missing");
  });

  it("caches a failed readiness audit for one second before retrying", async () => {
    mocks.checkSyncSchemaReadiness.mockRejectedValueOnce(new Error("database unavailable"));
    const first = await GET();
    mocks.checkSyncSchemaReadiness.mockResolvedValue(undefined);
    const second = await GET();
    monotonicNow += 1_001;
    const third = await GET();

    expect(first.status).toBe(503);
    expect(second.status).toBe(503);
    expect(third.status).toBe(200);
    expect(mocks.checkSyncSchemaReadiness).toHaveBeenCalledTimes(2);
    expect(console.error).toHaveBeenCalledOnce();
  });

  it("caches ensureSyncSchema failures and retries the whole pipeline after expiry", async () => {
    mocks.ensureSyncSchema.mockRejectedValueOnce(
      Object.assign(new Error("password authentication failed for postgres://secret"), {
        code: "28P01"
      })
    );
    const first = await GET();
    mocks.ensureSyncSchema.mockResolvedValue(undefined);
    const second = await GET();
    monotonicNow += 1_001;
    const third = await GET();

    expect(first.status).toBe(503);
    expect(second.status).toBe(503);
    expect(third.status).toBe(200);
    expect(JSON.stringify(await first.json())).not.toContain("secret");
    expect(mocks.ensureSyncSchema).toHaveBeenCalledTimes(2);
    expect(mocks.checkSyncSchemaReadiness).toHaveBeenCalledOnce();
    expect(console.error).toHaveBeenCalledOnce();
    const record = JSON.parse(String(vi.mocked(console.error).mock.calls[0]?.[0]));
    expect(record.errorCode).toBe("database_connection_failed");
    expect(JSON.stringify(record)).not.toContain("secret");
  });

  it.each([
    "ENOTFOUND",
    "EAI_AGAIN",
    "57P02",
    "57P03"
  ])("reports %s as a privacy-safe database connection failure", async (code) => {
    mocks.ensureSyncSchema.mockRejectedValueOnce(
      Object.assign(new Error("postgres://admin:secret@private-db.internal/address_atlas"), {
        code
      })
    );

    const response = await GET();

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({
      ok: false,
      service: "address-atlas-sync"
    });
    const serialized = String(vi.mocked(console.error).mock.calls[0]?.[0]);
    expect(JSON.parse(serialized)).toMatchObject({
      event: "health.not_ready",
      errorCode: "database_connection_failed"
    });
    expect(serialized).not.toContain(code);
    expect(serialized).not.toContain("secret");
    expect(serialized).not.toContain("private-db.internal");
  });

  it("coalesces a failed whole-pipeline probe and logs the transition once", async () => {
    let rejectEnsure: ((error: Error) => void) | undefined;
    mocks.ensureSyncSchema.mockImplementation(() => new Promise<void>((_resolve, reject) => {
      rejectEnsure = reject;
    }));

    const firstPromise = GET();
    const secondPromise = GET();
    await vi.waitFor(() => expect(mocks.ensureSyncSchema).toHaveBeenCalledOnce());
    rejectEnsure!(new Error("database unavailable"));
    const [first, second] = await Promise.all([firstPromise, secondPromise]);

    expect(first.status).toBe(503);
    expect(second.status).toBe(503);
    expect(mocks.checkSyncSchemaReadiness).not.toHaveBeenCalled();
    expect(console.error).toHaveBeenCalledOnce();
  });

  it("fails closed before database readiness when runtime configuration is invalid", async () => {
    mocks.validateSyncRuntimeConfig.mockImplementation(() => {
      throw new Error("SYNC_SESSION_SECRET contains secret details");
    });

    const response = await GET();
    expect(response.status).toBe(503);
    expect(mocks.ensureSyncSchema).not.toHaveBeenCalled();
    expect(JSON.stringify(await response.json())).not.toContain("secret details");
  });
});
