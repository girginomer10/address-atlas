import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  poolQuery: vi.fn(),
  connect: vi.fn(),
  end: vi.fn(),
  on: vi.fn(),
  configs: [] as unknown[],
  assertSyncSchemaReady: vi.fn(),
  initializeSyncSchema: vi.fn()
}));

vi.mock("pg", () => ({
  Pool: vi.fn(function Pool(config: unknown) {
    mocks.configs.push(config);
    return {
      query: mocks.poolQuery,
      connect: mocks.connect,
      end: mocks.end,
      on: mocks.on
    };
  })
}));

vi.mock("./postgres-readiness", () => ({
  assertSyncSchemaReady: mocks.assertSyncSchemaReady
}));

vi.mock("./postgres-schema", () => ({
  initializeSyncSchema: mocks.initializeSyncSchema
}));

import {
  bootstrapSyncSchema,
  checkSyncSchemaReadiness,
  closeSyncPoolForTests,
  ensureSyncSchema,
  getSyncPool
} from "./postgres";

describe("Postgres runtime orchestration", () => {
  beforeEach(async () => {
    await closeSyncPoolForTests();
    vi.clearAllMocks();
    mocks.configs.length = 0;
    mocks.poolQuery.mockResolvedValue({ rowCount: 0, rows: [] });
    mocks.assertSyncSchemaReady.mockResolvedValue(undefined);
    mocks.initializeSyncSchema.mockResolvedValue(undefined);
    vi.stubEnv("SYNC_DATABASE_URL", "postgres://user:password@localhost:5432/address_atlas");
    vi.stubEnv("SYNC_SCHEMA_MODE", "validate");
  });

  afterEach(async () => {
    await closeSyncPoolForTests();
    vi.unstubAllEnvs();
  });

  it("configures bounded runtime pool controls and consumes idle errors", () => {
    getSyncPool();
    expect(mocks.configs[0]).toMatchObject({
      application_name: "address-atlas-sync",
      connectionTimeoutMillis: 5_000,
      idleTimeoutMillis: 30_000,
      statement_timeout: 10_000,
      query_timeout: 12_000,
      max: 10
    });
    expect(mocks.on).toHaveBeenCalledWith("error", expect.any(Function));
  });

  it("forwards explicit pool size and idle timeout controls", () => {
    vi.stubEnv("SYNC_DB_POOL_SIZE", "7");
    vi.stubEnv("SYNC_DB_IDLE_TIMEOUT_MS", "45000");
    getSyncPool();
    expect(mocks.configs[0]).toMatchObject({ max: 7, idleTimeoutMillis: 45_000 });
  });

  it("pins the production pool search path independently of the URL", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv(
      "SYNC_DATABASE_URL",
      "postgres://address_atlas_runtime:runtime-secret-value@localhost:5432/address_atlas_sync"
    );
    getSyncPool();
    expect(mocks.configs[0]).toMatchObject({ options: "-csearch_path=public" });
  });

  it("keeps validate-only request startup free of bootstrap connections", async () => {
    await expect(ensureSyncSchema()).resolves.toBeUndefined();
    expect(mocks.assertSyncSchemaReady).toHaveBeenCalledOnce();
    expect(mocks.initializeSyncSchema).not.toHaveBeenCalled();
    expect(mocks.connect).not.toHaveBeenCalled();
  });

  it("runs local bootstrap through the runtime pool only when configured", async () => {
    vi.stubEnv("SYNC_SCHEMA_MODE", "bootstrap");
    await expect(ensureSyncSchema()).resolves.toBeUndefined();
    expect(mocks.initializeSyncSchema).toHaveBeenCalledWith(getSyncPool());
    expect(mocks.assertSyncSchemaReady).not.toHaveBeenCalled();
  });

  it("uses a distinct max-one owner pool for explicit bootstrap", async () => {
    vi.stubEnv(
      "SYNC_SCHEMA_DATABASE_URL",
      "postgres://schema:owner-password@localhost:5432/address_atlas"
    );
    await expect(bootstrapSyncSchema()).resolves.toBeUndefined();
    expect(mocks.configs).toContainEqual(expect.objectContaining({
      application_name: "address-atlas-schema-bootstrap",
      connectionString: "postgres://schema:owner-password@localhost:5432/address_atlas",
      max: 1
    }));
  });

  it("retries readiness after a transient validation failure", async () => {
    mocks.assertSyncSchemaReady
      .mockRejectedValueOnce(new Error("database starting"))
      .mockResolvedValueOnce(undefined);
    await expect(ensureSyncSchema()).rejects.toThrow(/starting/i);
    await expect(ensureSyncSchema()).resolves.toBeUndefined();
    expect(mocks.assertSyncSchemaReady).toHaveBeenCalledTimes(2);
  });

  it("runs explicit readiness independently of the cached startup result", async () => {
    await ensureSyncSchema();
    await checkSyncSchemaReadiness();
    expect(mocks.assertSyncSchemaReady).toHaveBeenCalledTimes(2);
  });
});
