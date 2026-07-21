import { NextRequest, NextResponse } from "next/server";
import {
  assertEnvelopeChecksum,
  assertNoPlaintextLeak,
  assertRemoteVaultSnapshot,
  MAX_SNAPSHOT_REQUEST_BYTES,
  StoredVaultSnapshotIntegrityError,
  type RemoteVaultSnapshot
} from "@/lib/sync/envelope";
import { getSyncPool } from "@/lib/sync/postgres";
import {
  acquireConcurrencyMany,
  clientKey,
  rateLimitMany,
  rateLimitWeightedMany
} from "@/lib/sync/rate-limit";
import {
  diagnosticHeaders,
  operationalErrorCode,
  recordSecurityEvent,
  requestDiagnostics
} from "@/lib/sync/diagnostics";
import { parseRequestJSON, readLimitedBody, RequestBodyError } from "@/lib/sync/request";
import { authenticateBearerSession } from "@/lib/sync/sessions";
import {
  GUARDED_STORED_VAULT_PROJECTION_SQL,
  type GuardedStoredVaultRow,
  STORED_VAULT_SAFETY_LATERAL_SQL,
  validateGuardedStoredVaultRow
} from "@/lib/sync/stored-vault-row";
import { TokenValidationError } from "@/lib/sync/tokens";
import {
  assertVaultIngressCapacity,
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
  let releaseConcurrency: (() => void) | undefined;
  let permitOwnership: AbortBoundPermit | undefined;
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
    const concurrencyPermit = acquireConcurrencyMany([
      { key: "vault-get-active:global", limit: 8 },
      { key: `vault-get-active:client:${client}`, limit: 2 },
      { key: `vault-get-active:account:${session.userId}`, limit: 2 }
    ]);
    if (!concurrencyPermit) {
      recordSecurityEvent("auth.rate_limited", diagnostics, {
        status: 429,
        reason: "vault_read_concurrency_limit"
      });
      return rateLimitedResponse(diagnostics);
    }
    permitOwnership = bindPermitToResponseLifecycle(request.signal, concurrencyPermit);
    releaseConcurrency = permitOwnership.release;
    if (permitOwnership.wasAborted()) return cancelledResponse(diagnostics);
    const result = await getSyncPool().query<GuardedStoredVaultRow & {
      snapshot_present: boolean;
    }>(
      `SELECT vault.user_id IS NOT NULL AS snapshot_present,
       ${GUARDED_STORED_VAULT_PROJECTION_SQL}
       FROM users AS account
       LEFT JOIN vault_snapshots AS vault ON vault.user_id = account.id
       ${STORED_VAULT_SAFETY_LATERAL_SQL}
       WHERE account.id = $1`,
      [session.userId]
    );
    // Abort only records intent while handler work is active; the permit stays
    // held until this database operation settles, bounding orphaned work.
    if (permitOwnership.wasAborted()) return cancelledResponse(diagnostics);
    const row = result.rows[0];
    if (!row) throw new VaultAccountMissingError();
    if (!row.snapshot_present) {
      return NextResponse.json(
        { error: "No vault snapshot." },
        { status: 404, headers: diagnosticHeaders(diagnostics, { "cache-control": "no-store" }) }
      );
    }
    const snapshot = validateGuardedStoredVaultRow(row);
    // Encode under the active permit so the weighted limiter charges the exact
    // downstream payload once. Cancellation never refunds egress work already
    // constructed by the service.
    const responseBytes = new TextEncoder().encode(JSON.stringify(snapshot));
    if (permitOwnership.wasAborted()) return cancelledResponse(diagnostics);
    if (!rateLimitWeightedMany([
      {
        key: "vault-get-egress:global",
        limit: 64 * MAX_SNAPSHOT_REQUEST_BYTES,
        windowMs: 60_000,
        weight: responseBytes.byteLength
      },
      {
        key: `vault-get-egress:client:${client}`,
        limit: 16 * MAX_SNAPSHOT_REQUEST_BYTES,
        windowMs: 60_000,
        weight: responseBytes.byteLength
      },
      {
        key: `vault-get-egress:account:${session.userId}`,
        limit: 8 * MAX_SNAPSHOT_REQUEST_BYTES,
        windowMs: 60_000,
        weight: responseBytes.byteLength
      }
    ])) {
      recordSecurityEvent("auth.rate_limited", diagnostics, {
        status: 429,
        reason: "vault_read_egress_byte_limit"
      });
      return rateLimitedResponse(diagnostics);
    }
    const response = streamedVaultSnapshotResponse(responseBytes, diagnostics, releaseConcurrency);
    if (!permitOwnership.transferToStream()) {
      void response.body?.cancel().catch(() => undefined);
      return cancelledResponse(diagnostics);
    }
    // The response stream now owns the permit through downstream drain/cancel.
    releaseConcurrency = undefined;
    return response;
  } catch (error) {
    const authenticationFailure = error instanceof TokenValidationError || error instanceof VaultAccountMissingError;
    recordSecurityEvent(authenticationFailure ? "session.rejected" : "vault.load_failed", diagnostics, {
      status: authenticationFailure ? 401 : 500,
      reason: authenticationFailure
        ? "invalid_session"
        : error instanceof StoredVaultSnapshotIntegrityError
          ? "stored_snapshot_invalid"
          : "internal_error",
      ...(!authenticationFailure
        ? { errorCode: operationalErrorCode(error, "unknown_internal_error") }
        : {}),
      severity: authenticationFailure ? "warn" : "error"
    });
    return NextResponse.json(
      { error: authenticationFailure ? "Authentication required." : "Vault snapshot could not be loaded." },
      {
        status: authenticationFailure ? 401 : 500,
        headers: diagnosticHeaders(diagnostics, { "cache-control": "no-store" })
      }
    );
  } finally {
    releaseConcurrency?.();
  }
}

