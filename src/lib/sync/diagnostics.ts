import { randomUUID } from "node:crypto";

export interface RequestDiagnostics {
  requestId: string;
  route: string;
}

export type SecurityEvent =
  | "account.deleted"
  | "account.deletion_rejected"
  | "account.deletion_rate_limited"
  | "auth.authentication_failed"
  | "auth.authentication_succeeded"
  | "auth.challenge_prune_failed"
  | "auth.rate_limited"
  | "auth.registration_denied"
  | "auth.registration_failed"
  | "auth.registration_succeeded"
  | "config.unavailable"
  | "database.connection_failed"
  | "health.not_ready"
  | "restore.readiness_failed"
  | "restore.readiness_succeeded"
  | "session.rejected"
  | "session.revoked"
  | "schema.bootstrap_failed"
  | "schema.bootstrap_succeeded"
  | "storage.ledger_audit_failed"
  | "storage.ledger_drift_detected"
  | "storage.ledger_integrity_restored"
  | "vault.conflict"
  | "vault.load_failed"
  | "vault.quota_exceeded"
  | "vault.request_rejected"
  | "vault.storage_exhausted"
  | "vault.storage_integrity_blocked"
  | "vault.write_failed";

export type OperationalErrorCode =
  | "configuration_invalid"
  | "database_connection_failed"
  | "database_query_failed"
  | "migration_failed"
  | "native_config_invalid"
  | "passkey_credential_invalid"
  | "restore_context_invalid"
  | "schema_contract_invalid"
  | "storage_ledger_invalid"
  | "unknown_internal_error"
  | "vault_snapshot_invalid";

const OPERATIONAL_ERROR_CODES = new Set<OperationalErrorCode>([
  "configuration_invalid",
  "database_connection_failed",
  "database_query_failed",
  "migration_failed",
  "native_config_invalid",
  "passkey_credential_invalid",
  "restore_context_invalid",
  "schema_contract_invalid",
  "storage_ledger_invalid",
  "unknown_internal_error",
  "vault_snapshot_invalid"
]);

const CONNECTION_ERROR_CODES = new Set([
  "CONNECTION_ENDED",
  "CONNECTION_TIMEOUT",
  "EAI_AGAIN",
  "ECONNREFUSED",
  "ECONNRESET",
  "EHOSTUNREACH",
  "ENOTFOUND",
  "ENETUNREACH",
  "ETIMEDOUT",
  "57P02",
  "57P03"
]);

/** An internal error with a stable code that is safe to emit to operations logs. */
export class OperationalError extends Error {
  constructor(
    readonly operationalCode: OperationalErrorCode,
    message: string
  ) {
    super(message);
    this.name = "OperationalError";
  }
}

/**
 * Reduce arbitrary failures to an allow-listed operational category. Raw
 * exception messages and database error details never enter structured logs.
 */
export function operationalErrorCode(
  error: unknown,
  fallback: OperationalErrorCode
): OperationalErrorCode {
  if (error && typeof error === "object") {
    const candidate = (error as { operationalCode?: unknown }).operationalCode;
    if (typeof candidate === "string" && isOperationalErrorCode(candidate)) {
      return candidate;
    }

    const databaseCode = (error as { code?: unknown }).code;
    if (typeof databaseCode === "string") {
      if (
        CONNECTION_ERROR_CODES.has(databaseCode)
        || databaseCode.startsWith("08")
        || databaseCode === "28P01"
        || databaseCode === "57P01"
      ) {
        return "database_connection_failed";
      }
      // PostgreSQL SQLSTATE values are five upper-case alphanumeric bytes.
      if (/^[0-9A-Z]{5}$/.test(databaseCode)) return "database_query_failed";
    }
  }
  return fallback;
}

function isOperationalErrorCode(value: string): value is OperationalErrorCode {
  return OPERATIONAL_ERROR_CODES.has(value as OperationalErrorCode);
}

export interface SecurityEventDetails {
  status: number;
  reason: string;
  errorCode?: OperationalErrorCode;
  mode?: "authenticate" | "register";
  severity?: "info" | "warn" | "error";
}

/**
 * Generate request IDs inside the application trust boundary. The current
 * public proxy does not overwrite X-Request-ID, so accepting even a tightly
 * shaped client value would still let arbitrary encoded request data enter
 * structured operational logs.
 */
export function requestDiagnostics(_request: Request, route: string): RequestDiagnostics {
  return { requestId: randomUUID(), route };
}

export function generatedDiagnostics(route: string): RequestDiagnostics {
  return { requestId: randomUUID(), route };
}

export function diagnosticHeaders(
  context: RequestDiagnostics,
  headers: Record<string, string> = {}
) {
  return { ...headers, "x-request-id": context.requestId };
}

/**
 * Emit an allow-listed, privacy-safe JSON record. Callers cannot attach raw
 * request data, IPs, user identifiers, tokens, credential IDs, WebAuthn
 * responses, or vault bodies by construction.
 */
export function recordSecurityEvent(
  event: SecurityEvent,
  context: RequestDiagnostics,
  details: SecurityEventDetails
) {
  const record = JSON.stringify({
    timestamp: new Date().toISOString(),
    service: "address-atlas-sync",
    event,
    severity: details.severity ?? (details.status >= 500 ? "error" : "warn"),
    requestId: context.requestId,
    route: context.route,
    status: details.status,
    reason: details.reason,
    ...(details.errorCode ? { errorCode: details.errorCode } : {}),
    ...(details.mode ? { mode: details.mode } : {})
  });
  const severity = details.severity ?? (details.status >= 500 ? "error" : "warn");
  if (severity === "error") {
    console.error(record);
  } else if (severity === "info") {
    console.info(record);
  } else {
    console.warn(record);
  }
}
