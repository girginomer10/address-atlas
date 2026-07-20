import { NextRequest, NextResponse } from "next/server";
import {
  assertEnvelopeChecksum,
  assertNoPlaintextLeak,
  assertRemoteVaultSnapshot,
  MAX_SNAPSHOT_REQUEST_BYTES,
  type RemoteVaultSnapshot
} from "@/lib/sync/envelope";
import { getSyncPool } from "@/lib/sync/postgres";
import {
  acquireConcurrencyMany,
  clientKey,
  rateLimitMany
} from "@/lib/sync/rate-limit";
import {
  diagnosticHeaders,
  recordSecurityEvent,
  requestDiagnostics
} from "@/lib/sync/diagnostics";
import { parseRequestJSON, readLimitedBody, RequestBodyError } from "@/lib/sync/request";
import { authenticateBearerSession } from "@/lib/sync/sessions";
import { TokenValidationError } from "@/lib/sync/tokens";
import {
  chargeVaultIngress,
  saveVaultSnapshot,
  VaultAccountMissingError,
  VaultConflictError,
  VaultQuotaError,
  VaultStorageCapacityError
} from "@/lib/sync/vault-storage";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function GET(request: NextRequest) {
  const diagnostics = requestDiagnostics(request, "/vault/latest");
  try {
    const client = clientKey(request);
    if (!rateLimitMany([
      { key: "vault-get-preflight:global", limit: 3_000, windowMs: 60_000 },
      { key: `vault-get-preflight:client:${client}`, limit: 120, windowMs: 60_000 }
    ])) {
      recordSecurityEvent("auth.rate_limited", diagnostics, {
        status: 429,
        reason: "vault_read_preflight_rate_limit"
      });
      return rateLimitedResponse(diagnostics);
    }
    // The separate public preflight bucket above bounds database work from
    // revoked-but-still-signed tokens. Live authentication then gates the
    // distinct account/global quota below, so rejected public traffic cannot
    // consume authenticated account capacity.
    const session = await authenticateBearerSession(request.headers.get("authorization"));
    if (!rateLimitMany([
      { key: "vault-get:global", limit: 3_000, windowMs: 60_000 },
      { key: `vault-get:account:${session.userId}`, limit: 120, windowMs: 60_000 }
    ])) {
      recordSecurityEvent("auth.rate_limited", diagnostics, {
        status: 429,
        reason: "vault_read_rate_limit"
      });
      return rateLimitedResponse(diagnostics);
    }
    const result = await getSyncPool().query<{
      version: number | null;
      envelope: unknown | null;
      byte_size: number | null;
      checksum: string | null;
      updated_at: Date | null;
    }>(
      `SELECT vault.version, vault.envelope, vault.byte_size, vault.checksum, vault.updated_at
       FROM users AS account
       LEFT JOIN vault_snapshots AS vault ON vault.user_id = account.id
       WHERE account.id = $1`,
      [session.userId]
    );
    const row = result.rows[0];
    if (!row) throw new VaultAccountMissingError();
    if (row.version === null) {
      return NextResponse.json(
        { error: "No vault snapshot." },
        { status: 404, headers: diagnosticHeaders(diagnostics, { "cache-control": "no-store" }) }
      );
    }
    if (
      row.envelope === null
      || row.byte_size === null
      || row.checksum === null
      || row.updated_at === null
    ) {
      throw new Error("Vault snapshot row is incomplete.");
    }
    return NextResponse.json(
      {
        version: row.version,
        envelope: row.envelope,
        byteSize: row.byte_size,
        checksum: row.checksum,
        updatedAt: row.updated_at.toISOString()
      },
      { headers: diagnosticHeaders(diagnostics, { "cache-control": "no-store" }) }
    );
  } catch (error) {
    const authenticationFailure = error instanceof TokenValidationError || error instanceof VaultAccountMissingError;
    recordSecurityEvent(authenticationFailure ? "session.rejected" : "vault.load_failed", diagnostics, {
      status: authenticationFailure ? 401 : 500,
      reason: authenticationFailure ? "invalid_session" : "internal_error",
      severity: authenticationFailure ? "warn" : "error"
    });
    return NextResponse.json(
      { error: authenticationFailure ? "Authentication required." : "Vault snapshot could not be loaded." },
      {
        status: authenticationFailure ? 401 : 500,
        headers: diagnosticHeaders(diagnostics, { "cache-control": "no-store" })
      }
    );
  }
}

