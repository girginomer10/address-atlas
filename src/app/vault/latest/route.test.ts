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
  saveVaultSnapshot: vi.fn(),
  dbQuery: vi.fn(),
  readBearerToken: vi.fn(),
  rateLimitMany: vi.fn()
}));

vi.mock("@/lib/sync/postgres", () => ({
  ensureSyncSchema: vi.fn(async () => undefined),
  getSyncPool: () => ({ query: mocks.dbQuery })
}));

vi.mock("@/lib/sync/tokens", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/sync/tokens")>()),
  readBearerToken: mocks.readBearerToken
}));

vi.mock("@/lib/sync/rate-limit", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/sync/rate-limit")>()),
  rateLimitMany: mocks.rateLimitMany
}));

vi.mock("@/lib/sync/vault-storage", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/sync/vault-storage")>()),
  saveVaultSnapshot: mocks.saveVaultSnapshot
}));

import { GET, PUT } from "./route";
import { TokenValidationError } from "@/lib/sync/tokens";
import { VaultConflictError } from "@/lib/sync/vault-storage";

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
    mocks.saveVaultSnapshot.mockResolvedValue({ idempotent: false });
    mocks.rateLimitMany.mockReturnValue(true);
    mocks.readBearerToken.mockReturnValue({
      userId: "11111111-1111-4111-8111-111111111111",
      expiresAt: Date.now() + 60_000
    });
    mocks.dbQuery.mockResolvedValue({ rows: [] });
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
    expect(mocks.saveVaultSnapshot).not.toHaveBeenCalled();
  });

  it("reports exact idempotent replays without rewriting storage", async () => {
    mocks.saveVaultSnapshot.mockResolvedValue({ idempotent: true });
    const response = await PUT(request(snapshot()));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, idempotent: true });
    expect(mocks.saveVaultSnapshot).toHaveBeenCalledWith(
      "11111111-1111-4111-8111-111111111111",
      expect.objectContaining({ version: 2 }),
      expect.any(Number)
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
    expect(mocks.saveVaultSnapshot).toHaveBeenCalledWith(
      "11111111-1111-4111-8111-111111111111",
      expect.objectContaining({ version: 2 }),
      Buffer.byteLength(body)
    );
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
    mocks.dbQuery.mockResolvedValue({ rows: [] });

    const response = await GET(new NextRequest("http://localhost/vault/latest", {
      headers: { authorization: "Bearer token" }
    }));

    expect(response.status).toBe(401);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ error: "Authentication required." });
  });

  it("returns 429 before reading or saving an upload when its request quota is exhausted", async () => {
    mocks.rateLimitMany.mockReturnValue(false);

    const response = await PUT(request(snapshot()));

    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ error: "Too many requests." });
    expect(mocks.saveVaultSnapshot).not.toHaveBeenCalled();
    expect(mocks.rateLimitMany).toHaveBeenCalledWith([
      { key: "vault-put:global", limit: 300, windowMs: 60_000 },
      { key: "vault-put:account:11111111-1111-4111-8111-111111111111", limit: 10, windowMs: 60_000 }
    ]);
  });

  it("returns 429 before querying storage when its read quota is exhausted", async () => {
    mocks.rateLimitMany.mockReturnValue(false);

    const response = await GET(new NextRequest("http://localhost/vault/latest", {
      headers: { authorization: "Bearer token" }
    }));

    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ error: "Too many requests." });
    expect(mocks.dbQuery).not.toHaveBeenCalled();
    expect(mocks.rateLimitMany).toHaveBeenCalledWith([
      { key: "vault-get:global", limit: 3_000, windowMs: 60_000 },
      { key: "vault-get:account:11111111-1111-4111-8111-111111111111", limit: 120, windowMs: 60_000 }
    ]);
  });

  it("does not let unauthenticated traffic consume shared vault quota", async () => {
    mocks.readBearerToken.mockImplementationOnce(() => {
      throw new TokenValidationError();
    });

    const response = await GET(new NextRequest("http://localhost/vault/latest"));

    expect(response.status).toBe(401);
    expect(mocks.rateLimitMany).not.toHaveBeenCalled();
    expect(mocks.dbQuery).not.toHaveBeenCalled();
  });

  it("rejects an unauthenticated upload before quota or storage work", async () => {
    mocks.readBearerToken.mockImplementationOnce(() => {
      throw new TokenValidationError();
    });

    const response = await PUT(request(snapshot()));

    expect(response.status).toBe(401);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(mocks.rateLimitMany).not.toHaveBeenCalled();
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
