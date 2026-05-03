import { NextRequest, NextResponse } from "next/server";
import { lookupTokenMetadata } from "@/lib/token-metadata";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function GET(request: NextRequest) {
  try {
    const metadata = await lookupTokenMetadata({
      chainKind: request.nextUrl.searchParams.get("chainKind") ?? undefined,
      chainId: request.nextUrl.searchParams.get("chainId") ?? undefined,
      address: request.nextUrl.searchParams.get("address") ?? undefined
    });
    return NextResponse.json({ metadata });
  } catch (error) {
    return NextResponse.json(
      {
        error: error instanceof Error ? error.message : "Token metadata could not be loaded."
      },
      { status: 400 }
    );
  }
}
