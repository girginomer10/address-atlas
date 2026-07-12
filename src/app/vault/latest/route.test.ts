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
  readBearerToken: vi.fn()
}));

vi.mock("@/lib/sync/postgres", () => ({
  ensureSyncSchema: vi.fn(async () => undefined),
  getSyncPool: () => ({ query: mocks.dbQuery })
}));

vi.mock("@/lib/sync/tokens", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/sync/tokens")>()),
  readBearerToken: mocks.readBearerToken
}));

vi.mock("@/lib/sync/vault-storage", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/sync/vault-storage")>()),
  saveVaultSnapshot: mocks.saveVaultSnapshot
}));

import { GET, PUT } from "./route";
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
