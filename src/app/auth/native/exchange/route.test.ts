import { NextRequest } from "next/server";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  acquireConcurrencyMany: vi.fn(),
  exchangeNativeAuthorization: vi.fn(),
  rateLimitMany: vi.fn(),
  releaseBodyConcurrency: vi.fn(),
  releaseExchangeConcurrency: vi.fn()
}));

vi.mock("@/lib/sync/native-authorization", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/sync/native-authorization")>()),
  exchangeNativeAuthorization: mocks.exchangeNativeAuthorization
}));

vi.mock("@/lib/sync/rate-limit", () => ({
  acquireConcurrencyMany: mocks.acquireConcurrencyMany,
  clientKey: () => "client",
  rateLimitMany: mocks.rateLimitMany
}));

import { NativeAuthorizationExchangeError } from "@/lib/sync/native-authorization";
import { POST } from "./route";

const AUTHORIZATION_CODE = "v1.native-authorization.body.signature";
const CODE_VERIFIER = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";

describe("native authorization exchange route", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.spyOn(console, "warn").mockImplementation(() => undefined);
    vi.spyOn(console, "info").mockImplementation(() => undefined);
    mocks.acquireConcurrencyMany.mockImplementation((rules: Array<{ key: string }>) =>
      rules[0]?.key === "auth-body-active:global"
        ? mocks.releaseBodyConcurrency
        : mocks.releaseExchangeConcurrency
    );
    mocks.rateLimitMany.mockReturnValue(true);
    mocks.exchangeNativeAuthorization.mockResolvedValue({
      userId: "11111111-1111-4111-8111-111111111111",
      sessionToken: "v1.session.body.signature"
    });
  });

  it("returns a no-store session response for the exact exchange body", async () => {
    const response = await POST(request());

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({
      userId: "11111111-1111-4111-8111-111111111111",
      sessionToken: "v1.session.body.signature"
    });
    expect(mocks.exchangeNativeAuthorization).toHaveBeenCalledWith({
      authorizationCode: AUTHORIZATION_CODE,
      codeVerifier: CODE_VERIFIER
    });
    expect(mocks.acquireConcurrencyMany).toHaveBeenNthCalledWith(1, [
      { key: "auth-body-active:global", limit: 64 },
      { key: "auth-body-active:client:client", limit: 4 }
    ]);
    expect(mocks.acquireConcurrencyMany).toHaveBeenNthCalledWith(2, [
      { key: "auth-database-active:global", limit: 5 },
      { key: "auth-native-exchange-active:client:client", limit: 2 },
      {
        key: expect.stringMatching(/^auth-native-exchange-active:code:native-code:/),
        limit: 1
      }
    ]);
    expect(mocks.releaseBodyConcurrency).toHaveBeenCalledOnce();
    expect(mocks.releaseExchangeConcurrency).toHaveBeenCalledOnce();
    expect(mocks.rateLimitMany).toHaveBeenCalledWith([
      { key: "native-exchange:global", limit: 600, windowMs: 60_000 },
      { key: "native-exchange:client:client", limit: 30, windowMs: 60_000 }
    ]);
  });

  it("normalizes forged, replayed, expired, and wrong-verifier outcomes", async () => {
    mocks.exchangeNativeAuthorization.mockRejectedValue(new NativeAuthorizationExchangeError());

    const response = await POST(request());

    expect(response.status).toBe(400);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ error: "Native authorization exchange failed." });
  });

  it("rate-limits before reading or exchanging the request", async () => {
    mocks.rateLimitMany.mockReturnValue(false);

    const response = await POST(new NextRequest("https://sync.example/auth/native/exchange", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "not-json"
    }));

    expect(response.status).toBe(429);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("retry-after")).toBe("60");
    expect(mocks.exchangeNativeAuthorization).not.toHaveBeenCalled();
    expect(mocks.acquireConcurrencyMany).not.toHaveBeenCalled();
  });

  it("rejects slow-body saturation before consuming request bytes", async () => {
    mocks.acquireConcurrencyMany.mockReturnValueOnce(null);

    const response = await POST(new NextRequest(
      "https://sync.example/auth/native/exchange",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "not-json"
      }
    ));

    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("1");
    expect(mocks.exchangeNativeAuthorization).not.toHaveBeenCalled();
    expect(mocks.releaseBodyConcurrency).not.toHaveBeenCalled();
  });

  it("rejects database-phase saturation before queueing an exchange", async () => {
    mocks.acquireConcurrencyMany
      .mockReturnValueOnce(mocks.releaseBodyConcurrency)
      .mockReturnValueOnce(null);

    const response = await POST(request());

    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("1");
    expect(mocks.releaseBodyConcurrency).toHaveBeenCalledOnce();
    expect(mocks.releaseExchangeConcurrency).not.toHaveBeenCalled();
    expect(mocks.exchangeNativeAuthorization).not.toHaveBeenCalled();
  });

  it("holds database capacity until authorization consumption settles", async () => {
    let finishExchange!: (value: { userId: string; sessionToken: string }) => void;
    mocks.exchangeNativeAuthorization.mockReturnValueOnce(new Promise((resolve) => {
      finishExchange = resolve;
    }));

    const pending = POST(request());
    await vi.waitFor(() => expect(mocks.exchangeNativeAuthorization).toHaveBeenCalledOnce());
    expect(mocks.releaseBodyConcurrency).toHaveBeenCalledOnce();
    expect(mocks.releaseExchangeConcurrency).not.toHaveBeenCalled();

    finishExchange({
      userId: "11111111-1111-4111-8111-111111111111",
      sessionToken: "v1.session.body.signature"
    });
    expect((await pending).status).toBe(200);
    expect(mocks.releaseExchangeConcurrency).toHaveBeenCalledOnce();
  });

  it("does not consume an authorization code after the request is cancelled", async () => {
    const controller = new AbortController();
    controller.abort();
    const response = await POST(request(controller.signal));

    expect(response.status).toBe(408);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(mocks.exchangeNativeAuthorization).not.toHaveBeenCalled();
    expect(mocks.acquireConcurrencyMany).not.toHaveBeenCalled();
  });

  it("bounds malformed bodies without exposing internal errors", async () => {
    const response = await POST(new NextRequest("https://sync.example/auth/native/exchange", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{".repeat(9_000)
    }));

    expect(response.status).toBe(413);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(mocks.exchangeNativeAuthorization).not.toHaveBeenCalled();
    expect(mocks.releaseBodyConcurrency).toHaveBeenCalledOnce();
    expect(mocks.releaseExchangeConcurrency).not.toHaveBeenCalled();
  });
});

function request(signal?: AbortSignal) {
  return new NextRequest("https://sync.example/auth/native/exchange", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      authorizationCode: AUTHORIZATION_CODE,
      codeVerifier: CODE_VERIFIER
    }),
    signal
  });
}
