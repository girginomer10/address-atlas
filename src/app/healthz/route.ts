import { NextResponse } from "next/server";
import { validateSyncRuntimeConfig } from "@/lib/sync/config";
import { getNativeEndpointConfig } from "@/lib/sync/native-config";
import { checkSyncSchemaReadiness, ensureSyncSchema } from "@/lib/sync/postgres";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

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
  if (databaseReadinessInFlight) {
    await databaseReadinessInFlight;
    return;
  }

  const attempt = checkSyncSchemaReadiness();
  databaseReadinessInFlight = attempt;
  try {
    await attempt;
  } finally {
    if (databaseReadinessInFlight === attempt) databaseReadinessInFlight = null;
  }
}

export function resetHealthReadinessForTests() {
  databaseReadinessInFlight = null;
}
