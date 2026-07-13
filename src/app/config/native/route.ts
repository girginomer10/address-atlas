import { NextResponse } from "next/server";
import { getNativeEndpointConfig } from "@/lib/sync/native-config";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function GET() {
  try {
    return NextResponse.json(getNativeEndpointConfig(), {
      headers: {
        "cache-control": "public, max-age=300"
      }
    });
  } catch {
    return NextResponse.json(
      { error: "Native configuration unavailable." },
      { status: 503, headers: { "cache-control": "no-store" } }
    );
  }
}
