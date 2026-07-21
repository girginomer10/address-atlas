import { createHash } from "node:crypto";
import { NextRequest } from "next/server";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  clientKey: vi.fn(),
  deleteBearerAccount: vi.fn(),
  rateLimitMany: vi.fn()
}));

vi.mock("@/lib/sync/sessions", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/sync/sessions")>()),
  deleteBearerAccount: mocks.deleteBearerAccount
}));
vi.mock("@/lib/sync/rate-limit", () => ({
  clientKey: mocks.clientKey,
  rateLimitMany: mocks.rateLimitMany
}));

import { DELETE } from "./route";
import { TokenValidationError } from "@/lib/sync/tokens";
import { AccountDeletionConfirmationError } from "@/lib/sync/sessions";

describe("self-service account deletion", () => {
  const rawKeyBytes = Buffer.alloc(32, 7);
  const idempotencyKey = rawKeyBytes.toString("base64url");
  const expectedDigest = createHash("sha256").update(rawKeyBytes).digest();

  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, "warn").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.spyOn(console, "info").mockImplementation(() => undefined);
    mocks.clientKey.mockReturnValue("test-client");
    mocks.rateLimitMany.mockReturnValue(true);
    mocks.deleteBearerAccount.mockImplementation(async (
      _authorization: string | null,
      _digest: Buffer,
      confirmed: boolean
    ) => {
      if (!confirmed) throw new AccountDeletionConfirmationError();
      return { replayed: false };
    });
  });

  it("requires an explicit destructive confirmation before authentication work", async () => {
    const response = await DELETE(new NextRequest("https://sync.example/account", {
      method: "DELETE",
      headers: { authorization: "Bearer token", "idempotency-key": idempotencyKey }
    }));
    expect(response.status).toBe(400);
    expect(mocks.deleteBearerAccount).toHaveBeenCalledWith("Bearer token", expectedDigest, false);
  });

  it("rejects a missing or non-canonical idempotency key before authentication", async () => {
    for (const key of [undefined, "short", `${"A".repeat(42)}B`]) {
      const headers: Record<string, string> = {
        authorization: "Bearer secret-material",
        "x-address-atlas-confirm": "delete-account"
      };
      if (key) headers["idempotency-key"] = key;
      const response = await DELETE(new NextRequest("https://sync.example/account", {
        method: "DELETE",
        headers
      }));
      expect(response.status).toBe(400);
    }
    expect(mocks.deleteBearerAccount).not.toHaveBeenCalled();
  });

  it("rate-limits before parsing attacker-controlled keys or reading deletion receipts", async () => {
    mocks.rateLimitMany.mockReturnValue(false);
    const response = await DELETE(new NextRequest("https://sync.example/account", {
      method: "DELETE",
      headers: {
        "idempotency-key": idempotencyKey,
        "x-forwarded-for": "203.0.113.17"
      }
    }));
    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(await response.json()).toEqual({ error: "Too many requests." });
    expect(mocks.clientKey).toHaveBeenCalledOnce();
    expect(mocks.rateLimitMany).toHaveBeenCalledWith([
      { key: "account-delete:global", limit: 300, windowMs: 60_000 },
      { key: "account-delete:client:test-client", limit: 10, windowMs: 60_000 }
    ]);
    expect(mocks.deleteBearerAccount).not.toHaveBeenCalled();
    expect(JSON.stringify(vi.mocked(console.warn).mock.calls)).toContain(
      "account.deletion_rate_limited"
    );
    expect(JSON.stringify(vi.mocked(console.warn).mock.calls)).not.toContain(idempotencyKey);
  });

  it("deletes the authenticated account without echoing identifiers", async () => {
    const response = await DELETE(new NextRequest("https://sync.example/account", {
      method: "DELETE",
      headers: {
        authorization: "Bearer token",
        "idempotency-key": idempotencyKey,
        "x-address-atlas-confirm": "delete-account",
        "x-request-id": "delete_req-1234"
      }
    }));
    expect(response.status).toBe(200);
    expect(response.headers.get("x-request-id")).toMatch(/^[0-9a-f-]{36}$/);
    expect(response.headers.get("x-request-id")).not.toBe("delete_req-1234");
    expect(await response.json()).toEqual({ ok: true });
    expect(mocks.deleteBearerAccount).toHaveBeenCalledWith("Bearer token", expectedDigest, true);
    expect(JSON.stringify([
      ...vi.mocked(console.info).mock.calls,
      ...vi.mocked(console.warn).mock.calls,
      ...vi.mocked(console.error).mock.calls
    ])).not.toContain(idempotencyKey);
  });

  it("allows a durable replay without the deleted session or confirmation header", async () => {
    mocks.deleteBearerAccount.mockResolvedValueOnce({ replayed: true });
    const response = await DELETE(new NextRequest("https://sync.example/account", {
      method: "DELETE",
      headers: { "idempotency-key": idempotencyKey }
    }));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
    expect(mocks.deleteBearerAccount).toHaveBeenCalledWith(null, expectedDigest, false);
    expect(JSON.stringify(vi.mocked(console.info).mock.calls)).toContain("idempotent_replay");
    expect(JSON.stringify(vi.mocked(console.info).mock.calls)).not.toContain(idempotencyKey);
  });

  it("maps an invalid or revoked token to a generic 401", async () => {
    mocks.deleteBearerAccount.mockRejectedValue(new TokenValidationError());
    const response = await DELETE(new NextRequest("https://sync.example/account", {
      method: "DELETE",
      headers: {
        authorization: "Bearer secret-material",
        "idempotency-key": idempotencyKey,
        "x-address-atlas-confirm": "delete-account"
      }
    }));
    expect(response.status).toBe(401);
    expect(JSON.stringify(await response.json())).not.toContain("secret-material");
  });
});
