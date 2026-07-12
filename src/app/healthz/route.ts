import { NextResponse } from "next/server";
import { ensureSyncSchema, getSyncPool } from "@/lib/sync/postgres";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function GET() {
  try {
    await ensureSyncSchema();
    await getSyncPool().query("SELECT 1 AS ready");
    return NextResponse.json(
      { ok: true, service: "address-atlas-sync" },
      { headers: { "cache-control": "no-store" } }
    );
  } catch {
    return NextResponse.json(
      { ok: false, service: "address-atlas-sync" },
      { status: 503, headers: { "cache-control": "no-store" } }
    );
  }
}
