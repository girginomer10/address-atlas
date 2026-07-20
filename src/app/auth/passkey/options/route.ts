import { NextRequest, NextResponse } from "next/server";
import { createPasskeyOptions, parsePasskeyOptionsInput, PasskeyInputError } from "@/lib/sync/passkeys";
import { clientKey, rateLimitMany } from "@/lib/sync/rate-limit";
import { readLimitedJSON, RequestBodyError } from "@/lib/sync/request";

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

    // Apply the public quota before touching the body. Invalid content types,
    // malformed JSON, oversized streams, and shape-invalid inputs must not get
    // an unmetered parsing path.
    const { value } = await readLimitedJSON(request, 4_096);
    const input = parsePasskeyOptionsInput(value);
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
      return rateLimitedResponse();
    }
    return NextResponse.json(await createPasskeyOptions(input), { headers: NO_STORE_HEADERS });
  } catch (error) {
    const expected = error instanceof RequestBodyError || error instanceof PasskeyInputError;
    return NextResponse.json(
      { error: expected ? error.message : "Passkey options failed." },
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
