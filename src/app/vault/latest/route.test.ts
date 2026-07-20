import { createHash } from "node:crypto";
import { NextRequest } from "next/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { base64urlEncode } from "@/lib/sync/base64url";
import {
  canonicalEnvelopeBytes,
  computeSnapshotChecksum,
  type EncryptedVaultEnvelope,
  type RemoteVaultSnapshot
} from "@/lib/sync/envelope";
import { resetRateLimitsForTests } from "@/lib/sync/rate-limit";

const mocks = vi.hoisted(() => ({
  acquireConcurrencyMany: vi.fn(),
  authenticateBearerSession: vi.fn(),
  chargeVaultIngress: vi.fn(),
  releaseConcurrency: vi.fn(),
  saveVaultSnapshot: vi.fn(),
  dbQuery: vi.fn(),
  rateLimitMany: vi.fn()
}));

vi.mock("@/lib/sync/postgres", () => ({
  ensureSyncSchema: vi.fn(async () => undefined),
  getSyncPool: () => ({ query: mocks.dbQuery })
}));

vi.mock("@/lib/sync/sessions", () => ({
  authenticateBearerSession: mocks.authenticateBearerSession
}));

vi.mock("@/lib/sync/rate-limit", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/sync/rate-limit")>()),
  acquireConcurrencyMany: mocks.acquireConcurrencyMany,
  clientKey: () => "client",
  rateLimitMany: mocks.rateLimitMany
}));

vi.mock("@/lib/sync/vault-storage", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/sync/vault-storage")>()),
  chargeVaultIngress: mocks.chargeVaultIngress,
  saveVaultSnapshot: mocks.saveVaultSnapshot
}));

import { GET, PUT } from "./route";
import { TokenValidationError } from "@/lib/sync/tokens";
import { VaultConflictError, VaultQuotaError } from "@/lib/sync/vault-storage";

function snapshot(schemaVersion: 1 | 2 = 2): RemoteVaultSnapshot {
  const nonce = Buffer.alloc(12, 3);
  const ciphertext = Buffer.alloc(48, 4);
  const keyId = schemaVersion === 2 ? "sync-v2" : "sync-v1";
  const innerChecksum = createHash("sha256")
    .update(Buffer.from(`schema:${schemaVersion}|crypto:${schemaVersion}|key:${keyId}|`))
    .update(nonce)
    .update(ciphertext)
    .digest("hex");
  const envelope: EncryptedVaultEnvelope = {
    schemaVersion,
    cryptoVersion: schemaVersion,
    keyId,
    nonce: base64urlEncode(nonce),
    ciphertext: base64urlEncode(ciphertext),
    checksum: innerChecksum,
    createdAt: "2026-07-12T12:00:00Z"
  };
  const canonical = canonicalEnvelopeBytes(envelope);
  return {
    version: 2,
    envelope,
    byteSize: canonical.byteLength,
    checksum: computeSnapshotChecksum(2, envelope, canonical)
  };
}

function request(body: unknown) {
  return new NextRequest("http://localhost/vault/latest", {
    method: "PUT",
    headers: {
      authorization: "Bearer token",
      "content-type": "application/json"
    },
    body: JSON.stringify(body)
  });
}

