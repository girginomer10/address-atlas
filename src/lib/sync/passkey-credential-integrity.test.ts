import type { Pool } from "pg";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { base64urlEncode } from "./base64url";
import { assertStoredPasskeyCredentialIntegrity } from "./passkey-credential-integrity";
import { StoredPasskeyCredentialIntegrityError } from "./stored-passkey-credential";

const PUBLIC_KEY = Buffer.from(
  "a50102032620012158206b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2962258204fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5",
  "hex"
);

function storedRow() {
  return {
    id: base64urlEncode("credential-id"),
    user_id: "11111111-1111-4111-8111-111111111111",
    public_key_base64url: base64urlEncode(PUBLIC_KEY),
    counter: "8",
    created_at: new Date("2026-07-13T12:00:00Z"),
    updated_at: new Date("2026-07-13T12:00:00Z"),
    stored_row_valid: true
  };
}

describe("bounded restored-passkey integrity scan", () => {
  const query = vi.fn();
  const release = vi.fn();
  const pool = {
    connect: vi.fn(async () => ({ query, release }))
  } as unknown as Pool;

  beforeEach(() => vi.clearAllMocks());

  it("validates cursor pages and commits only after the full scan", async () => {
    let fetchCount = 0;
    query.mockImplementation(async (sql: string) => {
      if (sql.includes("credentialless_user_exists")) {
        return { rows: [{ credentialless_user_exists: false }] };
      }
      if (sql.startsWith("FETCH FORWARD")) {
        fetchCount += 1;
        return { rows: fetchCount === 1 ? [storedRow()] : [] };
      }
      return { rows: [] };
    });

    await expect(assertStoredPasskeyCredentialIntegrity(pool)).resolves.toBeUndefined();

    const statements = query.mock.calls.map(([sql]) => String(sql));
    expect(statements[0]).toBe("BEGIN TRANSACTION READ ONLY");
    expect(statements[1]).toContain("credentialless_user_exists");
    expect(statements[2]).toContain("DECLARE address_atlas_passkey_integrity");
    expect(statements[2]).toContain("pg_column_compression(credential.public_key_base64url)");
    expect(statements[2]).toContain("ORDER BY credential.ctid");
    expect(statements[2]).not.toContain("ORDER BY credential.id");
    expect(statements.filter((sql) => sql.startsWith("FETCH FORWARD 32"))).toHaveLength(2);
    expect(statements.at(-2)).toBe("CLOSE address_atlas_passkey_integrity");
    expect(statements.at(-1)).toBe("COMMIT");
    expect(release).toHaveBeenCalledWith();
  });

  it("rolls back on an unsafe SQL sentinel without returning raw fields", async () => {
    query.mockImplementation(async (sql: string) => {
      if (sql.includes("credentialless_user_exists")) {
        return { rows: [{ credentialless_user_exists: false }] };
      }
      if (sql.startsWith("FETCH FORWARD")) {
        return {
          rows: [{
            ...storedRow(),
            id: null,
            public_key_base64url: null,
            stored_row_valid: false
          }]
        };
      }
      return { rows: [] };
    });

    await expect(assertStoredPasskeyCredentialIntegrity(pool))
      .rejects.toBeInstanceOf(StoredPasskeyCredentialIntegrityError);
    expect(query).toHaveBeenCalledWith("ROLLBACK");
  });

  it("rejects a restored account with no passkey before scanning credential values", async () => {
    query.mockImplementation(async (sql: string) => {
      if (sql.includes("credentialless_user_exists")) {
        return { rows: [{ credentialless_user_exists: true }] };
      }
      return { rows: [] };
    });

    await expect(assertStoredPasskeyCredentialIntegrity(pool))
      .rejects.toBeInstanceOf(StoredPasskeyCredentialIntegrityError);

    const statements = query.mock.calls.map(([sql]) => String(sql));
    expect(statements.some((sql) => sql.startsWith("DECLARE"))).toBe(false);
    expect(statements).toContain("ROLLBACK");
  });

  it("classifies connection failure without exposing its details", async () => {
    const unavailable = {
      connect: vi.fn().mockRejectedValue(Object.assign(
        new Error("postgres://admin:secret@db"),
        { code: "ECONNREFUSED" }
      ))
    } as unknown as Pool;

    const failure = await assertStoredPasskeyCredentialIntegrity(unavailable)
      .catch((error: unknown) => error);

    expect(failure).toMatchObject({
      operationalCode: "database_connection_failed",
      message: "Stored passkey integrity scan could not connect to PostgreSQL."
    });
    expect(JSON.stringify(failure)).not.toContain("secret");
  });
});
