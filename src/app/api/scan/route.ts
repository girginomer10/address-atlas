import { NextRequest, NextResponse } from "next/server";
import { parseAddressInput, scanAddresses } from "@/lib/scanner";

export const dynamic = "force-dynamic";

export async function POST(request: NextRequest) {
  try {
    const body = (await request.json()) as { addresses?: string | string[] };
    const addresses = parseAddressInput(body.addresses ?? "");

    if (addresses.length === 0) {
      return NextResponse.json(
        { error: "At least one wallet address is required." },
        { status: 400 }
      );
    }

    const result = await scanAddresses(addresses);
    return NextResponse.json(result);
  } catch (error) {
    return NextResponse.json(
      {
        error: "Scan failed.",
        details: error instanceof Error ? error.message : "Unknown error"
      },
      { status: 500 }
    );
  }
}
