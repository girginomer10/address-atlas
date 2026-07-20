import { randomUUID } from "node:crypto";

const REQUEST_ID_RE = /^[A-Za-z0-9_-]{8,64}$/;

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
  | "vault.conflict"
  | "vault.load_failed"
  | "vault.quota_exceeded"
  | "vault.request_rejected"
  | "vault.storage_exhausted"
  | "vault.write_failed";

export interface SecurityEventDetails {
  status: number;
  reason: string;
  mode?: "authenticate" | "register";
  severity?: "info" | "warn" | "error";
}

/**
 * Accept only a deliberately narrow request-id alphabet. Proxy-provided IDs
 * remain useful for correlation without allowing control characters or large
 * attacker strings into logs. Invalid/missing IDs are replaced locally.
 */
export function requestDiagnostics(request: Request, route: string): RequestDiagnostics {
  const supplied = request.headers.get("x-request-id")?.trim();
  return {
    requestId: supplied && REQUEST_ID_RE.test(supplied) ? supplied : randomUUID(),
    route
  };
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
