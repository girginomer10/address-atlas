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
  assertVaultIngressCapacity: vi.fn(),
  authenticateBearerSession: vi.fn(),
  chargeVaultIngress: vi.fn(),
  releaseConcurrency: vi.fn(),
  saveVaultSnapshot: vi.fn(),
  dbQuery: vi.fn(),
  rateLimitMany: vi.fn(),
  rateLimitWeightedMany: vi.fn()
}));

const INGRESS_ADMISSION = Object.freeze({
  userId: "11111111-1111-4111-8111-111111111111"
});

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
  rateLimitMany: mocks.rateLimitMany,
  rateLimitWeightedMany: mocks.rateLimitWeightedMany
}));

vi.mock("@/lib/sync/vault-storage", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/sync/vault-storage")>()),
  assertVaultIngressCapacity: mocks.assertVaultIngressCapacity,
  chargeVaultIngress: mocks.chargeVaultIngress,
  saveVaultSnapshot: mocks.saveVaultSnapshot
}));

import { GET, HEAD, PUT } from "./route";
import { TokenValidationError } from "@/lib/sync/tokens";
import {
  VaultConflictError,
  VaultQuotaError,
  VaultStorageIntegrityError
} from "@/lib/sync/vault-storage";

function snapshot(schemaVersion: 1 | 2 = 2, version = 2): RemoteVaultSnapshot {
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
    version,
    envelope,
    byteSize: canonical.byteLength,
    checksum: computeSnapshotChecksum(version, envelope, canonical)
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
    mocks.assertVaultIngressCapacity.mockResolvedValue(INGRESS_ADMISSION);
    mocks.chargeVaultIngress.mockResolvedValue(undefined);
    mocks.saveVaultSnapshot.mockResolvedValue({ idempotent: false });
    mocks.rateLimitMany.mockReturnValue(true);
    mocks.rateLimitWeightedMany.mockReturnValue(true);
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
    expect(mocks.assertVaultIngressCapacity).not.toHaveBeenCalled();
    expect(mocks.saveVaultSnapshot).not.toHaveBeenCalled();
  });

  it("rejects an authenticated download before loading storage when active capacity is full", async () => {
    mocks.acquireConcurrencyMany.mockReturnValue(null);

    const response = await GET(new NextRequest("http://localhost/vault/latest", {
      headers: { authorization: "Bearer token" }
    }));

    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(mocks.acquireConcurrencyMany).toHaveBeenCalledWith([
      { key: "vault-get-active:global", limit: 8 },
      { key: "vault-get-active:client:client", limit: 2 },
      {
        key: "vault-get-active:account:11111111-1111-4111-8111-111111111111",
        limit: 2
      }
    ]);
    expect(mocks.dbQuery).not.toHaveBeenCalled();
    expect(mocks.releaseConcurrency).not.toHaveBeenCalled();
  });

  it("releases exactly once when an already-aborted GET acquires a permit", async () => {
    const controller = new AbortController();
    controller.abort();

    const response = await GET(new NextRequest("http://localhost/vault/latest", {
      headers: { authorization: "Bearer token" },
      signal: controller.signal
    }));

    expect(response.status).toBe(408);
    expect(await response.json()).toEqual({ error: "Request cancelled." });
    expect(mocks.acquireConcurrencyMany).toHaveBeenCalledOnce();
    expect(mocks.releaseConcurrency).toHaveBeenCalledOnce();
    expect(mocks.dbQuery).not.toHaveBeenCalled();
    expect(mocks.rateLimitWeightedMany).not.toHaveBeenCalled();
  });

  it("rejects exhausted durable capacity before reading or charging the body", async () => {
    mocks.assertVaultIngressCapacity.mockRejectedValue(new VaultQuotaError());
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        controller.enqueue(new TextEncoder().encode("{}"));
        controller.close();
      }
    });
    const upload = new NextRequest("http://localhost/vault/latest", {
      method: "PUT",
      headers: {
        authorization: "Bearer token",
        "content-type": "application/json"
      },
      body,
      duplex: "half"
    } as NonNullable<ConstructorParameters<typeof NextRequest>[1]> & { duplex: "half" });
    const getReader = vi.spyOn(upload.body!, "getReader");

    const response = await PUT(upload);

    expect(response.status).toBe(429);
    expect(getReader).not.toHaveBeenCalled();
    expect(mocks.assertVaultIngressCapacity).toHaveBeenCalledWith(
      "11111111-1111-4111-8111-111111111111"
    );
    expect(mocks.chargeVaultIngress).not.toHaveBeenCalled();
    expect(mocks.saveVaultSnapshot).not.toHaveBeenCalled();
    expect(mocks.releaseConcurrency).toHaveBeenCalledOnce();
  });

  it("returns a retryable 503 before reading a body when ledger integrity blocks writes", async () => {
    mocks.assertVaultIngressCapacity.mockRejectedValue(new VaultStorageIntegrityError());
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        controller.enqueue(new TextEncoder().encode("{}"));
        controller.close();
      }
    });
    const upload = new NextRequest("http://localhost/vault/latest", {
      method: "PUT",
      headers: {
        authorization: "Bearer token",
        "content-type": "application/json"
      },
      body,
      duplex: "half"
    } as NonNullable<ConstructorParameters<typeof NextRequest>[1]> & { duplex: "half" });
    const getReader = vi.spyOn(upload.body!, "getReader");

    const response = await PUT(upload);

    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(await response.json()).toEqual({
      error: "Encrypted vault writes are temporarily unavailable while storage accounting is repaired."
    });
    expect(getReader).not.toHaveBeenCalled();
    expect(mocks.chargeVaultIngress).not.toHaveBeenCalled();
    expect(mocks.saveVaultSnapshot).not.toHaveBeenCalled();
    expect(mocks.releaseConcurrency).toHaveBeenCalledOnce();
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
      Buffer.byteLength(body),
      INGRESS_ADMISSION
    );
    expect(mocks.saveVaultSnapshot).not.toHaveBeenCalled();
  });

  it("charges only received bytes before rejecting an oversized declaration", async () => {
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
      2,
      INGRESS_ADMISSION
    );
  });

  it("returns durable quota exhaustion before replay or conflict semantics", async () => {
    mocks.chargeVaultIngress.mockRejectedValue(new VaultQuotaError());
    mocks.saveVaultSnapshot.mockRejectedValue(new VaultConflictError());
    const clock = vi.spyOn(Date, "now").mockReturnValue(
      Date.parse("2026-07-13T23:59:30.250Z")
    );
    try {
      const response = await PUT(request(snapshot()));
      expect(response.status).toBe(429);
      expect(response.headers.get("retry-after")).toBe("30");
      expect(mocks.saveVaultSnapshot).not.toHaveBeenCalled();
    } finally {
      clock.mockRestore();
    }
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
      Buffer.byteLength(body),
      INGRESS_ADMISSION
    );
  });

  it("returns the stored snapshot with the exact response field mapping", async () => {
    const stored = snapshot(2, 7);
    mocks.dbQuery.mockResolvedValue({
      rows: [{
        snapshot_present: true,
        stored_row_valid: true,
        version: stored.version,
        envelope: stored.envelope,
        byte_size: stored.byteSize,
        checksum: stored.checksum,
        updated_at: new Date("2026-07-13T08:30:00.123Z")
      }]
    });

    const response = await GET(new NextRequest("http://localhost/vault/latest", {
      headers: { authorization: "Bearer token" }
    }));

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("content-type")).toBe("application/json; charset=utf-8");
    expect(await response.json()).toEqual({
      ...stored,
      updatedAt: "2026-07-13T08:30:00.123Z"
    });
    expect(mocks.dbQuery).toHaveBeenCalledWith(expect.stringContaining("LEFT JOIN vault_snapshots"), [
      "11111111-1111-4111-8111-111111111111"
    ]);
    expect(mocks.releaseConcurrency).toHaveBeenCalledOnce();
  });

  it("returns a bodyless HEAD response without leaking the GET stream permit", async () => {
    const stored = snapshot(2, 7);
    mocks.dbQuery.mockResolvedValue({
      rows: [{
        snapshot_present: true,
        stored_row_valid: true,
        version: stored.version,
        envelope: stored.envelope,
        byte_size: stored.byteSize,
        checksum: stored.checksum,
        updated_at: new Date("2026-07-13T08:30:00.123Z")
      }]
    });

    const response = await HEAD(new NextRequest("http://localhost/vault/latest", {
      method: "HEAD",
      headers: { authorization: "Bearer token" }
    }));

    expect(response.status).toBe(200);
    expect(response.body).toBeNull();
    expect(response.headers.get("content-type")).toBe("application/json; charset=utf-8");
    expect(mocks.releaseConcurrency).toHaveBeenCalledOnce();
  });

  it("holds account permits until streamed bodies drain or are cancelled", async () => {
    const stored = snapshot(2, 7);
    let active = 0;
    mocks.acquireConcurrencyMany.mockImplementation(() => {
      if (active >= 2) return null;
      active += 1;
      let released = false;
      return () => {
        if (released) return;
        released = true;
        active -= 1;
        mocks.releaseConcurrency();
      };
    });
    mocks.dbQuery.mockResolvedValue({
      rows: [{
        snapshot_present: true,
        stored_row_valid: true,
        version: stored.version,
        envelope: stored.envelope,
        byte_size: stored.byteSize,
        checksum: stored.checksum,
        updated_at: new Date("2026-07-13T08:30:00.123Z")
      }]
    });
    const download = () => GET(new NextRequest("http://localhost/vault/latest", {
      headers: { authorization: "Bearer token" }
    }));

    const first = await download();
    const second = await download();
    expect(active).toBe(2);
    expect(mocks.releaseConcurrency).not.toHaveBeenCalled();

    const blocked = await download();
    expect(blocked.status).toBe(429);
    expect(mocks.dbQuery).toHaveBeenCalledTimes(2);
    expect(active).toBe(2);

    expect(await first.json()).toEqual({
      ...stored,
      updatedAt: "2026-07-13T08:30:00.123Z"
    });
    expect(active).toBe(1);
    expect(mocks.releaseConcurrency).toHaveBeenCalledTimes(1);

    const replacement = await download();
    expect(replacement.status).toBe(200);
    expect(active).toBe(2);
    await second.body!.cancel();
    expect(active).toBe(1);
    await replacement.body!.cancel();
    expect(active).toBe(0);
    expect(mocks.releaseConcurrency).toHaveBeenCalledTimes(3);
    expect(mocks.rateLimitWeightedMany).toHaveBeenCalledTimes(3);
  });

  it("releases a stream-owned permit when the request aborts before body drain", async () => {
    const stored = snapshot(2, 7);
    let active = 0;
    mocks.acquireConcurrencyMany.mockImplementation(() => {
      if (active >= 2) return null;
      active += 1;
      let released = false;
      return () => {
        if (released) return;
        released = true;
        active -= 1;
        mocks.releaseConcurrency();
      };
    });
    mocks.dbQuery.mockResolvedValue({
      rows: [{
        snapshot_present: true,
        stored_row_valid: true,
        version: stored.version,
        envelope: stored.envelope,
        byte_size: stored.byteSize,
        checksum: stored.checksum,
        updated_at: new Date("2026-07-13T08:30:00.123Z")
      }]
    });
    const firstAbort = new AbortController();
    const download = (signal?: AbortSignal) => GET(new NextRequest(
      "http://localhost/vault/latest",
      { headers: { authorization: "Bearer token" }, signal }
    ));

    const first = await download(firstAbort.signal);
    const second = await download();
    expect((await download()).status).toBe(429);
    expect(active).toBe(2);

    firstAbort.abort();
    expect(active).toBe(1);
    const replacement = await download();
    expect(replacement.status).toBe(200);
    expect(active).toBe(2);

    await first.body!.cancel();
    await second.body!.cancel();
    await replacement.body!.cancel();
    expect(active).toBe(0);
    expect(mocks.releaseConcurrency).toHaveBeenCalledTimes(3);
  });

  it("keeps an aborted handler permit until its delayed database work settles", async () => {
    const stored = snapshot(2, 7);
    const storedResult = {
      rows: [{
        snapshot_present: true,
        stored_row_valid: true,
        version: stored.version,
        envelope: stored.envelope,
        byte_size: stored.byteSize,
        checksum: stored.checksum,
        updated_at: new Date("2026-07-13T08:30:00.123Z")
      }]
    };
    let active = 0;
    mocks.acquireConcurrencyMany.mockImplementation(() => {
      if (active >= 2) return null;
      active += 1;
      let released = false;
      return () => {
        if (released) return;
        released = true;
        active -= 1;
        mocks.releaseConcurrency();
      };
    });
    let settleDelayedQuery!: (value: typeof storedResult) => void;
    mocks.dbQuery
      .mockImplementationOnce(() => new Promise((resolve) => {
        settleDelayedQuery = resolve;
      }))
      .mockResolvedValue(storedResult);
    const delayedAbort = new AbortController();
    const download = (signal?: AbortSignal) => GET(new NextRequest(
      "http://localhost/vault/latest",
      { headers: { authorization: "Bearer token" }, signal }
    ));

    const delayed = download(delayedAbort.signal);
    await vi.waitFor(() => expect(mocks.dbQuery).toHaveBeenCalledTimes(1));
    const second = await download();
    expect(active).toBe(2);

    delayedAbort.abort();
    expect(active).toBe(2);
    expect((await download()).status).toBe(429);

    settleDelayedQuery(storedResult);
    const cancelled = await delayed;
    expect(cancelled.status).toBe(408);
    expect(await cancelled.json()).toEqual({ error: "Request cancelled." });
    expect(active).toBe(1);

    const replacement = await download();
    expect(replacement.status).toBe(200);
    expect(active).toBe(2);
    await second.body!.cancel();
    await replacement.body!.cancel();
    expect(active).toBe(0);
  });

  it("charges exact encoded egress and releases the permit on byte-limit rejection", async () => {
    const stored = snapshot(2, 7);
    const updatedAt = "2026-07-13T08:30:00.123Z";
    const encodedBytes = Buffer.byteLength(JSON.stringify({ ...stored, updatedAt }));
    mocks.rateLimitWeightedMany.mockReturnValue(false);
    mocks.dbQuery.mockResolvedValue({
      rows: [{
        snapshot_present: true,
        stored_row_valid: true,
        version: stored.version,
        envelope: stored.envelope,
        byte_size: stored.byteSize,
        checksum: stored.checksum,
        updated_at: new Date(updatedAt)
      }]
    });

    const response = await GET(new NextRequest("http://localhost/vault/latest", {
      headers: { authorization: "Bearer token" }
    }));

    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(mocks.rateLimitWeightedMany).toHaveBeenCalledWith([
      {
        key: "vault-get-egress:global",
        limit: 64 * 8_100_000,
        windowMs: 60_000,
        weight: encodedBytes
      },
      {
        key: "vault-get-egress:client:client",
        limit: 16 * 8_100_000,
        windowMs: 60_000,
        weight: encodedBytes
      },
      {
        key: "vault-get-egress:account:11111111-1111-4111-8111-111111111111",
        limit: 8 * 8_100_000,
        windowMs: 60_000,
        weight: encodedBytes
      }
    ]);
    expect(mocks.releaseConcurrency).toHaveBeenCalledOnce();
  });

  it("never projects unsafe variable-width stored fields to the pg client", async () => {
    const errorLog = vi.spyOn(console, "error").mockImplementation(() => undefined);
    mocks.dbQuery.mockResolvedValue({
      rows: [{
        snapshot_present: true,
        stored_row_valid: false,
        version: 1,
        envelope: null,
        byte_size: 1,
        checksum: null,
        updated_at: null
      }]
    });

    const response = await GET(new NextRequest("http://localhost/vault/latest", {
      headers: { authorization: "Bearer token" }
    }));

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: "Vault snapshot could not be loaded." });
    const sql = String(mocks.dbQuery.mock.calls[0]?.[0]);
    expect(sql).toContain("pg_column_compression(vault.envelope) IS NULL");
    expect(sql).toContain("pg_column_size(vault.envelope)");
    expect(sql).toContain("pg_column_compression(vault.checksum) IS NULL");
    expect(sql).toContain("pg_column_size(vault.checksum)");
    expect(sql).toMatch(/CASE[\s\S]+pg_column_size\(vault\.envelope\)[\s\S]+THEN \([\s\S]+octet_length\(vault\.envelope::pg_catalog\.text\)/);
    expect(sql).toContain("jsonb_typeof(vault.envelope) = 'object'");
    expect(sql).toContain("octet_length(vault.envelope::pg_catalog.text)");
    expect(sql).toContain("octet_length(vault.checksum) = 64");
    expect(sql).toContain("isfinite(vault.created_at)");
    expect(sql).toContain("isfinite(vault.updated_at)");
    expect(sql).toContain("CASE WHEN safety.stored_row_valid THEN vault.envelope ELSE NULL END");
    expect(sql).toContain("CASE WHEN safety.stored_row_valid THEN vault.checksum ELSE NULL END");
    expect(sql).toContain("CASE WHEN safety.stored_row_valid THEN vault.updated_at ELSE NULL END");
    expect(JSON.stringify(errorLog.mock.calls)).not.toContain("envelope");
    errorLog.mockRestore();
  });

  it("fails closed with a typed privacy-safe log when a stored snapshot is corrupt", async () => {
    const errorLog = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const stored = snapshot(2, 7);
    mocks.dbQuery.mockResolvedValue({
      rows: [{
        snapshot_present: true,
        stored_row_valid: true,
        version: stored.version,
        envelope: stored.envelope,
        byte_size: stored.byteSize + 1,
        checksum: stored.checksum,
        updated_at: new Date("2026-07-13T08:30:00.123Z")
      }]
    });

    const response = await GET(new NextRequest("http://localhost/vault/latest", {
      headers: { authorization: "Bearer token" }
    }));

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: "Vault snapshot could not be loaded." });
    const record = JSON.parse(String(errorLog.mock.calls.at(-1)?.[0]));
    expect(record).toMatchObject({
      event: "vault.load_failed",
      reason: "stored_snapshot_invalid",
      errorCode: "vault_snapshot_invalid"
    });
    expect(JSON.stringify(record)).not.toContain(stored.checksum);
    expect(mocks.releaseConcurrency).toHaveBeenCalledOnce();
  });

  it("returns 404 when the authenticated account exists without a snapshot", async () => {
    mocks.dbQuery.mockResolvedValue({
      rows: [{
        snapshot_present: false,
        stored_row_valid: false,
        version: null,
        envelope: null,
        byte_size: null,
        checksum: null,
        updated_at: null
      }]
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
    expect(mocks.releaseConcurrency).toHaveBeenCalledOnce();
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
      expect.any(Number),
      INGRESS_ADMISSION
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
    expect(mocks.releaseConcurrency).toHaveBeenCalledOnce();
  });
});
