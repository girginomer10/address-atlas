import { NextResponse } from "next/server";
import { validateSyncRuntimeConfig } from "@/lib/sync/config";
import { getNativeEndpointConfig } from "@/lib/sync/native-config";
import { ensureSyncSchema, getSyncPool } from "@/lib/sync/postgres";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const DATABASE_READINESS_CACHE_MS = 1_000;
let databaseReadyUntil = 0;
let databaseReadinessInFlight: Promise<void> | null = null;

export async function GET() {
  try {
    validateSyncRuntimeConfig();
    getNativeEndpointConfig();
    await ensureSyncSchema();
    await checkDatabaseReadiness();
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

async function checkDatabaseReadiness() {
  if (Date.now() < databaseReadyUntil) return;
  if (databaseReadinessInFlight) {
    await databaseReadinessInFlight;
    return;
  }

  const attempt = getSyncPool().query("SELECT 1 AS ready").then(() => {
    databaseReadyUntil = Date.now() + DATABASE_READINESS_CACHE_MS;
  });
  databaseReadinessInFlight = attempt;
  try {
    await attempt;
  } finally {
    if (databaseReadinessInFlight === attempt) databaseReadinessInFlight = null;
  }
}

export function resetHealthReadinessForTests() {
  databaseReadyUntil = 0;
  databaseReadinessInFlight = null;
}
