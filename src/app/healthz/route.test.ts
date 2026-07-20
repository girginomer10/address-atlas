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
  beforeEach(() => {
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
    expect(mocks.validateSyncRuntimeConfig).toHaveBeenCalledOnce();
    expect(mocks.getNativeEndpointConfig).toHaveBeenCalledOnce();
    expect(response.headers.get("cache-control")).toBe("no-store");
  });

  it("coalesces concurrent schema probes without caching later readiness results", async () => {
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

  it("detects schema drift on the next sequential health check", async () => {
    const first = await GET();
    mocks.checkSyncSchemaReadiness.mockRejectedValueOnce(new Error("vault_snapshots is missing"));
    const second = await GET();

    expect(first.status).toBe(200);
    expect(second.status).toBe(503);
    expect(mocks.checkSyncSchemaReadiness).toHaveBeenCalledTimes(2);
  });

  it("returns a generic 503 without leaking database details", async () => {
    mocks.ensureSyncSchema.mockRejectedValue(new Error("password authentication failed for postgres://secret"));
    const response = await GET();
    expect(response.status).toBe(503);
    expect(JSON.stringify(await response.json())).not.toContain("secret");
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
