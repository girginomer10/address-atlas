import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  query: vi.fn(),
  end: vi.fn(),
  configs: [] as unknown[]
}));

vi.mock("pg", () => ({
  Pool: vi.fn(function Pool(config: unknown) {
    mocks.configs.push(config);
    return { query: mocks.query, end: mocks.end };
  })
}));

import { closeSyncPoolForTests, ensureSyncSchema, getSyncPool } from "./postgres";

describe("Postgres sync readiness", () => {
  beforeEach(async () => {
    await closeSyncPoolForTests();
    vi.clearAllMocks();
    mocks.configs.length = 0;
    vi.stubEnv("SYNC_DATABASE_URL", "postgres://user:password@localhost:5432/address_atlas");
  });

  afterEach(async () => {
    await closeSyncPoolForTests();
    vi.unstubAllEnvs();
  });

  it("configures bounded connect, statement, and query timeouts", () => {
    getSyncPool();
    expect(mocks.configs[0]).toMatchObject({
      connectionTimeoutMillis: 5_000,
      statement_timeout: 10_000,
      query_timeout: 12_000,
      max: 10
    });
  });

  it("retries schema initialization after a transient failure", async () => {
    mocks.query
      .mockRejectedValueOnce(new Error("database starting"))
      .mockResolvedValueOnce({ rows: [] });
    await expect(ensureSyncSchema()).rejects.toThrow(/starting/i);
    await expect(ensureSyncSchema()).resolves.toBeUndefined();
    expect(mocks.query).toHaveBeenCalledTimes(2);
  });
});
