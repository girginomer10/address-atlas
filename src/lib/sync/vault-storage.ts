import type { PoolClient } from "pg";
import type { RemoteVaultSnapshot } from "./envelope";
import { MAX_SNAPSHOT_REQUEST_BYTES } from "./envelope";
import { getSyncPool } from "./postgres";

export class VaultConflictError extends Error {
  constructor() {
    super("Remote vault snapshot is newer. Download before uploading again.");
    this.name = "VaultConflictError";
  }
}

export class VaultQuotaError extends Error {
  constructor() {
    super("Daily encrypted vault upload quota exceeded.");
    this.name = "VaultQuotaError";
  }
}

export class VaultStorageCapacityError extends Error {
  constructor() {
    super("Encrypted vault storage capacity has been reached.");
    this.name = "VaultStorageCapacityError";
  }
}

export class VaultAccountMissingError extends Error {
  constructor() {
    super("Session account no longer exists.");
    this.name = "VaultAccountMissingError";
  }
}

export interface VaultSaveResult {
  idempotent: boolean;
}

/**
 * Serialize writes per user, skip exact replays without touching WAL, and charge
 * non-idempotent writes to a durable per-account UTC-day quota.
 */
export async function saveVaultSnapshot(
  userId: string,
  snapshot: RemoteVaultSnapshot,
  chargedBytes: number
): Promise<VaultSaveResult> {
  const client = await getSyncPool().connect();
  try {
    await client.query("BEGIN");
    const account = await client.query("SELECT id FROM users WHERE id = $1 FOR UPDATE", [userId]);
    if (account.rowCount === 0) throw new VaultAccountMissingError();

    const encodedEnvelope = JSON.stringify(snapshot.envelope);
    const current = await client.query<{
      version: number;
      checksum: string;
      byte_size: number;
      same_envelope: boolean;
    }>(
      `SELECT version, checksum, byte_size, envelope = $2::jsonb AS same_envelope
       FROM vault_snapshots WHERE user_id = $1`,
      [userId, encodedEnvelope]
    );
    const row = current.rows[0];
    const isExactReplay = row
      && row.version === snapshot.version
      && row.checksum === snapshot.checksum
      && row.byte_size === snapshot.byteSize
      && row.same_envelope;
    if (isExactReplay) {
      await client.query("COMMIT");
      return { idempotent: true };
    }
    if (row && row.version >= snapshot.version) throw new VaultConflictError();

    await chargeDailyQuota(client, userId, chargedBytes);
    await chargeGlobalStorageCapacity(client, snapshot.byteSize - (row?.byte_size ?? 0));
    const stored = await client.query(
      `INSERT INTO vault_snapshots (user_id, version, envelope, byte_size, checksum)
       VALUES ($1, $2, $3::jsonb, $4, $5)
       ON CONFLICT (user_id) DO UPDATE SET
         version = excluded.version,
         envelope = excluded.envelope,
         byte_size = excluded.byte_size,
         checksum = excluded.checksum,
         updated_at = now()
       WHERE vault_snapshots.version < excluded.version
       RETURNING version`,
      [userId, snapshot.version, encodedEnvelope, snapshot.byteSize, snapshot.checksum]
    );
    if (stored.rowCount === 0) throw new VaultConflictError();
    await client.query("COMMIT");
    return { idempotent: false };
  } catch (error) {
    await rollbackQuietly(client);
    throw error;
  } finally {
    client.release();
  }
}

async function chargeGlobalStorageCapacity(client: PoolClient, byteDelta: number) {
  if (!Number.isSafeInteger(byteDelta)) throw new VaultStorageCapacityError();
  if (byteDelta === 0) return;
  const maxBytes = boundedIntegerFromEnv(
    "SYNC_GLOBAL_VAULT_STORAGE_LIMIT",
    10_000_000_000,
    MAX_SNAPSHOT_REQUEST_BYTES,
    10_000_000_000_000
  );
  const charged = await client.query(
    `UPDATE sync_storage_usage
     SET total_snapshot_bytes = total_snapshot_bytes + $1, updated_at = now()
     WHERE singleton = true
       AND total_snapshot_bytes + $1 >= 0
       AND ($1 <= 0 OR total_snapshot_bytes + $1 <= $2)
     RETURNING total_snapshot_bytes`,
    [byteDelta, maxBytes]
  );
  if (charged.rowCount === 0) throw new VaultStorageCapacityError();
}

async function chargeDailyQuota(client: PoolClient, userId: string, chargedBytes: number) {
  const maxWrites = boundedIntegerFromEnv("SYNC_VAULT_DAILY_WRITE_LIMIT", 100, 1, 10_000);
  const maxBytes = boundedIntegerFromEnv(
    "SYNC_VAULT_DAILY_BYTE_LIMIT",
    64_000_000,
    MAX_SNAPSHOT_REQUEST_BYTES,
    10_000_000_000
  );
  if (!Number.isSafeInteger(chargedBytes) || chargedBytes < 1 || chargedBytes > maxBytes) {
    throw new VaultQuotaError();
  }
  const usage = await client.query(
    `INSERT INTO vault_write_usage (user_id, usage_date, write_count, byte_count)
     VALUES ($1, (now() AT TIME ZONE 'UTC')::date, 1, $2)
     ON CONFLICT (user_id, usage_date) DO UPDATE SET
       write_count = vault_write_usage.write_count + 1,
       byte_count = vault_write_usage.byte_count + excluded.byte_count,
       updated_at = now()
     WHERE vault_write_usage.write_count < $3
       AND vault_write_usage.byte_count + excluded.byte_count <= $4
     RETURNING write_count`,
    [userId, chargedBytes, maxWrites, maxBytes]
  );
  if (usage.rowCount === 0) throw new VaultQuotaError();
}

async function rollbackQuietly(client: PoolClient) {
  try {
    await client.query("ROLLBACK");
  } catch {
    // The original error is the actionable one; connection cleanup is best effort.
  }
}

function boundedIntegerFromEnv(name: string, fallback: number, min: number, max: number) {
  const parsed = Number(process.env[name]);
  return Number.isSafeInteger(parsed) && parsed >= min && parsed <= max ? parsed : fallback;
}
