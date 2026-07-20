import { NextRequest } from "next/server";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  createPasskeyOptions: vi.fn()
}));

vi.mock("@/lib/sync/passkeys", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/sync/passkeys")>()),
  createPasskeyOptions: mocks.createPasskeyOptions
}));

import { resetRateLimitsForTests } from "@/lib/sync/rate-limit";
import { POST } from "./route";

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
});

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
