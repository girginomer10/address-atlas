import { afterEach, describe, expect, it, vi } from "vitest";
import {
  getSyncDatabaseConfig,
  getSyncLimitConfig,
  getSyncPasskeyConfig,
  getSyncRegistrationConfig,
  getSyncSchemaDatabaseConfig,
  getSyncSchemaMode,
  validateSyncRuntimeConfig
} from "./config";

function stubValidRuntimeConfig() {
  vi.stubEnv("ADDRESS_ATLAS_DOMAIN", "sync.address-atlas.example");
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

  it.each([
    "http://localhost",
    "http://localhost:3000",
    "http://localhost:8787"
  ])("accepts the exact localhost HTTP WebAuthn development contract: %s", (origin) => {
    vi.stubEnv("PASSKEY_RP_ID", "localhost");
    vi.stubEnv("PASSKEY_RP_NAME", "Address Atlas");
    vi.stubEnv("PASSKEY_ORIGIN", origin);

    expect(getSyncPasskeyConfig()).toMatchObject({
      rpID: "localhost",
      expectedOrigin: origin
    });
  });

  it.each([
    "http://127.0.0.1:3000",
    "http://[::1]:3000",
    "http://localhost.example:3000"
  ])("rejects plaintext hosts that cannot complete the localhost passkey flow: %s", (origin) => {
    vi.stubEnv("PASSKEY_RP_ID", "localhost");
    vi.stubEnv("PASSKEY_RP_NAME", "Address Atlas");
    vi.stubEnv("PASSKEY_ORIGIN", origin);

    expect(() => getSyncPasskeyConfig()).toThrow(/exact HTTP localhost/i);
  });

  it("rejects malformed explicit limits instead of broadening them to defaults", () => {
    vi.stubEnv("SYNC_MAX_ACCOUNTS", "not-a-number");
    expect(() => getSyncLimitConfig()).toThrow(/SYNC_MAX_ACCOUNTS/);

    vi.stubEnv("SYNC_MAX_ACCOUNTS", "100000");
    vi.stubEnv("SYNC_VAULT_DAILY_BYTE_LIMIT", "");
    expect(() => getSyncLimitConfig()).toThrow(/SYNC_VAULT_DAILY_BYTE_LIMIT/);
  });

  it("defaults production registration closed and validates explicit admission controls", () => {
    vi.stubEnv("NODE_ENV", "production");
    expect(getSyncRegistrationConfig()).toEqual({ enabled: false, hourlyLimit: 100 });

    vi.stubEnv("SYNC_REGISTRATION_ENABLED", "true");
    vi.stubEnv("SYNC_REGISTRATION_HOURLY_LIMIT", "25");
    expect(getSyncRegistrationConfig()).toEqual({ enabled: true, hourlyLimit: 25 });

    vi.stubEnv("SYNC_REGISTRATION_ENABLED", "yes");
    expect(() => getSyncRegistrationConfig()).toThrow(/true or false/i);
  });

  it("separates validate-only runtime from the production schema-owner URL", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv(
      "SYNC_DATABASE_URL",
      "postgres://address_atlas_runtime:runtime-secret-value@postgres:5432/address_atlas_sync"
    );
    expect(getSyncSchemaMode()).toBe("validate");
    expect(() => getSyncSchemaDatabaseConfig()).toThrow(/SYNC_SCHEMA_DATABASE_URL.*required/i);

    vi.stubEnv(
      "SYNC_SCHEMA_DATABASE_URL",
      "postgres://address_atlas:schema-owner-secret-value@postgres:5432/address_atlas_sync"
    );
    expect(getSyncSchemaDatabaseConfig().connectionString).toContain("address_atlas");

    vi.stubEnv("SYNC_SCHEMA_DATABASE_URL", "");
    expect(() => getSyncSchemaDatabaseConfig()).toThrow(/must not be blank/i);
    vi.stubEnv(
      "SYNC_SCHEMA_DATABASE_URL",
      "postgres://address_atlas:schema-owner-secret-value@postgres:5432/address_atlas_sync"
    );

    vi.stubEnv("SYNC_SCHEMA_MODE", "bootstrap");
    expect(getSyncSchemaMode()).toBe("bootstrap");
    vi.stubEnv("SYNC_SCHEMA_MODE", "auto");
    expect(() => getSyncSchemaMode()).toThrow(/validate or bootstrap/i);
  });

  it("parses a durable global daily ingress budget independently from storage", () => {
    vi.stubEnv("SYNC_GLOBAL_VAULT_DAILY_INGRESS_BYTE_LIMIT", "9000000");
    vi.stubEnv("SYNC_GLOBAL_VAULT_STORAGE_LIMIT", "12000000");
    expect(getSyncLimitConfig()).toMatchObject({
      globalDailyVaultIngressByteLimit: 9_000_000,
      globalVaultStorageLimit: 12_000_000
    });
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

  it("parses bounded pool and idle controls without silently falling back", () => {
    vi.stubEnv("SYNC_DATABASE_URL", "postgres://user:secret@postgres:5432/address_atlas_sync");
    vi.stubEnv("SYNC_DB_POOL_SIZE", "17");
    vi.stubEnv("SYNC_DB_IDLE_TIMEOUT_MS", "45000");

    expect(getSyncDatabaseConfig()).toMatchObject({ poolSize: 17, idleTimeoutMs: 45_000 });

    vi.stubEnv("SYNC_DB_POOL_SIZE", "0");
    expect(() => getSyncDatabaseConfig()).toThrow(/SYNC_DB_POOL_SIZE/);

    vi.stubEnv("SYNC_DB_POOL_SIZE", "17");
    vi.stubEnv("SYNC_DB_IDLE_TIMEOUT_MS", "");
    expect(() => getSyncDatabaseConfig()).toThrow(/SYNC_DB_IDLE_TIMEOUT_MS/);
  });

  it.each([
    ["127.0.0.1", "https://127.0.0.1"],
    ["::1", "https://[::1]"],
    ["co.uk", "https://login.co.uk"],
    ["github.io", "https://account.github.io"]
  ])("rejects an IP or public-suffix RP ID: %s", (rpID, origin) => {
    vi.stubEnv("PASSKEY_RP_ID", rpID);
    vi.stubEnv("PASSKEY_RP_NAME", "Address Atlas");
    vi.stubEnv("PASSKEY_ORIGIN", origin);

    expect(() => getSyncPasskeyConfig()).toThrow(/hostname|registrable domain/i);
  });

  it("rejects local and reserved RP IDs in production", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("ADDRESS_ATLAS_DOMAIN", "sync.address-atlas.example");
    vi.stubEnv("PASSKEY_RP_ID", "sync.address-atlas.example");
    vi.stubEnv("PASSKEY_RP_NAME", "Address Atlas");
    vi.stubEnv("PASSKEY_ORIGIN", "https://sync.address-atlas.example");
    expect(() => getSyncPasskeyConfig()).toThrow(/non-reserved production domain/i);

    vi.stubEnv("PASSKEY_RP_ID", "localhost");
    vi.stubEnv("PASSKEY_ORIGIN", "http://localhost:3000");
    expect(() => getSyncPasskeyConfig()).toThrow(/production domain/i);

    vi.stubEnv("PASSKEY_RP_ID", "sync.addressatlas.com");
    vi.stubEnv("PASSKEY_ORIGIN", "https://sync.addressatlas.com");
    vi.stubEnv("ADDRESS_ATLAS_DOMAIN", "sync.addressatlas.com");
    expect(getSyncPasskeyConfig().rpID).toBe("sync.addressatlas.com");
  });

  it("requires the production WebAuthn origin to match the published domain exactly", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("PASSKEY_RP_ID", "addressatlas.com");
    vi.stubEnv("PASSKEY_RP_NAME", "Address Atlas");
    vi.stubEnv("PASSKEY_ORIGIN", "https://auth.addressatlas.com");
    vi.stubEnv("ADDRESS_ATLAS_DOMAIN", "sync.addressatlas.com");

    expect(() => getSyncPasskeyConfig()).toThrow(/exactly equal/i);

    vi.stubEnv("PASSKEY_ORIGIN", "https://sync.addressatlas.com");
    expect(getSyncPasskeyConfig()).toMatchObject({
      rpID: "addressatlas.com",
      expectedOrigin: "https://sync.addressatlas.com"
    });
  });

  it.each([
    "https://sync.addressatlas.com",
    "sync.addressatlas.com:443",
    "SYNC.addressatlas.com",
    "localhost"
  ])("rejects an invalid production ADDRESS_ATLAS_DOMAIN: %s", (domain) => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("PASSKEY_RP_ID", "addressatlas.com");
    vi.stubEnv("PASSKEY_RP_NAME", "Address Atlas");
    vi.stubEnv("PASSKEY_ORIGIN", "https://sync.addressatlas.com");
    vi.stubEnv("ADDRESS_ATLAS_DOMAIN", domain);

    expect(() => getSyncPasskeyConfig()).toThrow(/ADDRESS_ATLAS_DOMAIN/i);
  });

  it("rejects placeholder database credentials in production", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv(
      "SYNC_DATABASE_URL",
      "postgres://address_atlas_runtime:replace-with-password@postgres:5432/address_atlas_sync"
    );
    expect(() => getSyncDatabaseConfig()).toThrow(/non-placeholder username and password/i);
  });

  it("pins production database URLs to the runtime and owner identities", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv(
      "SYNC_DATABASE_URL",
      "postgres://address_atlas:runtime-secret-value@postgres:5432/address_atlas_sync"
    );
    expect(() => getSyncDatabaseConfig()).toThrow(/fixed production role address_atlas_runtime/i);

    vi.stubEnv(
      "SYNC_DATABASE_URL",
      "postgres://address_atlas_runtime:runtime-secret-value@postgres:5432/address_atlas_other"
    );
    expect(() => getSyncDatabaseConfig()).toThrow(/exact production database address_atlas_sync/i);

    vi.stubEnv(
      "SYNC_SCHEMA_DATABASE_URL",
      "postgres://address_atlas_runtime:owner-secret-value@postgres:5432/address_atlas_sync"
    );
    expect(() => getSyncSchemaDatabaseConfig()).toThrow(/fixed production role address_atlas/i);

    vi.stubEnv(
      "SYNC_SCHEMA_DATABASE_URL",
      "postgres://address_atlas:owner-secret-value@postgres:5432/address_atlas_sync"
    );
    expect(getSyncSchemaDatabaseConfig().connectionString).toContain("address_atlas_sync");
  });

  it.each([
    "options=-csearch_path%3Devil",
    "application_name=spoofed",
    "statement_timeout=0",
    "connect_timeout=0",
    "target_session_attrs=read-write"
  ])("rejects a dangerous production database URL parameter: %s", (parameter) => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv(
      "SYNC_DATABASE_URL",
      `postgres://address_atlas_runtime:runtime-secret-value@postgres:5432/address_atlas_sync?${parameter}`
    );
    expect(() => getSyncDatabaseConfig()).toThrow(/forbidden or duplicate production URL parameter/i);
  });

  it("allows a single TLS-only production URL parameter and rejects duplicates", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv(
      "SYNC_DATABASE_URL",
      "postgres://address_atlas_runtime:runtime-secret-value@postgres:5432/address_atlas_sync?sslmode=require"
    );
    expect(getSyncDatabaseConfig().connectionString).toContain("sslmode=require");

    vi.stubEnv(
      "SYNC_DATABASE_URL",
      "postgres://address_atlas_runtime:runtime-secret-value@postgres:5432/address_atlas_sync?sslmode=require&sslmode=verify-full"
    );
    expect(() => getSyncDatabaseConfig()).toThrow(/forbidden or duplicate production URL parameter/i);
  });

  it.each([
    "atlas_drill_case1",
    "atlas_restore_case_2",
    "atlas_bootstrap_case3"
  ])("allows only an explicitly marked isolated restore schema migration: %s", (database) => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("ADDRESS_ATLAS_RESTORE_MIGRATION", "1");
    vi.stubEnv("SYNC_SCHEMA_MODE", "bootstrap");
    vi.stubEnv(
      "SYNC_SCHEMA_DATABASE_URL",
      `postgres://address_atlas:owner-secret-value@postgres:5432/${database}`
    );
    expect(getSyncSchemaDatabaseConfig().connectionString).toContain(database);
  });

  it("rejects restore database exceptions with a missing flag, wrong mode, source, or name", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("SYNC_SCHEMA_MODE", "bootstrap");
    vi.stubEnv(
      "SYNC_SCHEMA_DATABASE_URL",
      "postgres://address_atlas:owner-secret-value@postgres:5432/atlas_restore_case1"
    );
    expect(() => getSyncSchemaDatabaseConfig()).toThrow(/exact production database/i);

    vi.stubEnv("ADDRESS_ATLAS_RESTORE_MIGRATION", "1");
    vi.stubEnv("SYNC_SCHEMA_MODE", "validate");
    expect(() => getSyncSchemaDatabaseConfig()).toThrow(/exact production database/i);

    vi.stubEnv("SYNC_SCHEMA_MODE", "bootstrap");
    vi.stubEnv(
      "SYNC_SCHEMA_DATABASE_URL",
      "postgres://address_atlas:owner-secret-value@postgres:5432/customer_database"
    );
    expect(() => getSyncSchemaDatabaseConfig()).toThrow(/exact production database/i);

    vi.stubEnv(
      "SYNC_DATABASE_URL",
      "postgres://address_atlas_runtime:runtime-secret-value@postgres:5432/atlas_restore_case1"
    );
    expect(() => getSyncDatabaseConfig()).toThrow(/exact production database/i);
  });
});
