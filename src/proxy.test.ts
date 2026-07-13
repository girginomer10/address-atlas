import { NextRequest } from "next/server";
import { afterEach, describe, expect, it, vi } from "vitest";
import { config, proxy } from "./proxy";

function request(pathname: string) {
  return new NextRequest(`https://sync.addressatlas.test${pathname}`);
}

describe("sync-only proxy gate", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("fails closed unless sync-only mode is explicitly disabled", async () => {
    vi.stubEnv("ADDRESS_ATLAS_SYNC_ONLY", "");

    const response = proxy(request("/api/wallets.json"));

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "Not found." });
  });

  it("passes allowed sync routes through to Next", () => {
    vi.stubEnv("ADDRESS_ATLAS_SYNC_ONLY", "true");

    const response = proxy(request("/vault/latest"));

    expect(response.status).toBe(200);
    expect(response.headers.get("x-middleware-next")).toBe("1");
  });

  it("passes all routes through only when sync-only mode is explicitly disabled", () => {
    vi.stubEnv("ADDRESS_ATLAS_SYNC_ONLY", "false");

    const response = proxy(request("/api/wallets.json"));

    expect(response.status).toBe(200);
    expect(response.headers.get("x-middleware-next")).toBe("1");
  });

  it("matches every pathname so dotted routes cannot bypass the gate", () => {
    expect(config.matcher).toEqual(["/(.*)"]);
  });
});
