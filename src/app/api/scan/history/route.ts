import { NextRequest, NextResponse } from "next/server";
import { clampHistoryLimit, listScanRunHistory, SCAN_HISTORY_DEFAULT_LIMIT } from "@/lib/local-store";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function GET(request: NextRequest) {
  try {
    const limitParam = request.nextUrl.searchParams.get("limit");
    const limit = clampHistoryLimit(limitParam ? Number(limitParam) : SCAN_HISTORY_DEFAULT_LIMIT);
    const entries = await listScanRunHistory(limit);
    return NextResponse.json({ entries });
  } catch (error) {
    return NextResponse.json(
      {
        error: "Scan history could not be read.",
        details: error instanceof Error ? error.message : "Unknown error"
      },
      { status: 500 }
    );
  }
}
