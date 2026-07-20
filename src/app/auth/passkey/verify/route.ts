import { NextRequest, NextResponse } from "next/server";
import {
  parsePasskeyVerifyInput,
  PasskeyInputError,
  PasskeyVerificationError,
  verifyPasskey
} from "@/lib/sync/passkeys";
import {
  diagnosticHeaders,
  recordSecurityEvent,
  requestDiagnostics
} from "@/lib/sync/diagnostics";
import { clientKey, rateLimitMany } from "@/lib/sync/rate-limit";
import { RegistrationDisabledError } from "@/lib/sync/registration";
import { readLimitedJSON, RequestBodyError } from "@/lib/sync/request";
import { TokenValidationError } from "@/lib/sync/tokens";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";
const NO_STORE_HEADERS = { "cache-control": "no-store" };

export async function POST(request: NextRequest) {
  const diagnostics = requestDiagnostics(request, "/auth/passkey/verify");
  let mode: "authenticate" | "register" | undefined;
  try {
    const client = clientKey(request);
    if (!rateLimitMany([
      { key: "auth-body:global", limit: 2_400, windowMs: 60_000 },
      { key: `auth-body:client:${client}`, limit: 120, windowMs: 60_000 }
    ])) {
      recordSecurityEvent("auth.rate_limited", diagnostics, {
        status: 429,
        reason: "auth_body_rate_limit"
      });
      return rateLimitedResponse(diagnostics);
    }

    const { value } = await readLimitedJSON(request, 128_000);
    const input = parsePasskeyVerifyInput(value);
    mode = input.mode;
    const rules = [
      { key: "auth-verify:global", limit: 600, windowMs: 60_000 },
      { key: `auth-verify:client:${client}`, limit: 30, windowMs: 60_000 }
    ];
    if (input.mode === "register") {
      rules.push(
        { key: "auth-register-verify:global", limit: 100, windowMs: 3_600_000 },
        { key: `auth-register-verify:client:${client}`, limit: 5, windowMs: 3_600_000 }
      );
    }
    if (!rateLimitMany(rules)) {
      recordSecurityEvent("auth.rate_limited", diagnostics, {
        status: 429,
        reason: input.mode === "register" ? "registration_verify_rate_limit" : "authentication_rate_limit",
        mode: input.mode
      });
      return rateLimitedResponse(diagnostics);
    }
    const result = await verifyPasskey(input);
    recordSecurityEvent(
      input.mode === "register" ? "auth.registration_succeeded" : "auth.authentication_succeeded",
      diagnostics,
      { status: 200, reason: "verified", mode: input.mode, severity: "info" }
    );
    return NextResponse.json(result, { headers: diagnosticHeaders(diagnostics, NO_STORE_HEADERS) });
  } catch (error) {
    const disabled = error instanceof RegistrationDisabledError;
    const expected = error instanceof RequestBodyError
      || error instanceof PasskeyInputError
      || error instanceof PasskeyVerificationError
      || error instanceof TokenValidationError
      || disabled;
    const status = error instanceof RequestBodyError ? error.status : disabled ? 403 : expected ? 400 : 500;
    recordSecurityEvent(
      disabled ? "auth.registration_denied" : mode === "register" ? "auth.registration_failed" : "auth.authentication_failed",
      diagnostics,
      {
        status,
        reason: disabled ? "registration_disabled" : expected ? "verification_rejected" : "internal_error",
        ...(mode ? { mode } : {}),
        severity: status >= 500 ? "error" : "warn"
      }
    );
    return NextResponse.json(
      {
        error: error instanceof RequestBodyError || disabled
          ? error.message
          : "Passkey verification failed."
      },
      {
        status,
        headers: diagnosticHeaders(diagnostics, NO_STORE_HEADERS)
      }
    );
  }
}

function rateLimitedResponse(diagnostics: ReturnType<typeof requestDiagnostics>) {
  return NextResponse.json(
    { error: "Too many requests." },
    {
      status: 429,
      headers: diagnosticHeaders(diagnostics, { ...NO_STORE_HEADERS, "retry-after": "60" })
    }
  );
}
