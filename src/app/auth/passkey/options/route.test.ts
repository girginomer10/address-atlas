import { NextRequest } from "next/server";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  createPasskeyOptions: vi.fn(),
  rateLimitMany: vi.fn()
}));

vi.mock("@/lib/sync/passkeys", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/sync/passkeys")>()),
  createPasskeyOptions: mocks.createPasskeyOptions
}));

vi.mock("@/lib/sync/rate-limit", () => ({
  clientKey: () => "client",
  rateLimitMany: mocks.rateLimitMany
}));

import { POST } from "./route";

describe("passkey options request ordering", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.rateLimitMany.mockReturnValue(true);
    mocks.createPasskeyOptions.mockResolvedValue({ mode: "authenticate", publicKey: {}, challengeToken: "token" });
  });

  it("rejects invalid content types before consuming rate-limit quota", async () => {
    const response = await POST(new NextRequest("https://sync.example/auth/passkey/options", {
      method: "POST",
      headers: { "content-type": "text/plain" },
      body: JSON.stringify({ mode: "authenticate" })
    }));
    expect(response.status).toBe(415);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(mocks.rateLimitMany).not.toHaveBeenCalled();
  });

  it("applies quota only after a structurally valid JSON request", async () => {
    const response = await POST(new NextRequest("https://sync.example/auth/passkey/options", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ mode: "authenticate" })
    }));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(mocks.rateLimitMany).toHaveBeenCalledOnce();
    expect(mocks.createPasskeyOptions).toHaveBeenCalledWith({ mode: "authenticate" });
  });

  it("marks rate-limit responses as non-cacheable", async () => {
    mocks.rateLimitMany.mockReturnValue(false);
    const response = await POST(new NextRequest("https://sync.example/auth/passkey/options", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ mode: "authenticate" })
    }));

    expect(response.status).toBe(429);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(mocks.createPasskeyOptions).not.toHaveBeenCalled();
  });
});
