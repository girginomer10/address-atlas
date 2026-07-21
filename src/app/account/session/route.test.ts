import { NextRequest } from "next/server";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  clientKey: vi.fn(),
  rateLimitMany: vi.fn(),
  revokeBearerSession: vi.fn()
}));

vi.mock("@/lib/sync/sessions", () => ({
  revokeBearerSession: mocks.revokeBearerSession
}));
vi.mock("@/lib/sync/rate-limit", () => ({
  clientKey: mocks.clientKey,
  rateLimitMany: mocks.rateLimitMany
}));

import { DELETE } from "./route";
import { AuthenticationDatabaseCapacityError } from "@/lib/sync/auth-database-concurrency";
import { TokenValidationError } from "@/lib/sync/tokens";

describe("targeted session revocation", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, "warn").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    mocks.clientKey.mockReturnValue("test-client");
    mocks.rateLimitMany.mockReturnValue(true);
    mocks.revokeBearerSession.mockResolvedValue(undefined);
  });

  it("revokes the authenticated session and returns a correlation id", async () => {
    const response = await DELETE(new NextRequest("https://sync.example/account/session", {
      method: "DELETE",
      headers: { authorization: "Bearer token", "x-request-id": "session_req-1234" }
    }));
    expect(response.status).toBe(200);
    expect(response.headers.get("x-request-id")).toMatch(/^[0-9a-f-]{36}$/);
    expect(response.headers.get("x-request-id")).not.toBe("session_req-1234");
    expect(await response.json()).toEqual({ ok: true });
    expect(mocks.revokeBearerSession).toHaveBeenCalledWith("Bearer token", "test-client");
    expect(mocks.rateLimitMany).toHaveBeenCalledWith([
      { key: "session-revoke:global", limit: 300, windowMs: 60_000 },
      { key: "session-revoke:client:test-client", limit: 10, windowMs: 60_000 }
    ]);
  });

  it("rate-limits before revoked-token database work", async () => {
    mocks.rateLimitMany.mockReturnValue(false);
    const response = await DELETE(new NextRequest("https://sync.example/account/session", {
      method: "DELETE",
      headers: { authorization: "Bearer revoked-token", "x-forwarded-for": "203.0.113.17" }
    }));

    expect(response.status).toBe(429);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("retry-after")).toBe("60");
    expect(await response.json()).toEqual({ error: "Too many requests." });
    expect(mocks.clientKey).toHaveBeenCalledOnce();
    expect(mocks.revokeBearerSession).not.toHaveBeenCalled();
  });

  it("rejects an already-revoked session generically", async () => {
    mocks.revokeBearerSession.mockRejectedValue(new TokenValidationError());
    const response = await DELETE(new NextRequest("https://sync.example/account/session", {
      method: "DELETE",
      headers: { authorization: "Bearer token" }
    }));
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "Authentication required." });
  });

  it("rejects database-saturated revocations without queueing", async () => {
    mocks.revokeBearerSession.mockRejectedValue(new AuthenticationDatabaseCapacityError());
    const response = await DELETE(new NextRequest("https://sync.example/account/session", {
      method: "DELETE",
      headers: { authorization: "Bearer token" }
    }));

    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("1");
    expect(await response.json()).toEqual({ error: "Too many requests." });
  });
});
