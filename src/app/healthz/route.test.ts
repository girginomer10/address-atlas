import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  ensureSyncSchema: vi.fn(),
  query: vi.fn()
}));

vi.mock("@/lib/sync/postgres", () => ({
  ensureSyncSchema: mocks.ensureSyncSchema,
  getSyncPool: () => ({ query: mocks.query })
}));

import { GET } from "./route";

describe("sync readiness", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.ensureSyncSchema.mockResolvedValue(undefined);
    mocks.query.mockResolvedValue({ rows: [{ ready: 1 }] });
  });

  it("reports ready only after schema and database checks succeed", async () => {
    const response = await GET();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, service: "address-atlas-sync" });
    expect(mocks.query).toHaveBeenCalledWith("SELECT 1 AS ready");
    expect(response.headers.get("cache-control")).toBe("no-store");
  });

  it("returns a generic 503 without leaking database details", async () => {
    mocks.ensureSyncSchema.mockRejectedValue(new Error("password authentication failed for postgres://secret"));
    const response = await GET();
    expect(response.status).toBe(503);
    expect(JSON.stringify(await response.json())).not.toContain("secret");
  });
});
