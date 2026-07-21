import { createHash } from "node:crypto";
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
    vi.clearAllMocks();
  });

  it("validates cursor pages and commits only after the full scan", async () => {
    let fetchCount = 0;
    query.mockImplementation(async (sql: string) => {
      if (sql.startsWith("FETCH FORWARD")) {
        fetchCount += 1;
        return { rowCount: fetchCount === 1 ? 1 : 0, rows: fetchCount === 1 ? [storedRow()] : [] };
      }
      return { rowCount: null, rows: [] };
    });

    await expect(assertStoredVaultIntegrity(pool)).resolves.toBeUndefined();

    const statements = query.mock.calls.map(([sql]) => String(sql));
    expect(statements[0]).toBe("BEGIN TRANSACTION READ ONLY");
    expect(statements[1]).toContain("DECLARE address_atlas_vault_integrity");
    expect(statements[1]).toContain("jsonb_typeof(vault.envelope) = 'object'");
    expect(statements[1]).toContain("pg_column_compression(vault.envelope) IS NULL");
    expect(statements[1]).toContain("pg_column_size(vault.envelope)");
    expect(statements[1]).toContain("pg_column_compression(vault.checksum) IS NULL");
    expect(statements[1]).toContain("pg_column_size(vault.checksum)");
    expect(statements[1]).toMatch(/CASE[\s\S]+pg_column_size\(vault\.envelope\)[\s\S]+THEN \([\s\S]+octet_length\(vault\.envelope::pg_catalog\.text\)/);
    expect(statements[1]).toContain("octet_length(vault.envelope::pg_catalog.text)");
    expect(statements[1]).toContain("CASE WHEN safety.stored_row_valid THEN vault.envelope ELSE NULL END");
    expect(statements[1]).toContain("CASE WHEN safety.stored_row_valid THEN vault.checksum ELSE NULL END");
    expect(statements[1]).toContain("CASE WHEN safety.stored_row_valid THEN vault.updated_at ELSE NULL END");
    expect(statements.filter((sql) => sql.startsWith("FETCH FORWARD 8"))).toHaveLength(2);
    expect(statements.at(-2)).toBe("CLOSE address_atlas_vault_integrity");
    expect(statements.at(-1)).toBe("COMMIT");
    expect(release).toHaveBeenCalledWith();
  });

  it("fails on an explicit SQL sentinel without accepting raw unsafe fields", async () => {
    query.mockImplementation(async (sql: string) => {
      if (sql.startsWith("FETCH FORWARD")) {
        return {
          rowCount: 1,
          rows: [{
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
      if (sql.startsWith("FETCH FORWARD")) return { rowCount: 1, rows: [corrupt] };
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
      if (sql.startsWith("FETCH FORWARD")) return { rowCount: 1, rows: [corrupt] };
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
});