describe("vault latest route", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    resetRateLimitsForTests();
    mocks.acquireConcurrencyMany.mockReturnValue(mocks.releaseConcurrency);
    mocks.chargeVaultIngress.mockResolvedValue(undefined);
    mocks.saveVaultSnapshot.mockResolvedValue({ idempotent: false });
    mocks.rateLimitMany.mockReturnValue(true);
    mocks.authenticateBearerSession.mockResolvedValue({
      userId: "11111111-1111-4111-8111-111111111111",
      sessionId: "22222222-2222-4222-8222-222222222222",
      expiresAt: Date.now() + 60_000
    });
    mocks.dbQuery.mockResolvedValue({ rows: [] });
  });

  it("rejects GET before database authentication when preflight capacity is exhausted", async () => {
    mocks.rateLimitMany.mockReturnValue(false);

    const response = await GET(new NextRequest("http://localhost/vault/latest", {
      headers: { authorization: "Bearer revoked-token" }
    }));

    expect(response.status).toBe(429);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("retry-after")).toBe("60");
    expect(mocks.rateLimitMany).toHaveBeenCalledWith([
      { key: "vault-get-preflight:global", limit: 3_000, windowMs: 60_000 },
      { key: "vault-get-preflight:client:client", limit: 120, windowMs: 60_000 }
    ]);
    expect(mocks.authenticateBearerSession).not.toHaveBeenCalled();
    expect(mocks.dbQuery).not.toHaveBeenCalled();
  });

  it("rejects PUT before authentication, body reads, or durable ingress work", async () => {
    mocks.rateLimitMany.mockReturnValue(false);

    const response = await PUT(request(snapshot()));

    expect(response.status).toBe(429);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("retry-after")).toBe("60");
    expect(mocks.rateLimitMany).toHaveBeenCalledWith([
      { key: "vault-put-preflight:global", limit: 300, windowMs: 60_000 },
      { key: "vault-put-preflight:client:client", limit: 10, windowMs: 60_000 }
    ]);
    expect(mocks.authenticateBearerSession).not.toHaveBeenCalled();
    expect(mocks.chargeVaultIngress).not.toHaveBeenCalled();
    expect(mocks.acquireConcurrencyMany).not.toHaveBeenCalled();
  });

  it("rejects an authenticated upload before reading its body when active capacity is full", async () => {
    mocks.acquireConcurrencyMany.mockReturnValue(null);

    const response = await PUT(request(snapshot()));

    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(mocks.acquireConcurrencyMany).toHaveBeenCalledWith([
      { key: "vault-put-active:global", limit: 8 },
      { key: "vault-put-active:client:client", limit: 2 },
      {
        key: "vault-put-active:account:11111111-1111-4111-8111-111111111111",
        limit: 2
      }
    ]);
    expect(mocks.chargeVaultIngress).not.toHaveBeenCalled();
    expect(mocks.saveVaultSnapshot).not.toHaveBeenCalled();
  });

  it("releases active upload capacity after a durable quota failure", async () => {
    mocks.chargeVaultIngress.mockRejectedValue(new VaultQuotaError());

    const response = await PUT(request(snapshot()));

    expect(response.status).toBe(429);
    expect(mocks.releaseConcurrency).toHaveBeenCalledOnce();
  });

  it("returns 409 when storage detects a version conflict", async () => {
    mocks.saveVaultSnapshot.mockRejectedValue(new VaultConflictError());
    const response = await PUT(request(snapshot()));
    expect(response.status).toBe(409);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect((await response.json()).error).toMatch(/newer/i);
  });

  it("rejects legacy v1 uploads while leaving them readable for migration", async () => {
    const response = await PUT(request(snapshot(1)));
    expect(response.status).toBe(400);
    expect((await response.json()).error).toMatch(/version 2/i);
    expect(mocks.chargeVaultIngress).toHaveBeenCalledOnce();
    expect(mocks.saveVaultSnapshot).not.toHaveBeenCalled();
  });

  it.each([
    ["application/json", "not-json", 400],
    ["text/plain", JSON.stringify(snapshot()), 415]
  ])("charges %s request bytes before a body-level %s rejection", async (contentType, body, status) => {
    const response = await PUT(new NextRequest("http://localhost/vault/latest", {
      method: "PUT",
      headers: { authorization: "Bearer token", "content-type": contentType },
      body
    }));

    expect(response.status).toBe(status);
    expect(mocks.chargeVaultIngress).toHaveBeenCalledWith(
      "11111111-1111-4111-8111-111111111111",
      Buffer.byteLength(body)
    );
    expect(mocks.saveVaultSnapshot).not.toHaveBeenCalled();
  });

  it("charges a bounded full request before rejecting an oversized declaration", async () => {
    const response = await PUT(new NextRequest("http://localhost/vault/latest", {
      method: "PUT",
      headers: {
        authorization: "Bearer token",
        "content-type": "application/json",
        "content-length": "9000000"
      },
      body: "{}"
    }));

    expect(response.status).toBe(413);
    expect(mocks.chargeVaultIngress).toHaveBeenCalledWith(
      "11111111-1111-4111-8111-111111111111",
      8_100_000
    );
  });

  it("returns durable quota exhaustion before replay or conflict semantics", async () => {
    mocks.chargeVaultIngress.mockRejectedValue(new VaultQuotaError());
    mocks.saveVaultSnapshot.mockRejectedValue(new VaultConflictError());
    const response = await PUT(request(snapshot()));
    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("3600");
    expect(mocks.saveVaultSnapshot).not.toHaveBeenCalled();
  });

  it("reports exact idempotent replays without rewriting storage", async () => {
    mocks.saveVaultSnapshot.mockResolvedValue({ idempotent: true });
    const response = await PUT(request(snapshot()));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, idempotent: true });
    expect(mocks.saveVaultSnapshot).toHaveBeenCalledWith(
      "11111111-1111-4111-8111-111111111111",
      expect.objectContaining({ version: 2 })
    );
  });

  it("passes the actual padded request byte count to replay quota accounting", async () => {
    mocks.saveVaultSnapshot.mockResolvedValue({ idempotent: true });
    const body = `${JSON.stringify(snapshot())}${" ".repeat(2_048)}`;
    const response = await PUT(new NextRequest("http://localhost/vault/latest", {
      method: "PUT",
      headers: {
        authorization: "Bearer token",
        "content-type": "application/json"
      },
      body
    }));

    expect(response.status).toBe(200);
    expect(mocks.chargeVaultIngress).toHaveBeenCalledWith(
      "11111111-1111-4111-8111-111111111111",
      Buffer.byteLength(body)
    );
  });

  it("returns the stored snapshot with the exact response field mapping", async () => {
    const { envelope } = snapshot();
    mocks.dbQuery.mockResolvedValue({
      rows: [{
        version: 7,
        envelope,
        byte_size: 4_321,
        checksum: "c".repeat(64),
        updated_at: new Date("2026-07-13T08:30:00.123Z")
      }]
    });

    const response = await GET(new NextRequest("http://localhost/vault/latest", {
      headers: { authorization: "Bearer token" }
    }));

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({
      version: 7,
      envelope,
      byteSize: 4_321,
      checksum: "c".repeat(64),
      updatedAt: "2026-07-13T08:30:00.123Z"
    });
    expect(mocks.dbQuery).toHaveBeenCalledWith(expect.stringContaining("LEFT JOIN vault_snapshots"), [
      "11111111-1111-4111-8111-111111111111"
    ]);
  });

  it("returns 404 when the authenticated account exists without a snapshot", async () => {
    mocks.dbQuery.mockResolvedValue({
      rows: [{ version: null, envelope: null, byte_size: null, checksum: null, updated_at: null }]
    });

    const response = await GET(new NextRequest("http://localhost/vault/latest", {
      headers: { authorization: "Bearer token" }
    }));

    expect(response.status).toBe(404);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ error: "No vault snapshot." });
    expect(mocks.dbQuery).toHaveBeenCalledWith(expect.stringContaining("LEFT JOIN vault_snapshots"), [
      "11111111-1111-4111-8111-111111111111"
    ]);
  });

  it("returns 401 when a valid session refers to a deleted account", async () => {
    mocks.authenticateBearerSession.mockRejectedValue(new TokenValidationError());

    const response = await GET(new NextRequest("http://localhost/vault/latest", {
      headers: { authorization: "Bearer token" }
    }));

    expect(response.status).toBe(401);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ error: "Authentication required." });
  });

  it("durably charges an upload before returning an in-memory rate limit", async () => {
    mocks.rateLimitMany.mockReturnValueOnce(true).mockReturnValueOnce(false);

    const response = await PUT(request(snapshot()));

    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ error: "Too many requests." });
    expect(mocks.chargeVaultIngress).toHaveBeenCalledWith(
      "11111111-1111-4111-8111-111111111111",
      expect.any(Number)
    );
    expect(mocks.saveVaultSnapshot).not.toHaveBeenCalled();
    expect(mocks.rateLimitMany).toHaveBeenLastCalledWith([
      { key: "vault-put:global", limit: 300, windowMs: 60_000 },
      { key: "vault-put:account:11111111-1111-4111-8111-111111111111", limit: 10, windowMs: 60_000 }
    ]);
  });

  it("returns 429 before querying storage when its read quota is exhausted", async () => {
    mocks.rateLimitMany.mockReturnValueOnce(true).mockReturnValueOnce(false);

    const response = await GET(new NextRequest("http://localhost/vault/latest", {
      headers: { authorization: "Bearer token" }
    }));

    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ error: "Too many requests." });
    expect(mocks.dbQuery).not.toHaveBeenCalled();
    expect(mocks.rateLimitMany).toHaveBeenLastCalledWith([
      { key: "vault-get:global", limit: 3_000, windowMs: 60_000 },
      { key: "vault-get:account:11111111-1111-4111-8111-111111111111", limit: 120, windowMs: 60_000 }
    ]);
  });

  it("meters unauthenticated traffic only against the preflight quota", async () => {
    mocks.authenticateBearerSession.mockRejectedValueOnce(new TokenValidationError());

    const response = await GET(new NextRequest("http://localhost/vault/latest"));

    expect(response.status).toBe(401);
    expect(mocks.rateLimitMany).toHaveBeenCalledOnce();
    expect(mocks.rateLimitMany).toHaveBeenCalledWith([
      { key: "vault-get-preflight:global", limit: 3_000, windowMs: 60_000 },
      { key: "vault-get-preflight:client:client", limit: 120, windowMs: 60_000 }
    ]);
    expect(mocks.dbQuery).not.toHaveBeenCalled();
  });

  it("rejects an unauthenticated upload before body, account quota, or storage work", async () => {
    mocks.authenticateBearerSession.mockRejectedValueOnce(new TokenValidationError());

    const response = await PUT(request(snapshot()));

    expect(response.status).toBe(401);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(mocks.rateLimitMany).toHaveBeenCalledOnce();
    expect(mocks.rateLimitMany).toHaveBeenCalledWith([
      { key: "vault-put-preflight:global", limit: 300, windowMs: 60_000 },
      { key: "vault-put-preflight:client:client", limit: 10, windowMs: 60_000 }
    ]);
    expect(mocks.chargeVaultIngress).not.toHaveBeenCalled();
    expect(mocks.saveVaultSnapshot).not.toHaveBeenCalled();
  });

  it("does not expose unexpected database details", async () => {
    mocks.dbQuery.mockRejectedValue(new Error("postgres://admin:secret@db internal failure"));
    const response = await GET(new NextRequest("http://localhost/vault/latest", {
      headers: { authorization: "Bearer token" }
    }));
    expect(response.status).toBe(500);
    const body = JSON.stringify(await response.json());
    expect(body).toContain("could not be loaded");
    expect(body).not.toContain("secret");
  });
});
