import { NextRequest, NextResponse } from "next/server";
import { testExchangeCredentials } from "@/lib/exchanges";
import { ExchangeCredentialInput } from "@/lib/types";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function POST(request: NextRequest) {
  try {
    const body = (await request.json()) as ExchangeCredentialInput;
    const result = await testExchangeCredentials(body);
    return NextResponse.json({ ok: true, result });
  } catch (error) {
    return NextResponse.json(
      {
        ok: false,
        error: error instanceof Error ? error.message : "Exchange test failed."
      },
      { status: 400 }
    );
  }
}
