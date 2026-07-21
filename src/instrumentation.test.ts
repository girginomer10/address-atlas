import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  validateSyncRuntimeConfig: vi.fn(),
  ensureSyncSchema: vi.fn(),
  checkSyncSchemaReadiness: vi.fn(),
  scheduleStorageLedgerIntegrityAudit: vi.fn()
}));

vi.mock("@/lib/sync/config", () => ({
  validateSyncRuntimeConfig: mocks.validateSyncRuntimeConfig
}));

vi.mock("@/lib/sync/postgres", () => ({
  ensureSyncSchema: mocks.ensureSyncSchema,
  checkSyncSchemaReadiness: mocks.checkSyncSchemaReadiness
}));

vi.mock("@/lib/sync/storage-ledger-integrity", () => ({
  scheduleStorageLedgerIntegrityAudit: mocks.scheduleStorageLedgerIntegrityAudit
}));

import { register } from "./instrumentation";

describe("production startup instrumentation", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("NEXT_RUNTIME", "nodejs");
    mocks.ensureSyncSchema.mockResolvedValue(undefined);
    mocks.checkSyncSchemaReadiness.mockResolvedValue(undefined);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllEnvs();
  });

  it("schedules the initial ledger audit after schema readiness without waiting for healthz", async () => {
    await register();

    expect(mocks.validateSyncRuntimeConfig).toHaveBeenCalledOnce();
    expect(mocks.ensureSyncSchema).toHaveBeenCalledOnce();
    expect(mocks.checkSyncSchemaReadiness).toHaveBeenCalledOnce();
    expect(mocks.scheduleStorageLedgerIntegrityAudit).toHaveBeenCalledWith(
      expect.objectContaining({ route: "instrumentation.storage-ledger-audit" })
    );
  });

  it("does not touch PostgreSQL after startup configuration validation fails", async () => {
    mocks.validateSyncRuntimeConfig.mockImplementation(() => {
      throw new Error("invalid secret configuration");
    });

    await expect(register()).rejects.toThrow("invalid secret configuration");

    expect(mocks.ensureSyncSchema).not.toHaveBeenCalled();
    expect(mocks.scheduleStorageLedgerIntegrityAudit).not.toHaveBeenCalled();
  });
});
