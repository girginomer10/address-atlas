import { NextRequest, NextResponse } from "next/server";
import { AuthenticationDatabaseCapacityError } from "@/lib/sync/auth-database-concurrency";
import {
  diagnosticHeaders,
  recordSecurityEvent,
  requestDiagnostics
} from "@/lib/sync/diagnostics";
import {
  AccountDeletionConfirmationError,
  accountDeletionKeyDigest,
  deleteBearerAccount
} from "@/lib/sync/sessions";
import { clientKey, rateLimitMany } from "@/lib/sync/rate-limit";
import { TokenValidationError } from "@/lib/sync/tokens";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function DELETE(request: NextRequest) {
  const diagnostics = requestDiagnostics(request, "/account");
  const client = clientKey(request);
  if (!rateLimitMany([
    { key: "account-delete:global", limit: 300, windowMs: 60_000 },
    { key: `account-delete:client:${client}`, limit: 10, windowMs: 60_000 }
  ])) {
    recordSecurityEvent("account.deletion_rate_limited", diagnostics, {
      status: 429,
      reason: "account_deletion_rate_limit"
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
  let idempotencyKeyDigest: Buffer;
  try {
    idempotencyKeyDigest = accountDeletionKeyDigest(request.headers.get("idempotency-key"));
  } catch {
    recordSecurityEvent("account.deletion_rejected", diagnostics, {
      status: 400,
      reason: "invalid_idempotency_key"
    });
    return NextResponse.json(
      { error: "A valid Idempotency-Key is required." },
      { status: 400, headers: diagnosticHeaders(diagnostics, { "cache-control": "no-store" }) }
    );
  }
  try {
    const deletion = await deleteBearerAccount(
      request.headers.get("authorization"),
      idempotencyKeyDigest,
      request.headers.get("x-address-atlas-confirm") === "delete-account",
      client
    );
    recordSecurityEvent("account.deleted", diagnostics, {
      status: 200,
      reason: deletion.replayed ? "idempotent_replay" : "self_service",
      severity: "info"
    });
    return NextResponse.json(
      { ok: true },
      { headers: diagnosticHeaders(diagnostics, { "cache-control": "no-store" }) }
    );
  } catch (error) {
    const confirmationFailure = error instanceof AccountDeletionConfirmationError;
    const capacityFailure = error instanceof AuthenticationDatabaseCapacityError;
    const authenticationFailure = error instanceof TokenValidationError;
    const status = confirmationFailure
      ? 400
      : capacityFailure ? 429 : authenticationFailure ? 401 : 500;
    recordSecurityEvent(
      capacityFailure
        ? "auth.rate_limited"
        : authenticationFailure ? "session.rejected" : "account.deletion_rejected",
      diagnostics,
      {
        status,
        reason: confirmationFailure
          ? "confirmation_required"
          : capacityFailure
            ? "account_deletion_database_concurrency_limit"
            : authenticationFailure ? "invalid_session" : "internal_error",
        severity: status >= 500 ? "error" : "warn"
      }
    );
    return NextResponse.json(
      {
        error: confirmationFailure
          ? "Account deletion confirmation is required."
          : capacityFailure
            ? "Too many requests."
            : authenticationFailure ? "Authentication required." : "Account could not be deleted."
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