export async function PUT(request: NextRequest) {
  const diagnostics = requestDiagnostics(request, "/vault/latest");
  let releaseConcurrency: (() => void) | undefined;
  try {
    const client = clientKey(request);
    if (!rateLimitMany([
      { key: "vault-put-preflight:global", limit: 300, windowMs: 60_000 },
      { key: `vault-put-preflight:client:${client}`, limit: 10, windowMs: 60_000 }
    ])) {
      recordSecurityEvent("auth.rate_limited", diagnostics, {
        status: 429,
        reason: "vault_write_preflight_rate_limit"
      });
      return rateLimitedResponse(diagnostics);
    }
    // Authenticate before reading any body bytes. Once authenticated, read and
    // durably charge ingress before applying content-type, JSON, validation,
    // replay, conflict, or in-memory rate-limit semantics.
    const session = await authenticateBearerSession(request.headers.get("authorization"));
    const concurrencyPermit = acquireConcurrencyMany([
      { key: "vault-put-active:global", limit: 8 },
      { key: `vault-put-active:client:${client}`, limit: 2 },
      { key: `vault-put-active:account:${session.userId}`, limit: 2 }
    ]);
    if (!concurrencyPermit) {
      recordSecurityEvent("auth.rate_limited", diagnostics, {
        status: 429,
        reason: "vault_write_concurrency_limit"
      });
      return rateLimitedResponse(diagnostics);
    }
    releaseConcurrency = concurrencyPermit;
    let limitedBody;
    let bodyReadError: RequestBodyError | undefined;
    try {
      limitedBody = await readLimitedBody(request, MAX_SNAPSHOT_REQUEST_BYTES);
    } catch (error) {
      if (!(error instanceof RequestBodyError)) throw error;
      bodyReadError = error;
      if (error.byteLength > 0) {
        await chargeVaultIngress(session.userId, error.byteLength);
      }
    }
    if (limitedBody) await chargeVaultIngress(session.userId, limitedBody.byteLength);

    if (!rateLimitMany([
      { key: "vault-put:global", limit: 300, windowMs: 60_000 },
      { key: `vault-put:account:${session.userId}`, limit: 10, windowMs: 60_000 }
    ])) {
      recordSecurityEvent("auth.rate_limited", diagnostics, {
        status: 429,
        reason: "vault_write_rate_limit"
      });
      return rateLimitedResponse(diagnostics);
    }
    if (bodyReadError) throw bodyReadError;
    if (!limitedBody) throw new Error("Vault request body reader returned no result.");

    const body = validateUploadedSnapshot(parseRequestJSON(request, limitedBody));
    const result = await saveVaultSnapshot(session.userId, body);
    return NextResponse.json({ ok: true, idempotent: result.idempotent }, {
      headers: diagnosticHeaders(diagnostics, { "cache-control": "no-store" })
    });
  } catch (error) {
    const status = vaultErrorStatus(error);
    recordVaultFailure(error, status, diagnostics);
    return NextResponse.json(
      { error: vaultErrorMessage(error) },
      {
        status,
        headers: diagnosticHeaders(diagnostics, {
          "cache-control": "no-store",
          ...(error instanceof VaultQuotaError ? { "retry-after": "3600" } : {})
        })
      }
    );
  } finally {
    releaseConcurrency?.();
  }
}

class VaultValidationError extends Error {}

function validateUploadedSnapshot(input: unknown): RemoteVaultSnapshot {
  try {
    assertRemoteVaultSnapshot(input);
    assertNoPlaintextLeak(input);
    assertEnvelopeChecksum(input.envelope);
    // New writes must bind account/version metadata through sync-v2 AES-GCM AAD.
    // Existing v1 rows remain readable so the current client can migrate them.
    if (input.envelope.schemaVersion !== 2 || input.envelope.cryptoVersion !== 2) {
      throw new Error("Encrypted vault uploads must use sync envelope version 2.");
    }
    return input;
  } catch (error) {
    throw new VaultValidationError(error instanceof Error ? error.message : "Invalid vault snapshot.");
  }
}

function vaultErrorStatus(error: unknown) {
  if (error instanceof TokenValidationError || error instanceof VaultAccountMissingError) return 401;
  if (error instanceof RequestBodyError) return error.status;
  if (error instanceof VaultValidationError) return 400;
  if (error instanceof VaultConflictError) return 409;
  if (error instanceof VaultQuotaError) return 429;
  if (error instanceof VaultStorageCapacityError) return 507;
  return 500;
}

function vaultErrorMessage(error: unknown) {
  if (error instanceof TokenValidationError || error instanceof VaultAccountMissingError) {
    return "Authentication required.";
  }
  if (
    error instanceof RequestBodyError
    || error instanceof VaultValidationError
    || error instanceof VaultConflictError
    || error instanceof VaultQuotaError
    || error instanceof VaultStorageCapacityError
  ) {
    return error.message;
  }
  return "Vault snapshot could not be saved.";
}

function recordVaultFailure(
  error: unknown,
  status: number,
  diagnostics: ReturnType<typeof requestDiagnostics>
) {
  if (error instanceof TokenValidationError || error instanceof VaultAccountMissingError) {
    recordSecurityEvent("session.rejected", diagnostics, {
      status,
      reason: "invalid_session"
    });
  } else if (error instanceof VaultQuotaError) {
    recordSecurityEvent("vault.quota_exceeded", diagnostics, {
      status,
      reason: "durable_ingress_or_write_quota"
    });
  } else if (error instanceof VaultConflictError) {
    recordSecurityEvent("vault.conflict", diagnostics, {
      status,
      reason: "stale_version",
      severity: "info"
    });
  } else if (error instanceof VaultStorageCapacityError) {
    recordSecurityEvent("vault.storage_exhausted", diagnostics, {
      status,
      reason: "storage_capacity"
    });
  } else if (error instanceof RequestBodyError || error instanceof VaultValidationError) {
    recordSecurityEvent("vault.request_rejected", diagnostics, {
      status,
      reason: error instanceof RequestBodyError ? "invalid_body" : "invalid_snapshot"
    });
  } else {
    recordSecurityEvent("vault.write_failed", diagnostics, {
      status,
      reason: "internal_error",
      severity: "error"
    });
  }
}

function rateLimitedResponse(diagnostics: ReturnType<typeof requestDiagnostics>) {
  return NextResponse.json(
    { error: "Too many requests." },
    {
      status: 429,
      headers: diagnosticHeaders(diagnostics, { "retry-after": "60", "cache-control": "no-store" })
    }
  );
}
