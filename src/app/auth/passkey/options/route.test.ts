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
import {
  RegistrationAdmissionQuotaError,
  RegistrationDisabledError
} from "@/lib/sync/registration";

describe("passkey options request ordering", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.rateLimitMany.mockReturnValue(true);
    mocks.createPasskeyOptions.mockResolvedValue({ mode: "authenticate", publicKey: {}, challengeToken: "token" });
  });

  it("meters invalid content types before rejecting their bodies", async () => {
    const response = await POST(new NextRequest("https://sync.example/auth/passkey/options", {
      method: "POST",
      headers: { "content-type": "text/plain" },
      body: JSON.stringify({ mode: "authenticate" })
    }));
    expect(response.status).toBe(415);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(mocks.rateLimitMany).toHaveBeenCalledWith([
      { key: "auth-body:global", limit: 2_400, windowMs: 60_000 },
      { key: "auth-body:client:client", limit: 120, windowMs: 60_000 }
    ]);
  });

  it("applies the public quota before processing a structurally valid JSON request", async () => {
    const response = await POST(new NextRequest("https://sync.example/auth/passkey/options", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ mode: "authenticate" })
    }));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(mocks.rateLimitMany).toHaveBeenCalledTimes(2);
    expect(mocks.createPasskeyOptions).toHaveBeenCalledWith({ mode: "authenticate" });
  });

  it("meters malformed and shape-invalid JSON requests", async () => {
    const malformed = await POST(new NextRequest("https://sync.example/auth/passkey/options", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "not-json"
    }));
    const shapeInvalid = await POST(new NextRequest("https://sync.example/auth/passkey/options", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ mode: "unsupported" })
    }));

    expect(malformed.status).toBe(400);
    expect(shapeInvalid.status).toBe(400);
    expect(mocks.rateLimitMany).toHaveBeenCalledTimes(2);
    expect(mocks.rateLimitMany).toHaveBeenNthCalledWith(1, [
      { key: "auth-body:global", limit: 2_400, windowMs: 60_000 },
      { key: "auth-body:client:client", limit: 120, windowMs: 60_000 }
    ]);
    expect(mocks.rateLimitMany).toHaveBeenNthCalledWith(2, [
      { key: "auth-body:global", limit: 2_400, windowMs: 60_000 },
      { key: "auth-body:client:client", limit: 120, windowMs: 60_000 }
    ]);
    expect(mocks.createPasskeyOptions).not.toHaveBeenCalled();
  });

  it("rejects before reading even malformed JSON when the public quota is exhausted", async () => {
    mocks.rateLimitMany.mockReturnValue(false);
    const response = await POST(new NextRequest("https://sync.example/auth/passkey/options", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "not-json"
    }));

    expect(response.status).toBe(429);
    expect(mocks.rateLimitMany).toHaveBeenCalledOnce();
  });

  it("applies the stricter registration quota after the public quota", async () => {
    const response = await POST(new NextRequest("https://sync.example/auth/passkey/options", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ mode: "register", accountName: "Atlas" })
    }));

    expect(response.status).toBe(200);
    expect(mocks.rateLimitMany).toHaveBeenNthCalledWith(1, [
      { key: "auth-body:global", limit: 2_400, windowMs: 60_000 },
      { key: "auth-body:client:client", limit: 120, windowMs: 60_000 }
    ]);
    expect(mocks.rateLimitMany).toHaveBeenNthCalledWith(2, [
      { key: "auth-options:global", limit: 600, windowMs: 60_000 },
      { key: "auth-options:client:client", limit: 30, windowMs: 60_000 },
      { key: "auth-register-options:global", limit: 100, windowMs: 3_600_000 },
      { key: "auth-register-options:client:client", limit: 5, windowMs: 3_600_000 }
    ]);
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

  it("maps durable production registration controls without exposing internals", async () => {
    mocks.createPasskeyOptions.mockRejectedValueOnce(new RegistrationDisabledError());
    const closed = await POST(new NextRequest("https://sync.example/auth/passkey/options", {
      method: "POST",
      headers: { "content-type": "application/json", "x-request-id": "register_req-1234" },
      body: JSON.stringify({ mode: "register" })
    }));
    expect(closed.status).toBe(403);
    expect(closed.headers.get("x-request-id")).toBe("register_req-1234");
    expect((await closed.json()).error).toMatch(/closed/i);

    mocks.createPasskeyOptions.mockRejectedValueOnce(new RegistrationAdmissionQuotaError());
    const full = await POST(new NextRequest("https://sync.example/auth/passkey/options", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ mode: "register" })
    }));
    expect(full.status).toBe(429);
    expect(full.headers.get("retry-after")).toBe("3600");
  });
});
