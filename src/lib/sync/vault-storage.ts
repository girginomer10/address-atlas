import type { PoolClient } from "pg";
import { getSyncLimitConfig } from "./config";
import type { RemoteVaultSnapshot } from "./envelope";
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
 * Serialize writes per user, skip exact replays without touching snapshot WAL,
 * and charge snapshot mutations to a durable UTC-day quota. Exact retries are
 * idempotent: request rate limits still bound them, but they consume neither
 * the logical write counter nor the byte quota a second time.
 */
export async function saveVaultSnapshot(
  userId: string,
  snapshot: RemoteVaultSnapshot,
  chargedBytes: number
): Promise<VaultSaveResult> {
  assertValidChargedBytes(chargedBytes);
  const client = await getSyncPool().connect();
  let discardClient = false;
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
       FROM vault_snapshots WHERE user_id = $1 FOR UPDATE`,
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

    await chargeDailyQuota(client, userId, chargedBytes, 1);
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
    // Snapshot mutations and the delete trigger both lock the snapshot before
    // the aggregate counter. Keeping one global order prevents deadlocks and
    // makes a concurrent administrative delete's byte delta deterministic.
    await chargeGlobalStorageCapacity(client, snapshot.byteSize - (row?.byte_size ?? 0));
    await client.query("COMMIT");
    return { idempotent: false };
  } catch (error) {
    discardClient = !(await rollbackQuietly(client));
    throw error;
  } finally {
    if (discardClient) client.release(true);
    else client.release();
  }
}

async function chargeGlobalStorageCapacity(client: PoolClient, byteDelta: number) {
  if (!Number.isSafeInteger(byteDelta)) throw new VaultStorageCapacityError();
  if (byteDelta === 0) return;
  const maxBytes = getSyncLimitConfig().globalVaultStorageLimit;
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

async function chargeDailyQuota(
  client: PoolClient,
  userId: string,
  chargedBytes: number,
  writeIncrement: 0 | 1
) {
  const limits = getSyncLimitConfig();
  const maxWrites = limits.dailyVaultWriteLimit;
  const maxBytes = limits.dailyVaultByteLimit;
  assertValidChargedBytes(chargedBytes, maxBytes);
  const usage = await client.query(
    `INSERT INTO vault_write_usage (user_id, usage_date, write_count, byte_count)
     VALUES ($1, (now() AT TIME ZONE 'UTC')::date, $3, $2)
     ON CONFLICT (user_id, usage_date) DO UPDATE SET
       write_count = vault_write_usage.write_count + excluded.write_count,
       byte_count = vault_write_usage.byte_count + excluded.byte_count,
       updated_at = now()
     WHERE vault_write_usage.write_count + excluded.write_count <= $4
       AND vault_write_usage.byte_count + excluded.byte_count <= $5
     RETURNING write_count`,
    [userId, chargedBytes, writeIncrement, maxWrites, maxBytes]
  );
  if (usage.rowCount === 0) throw new VaultQuotaError();
}

function assertValidChargedBytes(
  chargedBytes: number,
  maxBytes = getSyncLimitConfig().dailyVaultByteLimit
) {
  if (!Number.isSafeInteger(chargedBytes) || chargedBytes < 1 || chargedBytes > maxBytes) {
    throw new VaultQuotaError();
  }
}

async function rollbackQuietly(client: PoolClient) {
  try {
    await client.query("ROLLBACK");
    return true;
  } catch {
    // A timed-out statement may still be active server-side; discard instead of
    // returning an ambiguous transaction state to the pool.
    return false;
  }
}
