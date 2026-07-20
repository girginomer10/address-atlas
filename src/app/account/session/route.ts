import { NextRequest, NextResponse } from "next/server";
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
    await revokeBearerSession(request.headers.get("authorization"));
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
    const authenticationFailure = error instanceof TokenValidationError;
    recordSecurityEvent("session.rejected", diagnostics, {
      status: authenticationFailure ? 401 : 500,
      reason: authenticationFailure ? "invalid_session" : "internal_error",
      severity: authenticationFailure ? "warn" : "error"
    });
    return NextResponse.json(
      { error: authenticationFailure ? "Authentication required." : "Session could not be revoked." },
      {
        status: authenticationFailure ? 401 : 500,
        headers: diagnosticHeaders(diagnostics, { "cache-control": "no-store" })
      }
    );
  }
}
