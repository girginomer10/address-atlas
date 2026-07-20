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
 * Serialize writes per user and charge actual request bytes for successful
 * mutations, exact replays, and rejected stale/same-version writes. Only a
 * committed snapshot mutation increments the logical write counter.
 */
export async function saveVaultSnapshot(
  userId: string,
  snapshot: RemoteVaultSnapshot,
  chargedBytes: number
): Promise<VaultSaveResult> {
  assertValidChargedBytes(chargedBytes);
  const client = await getSyncPool().connect();
  let discardClient = false;
  let transactionOpen = false;
  try {
    // A client-side query timeout is ambiguous: PostgreSQL may still execute
    // BEGIN after the promise rejects. Mark the transaction as potentially
    // open before sending it so catch always rolls back or destroys the client.
    transactionOpen = true;
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
      await chargeDailyQuota(client, userId, chargedBytes, 0);
      await client.query("COMMIT");
      transactionOpen = false;
      return { idempotent: true };
    }
    if (row && row.version >= snapshot.version) {
      // Persist the request-byte charge while leaving both the logical write
      // counter and stored snapshot untouched. The conflict is raised only
      // after that quota transaction settles. The 409 outranks the 429: a
      // stale writer must be told to download the newer snapshot, so if the
      // charge itself fails (for example the daily quota is already
      // exhausted) it is rolled back and the conflict is still raised.
      try {
        await chargeDailyQuota(client, userId, chargedBytes, 0);
        await client.query("COMMIT");
      } catch {
        discardClient = !(await rollbackQuietly(client));
      }
      transactionOpen = false;
      throw new VaultConflictError();
    }

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
    if (stored.rowCount === 0) {
      // The SQL version gate is a final defense against writers that do not
      // follow this process's per-account lock. Charge bytes, but not a logical
      // write, for that conflict as well — and, as above, a failed charge is
      // rolled back without masking the conflict.
      try {
        await chargeDailyQuota(client, userId, chargedBytes, 0);
        await client.query("COMMIT");
      } catch {
        discardClient = !(await rollbackQuietly(client));
      }
      transactionOpen = false;
      throw new VaultConflictError();
    }
    // The tentative snapshot and its quota charge commit or roll back together.
    await chargeDailyQuota(client, userId, chargedBytes, 1);
    // Snapshot mutations and the delete trigger both lock the snapshot before
    // the aggregate counter. Keeping one global order prevents deadlocks and
    // makes a concurrent administrative delete's byte delta deterministic.
    await chargeGlobalStorageCapacity(client, snapshot.byteSize - (row?.byte_size ?? 0));
    await client.query("COMMIT");
    transactionOpen = false;
    return { idempotent: false };
  } catch (error) {
    if (transactionOpen) discardClient = !(await rollbackQuietly(client));
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
