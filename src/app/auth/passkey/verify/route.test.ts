import { NextRequest } from "next/server";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  acquireConcurrencyMany: vi.fn(),
  releaseBodyConcurrency: vi.fn(),
  releaseVerificationConcurrency: vi.fn(),
  verifyPasskey: vi.fn(),
  rateLimitMany: vi.fn()
}));

vi.mock("@/lib/sync/passkeys", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/sync/passkeys")>()),
  verifyPasskey: mocks.verifyPasskey
}));

vi.mock("@/lib/sync/rate-limit", () => ({
  acquireConcurrencyMany: mocks.acquireConcurrencyMany,
  clientKey: () => "client",
  rateLimitMany: mocks.rateLimitMany
}));

import { PasskeyVerificationError } from "@/lib/sync/passkeys";
import {
  RegistrationAdmissionQuotaError,
  RegistrationDisabledError
} from "@/lib/sync/registration";
import { PASSKEY_BODY_DEADLINE_MS } from "../body-concurrency";
import { POST } from "./route";

function request() {
  return new NextRequest("https://sync.example/auth/passkey/verify", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ mode: "authenticate", challengeToken: "token", response: { id: "credential" } })
  });
}

describe("passkey verification error boundary", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.acquireConcurrencyMany.mockImplementation((rules: Array<{ key: string }>) =>
      rules[0]?.key === "auth-body-active:global"
        ? mocks.releaseBodyConcurrency
        : mocks.releaseVerificationConcurrency
    );
    mocks.rateLimitMany.mockReturnValue(true);
    mocks.verifyPasskey.mockResolvedValue({
      verified: true,
      userId: "user-1",
      sessionToken: "session-token"
    });
  });

  it("marks session-token responses as non-cacheable", async () => {
    mocks.verifyPasskey.mockImplementationOnce(async () => {
      expect(mocks.releaseBodyConcurrency).toHaveBeenCalledOnce();
      return { verified: true, userId: "user-1", sessionToken: "session-token" };
    });
    const response = await POST(request());
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(mocks.releaseBodyConcurrency).toHaveBeenCalledOnce();
    expect(mocks.releaseVerificationConcurrency).toHaveBeenCalledOnce();
    expect(PASSKEY_BODY_DEADLINE_MS).toBe(15_000);
  });

  it("rejects at the active-body boundary before reading the request", async () => {
    mocks.acquireConcurrencyMany.mockReturnValueOnce(null);
    const response = await POST(new NextRequest("https://sync.example/auth/passkey/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "not-json"
    }));

    expect(response.status).toBe(429);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ error: "Too many requests." });
    expect(mocks.acquireConcurrencyMany).toHaveBeenCalledWith([
      { key: "auth-body-active:global", limit: 64 },
      { key: "auth-body-active:client:client", limit: 4 }
    ]);
    expect(mocks.rateLimitMany).toHaveBeenCalledOnce();
    expect(mocks.verifyPasskey).not.toHaveBeenCalled();
    expect(mocks.releaseBodyConcurrency).not.toHaveBeenCalled();
  });

  it("normalizes expected authentication failures", async () => {
    mocks.verifyPasskey.mockRejectedValue(new PasskeyVerificationError());
    const response = await POST(request());
    expect(response.status).toBe(400);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ error: "Passkey verification failed." });
  });

  it("does not expose unexpected database/configuration details", async () => {
    mocks.verifyPasskey.mockRejectedValue(new Error("postgres://admin:secret@db failed"));
    const response = await POST(request());
    expect(response.status).toBe(500);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = JSON.stringify(await response.json());
    expect(body).toContain("Passkey verification failed");
    expect(body).not.toContain("secret");
    expect(mocks.releaseBodyConcurrency).toHaveBeenCalledOnce();
    expect(mocks.releaseVerificationConcurrency).toHaveBeenCalledOnce();
  });

  it("marks rate-limit responses as non-cacheable", async () => {
    mocks.rateLimitMany.mockReturnValue(false);
    const response = await POST(request());

    expect(response.status).toBe(429);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(mocks.verifyPasskey).not.toHaveBeenCalled();
  });

  it("rejects before database verification when active verification capacity is full", async () => {
    mocks.acquireConcurrencyMany
      .mockReturnValueOnce(mocks.releaseBodyConcurrency)
      .mockReturnValueOnce(null);

    const response = await POST(request());

    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("1");
    expect(mocks.releaseBodyConcurrency).toHaveBeenCalledOnce();
    expect(mocks.releaseVerificationConcurrency).not.toHaveBeenCalled();
    expect(mocks.verifyPasskey).not.toHaveBeenCalled();
    expect(mocks.acquireConcurrencyMany).toHaveBeenNthCalledWith(2, [
      { key: "auth-verify-active:global", limit: 5 },
      { key: "auth-verify-active:client:client", limit: 2 },
      { key: "auth-verify-active:credential:credential", limit: 1 }
    ]);
  });

  it("holds verification capacity until passkey verification settles", async () => {
    let finishVerification!: (value: {
      verified: boolean;
      userId: string;
      sessionToken: string;
    }) => void;
    mocks.verifyPasskey.mockReturnValueOnce(new Promise((resolve) => {
      finishVerification = resolve;
    }));

    const pending = POST(request());
    await vi.waitFor(() => expect(mocks.verifyPasskey).toHaveBeenCalledOnce());
    expect(mocks.releaseBodyConcurrency).toHaveBeenCalledOnce();
    expect(mocks.releaseVerificationConcurrency).not.toHaveBeenCalled();

    finishVerification({ verified: true, userId: "user-1", sessionToken: "session-token" });
    expect((await pending).status).toBe(200);
    expect(mocks.releaseVerificationConcurrency).toHaveBeenCalledOnce();
  });

  it("stops an aborted request before acquiring verification capacity", async () => {
    const controller = new AbortController();
    mocks.rateLimitMany
      .mockReturnValueOnce(true)
      .mockImplementationOnce(() => {
        controller.abort();
        return true;
      });
    const aborted = new NextRequest("https://sync.example/auth/passkey/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        mode: "authenticate",
        challengeToken: "token",
        response: { id: "credential" }
      }),
      signal: controller.signal
    });

    const response = await POST(aborted);

    expect(response.status).toBe(408);
    expect(mocks.acquireConcurrencyMany).toHaveBeenCalledOnce();
    expect(mocks.releaseBodyConcurrency).toHaveBeenCalledOnce();
    expect(mocks.verifyPasskey).not.toHaveBeenCalled();
  });

  it("meters malformed and shape-invalid JSON requests", async () => {
    const malformed = await POST(new NextRequest("https://sync.example/auth/passkey/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "not-json"
    }));
    const shapeInvalid = await POST(new NextRequest("https://sync.example/auth/passkey/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ mode: "authenticate" })
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
    expect(mocks.verifyPasskey).not.toHaveBeenCalled();
  });

  it("rejects before reading even malformed JSON when the public quota is exhausted", async () => {
    mocks.rateLimitMany.mockReturnValue(false);
    const response = await POST(new NextRequest("https://sync.example/auth/passkey/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "not-json"
    }));

    expect(response.status).toBe(429);
    expect(mocks.rateLimitMany).toHaveBeenCalledOnce();
  });

  it("adds the stricter edge quota for registration verification", async () => {
    const response = await POST(new NextRequest("https://sync.example/auth/passkey/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ mode: "register", challengeToken: "token", response: { id: "credential" } })
    }));

    expect(response.status).toBe(200);
    expect(mocks.rateLimitMany).toHaveBeenNthCalledWith(1, [
      { key: "auth-body:global", limit: 2_400, windowMs: 60_000 },
      { key: "auth-body:client:client", limit: 120, windowMs: 60_000 }
    ]);
    expect(mocks.rateLimitMany).toHaveBeenNthCalledWith(2, [
      { key: "auth-verify:global", limit: 600, windowMs: 60_000 },
      { key: "auth-verify:client:client", limit: 30, windowMs: 60_000 },
      { key: "auth-register-verify:global", limit: 100, windowMs: 3_600_000 },
      { key: "auth-register-verify:client:client", limit: 5, windowMs: 3_600_000 }
    ]);
  });

  it("advertises the full registration retry window when verification edge quota is exhausted", async () => {
    mocks.rateLimitMany
      .mockReturnValueOnce(true)
      .mockReturnValueOnce(false);

    const response = await POST(new NextRequest("https://sync.example/auth/passkey/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        mode: "register",
        challengeToken: "token",
        response: { id: "credential" }
      })
    }));

    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("3600");
    expect(mocks.verifyPasskey).not.toHaveBeenCalled();
    expect(mocks.releaseBodyConcurrency).toHaveBeenCalledOnce();
    expect(mocks.releaseVerificationConcurrency).not.toHaveBeenCalled();
  });

  it("maps durable registration capacity only at verified account creation", async () => {
    mocks.verifyPasskey.mockRejectedValueOnce(new RegistrationAdmissionQuotaError());
    const response = await POST(new NextRequest("https://sync.example/auth/passkey/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        mode: "register",
        challengeToken: "token",
        response: { id: "credential" }
      })
    }));

    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("3600");
    expect(await response.json()).toEqual({
      error: "Registration capacity is temporarily unavailable."
    });
  });

  it("honors a registration kill-switch change after options were issued", async () => {
    mocks.verifyPasskey.mockRejectedValueOnce(new RegistrationDisabledError());
    const response = await POST(new NextRequest("https://sync.example/auth/passkey/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        mode: "register",
        challengeToken: "token",
        response: { id: "credential" }
      })
    }));
    expect(response.status).toBe(403);
    expect((await response.json()).error).toMatch(/closed/i);
  });
});
