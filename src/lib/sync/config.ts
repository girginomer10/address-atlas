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
  globalVaultStorageLimit: number;
}

const PLACEHOLDER_RE = /(replace[-_ ]?with|change[-_ ]?me|example|your[-_ ]?secret|password)/i;
const RP_ID_RE = /^(?:localhost|(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)$/;
const RESERVED_PRODUCTION_RP_SUFFIXES = ["example.com", "example.net", "example.org"];
const LOCAL_PASSKEY_HOST = "localhost";

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
  let databaseURL: URL;
  try {
    databaseURL = new URL(connectionString);
  } catch {
    throw new SyncConfigurationError("SYNC_DATABASE_URL must be a valid Postgres URL.");
  }
  if (
    (databaseURL.protocol !== "postgres:" && databaseURL.protocol !== "postgresql:")
    || !databaseURL.hostname
    || !databaseURL.pathname
    || databaseURL.pathname === "/"
  ) {
    throw new SyncConfigurationError("SYNC_DATABASE_URL must point to a Postgres database.");
  }
  if (isProduction()) {
    let decodedPassword: string;
    try {
      decodedPassword = decodeURIComponent(databaseURL.password);
    } catch {
      throw new SyncConfigurationError("SYNC_DATABASE_URL contains invalid password encoding.");
    }
    if (!databaseURL.username || !decodedPassword || PLACEHOLDER_RE.test(decodedPassword)) {
      throw new SyncConfigurationError("SYNC_DATABASE_URL must include a non-placeholder username and password in production.");
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
    globalVaultStorageLimit: boundedIntegerFromEnv(
      "SYNC_GLOBAL_VAULT_STORAGE_LIMIT",
      10_000_000_000,
      MAX_SNAPSHOT_REQUEST_BYTES,
      10_000_000_000_000
    )
  };
}

export function validateSyncRuntimeConfig() {
  return {
    sessionSecret: getSyncSessionSecret(),
    passkeys: getSyncPasskeyConfig(),
    database: getSyncDatabaseConfig(),
    limits: getSyncLimitConfig()
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
