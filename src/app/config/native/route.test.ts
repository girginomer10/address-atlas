import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  getNativeEndpointConfig: vi.fn()
}));

vi.mock("@/lib/sync/native-config", () => ({
  getNativeEndpointConfig: mocks.getNativeEndpointConfig
}));

import { GET } from "./route";

describe("native configuration route", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.getNativeEndpointConfig.mockReturnValue({
      configVersion: 1,
      refreshAfterSeconds: 300,
      chains: {}
    });
  });

  it("returns a cacheable native configuration", async () => {
    const response = await GET();

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("public, max-age=300");
    expect(await response.json()).toEqual({
      configVersion: 1,
      refreshAfterSeconds: 300,
      chains: {}
    });
  });

  it("returns a generic non-cacheable 503 for invalid server configuration", async () => {
    mocks.getNativeEndpointConfig.mockImplementation(() => {
      throw new Error("NATIVE_ENDPOINT_CONFIG contains secret details");
    });

    const response = await GET();
    const body = JSON.stringify(await response.json());

    expect(response.status).toBe(503);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(body).toContain("Native configuration unavailable");
    expect(body).not.toContain("secret details");
  });
});
