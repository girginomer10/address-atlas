import { NextResponse } from "next/server";
import { getNativeEndpointConfig } from "@/lib/sync/native-config";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function GET() {
  return NextResponse.json(getNativeEndpointConfig(), {
    headers: {
      "cache-control": "public, max-age=300"
    }
  });
}
