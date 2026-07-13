import { NextRequest } from "next/server";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  verifyPasskey: vi.fn(),
  rateLimitMany: vi.fn()
}));

vi.mock("@/lib/sync/passkeys", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/sync/passkeys")>()),
  verifyPasskey: mocks.verifyPasskey
}));

vi.mock("@/lib/sync/rate-limit", () => ({
  clientKey: () => "client",
  rateLimitMany: mocks.rateLimitMany
}));

import { PasskeyVerificationError } from "@/lib/sync/passkeys";
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
    mocks.rateLimitMany.mockReturnValue(true);
    mocks.verifyPasskey.mockResolvedValue({
      verified: true,
      userId: "user-1",
      sessionToken: "session-token"
    });
  });

  it("marks session-token responses as non-cacheable", async () => {
    const response = await POST(request());
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
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
  });

  it("marks rate-limit responses as non-cacheable", async () => {
    mocks.rateLimitMany.mockReturnValue(false);
    const response = await POST(request());

    expect(response.status).toBe(429);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(mocks.verifyPasskey).not.toHaveBeenCalled();
  });
});
