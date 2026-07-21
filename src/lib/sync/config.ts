import { MAX_SNAPSHOT_REQUEST_BYTES } from "./envelope";
import { parse as parseDomain } from "tldts";

export class SyncConfigurationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SyncConfigurationError";
  }
}

export interface SyncPasskeyConfig {
  rpID: string;
  rpName: string;
  expectedOrigin: string;
}

export interface SyncDatabaseConfig {
  connectionString: string;
  poolSize: number;
  connectTimeoutMs: number;
  idleTimeoutMs: number;
  statementTimeoutMs: number;
  queryTimeoutMs: number;
}

export interface SyncLimitConfig {
  maxAccounts: number;
  dailyVaultWriteLimit: number;
  dailyVaultByteLimit: number;
  globalDailyVaultIngressByteLimit: number;
  globalVaultStorageLimit: number;
}

export interface SyncRegistrationConfig {
  enabled: boolean;
  hourlyLimit: number;
}

export type SyncSchemaMode = "validate" | "bootstrap";

const PLACEHOLDER_RE = /(replace[-_ ]?with|change[-_ ]?me|example|your[-_ ]?secret|password)/i;
const RP_ID_RE = /^(?:localhost|(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)$/;
const RESERVED_PRODUCTION_RP_SUFFIXES = ["example.com", "example.net", "example.org"];
const LOCAL_PASSKEY_HOST = "localhost";
const PRODUCTION_DATABASE_NAME = "address_atlas_sync";
const PRODUCTION_RUNTIME_ROLE = "address_atlas_runtime";
const PRODUCTION_SCHEMA_OWNER_ROLE = "address_atlas";
const RESTORE_MIGRATION_DATABASE_RE = /^atlas_(?:drill|restore|bootstrap)_[A-Za-z0-9_]+$/;
const SAFE_PRODUCTION_DATABASE_URL_PARAMETERS = new Set([
  "channel_binding",
  "sslcert",
  "sslcrl",
  "sslkey",
  "sslmode",
  "sslnegotiation",
  "sslpassword",
  "sslrootcert"
]);

export function validateSessionSecret(value: string | undefined) {
  const configured = value?.trim();
  if (!configured) {
    throw new SyncConfigurationError("SYNC_SESSION_SECRET is required.");
  }
  if (Buffer.byteLength(configured, "utf8") < 32) {
    throw new SyncConfigurationError("SYNC_SESSION_SECRET must contain at least 32 bytes.");
  }
  if (
    PLACEHOLDER_RE.test(configured)
    || /^(.)(\1)+$/.test(configured)
    || new Set(configured).size < 12
  ) {
    throw new SyncConfigurationError("SYNC_SESSION_SECRET must be a random, non-placeholder value.");
  }
  return configured;
}

export function getSyncSessionSecret() {
  return validateSessionSecret(process.env.SYNC_SESSION_SECRET);
}

export function getSyncPasskeyConfig(): SyncPasskeyConfig {
  const configuredRPID = requiredInProduction("PASSKEY_RP_ID", "localhost");
  const rpID = configuredRPID.toLowerCase();
  if (!RP_ID_RE.test(rpID) || rpID !== configuredRPID) {
    throw new SyncConfigurationError("PASSKEY_RP_ID must be a lowercase hostname without a scheme, port, or path.");
  }
  const parsedRPID = parseDomain(rpID, { allowPrivateDomains: true });
  if (rpID !== "localhost" && (parsedRPID.isIp || !parsedRPID.domain)) {
    throw new SyncConfigurationError("PASSKEY_RP_ID must be a registrable domain, not an IP address or public suffix.");
  }
  if (isProduction() && isReservedProductionRPID(rpID)) {
    throw new SyncConfigurationError("PASSKEY_RP_ID must be a real, non-reserved production domain.");
  }

  const rpName = requiredInProduction("PASSKEY_RP_NAME", "Address Atlas");
  if (rpName.length > 100 || /[\u0000-\u001f\u007f]/.test(rpName)) {
    throw new SyncConfigurationError("PASSKEY_RP_NAME must be at most 100 characters and contain no control characters.");
  }

  const expectedOrigin = requiredInProduction("PASSKEY_ORIGIN", "http://localhost:3000");
  let origin: URL;
  try {
    origin = new URL(expectedOrigin);
  } catch {
    throw new SyncConfigurationError("PASSKEY_ORIGIN must be an absolute origin URL.");
  }
  // WebAuthn's insecure-origin development exception is exact localhost. IP
  // loopback literals are intentionally excluded because they are invalid RP IDs.
  const isLocalHTTP = origin.protocol === "http:"
    && rpID === LOCAL_PASSKEY_HOST
    && origin.hostname === LOCAL_PASSKEY_HOST;
  if (
    (origin.protocol !== "https:" && !isLocalHTTP)
    || origin.origin !== expectedOrigin
    || origin.username
    || origin.password
    || origin.pathname !== "/"
    || origin.search
    || origin.hash
  ) {
    throw new SyncConfigurationError("PASSKEY_ORIGIN must be an HTTPS origin (or exact HTTP localhost) without credentials, path, query, or fragment.");
  }
  if (origin.hostname !== rpID && !origin.hostname.endsWith(`.${rpID}`)) {
    throw new SyncConfigurationError("PASSKEY_ORIGIN must use PASSKEY_RP_ID or one of its subdomains.");
  }
  if (isProduction()) {
    const publicDomain = requiredInProduction("ADDRESS_ATLAS_DOMAIN", "localhost");
    if (!RP_ID_RE.test(publicDomain) || publicDomain !== publicDomain.toLowerCase() || publicDomain === "localhost") {
      throw new SyncConfigurationError(
        "ADDRESS_ATLAS_DOMAIN must be a lowercase production hostname without a scheme, port, or path."
      );
    }
    if (expectedOrigin !== `https://${publicDomain}`) {
      throw new SyncConfigurationError(
        "PASSKEY_ORIGIN must exactly equal https://ADDRESS_ATLAS_DOMAIN in production."
      );
    }
  }

  return { rpID, rpName, expectedOrigin };
}

export function getSyncDatabaseConfig(): SyncDatabaseConfig {
  const connectionString = requiredStringFromEither("SYNC_DATABASE_URL", "DATABASE_URL");
  return parseDatabaseConfig(connectionString, "SYNC_DATABASE_URL");
}

/**
 * Returns the privileged, one-shot bootstrap connection. Production bootstrap
 * deliberately requires a distinct URL so the request-serving role can remain
 * DML-only. Development keeps a convenient single-role fallback.
 */
export function getSyncSchemaDatabaseConfig(): SyncDatabaseConfig {
  const raw = process.env.SYNC_SCHEMA_DATABASE_URL;
  const configured = raw?.trim();
  if (raw !== undefined && !configured) {
    throw new SyncConfigurationError("SYNC_SCHEMA_DATABASE_URL must not be blank.");
  }
  if (!configured && isProduction()) {
    throw new SyncConfigurationError(
      "SYNC_SCHEMA_DATABASE_URL is required for production schema bootstrap."
    );
  }
  const connectionString = configured || requiredStringFromEither("SYNC_DATABASE_URL", "DATABASE_URL");
  return parseDatabaseConfig(connectionString, configured ? "SYNC_SCHEMA_DATABASE_URL" : "SYNC_DATABASE_URL");
}

function parseDatabaseConfig(connectionString: string, sourceName: string): SyncDatabaseConfig {
  let databaseURL: URL;
  try {
    databaseURL = new URL(connectionString);
  } catch {
    throw new SyncConfigurationError(`${sourceName} must be a valid Postgres URL.`);
  }
  if (
    (databaseURL.protocol !== "postgres:" && databaseURL.protocol !== "postgresql:")
    || !databaseURL.hostname
    || !databaseURL.pathname
    || databaseURL.pathname === "/"
  ) {
    throw new SyncConfigurationError(`${sourceName} must point to a Postgres database.`);
  }
  if (isProduction()) {
    let decodedUsername: string;
    let decodedPassword: string;
    let decodedDatabase: string;
    try {
      decodedUsername = decodeURIComponent(databaseURL.username);
      decodedPassword = decodeURIComponent(databaseURL.password);
      decodedDatabase = decodeURIComponent(databaseURL.pathname.slice(1));
    } catch {
      throw new SyncConfigurationError(`${sourceName} contains invalid credential or database encoding.`);
    }
    const expectedRole = sourceName === "SYNC_SCHEMA_DATABASE_URL"
      ? PRODUCTION_SCHEMA_OWNER_ROLE
      : PRODUCTION_RUNTIME_ROLE;
    if (decodedUsername !== expectedRole) {
      throw new SyncConfigurationError(
        `${sourceName} must use the fixed production role ${expectedRole}.`
      );
    }
    if (!decodedPassword || PLACEHOLDER_RE.test(decodedPassword)) {
      throw new SyncConfigurationError(`${sourceName} must include a non-placeholder username and password in production.`);
    }
    const restoreMigrationDatabase = sourceName === "SYNC_SCHEMA_DATABASE_URL"
      && process.env.ADDRESS_ATLAS_RESTORE_MIGRATION === "1"
      && process.env.SYNC_SCHEMA_MODE?.trim().toLowerCase() === "bootstrap"
      && decodedDatabase.length <= 63
      && RESTORE_MIGRATION_DATABASE_RE.test(decodedDatabase);
    if ((decodedDatabase !== PRODUCTION_DATABASE_NAME && !restoreMigrationDatabase) || databaseURL.hash) {
      throw new SyncConfigurationError(
        `${sourceName} must target the exact production database ${PRODUCTION_DATABASE_NAME} without a fragment.`
      );
    }
    const seenParameters = new Set<string>();
    for (const [name] of databaseURL.searchParams) {
      if (seenParameters.has(name) || !SAFE_PRODUCTION_DATABASE_URL_PARAMETERS.has(name)) {
        throw new SyncConfigurationError(
          `${sourceName} contains a forbidden or duplicate production URL parameter: ${name}.`
        );
      }
      seenParameters.add(name);
    }
  }

  const statementTimeoutMs = boundedIntegerFromEnv("SYNC_DB_STATEMENT_TIMEOUT_MS", 10_000, 500, 120_000);
  const queryTimeoutMs = boundedIntegerFromEnv("SYNC_DB_QUERY_TIMEOUT_MS", 12_000, 500, 120_000);
  if (queryTimeoutMs < statementTimeoutMs + 1_000) {
    throw new SyncConfigurationError(
      "SYNC_DB_QUERY_TIMEOUT_MS must be at least 1000ms greater than SYNC_DB_STATEMENT_TIMEOUT_MS."
    );
  }

  return {
    connectionString,
    poolSize: boundedIntegerFromEnv("SYNC_DB_POOL_SIZE", 10, 1, 50),
    connectTimeoutMs: boundedIntegerFromEnv("SYNC_DB_CONNECT_TIMEOUT_MS", 5_000, 500, 60_000),
    idleTimeoutMs: boundedIntegerFromEnv("SYNC_DB_IDLE_TIMEOUT_MS", 30_000, 1_000, 300_000),
    statementTimeoutMs,
    queryTimeoutMs
  };
}

export function getSyncLimitConfig(): SyncLimitConfig {
  return {
    maxAccounts: boundedIntegerFromEnv("SYNC_MAX_ACCOUNTS", 100_000, 1, 10_000_000),
    dailyVaultWriteLimit: boundedIntegerFromEnv("SYNC_VAULT_DAILY_WRITE_LIMIT", 100, 1, 10_000),
    dailyVaultByteLimit: boundedIntegerFromEnv(
      "SYNC_VAULT_DAILY_BYTE_LIMIT",
      64_000_000,
      MAX_SNAPSHOT_REQUEST_BYTES,
      10_000_000_000
    ),
    globalDailyVaultIngressByteLimit: boundedIntegerFromEnv(
      "SYNC_GLOBAL_VAULT_DAILY_INGRESS_BYTE_LIMIT",
      2_000_000_000,
      MAX_SNAPSHOT_REQUEST_BYTES,
      10_000_000_000_000
    ),
    globalVaultStorageLimit: boundedIntegerFromEnv(
      "SYNC_GLOBAL_VAULT_STORAGE_LIMIT",
      10_000_000_000,
      MAX_SNAPSHOT_REQUEST_BYTES,
      10_000_000_000_000
    )
  };
}

export function getSyncRegistrationConfig(): SyncRegistrationConfig {
  return {
    enabled: strictBooleanFromEnv("SYNC_REGISTRATION_ENABLED", !isProduction()),
    hourlyLimit: boundedIntegerFromEnv("SYNC_REGISTRATION_HOURLY_LIMIT", 100, 1, 100_000)
  };
}

export function getSyncSchemaMode(): SyncSchemaMode {
  const fallback: SyncSchemaMode = isProduction() ? "validate" : "bootstrap";
  const raw = process.env.SYNC_SCHEMA_MODE;
  if (raw === undefined) return fallback;
  const value = raw.trim().toLowerCase();
  if (value !== "validate" && value !== "bootstrap") {
    throw new SyncConfigurationError("SYNC_SCHEMA_MODE must be validate or bootstrap.");
  }
  return value;
}

export function validateSyncRuntimeConfig() {
  return {
    sessionSecret: getSyncSessionSecret(),
    passkeys: getSyncPasskeyConfig(),
    database: getSyncDatabaseConfig(),
    limits: getSyncLimitConfig(),
    registration: getSyncRegistrationConfig(),
    schemaMode: getSyncSchemaMode()
  };
}

function requiredString(name: string) {
  const value = process.env[name]?.trim();
  if (!value) throw new SyncConfigurationError(`${name} is required.`);
  return value;
}

function requiredInProduction(name: string, developmentDefault: string) {
  const raw = process.env[name];
  if (raw === undefined) {
    if (isProduction()) throw new SyncConfigurationError(`${name} is required in production.`);
    return developmentDefault;
  }
  const value = raw.trim();
  if (!value) throw new SyncConfigurationError(`${name} must not be blank.`);
  return value;
}

function requiredStringFromEither(primary: string, fallback: string) {
  const primaryValue = process.env[primary];
  if (primaryValue !== undefined) {
    const value = primaryValue.trim();
    if (!value) throw new SyncConfigurationError(`${primary} must not be blank.`);
    return value;
  }
  return requiredString(fallback);
}

function boundedIntegerFromEnv(name: string, fallback: number, min: number, max: number) {
  const raw = process.env[name];
  if (raw === undefined) return fallback;
  if (!raw.trim()) {
    throw new SyncConfigurationError(`${name} must be an integer between ${min} and ${max}.`);
  }
  const parsed = Number(raw);
  if (!Number.isSafeInteger(parsed) || parsed < min || parsed > max) {
    throw new SyncConfigurationError(`${name} must be an integer between ${min} and ${max}.`);
  }
  return parsed;
}

function strictBooleanFromEnv(name: string, fallback: boolean) {
  const raw = process.env[name];
  if (raw === undefined) return fallback;
  const value = raw.trim().toLowerCase();
  if (value === "true") return true;
  if (value === "false") return false;
  throw new SyncConfigurationError(`${name} must be true or false.`);
}

function isProduction() {
  return process.env.NODE_ENV === "production";
}

function isReservedProductionRPID(rpID: string) {
  if (!rpID.includes(".")) return true;
  if (/(?:^|\.)(?:example|invalid|test)$/.test(rpID)) return true;
  return RESERVED_PRODUCTION_RP_SUFFIXES.some(
    (reserved) => rpID === reserved || rpID.endsWith(`.${reserved}`)
  );
}
