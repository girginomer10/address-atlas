import { NextRequest, NextResponse } from "next/server";
import { createPasskeyOptions, parsePasskeyOptionsInput, PasskeyInputError } from "@/lib/sync/passkeys";
import {
  diagnosticHeaders,
  recordSecurityEvent,
  requestDiagnostics
} from "@/lib/sync/diagnostics";
import { clientKey, rateLimitMany } from "@/lib/sync/rate-limit";
import { RegistrationAdmissionQuotaError, RegistrationDisabledError } from "@/lib/sync/registration";
import { readLimitedJSON, RequestBodyError } from "@/lib/sync/request";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";
const NO_STORE_HEADERS = { "cache-control": "no-store" };

export async function POST(request: NextRequest) {
  const diagnostics = requestDiagnostics(request, "/auth/passkey/options");
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

    // Apply the public quota before touching the body. Invalid content types,
    // malformed JSON, oversized streams, and shape-invalid inputs must not get
    // an unmetered parsing path.
    const { value } = await readLimitedJSON(request, 4_096);
    const input = parsePasskeyOptionsInput(value);
    mode = input.mode;
    const rules = [
      { key: "auth-options:global", limit: 600, windowMs: 60_000 },
      { key: `auth-options:client:${client}`, limit: 30, windowMs: 60_000 }
    ];
    if (input.mode === "register") {
      rules.push(
        { key: "auth-register-options:global", limit: 100, windowMs: 3_600_000 },
        { key: `auth-register-options:client:${client}`, limit: 5, windowMs: 3_600_000 }
      );
    }
    if (!rateLimitMany(rules)) {
      recordSecurityEvent("auth.rate_limited", diagnostics, {
        status: 429,
        reason: input.mode === "register" ? "registration_edge_rate_limit" : "auth_options_rate_limit",
        mode: input.mode
      });
      return rateLimitedResponse(diagnostics);
    }
    return NextResponse.json(await createPasskeyOptions(input), {
      headers: diagnosticHeaders(diagnostics, NO_STORE_HEADERS)
    });
  } catch (error) {
    const expected = error instanceof RequestBodyError || error instanceof PasskeyInputError;
    const disabled = error instanceof RegistrationDisabledError;
    const capacity = error instanceof RegistrationAdmissionQuotaError;
    const status = error instanceof RequestBodyError
      ? error.status
      : disabled
        ? 403
        : capacity
          ? 429
          : expected
            ? 400
            : 500;
    recordSecurityEvent(
      disabled ? "auth.registration_denied" : capacity ? "auth.rate_limited" : "auth.authentication_failed",
      diagnostics,
      {
        status,
        reason: disabled
          ? "registration_disabled"
          : capacity
            ? "registration_durable_rate_limit"
            : expected
              ? "invalid_request"
              : "internal_error",
        ...(mode ? { mode } : {}),
        severity: status >= 500 ? "error" : "warn"
      }
    );
    return NextResponse.json(
      {
        error: expected || disabled || capacity
          ? (error as Error).message
          : "Passkey options failed."
      },
      {
        status,
        headers: diagnosticHeaders(diagnostics, {
          ...NO_STORE_HEADERS,
          ...(capacity ? { "retry-after": "3600" } : {})
        })
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
