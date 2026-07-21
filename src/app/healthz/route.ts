import { performance } from "node:perf_hooks";
import { NextResponse } from "next/server";
import { validateSyncRuntimeConfig } from "@/lib/sync/config";
import {
  diagnosticHeaders,
  generatedDiagnostics,
  operationalErrorCode,
  type OperationalErrorCode,
  recordSecurityEvent,
  requestDiagnostics
} from "@/lib/sync/diagnostics";
import { getNativeEndpointConfig } from "@/lib/sync/native-config";
import { checkSyncSchemaReadiness, ensureSyncSchema } from "@/lib/sync/postgres";
import {
  scheduleStorageLedgerIntegrityAudit,
  resetStorageLedgerIntegrityForTests
} from "@/lib/sync/storage-ledger-integrity";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

let readinessInFlight: Promise<void> | null = null;
let readinessCache: { ready: boolean; expiresAt: number } | null = null;
const READY_TTL_MS = 10_000;
const NOT_READY_TTL_MS = 1_000;

export async function GET(request?: Request) {
  const diagnostics = request
    ? requestDiagnostics(request, "/healthz")
    : generatedDiagnostics("/healthz");
  try {
    await checkReadiness(diagnostics);
    return NextResponse.json(
      { ok: true, service: "address-atlas-sync" },
      { headers: diagnosticHeaders(diagnostics, { "cache-control": "no-store" }) }
    );
  } catch {
    return NextResponse.json(
      { ok: false, service: "address-atlas-sync" },
      {
        status: 503,
        headers: diagnosticHeaders(diagnostics, { "cache-control": "no-store" })
      }
    );
  }
}

async function checkReadiness(diagnostics: ReturnType<typeof requestDiagnostics>) {
  const cached = readinessCache;
  if (cached && performance.now() < cached.expiresAt) {
    if (cached.ready) return;
    throw new Error("Readiness is temporarily cached as unavailable.");
  }
  if (readinessInFlight) {
    await readinessInFlight;
    return;
  }

  const attempt = (async () => {
    let failureCode: OperationalErrorCode = "configuration_invalid";
    try {
      validateSyncRuntimeConfig();
      failureCode = "native_config_invalid";
      getNativeEndpointConfig();
      failureCode = "migration_failed";
      await ensureSyncSchema();
      failureCode = "schema_contract_invalid";
      await checkSyncSchemaReadiness();
      // The exact ledger scan is deliberately off the readiness latency path.
      // A confirmed drift persists a marker that blocks vault writes without
      // taking authentication or encrypted reads out of service.
      scheduleStorageLedgerIntegrityAudit(diagnostics);
      readinessCache = {
        ready: true,
        expiresAt: performance.now() + READY_TTL_MS
      };
    } catch (error) {
      readinessCache = {
        ready: false,
        expiresAt: performance.now() + NOT_READY_TTL_MS
      };
      // Log once per real readiness attempt. Concurrent waiters and requests
      // served from the negative cache must not amplify an outage into one
      // error record per probe.
      recordSecurityEvent("health.not_ready", diagnostics, {
        status: 503,
        reason: "runtime_or_database_not_ready",
        errorCode: operationalErrorCode(error, failureCode),
        severity: "error"
      });
      throw error;
    }
  })();
  readinessInFlight = attempt;
  try {
    await attempt;
  } finally {
    if (readinessInFlight === attempt) readinessInFlight = null;
  }
}

export function resetHealthReadinessForTests() {
  readinessInFlight = null;
  readinessCache = null;
  resetStorageLedgerIntegrityForTests();
}
