import { NextRequest } from "next/server";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  createPasskeyOptions: vi.fn(),
  verifyPasskey: vi.fn()
}));

vi.mock("@/lib/sync/passkeys", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/sync/passkeys")>()),
  createPasskeyOptions: mocks.createPasskeyOptions,
  verifyPasskey: mocks.verifyPasskey
}));

import { resetRateLimitsForTests } from "@/lib/sync/rate-limit";
import { POST } from "./route";
import { POST as verifyPOST } from "../verify/route";

describe("public passkey body throttling", () => {
  beforeEach(() => {
    resetRateLimitsForTests();
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-13T12:00:00Z"));
    mocks.createPasskeyOptions.mockResolvedValue({
      mode: "authenticate",
      publicKey: {},
      challengeToken: "token"
    });
    mocks.verifyPasskey.mockResolvedValue({
      verified: true,
      userId: "user-1",
      sessionToken: "session-token"
    });
  });

  afterEach(() => {
    resetRateLimitsForTests();
    vi.useRealTimers();
    vi.clearAllMocks();
  });

  it("bounds malformed bodies before parsing them", async () => {
    for (let index = 0; index < 120; index += 1) {
      expect((await POST(malformedRequest())).status).toBe(400);
    }

    expect((await POST(malformedRequest())).status).toBe(429);
    expect(mocks.createPasskeyOptions).not.toHaveBeenCalled();
  });

  it("does not charge malformed bodies to the stricter valid-auth quota", async () => {
    for (let index = 0; index < 40; index += 1) {
      expect((await POST(malformedRequest())).status).toBe(400);
    }
    for (let index = 0; index < 30; index += 1) {
      expect((await POST(validRequest())).status).toBe(200);
    }

    expect((await POST(validRequest())).status).toBe(429);
    expect(mocks.createPasskeyOptions).toHaveBeenCalledTimes(30);
  });

  it("shares and releases the per-client active-body ceiling across both public routes", async () => {
    vi.useRealTimers();
    const pending = [
      heldRequest("options", '{"mode":"authenticate"'),
      heldRequest("verify", '{"mode":"authenticate","challengeToken":"token","response":{"id":"credential-1"}'),
      heldRequest("options", '{"mode":"authenticate"'),
      heldRequest("verify", '{"mode":"authenticate","challengeToken":"token","response":{"id":"credential-2"}')
    ];
    const inFlight = pending.map(({ request }, index) => index % 2 === 0
      ? POST(request)
      : verifyPOST(request));

    const rejected = await POST(validRequest());
    expect(rejected.status).toBe(429);
    expect(await rejected.json()).toEqual({ error: "Too many requests." });

    for (const body of pending) body.close();
    const completed = await Promise.all(inFlight);
    expect(completed.map((response) => response.status)).toEqual([200, 200, 200, 200]);

    expect((await POST(validRequest())).status).toBe(200);
  });
});

function heldRequest(route: "options" | "verify", prefix: string) {
  let bodyController: ReadableStreamDefaultController<Uint8Array> | undefined;
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      bodyController = controller;
      controller.enqueue(new TextEncoder().encode(prefix));
    }
  });
  const streamedRequest = new Request(`https://sync.example/auth/passkey/${route}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-forwarded-for": "203.0.113.10"
    },
    body,
    duplex: "half"
  } as RequestInit & { duplex: "half" });
  const request = new NextRequest(streamedRequest);
  return {
    request,
    close() {
      bodyController?.enqueue(new TextEncoder().encode("}"));
      bodyController?.close();
    }
  };
}

function malformedRequest() {
  return new NextRequest("https://sync.example/auth/passkey/options", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-forwarded-for": "203.0.113.10"
    },
    body: "not-json"
  });
}

function validRequest() {
  return new NextRequest("https://sync.example/auth/passkey/options", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-forwarded-for": "203.0.113.10"
    },
    body: JSON.stringify({ mode: "authenticate" })
  });
}
