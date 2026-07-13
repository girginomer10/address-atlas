import { afterEach, describe, expect, it, vi } from "vitest";
import {
  getSyncDatabaseConfig,
  getSyncLimitConfig,
  getSyncPasskeyConfig,
  validateSyncRuntimeConfig
} from "./config";

function stubValidRuntimeConfig() {
  vi.stubEnv("SYNC_DATABASE_URL", "postgres://user:9f4a8c2e71d63b50f8a4c2e71d63b50f@postgres:5432/address_atlas_sync");
  vi.stubEnv("SYNC_SESSION_SECRET", "f4L7p9Q2v6N8x1R3m5K0s2T4u7W9y1Z3b6D8g0H2");
  vi.stubEnv("PASSKEY_RP_ID", "sync.address-atlas.example");
  vi.stubEnv("PASSKEY_RP_NAME", "Address Atlas");
  vi.stubEnv("PASSKEY_ORIGIN", "https://sync.address-atlas.example");
}

describe("sync runtime configuration", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("accepts a complete configuration and uses defaults only for absent limits", () => {
    stubValidRuntimeConfig();

    expect(validateSyncRuntimeConfig()).toMatchObject({
      passkeys: {
        rpID: "sync.address-atlas.example",
        expectedOrigin: "https://sync.address-atlas.example"
      },
      database: { poolSize: 10, connectTimeoutMs: 5_000 },
      limits: { maxAccounts: 100_000, dailyVaultWriteLimit: 100 }
    });
  });

  it("rejects missing secrets and malformed passkey origins", () => {
    stubValidRuntimeConfig();
    vi.stubEnv("SYNC_SESSION_SECRET", "");
    expect(() => validateSyncRuntimeConfig()).toThrow(/secret.*required/i);

    vi.stubEnv("SYNC_SESSION_SECRET", "f4L7p9Q2v6N8x1R3m5K0s2T4u7W9y1Z3b6D8g0H2");
    vi.stubEnv("PASSKEY_ORIGIN", "https://other.example/path");
    expect(() => getSyncPasskeyConfig()).toThrow(/origin/i);
  });

  it("rejects malformed explicit limits instead of broadening them to defaults", () => {
    vi.stubEnv("SYNC_MAX_ACCOUNTS", "not-a-number");
    expect(() => getSyncLimitConfig()).toThrow(/SYNC_MAX_ACCOUNTS/);

    vi.stubEnv("SYNC_MAX_ACCOUNTS", "100000");
    vi.stubEnv("SYNC_VAULT_DAILY_BYTE_LIMIT", "");
    expect(() => getSyncLimitConfig()).toThrow(/SYNC_VAULT_DAILY_BYTE_LIMIT/);
  });

  it("rejects malformed database URLs and timeout values", () => {
    vi.stubEnv("SYNC_DATABASE_URL", "https://example.com/not-postgres");
    expect(() => getSyncDatabaseConfig()).toThrow(/Postgres/i);

    vi.stubEnv("SYNC_DATABASE_URL", "postgres://user:secret@postgres:5432/address_atlas_sync");
    vi.stubEnv("SYNC_DB_QUERY_TIMEOUT_MS", "999999");
    expect(() => getSyncDatabaseConfig()).toThrow(/SYNC_DB_QUERY_TIMEOUT_MS/);

    vi.stubEnv("SYNC_DB_QUERY_TIMEOUT_MS", "10000");
    vi.stubEnv("SYNC_DB_STATEMENT_TIMEOUT_MS", "9500");
    expect(() => getSyncDatabaseConfig()).toThrow(/at least 1000ms greater/i);
  });

  it.each([
    ["127.0.0.1", "https://127.0.0.1"],
    ["co.uk", "https://login.co.uk"],
    ["github.io", "https://account.github.io"]
  ])("rejects an IP or public-suffix RP ID: %s", (rpID, origin) => {
    vi.stubEnv("PASSKEY_RP_ID", rpID);
    vi.stubEnv("PASSKEY_RP_NAME", "Address Atlas");
    vi.stubEnv("PASSKEY_ORIGIN", origin);

    expect(() => getSyncPasskeyConfig()).toThrow(/registrable domain/i);
  });

  it("rejects local and reserved RP IDs in production", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("PASSKEY_RP_ID", "sync.address-atlas.example");
    vi.stubEnv("PASSKEY_RP_NAME", "Address Atlas");
    vi.stubEnv("PASSKEY_ORIGIN", "https://sync.address-atlas.example");
    expect(() => getSyncPasskeyConfig()).toThrow(/non-reserved production domain/i);

    vi.stubEnv("PASSKEY_RP_ID", "localhost");
    vi.stubEnv("PASSKEY_ORIGIN", "http://localhost:3000");
    expect(() => getSyncPasskeyConfig()).toThrow(/production domain/i);

    vi.stubEnv("PASSKEY_RP_ID", "sync.addressatlas.com");
    vi.stubEnv("PASSKEY_ORIGIN", "https://sync.addressatlas.com");
    expect(getSyncPasskeyConfig().rpID).toBe("sync.addressatlas.com");
  });

  it("rejects placeholder database credentials in production", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv(
      "SYNC_DATABASE_URL",
      "postgres://address_atlas:replace-with-password@postgres:5432/address_atlas_sync"
    );
    expect(() => getSyncDatabaseConfig()).toThrow(/non-placeholder username and password/i);
  });
});
