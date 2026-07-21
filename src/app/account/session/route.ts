import { NextRequest, NextResponse } from "next/server";
import { AuthenticationDatabaseCapacityError } from "@/lib/sync/auth-database-concurrency";
import {
  diagnosticHeaders,
  recordSecurityEvent,
  requestDiagnostics
} from "@/lib/sync/diagnostics";
import { clientKey, rateLimitMany } from "@/lib/sync/rate-limit";
import { revokeBearerSession } from "@/lib/sync/sessions";
import { TokenValidationError } from "@/lib/sync/tokens";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function DELETE(request: NextRequest) {
  const diagnostics = requestDiagnostics(request, "/account/session");
  const client = clientKey(request);
  if (!rateLimitMany([
    { key: "session-revoke:global", limit: 300, windowMs: 60_000 },
    { key: `session-revoke:client:${client}`, limit: 10, windowMs: 60_000 }
  ])) {
    recordSecurityEvent("auth.rate_limited", diagnostics, {
      status: 429,
      reason: "session_revocation_rate_limit"
    });
    return NextResponse.json(
      { error: "Too many requests." },
      {
        status: 429,
        headers: diagnosticHeaders(diagnostics, {
          "cache-control": "no-store",
          "retry-after": "60"
        })
      }
    );
  }
  try {
    await revokeBearerSession(request.headers.get("authorization"), client);
    recordSecurityEvent("session.revoked", diagnostics, {
      status: 200,
      reason: "self_service",
      severity: "info"
    });
    return NextResponse.json(
      { ok: true },
      { headers: diagnosticHeaders(diagnostics, { "cache-control": "no-store" }) }
    );
  } catch (error) {
    const capacityFailure = error instanceof AuthenticationDatabaseCapacityError;
    const authenticationFailure = error instanceof TokenValidationError;
    const status = capacityFailure ? 429 : authenticationFailure ? 401 : 500;
    recordSecurityEvent(capacityFailure ? "auth.rate_limited" : "session.rejected", diagnostics, {
      status,
      reason: capacityFailure
        ? "session_revocation_database_concurrency_limit"
        : authenticationFailure ? "invalid_session" : "internal_error",
      severity: status >= 500 ? "error" : "warn"
    });
    return NextResponse.json(
      {
        error: capacityFailure
          ? "Too many requests."
          : authenticationFailure ? "Authentication required." : "Session could not be revoked."
      },
      {
        status,
        headers: diagnosticHeaders(diagnostics, {
          "cache-control": "no-store",
          ...(capacityFailure ? { "retry-after": "1" } : {})
        })
      }
    );
  }
}