const VAULT_RESPONSE_CHUNK_BYTES = 64 * 1024;

interface AbortBoundPermit {
  release: () => void;
  transferToStream: () => boolean;
  wasAborted: () => boolean;
}

function bindPermitToResponseLifecycle(
  signal: AbortSignal,
  releasePermit: () => void
): AbortBoundPermit {
  let aborted = signal.aborted;
  let released = false;
  let streamOwnsPermit = false;
  const release = () => {
    if (released) return;
    released = true;
    signal.removeEventListener("abort", onAbort);
    releasePermit();
  };
  const onAbort = () => {
    aborted = true;
    // Handler-side auth/database/encoding work retains the permit. Once the
    // response stream owns it, disconnect is the terminal release signal.
    if (streamOwnsPermit) release();
  };
  signal.addEventListener("abort", onAbort, { once: true });
  if (signal.aborted) onAbort();

  return {
    release,
    wasAborted: () => aborted,
    transferToStream: () => {
      streamOwnsPermit = true;
      if (aborted) {
        release();
        return false;
      }
      return true;
    }
  };
}

function cancelledResponse(diagnostics: ReturnType<typeof requestDiagnostics>) {
  return NextResponse.json(
    { error: "Request cancelled." },
    {
      status: 408,
      headers: diagnosticHeaders(diagnostics, { "cache-control": "no-store" })
    }
  );
}

function streamedVaultSnapshotResponse(
  bytes: Uint8Array,
  diagnostics: ReturnType<typeof requestDiagnostics>,
  releaseConcurrency: () => void
) {
  let offset = 0;
  let released = false;
  const releaseOnce = () => {
    if (released) return;
    released = true;
    releaseConcurrency();
  };
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      // Close only on the pull after the final chunk. That pull proves the
      // downstream consumer drained the queued bytes; enqueueing alone does not.
      if (offset >= bytes.byteLength) {
        controller.close();
        releaseOnce();
        return;
      }
      const end = Math.min(offset + VAULT_RESPONSE_CHUNK_BYTES, bytes.byteLength);
      controller.enqueue(bytes.subarray(offset, end));
      offset = end;
    },
    cancel() {
      releaseOnce();
    }
  }, { highWaterMark: 0 });

  return new Response(body, {
    headers: diagnosticHeaders(diagnostics, {
      "cache-control": "no-store",
      "content-type": "application/json; charset=utf-8"
    })
  });
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
    // Fail closed before receiving a body when a previous request has already
    // exhausted either durable ingress budget. This is not a reservation;
    // concurrently admitted bodies are still charged in full below.
    const ingressAdmission = await assertVaultIngressCapacity(session.userId);
    let limitedBody;
    let bodyReadError: RequestBodyError | undefined;
    try {
      limitedBody = await readLimitedBody(request, MAX_SNAPSHOT_REQUEST_BYTES);
    } catch (error) {
      if (!(error instanceof RequestBodyError)) throw error;
      bodyReadError = error;
      if (error.byteLength > 0) {
        await chargeVaultIngress(session.userId, error.byteLength, ingressAdmission);
      }
    }
    if (limitedBody) {
      await chargeVaultIngress(session.userId, limitedBody.byteLength, ingressAdmission);
    }

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
