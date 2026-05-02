import { NextResponse } from "next/server";
import { getUsdFxRates, SUPPORTED_DISPLAY_CURRENCIES } from "@/lib/fx";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function GET() {
  try {
    const rates = await getUsdFxRates();
    return NextResponse.json({
      base: "USD",
      generatedAt: new Date().toISOString(),
      supported: SUPPORTED_DISPLAY_CURRENCIES,
      rates
    });
  } catch (error) {
    return NextResponse.json(
      {
        error: "FX rates could not be loaded.",
        details: error instanceof Error ? error.message : "Unknown error",
        base: "USD",
        generatedAt: new Date().toISOString(),
        supported: SUPPORTED_DISPLAY_CURRENCIES,
        rates: { USD: 1 }
      },
      { status: 502 }
    );
  }
}
