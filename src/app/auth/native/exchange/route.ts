import { NextRequest, NextResponse } from "next/server";
import {
  diagnosticHeaders,
  operationalErrorCode,
  recordSecurityEvent,
  requestDiagnostics
} from "@/lib/sync/diagnostics";
import {
  exchangeNativeAuthorization,
  nativeAuthorizationConsumptionKey,
  parseNativeAuthorizationExchangeInput,
  NativeAuthorizationExchangeError
} from "@/lib/sync/native-authorization";
import { getSyncDatabasePoolSize } from "@/lib/sync/config";
import { clientKey, rateLimitMany } from "@/lib/sync/rate-limit";
import { readLimitedJSON, RequestBodyError } from "@/lib/sync/request";
import { acquirePasskeyBodyConcurrency } from "@/app/auth/passkey/body-concurrency";
import {
  acquireNativeAuthorizationExchangeConcurrency
} from "@/app/auth/passkey/verification-concurrency";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const NO_STORE_HEADERS = { "cache-control": "no-store" };
const EXCHANGE_BODY_LIMIT_BYTES = 8_192;
const EXCHANGE_BODY_DEADLINE_MS = 5_000;

export async function POST(request: NextRequest) {
  const diagnostics = requestDiagnostics(request, "/auth/native/exchange");
  try {
    const client = clientKey(request);
    if (!rateLimitMany([
      { key: "native-exchange:global", limit: 600, windowMs: 60_000 },
      { key: `native-exchange:client:${client}`, limit: 30, windowMs: 60_000 }
    ])) {
      recordSecurityEvent("auth.rate_limited", diagnostics, {
        status: 429,
        reason: "native_exchange_rate_limit"
      });
      return rateLimitedResponse(diagnostics);
    }
    if (request.signal.aborted) return cancelledResponse(diagnostics);

    const bodyPermit = acquirePasskeyBodyConcurrency(client);
    if (!bodyPermit) {
      recordSecurityEvent("auth.rate_limited", diagnostics, {
        status: 429,
        reason: "native_exchange_body_concurrency_limit"
      });
      return rateLimitedResponse(diagnostics, 1);
    }
    let value: unknown;
    try {
      ({ value } = await readLimitedJSON(
        request,
        EXCHANGE_BODY_LIMIT_BYTES,
        EXCHANGE_BODY_DEADLINE_MS
      ));
    } finally {
      bodyPermit();
    }
    if (request.signal.aborted) return cancelledResponse(diagnostics);
    const input = parseNativeAuthorizationExchangeInput(value);
    const exchangePermit = acquireNativeAuthorizationExchangeConcurrency(
      client,
      nativeAuthorizationConsumptionKey(input.authorizationCode),
      getSyncDatabasePoolSize()
    );
    if (!exchangePermit) {
      recordSecurityEvent("auth.rate_limited", diagnostics, {
        status: 429,
        reason: "native_exchange_database_concurrency_limit"
      });
      return rateLimitedResponse(diagnostics, 1);
    }
    let result: Awaited<ReturnType<typeof exchangeNativeAuthorization>>;
    try {
      if (request.signal.aborted) return cancelledResponse(diagnostics);
      result = await exchangeNativeAuthorization(input);
    } finally {
      exchangePermit();
    }
    recordSecurityEvent("auth.native_exchange_succeeded", diagnostics, {
      status: 200,
      reason: "authorization_code_exchanged",
      severity: "info"
    });
    return NextResponse.json(result, {
      headers: diagnosticHeaders(diagnostics, NO_STORE_HEADERS)
    });
  } catch (error) {
    const requestError = error instanceof RequestBodyError;
    const rejected = error instanceof NativeAuthorizationExchangeError;
    const status = requestError ? error.status : rejected ? 400 : 500;
    recordSecurityEvent("auth.native_exchange_failed", diagnostics, {
      status,
      reason: requestError
        ? "invalid_exchange_request"
        : rejected
          ? "authorization_code_rejected"
          : "internal_error",
      ...(status >= 500
        ? { errorCode: operationalErrorCode(error, "unknown_internal_error") }
        : {}),
      severity: status >= 500 ? "error" : "warn"
    });
    return NextResponse.json(
      {
        error: requestError
          ? error.message
          : "Native authorization exchange failed."
      },
      {
        status,
        headers: diagnosticHeaders(diagnostics, NO_STORE_HEADERS)
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
