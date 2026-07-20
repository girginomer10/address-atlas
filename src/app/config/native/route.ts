import { NextResponse } from "next/server";
import { getNativeEndpointConfig } from "@/lib/sync/native-config";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

// force-dynamic paired with "cache-control: public, max-age=300" is
// intentional: Next's own route cache is disabled so every origin hit
// re-reads the env-driven config, while CDNs/proxies may still cache the
// response for five minutes to absorb client fan-out.
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
