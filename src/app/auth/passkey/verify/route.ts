import { NextRequest, NextResponse } from "next/server";
import { verifyPasskey } from "@/lib/sync/passkeys";
import { clientKey, rateLimit } from "@/lib/sync/rate-limit";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function POST(request: NextRequest) {
  try {
    if (!rateLimit(`auth:${clientKey(request)}`, 20, 60_000)) {
      return NextResponse.json({ error: "Too many requests." }, { status: 429 });
    }
    const body = await request.json().catch(() => ({}));
    return NextResponse.json(await verifyPasskey(body));
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Passkey verification failed." },
      { status: 400 }
    );
  }
}
