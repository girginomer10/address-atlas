import { NextRequest, NextResponse } from "next/server";
import { verifyPasskey } from "@/lib/sync/passkeys";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function POST(request: NextRequest) {
  try {
    const body = await request.json().catch(() => ({}));
    return NextResponse.json(await verifyPasskey(body));
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Passkey verification failed." },
      { status: 400 }
    );
  }
}
