import { createHash } from "node:crypto";
import { performance } from "node:perf_hooks";
import type { Pool } from "pg";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { base64urlEncode } from "./base64url";
import {
  canonicalEnvelopeBytes,
  computeSnapshotChecksum,
  StoredVaultSnapshotIntegrityError,
  type EncryptedVaultEnvelope
} from "./envelope";
import { assertStoredVaultIntegrity } from "./vault-integrity";

const USER_ID = "11111111-1111-4111-8111-111111111111";

function storedRow() {
  const nonce = Buffer.alloc(12, 7);
  const ciphertext = Buffer.alloc(48, 8);
  const envelope: EncryptedVaultEnvelope = {
    schemaVersion: 2,
    cryptoVersion: 2,
    keyId: "sync-v2",
    nonce: base64urlEncode(nonce),
    ciphertext: base64urlEncode(ciphertext),
    checksum: createHash("sha256")
      .update(Buffer.from("schema:2|crypto:2|key:sync-v2|"))
      .update(nonce)
      .update(ciphertext)
      .digest("hex"),
    createdAt: "2026-07-12T12:00:00Z"
  };
  const canonical = canonicalEnvelopeBytes(envelope);
  return {
    stored_row_valid: true,
    version: 3,
    envelope,
    byte_size: canonical.byteLength,
    checksum: computeSnapshotChecksum(3, envelope, canonical),
    updated_at: new Date("2026-07-12T12:00:00Z")
  };
}

