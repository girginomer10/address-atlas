import { NextRequest, NextResponse } from "next/server";
import {
  parsePasskeyVerifyInput,
  PasskeyInputError,
  PasskeyVerificationError,
  verifyPasskey
} from "@/lib/sync/passkeys";
import { clientKey, rateLimitMany } from "@/lib/sync/rate-limit";
import { readLimitedJSON, RequestBodyError } from "@/lib/sync/request";
import { TokenValidationError } from "@/lib/sync/tokens";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";
const NO_STORE_HEADERS = { "cache-control": "no-store" };

export async function POST(request: NextRequest) {
  try {
    const client = clientKey(request);
    if (!rateLimitMany([
      { key: "auth-body:global", limit: 2_400, windowMs: 60_000 },
      { key: `auth-body:client:${client}`, limit: 120, windowMs: 60_000 }
    ])) {
      return rateLimitedResponse();
    }

    const { value } = await readLimitedJSON(request, 128_000);
    const input = parsePasskeyVerifyInput(value);
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
      return rateLimitedResponse();
    }
    return NextResponse.json(await verifyPasskey(input), { headers: NO_STORE_HEADERS });
  } catch (error) {
    const expected = error instanceof RequestBodyError
      || error instanceof PasskeyInputError
      || error instanceof PasskeyVerificationError
      || error instanceof TokenValidationError;
    return NextResponse.json(
      { error: error instanceof RequestBodyError ? error.message : "Passkey verification failed." },
      {
        status: error instanceof RequestBodyError ? error.status : expected ? 400 : 500,
        headers: NO_STORE_HEADERS
      }
    );
  }
}

function rateLimitedResponse() {
  return NextResponse.json(
    { error: "Too many requests." },
    { status: 429, headers: NO_STORE_HEADERS }
  );
}
