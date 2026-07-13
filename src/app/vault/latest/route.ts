import { NextRequest, NextResponse } from "next/server";
import {
  assertEnvelopeChecksum,
  assertNoPlaintextLeak,
  assertRemoteVaultSnapshot,
  MAX_SNAPSHOT_REQUEST_BYTES,
  type RemoteVaultSnapshot
} from "@/lib/sync/envelope";
import { ensureSyncSchema, getSyncPool } from "@/lib/sync/postgres";
import { rateLimitMany } from "@/lib/sync/rate-limit";
import { readLimitedJSON, RequestBodyError } from "@/lib/sync/request";
import { readBearerToken, TokenValidationError } from "@/lib/sync/tokens";
import {
  saveVaultSnapshot,
  VaultAccountMissingError,
  VaultConflictError,
  VaultQuotaError,
  VaultStorageCapacityError
} from "@/lib/sync/vault-storage";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function GET(request: NextRequest) {
  try {
    // Authenticate before touching shared quota. Token parsing is bounded and
    // HMAC-only; charging invalid public traffic here would let anyone exhaust
    // the global bucket and deny vault access to authenticated clients.
    const session = readBearerToken(request.headers.get("authorization"));
    if (!rateLimitMany([
      { key: "vault-get:global", limit: 3_000, windowMs: 60_000 },
      { key: `vault-get:account:${session.userId}`, limit: 120, windowMs: 60_000 }
    ])) {
      return rateLimitedResponse();
    }
    await ensureSyncSchema();
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
        { status: 404, headers: { "cache-control": "no-store" } }
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
      { headers: { "cache-control": "no-store" } }
    );
  } catch (error) {
    const authenticationFailure = error instanceof TokenValidationError || error instanceof VaultAccountMissingError;
    return NextResponse.json(
      { error: authenticationFailure ? "Authentication required." : "Vault snapshot could not be loaded." },
      { status: authenticationFailure ? 401 : 500, headers: { "cache-control": "no-store" } }
    );
  }
}

export async function PUT(request: NextRequest) {
  try {
    // Keep invalid public traffic out of the shared authenticated quota. The
    // request body is deliberately not read until after auth and throttling.
    const session = readBearerToken(request.headers.get("authorization"));
    if (!rateLimitMany([
      { key: "vault-put:global", limit: 300, windowMs: 60_000 },
      { key: `vault-put:account:${session.userId}`, limit: 10, windowMs: 60_000 }
    ])) {
      return rateLimitedResponse();
    }
    const { value, byteLength } = await readLimitedJSON(request, MAX_SNAPSHOT_REQUEST_BYTES);
    const body = validateUploadedSnapshot(value);
    await ensureSyncSchema();
    const result = await saveVaultSnapshot(session.userId, body, byteLength);
    return NextResponse.json({ ok: true, idempotent: result.idempotent }, {
      headers: { "cache-control": "no-store" }
    });
  } catch (error) {
    return NextResponse.json(
      { error: vaultErrorMessage(error) },
      {
        status: vaultErrorStatus(error),
        headers: {
          "cache-control": "no-store",
          ...(error instanceof VaultQuotaError ? { "retry-after": "3600" } : {})
        }
      }
    );
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

function rateLimitedResponse() {
  return NextResponse.json(
    { error: "Too many requests." },
    { status: 429, headers: { "retry-after": "60", "cache-control": "no-store" } }
  );
}