describe("bounded restored-vault integrity scan", () => {
  const query = vi.fn();
  const release = vi.fn();
  const pool = {
    connect: vi.fn(async () => ({ query, release }))
  } as unknown as Pool;

  beforeEach(() => {
    vi.restoreAllMocks();
    vi.clearAllMocks();
  });

  it("validates byte-bounded keyset pages and commits only after the full scan", async () => {
    let pageCount = 0;
    const progress = vi.fn();
    query.mockImplementation(async (sql: string) => {
      if (sql.includes("WITH candidates AS MATERIALIZED")) {
        pageCount += 1;
        return {
          rowCount: pageCount === 1 ? 1 : 0,
          rows: pageCount === 1 ? [{ ...storedRow(), scan_key: USER_ID }] : []
        };
      }
      return { rowCount: null, rows: [] };
    });

    await expect(assertStoredVaultIntegrity(pool, { onProgress: progress }))
      .resolves.toBeUndefined();

    const statements = query.mock.calls.map(([sql]) => String(sql));
    expect(statements[0]).toBe("BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY");
    expect(statements[1]).toContain("WITH candidates AS MATERIALIZED");
    expect(statements[1]).toContain("pg_column_size(vault.envelope)");
    expect(statements[1]).toContain("cumulative_bytes <= $2 OR page_row = 1");
    expect(statements[1]).not.toContain("WHERE vault.user_id >");
    expect(statements[1]).toContain("jsonb_typeof(vault.envelope) = 'object'");
    expect(statements[1]).toContain("CASE WHEN safety.stored_row_valid THEN vault.envelope ELSE NULL END");
    expect(query.mock.calls[1]?.[1]).toEqual([1_024, 64 * 1024 * 1024]);
    expect(query.mock.calls[2]?.[1]).toEqual([USER_ID, 1_024, 64 * 1024 * 1024]);
    expect(statements[2]).toContain("WHERE vault.user_id > $1::uuid");
    expect(statements[2]).toContain("cumulative_bytes <= $3 OR page_row = 1");
    expect(statements.at(-1)).toBe("COMMIT");
    expect(progress).toHaveBeenNthCalledWith(1, {
      rowsScanned: 1,
      pagesScanned: 1,
      done: false
    });
    expect(progress).toHaveBeenLastCalledWith({
      rowsScanned: 1,
      pagesScanned: 1,
      done: true
    });
    expect(release).toHaveBeenCalledWith();
  });

  it("fails on an explicit SQL sentinel without accepting raw unsafe fields", async () => {
    query.mockImplementation(async (sql: string) => {
      if (sql.includes("WITH candidates AS MATERIALIZED")) {
        return {
          rowCount: 1,
          rows: [{
            scan_key: USER_ID,
            stored_row_valid: false,
            version: 1,
            byte_size: 1,
            envelope: null,
            checksum: null,
            updated_at: null
          }]
        };
      }
      return { rowCount: null, rows: [] };
    });

    await expect(assertStoredVaultIntegrity(pool))
      .rejects.toBeInstanceOf(StoredVaultSnapshotIntegrityError);
    expect(query).toHaveBeenCalledWith("ROLLBACK");
  });

  it("rolls back and rejects a corrupted restored row", async () => {
    const corrupt = { ...storedRow(), byte_size: storedRow().byte_size + 1 };
    query.mockImplementation(async (sql: string) => {
      if (sql.includes("WITH candidates AS MATERIALIZED")) {
        return { rowCount: 1, rows: [{ ...corrupt, scan_key: USER_ID }] };
      }
      return { rowCount: null, rows: [] };
    });

    await expect(assertStoredVaultIntegrity(pool))
      .rejects.toBeInstanceOf(StoredVaultSnapshotIntegrityError);

    expect(query).toHaveBeenCalledWith("ROLLBACK");
    expect(query.mock.calls.map(([sql]) => String(sql))).not.toContain("COMMIT");
    expect(release).toHaveBeenCalledWith();
  });

  it("rolls back when a restored timestamp is not finite", async () => {
    const corrupt = { ...storedRow(), updated_at: Number.POSITIVE_INFINITY };
    query.mockImplementation(async (sql: string) => {
      if (sql.includes("WITH candidates AS MATERIALIZED")) {
        return { rowCount: 1, rows: [{ ...corrupt, scan_key: USER_ID }] };
      }
      return { rowCount: null, rows: [] };
    });

    await expect(assertStoredVaultIntegrity(pool))
      .rejects.toBeInstanceOf(StoredVaultSnapshotIntegrityError);
    expect(query).toHaveBeenCalledWith("ROLLBACK");
  });

  it("classifies a cursor connection failure without exposing its message", async () => {
    const connectionError = Object.assign(
      new Error("postgres://admin:secret@db"),
      { code: "ECONNREFUSED" }
    );
    const unavailablePool = {
      connect: vi.fn().mockRejectedValue(connectionError)
    } as unknown as Pool;

    const failure = await assertStoredVaultIntegrity(unavailablePool).catch((error: unknown) => error);

    expect(failure).toMatchObject({
      operationalCode: "database_connection_failed",
      message: "Stored vault integrity scan could not connect to PostgreSQL."
    });
    expect(JSON.stringify(failure)).not.toContain("secret");
  });

  it("rolls back when the finite recovery deadline is exhausted between pages", async () => {
    let monotonicNow = 1_000;
    vi.spyOn(performance, "now").mockImplementation(() => monotonicNow);
    query.mockImplementation(async (sql: string) => {
      if (sql.includes("WITH candidates AS MATERIALIZED")) {
        monotonicNow += 11;
        return { rowCount: 1, rows: [{ ...storedRow(), scan_key: USER_ID }] };
      }
      return { rowCount: 1, rows: [] };
    });

    await expect(assertStoredVaultIntegrity(pool, { deadlineMs: 10 }))
      .rejects.toMatchObject({ operationalCode: "database_query_failed" });
    expect(query).toHaveBeenCalledWith("ROLLBACK");
  });

  it("rejects an absolute deadline that could bypass the recovery RTO ceiling", async () => {
    vi.spyOn(performance, "now").mockReturnValue(1_000);

    await expect(assertStoredVaultIntegrity(pool, { deadlineAt: 1_000 + 30 * 60_000 + 1 }))
      .rejects.toThrow("Restore integrity deadline is invalid.");

    expect(pool.connect).not.toHaveBeenCalled();
  });
});
