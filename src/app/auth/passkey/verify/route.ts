import { NextRequest, NextResponse } from "next/server";
import {
  parsePasskeyVerifyInput,
  PasskeyInputError,
  PasskeyVerificationError,
  verifyPasskey
} from "@/lib/sync/passkeys";
import { getSyncDatabasePoolSize } from "@/lib/sync/config";
import {
  diagnosticHeaders,
  operationalErrorCode,
  recordSecurityEvent,
  requestDiagnostics
} from "@/lib/sync/diagnostics";
import { clientKey, rateLimitMany } from "@/lib/sync/rate-limit";
import {
  RegistrationAdmissionQuotaError,
  RegistrationDisabledError
} from "@/lib/sync/registration";
import { readLimitedJSON, RequestBodyError } from "@/lib/sync/request";
import { TokenValidationError } from "@/lib/sync/tokens";
import {
  acquirePasskeyBodyConcurrency,
  PASSKEY_BODY_DEADLINE_MS
} from "../body-concurrency";
import { acquirePasskeyVerificationConcurrency } from "../verification-concurrency";

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

    const bodyPermit = acquirePasskeyBodyConcurrency(client);
    if (!bodyPermit) {
      recordSecurityEvent("auth.rate_limited", diagnostics, {
        status: 429,
        reason: "auth_body_concurrency_limit"
      });
      return rateLimitedResponse(diagnostics, 1);
    }
    let value: unknown;
    try {
      ({ value } = await readLimitedJSON(request, 128_000, PASSKEY_BODY_DEADLINE_MS));
    } finally {
      // Do not hold a scarce body-reader slot while verification touches the
      // authenticator library and durable state.
      bodyPermit();
    }
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
      return rateLimitedResponse(diagnostics, input.mode === "register" ? 3_600 : 60);
    }
    if (request.signal.aborted) return cancelledResponse(diagnostics);
    const verificationPermit = acquirePasskeyVerificationConcurrency(
      client,
      input.response.id,
      getSyncDatabasePoolSize()
    );
    if (!verificationPermit) {
      recordSecurityEvent("auth.rate_limited", diagnostics, {
        status: 429,
        reason: "auth_verification_concurrency_limit",
        mode: input.mode
      });
      return rateLimitedResponse(diagnostics, 1);
    }
    let result: Awaited<ReturnType<typeof verifyPasskey>>;
    try {
      if (request.signal.aborted) return cancelledResponse(diagnostics);
      result = await verifyPasskey(input);
    } finally {
      verificationPermit();
    }
    recordSecurityEvent(
      input.mode === "register" ? "auth.registration_succeeded" : "auth.authentication_succeeded",
      diagnostics,
      { status: 200, reason: "verified", mode: input.mode, severity: "info" }
    );
    return NextResponse.json(result, { headers: diagnosticHeaders(diagnostics, NO_STORE_HEADERS) });
  } catch (error) {
    const disabled = error instanceof RegistrationDisabledError;
    const capacity = error instanceof RegistrationAdmissionQuotaError;
    const expected = error instanceof RequestBodyError
      || error instanceof PasskeyInputError
      || error instanceof PasskeyVerificationError
      || error instanceof TokenValidationError
      || disabled
      || capacity;
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
      disabled
        ? "auth.registration_denied"
        : capacity
          ? "auth.rate_limited"
          : mode === "register"
            ? "auth.registration_failed"
            : "auth.authentication_failed",
      diagnostics,
      {
        status,
        reason: disabled
          ? "registration_disabled"
          : capacity
            ? "registration_durable_rate_limit"
            : expected
              ? "verification_rejected"
              : "internal_error",
        ...(mode ? { mode } : {}),
        ...(status >= 500
          ? { errorCode: operationalErrorCode(error, "unknown_internal_error") }
          : {}),
        severity: status >= 500 ? "error" : "warn"
      }
    );
    return NextResponse.json(
      {
        error: error instanceof RequestBodyError || disabled || capacity
          ? error.message
          : "Passkey verification failed."
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

function rateLimitedResponse(
  diagnostics: ReturnType<typeof requestDiagnostics>,
  retryAfterSeconds = 60
) {
  return NextResponse.json(
    { error: "Too many requests." },
    {
      status: 429,
      headers: diagnosticHeaders(diagnostics, {
        ...NO_STORE_HEADERS,
        "retry-after": String(retryAfterSeconds)
      })
    }
  );
}

function cancelledResponse(diagnostics: ReturnType<typeof requestDiagnostics>) {
  return NextResponse.json(
    { error: "Request cancelled." },
    {
      status: 408,
      headers: diagnosticHeaders(diagnostics, NO_STORE_HEADERS)
    }
  );
}
