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

export class VaultGlobalIngressQuotaError extends VaultQuotaError {
  constructor() {
    super();
    this.message = "Service-wide encrypted vault ingress quota exceeded.";
    this.name = "VaultGlobalIngressQuotaError";
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

const ingressAdmissions = new WeakSet<object>();
const ingressAdmissionBrand: unique symbol = Symbol("vault-ingress-admission");

/**
 * An in-process, single-use proof that this request authenticated and locked a
 * live account before receiving its body. Callers cannot construct one because
 * the runtime proof is retained in this module's WeakSet.
 */
export interface VaultIngressAdmission {
  readonly userId: string;
  readonly [ingressAdmissionBrand]: true;
}

/**
 * Fail closed before an authenticated request body is read when either durable
 * ingress budget is already exhausted. This is intentionally only a capacity
 * check, not a reservation: concurrent bodies are bounded by the route's
 * account/global concurrency permits and are all charged after they are read.
 */
export async function assertVaultIngressCapacity(userId: string): Promise<VaultIngressAdmission> {
  const client = await getSyncPool().connect();
  let discardClient = false;
  let transactionOpen = false;
  try {
    const limits = getSyncLimitConfig();

    transactionOpen = true;
    await client.query("BEGIN");
    const accountBytes = await lockAccountIngressUsage(client, userId);
    if (accountBytes >= limits.dailyVaultByteLimit) throw new VaultQuotaError();

    const globalBytes = await lockGlobalIngressUsage(client);
    if (globalBytes >= limits.globalDailyVaultIngressByteLimit) {
      throw new VaultGlobalIngressQuotaError();
    }

    await client.query("COMMIT");
    transactionOpen = false;
    const admission = Object.freeze({
      userId,
      [ingressAdmissionBrand]: true as const
    });
    ingressAdmissions.add(admission);
    return admission;
  } catch (error) {
    if (transactionOpen) discardClient = !(await rollbackQuietly(client));
    throw error;
  } finally {
    if (discardClient) client.release(true);
    else client.release();
  }
}

/**
 * Durably charge every authenticated request body before interpreting its JSON
 * or snapshot semantics. Rows are always locked in account -> account usage ->
 * global usage order. An over-budget body saturates the account counter, adds
 * every received byte to the global counter, commits both changes, and only
 * then reports the quota failure. That makes concurrent bodies accountable
 * without letting a never-admitted missing account consume shared capacity.
 */
export async function chargeVaultIngress(
  userId: string,
  chargedBytes: number,
  admission?: VaultIngressAdmission
): Promise<void> {
  assertValidChargedBytes(chargedBytes);
  const admittedBeforeBodyRead = consumeIngressAdmission(admission, userId);
  const client = await getSyncPool().connect();
  let discardClient = false;
  let transactionOpen = false;
  try {
    const limits = getSyncLimitConfig();

    // Mark the transaction as potentially open before BEGIN: a client-side
    // timeout does not prove that PostgreSQL did not execute the statement.
    transactionOpen = true;
    await client.query("BEGIN");
    let accountBytes: number | null;
    try {
      accountBytes = await lockAccountIngressUsage(client, userId);
    } catch (error) {
      if (!(error instanceof VaultAccountMissingError) || !admittedBeforeBodyRead) throw error;
      // The account existed and was locked immediately before this request body
      // was admitted, but self-service deletion won the race while the body was
      // in flight. Preserve the shared ingress charge, then return the same
      // privacy-safe missing-account result after commit.
      accountBytes = null;
    }
    const globalBytes = await lockGlobalIngressUsage(client);
    const accountExceeded = accountBytes !== null
      && chargedBytes > limits.dailyVaultByteLimit - accountBytes;
    const globalExceeded = chargedBytes
      > limits.globalDailyVaultIngressByteLimit - globalBytes;

    if (accountBytes !== null) {
      await client.query(
        `UPDATE vault_write_usage
         SET byte_count = LEAST($3::bigint, byte_count + $2::bigint), updated_at = now()
         WHERE user_id = $1 AND usage_date = (now() AT TIME ZONE 'UTC')::date`,
        [userId, chargedBytes, limits.dailyVaultByteLimit]
      );
    }
    await client.query(
      `UPDATE vault_global_ingress_usage
       SET byte_count = byte_count + $1::bigint, updated_at = now()
       WHERE usage_date = (now() AT TIME ZONE 'UTC')::date`,
      [chargedBytes]
    );
    await client.query("COMMIT");
    transactionOpen = false;

    if (accountBytes === null) throw new VaultAccountMissingError();
    if (globalExceeded) throw new VaultGlobalIngressQuotaError();
    if (accountExceeded) throw new VaultQuotaError();
  } catch (error) {
    if (transactionOpen) discardClient = !(await rollbackQuietly(client));
    throw error;
  } finally {
    if (discardClient) client.release(true);
    else client.release();
  }
}

function consumeIngressAdmission(
  admission: VaultIngressAdmission | undefined,
  userId: string
) {
  if (!admission || !ingressAdmissions.has(admission)) return false;
  ingressAdmissions.delete(admission);
  return admission.userId === userId;
}

async function lockAccountIngressUsage(client: PoolClient, userId: string) {
  const account = await client.query("SELECT id FROM users WHERE id = $1 FOR UPDATE", [userId]);
  if (account.rowCount === 0) throw new VaultAccountMissingError();

  await client.query(
    `INSERT INTO vault_write_usage (user_id, usage_date, write_count, byte_count)
     VALUES ($1, (now() AT TIME ZONE 'UTC')::date, 0, 0)
     ON CONFLICT (user_id, usage_date) DO NOTHING`,
    [userId]
  );
  const usage = await client.query<{ byte_count: string }>(
    `SELECT byte_count::text AS byte_count
     FROM vault_write_usage
     WHERE user_id = $1 AND usage_date = (now() AT TIME ZONE 'UTC')::date
     FOR UPDATE`,
    [userId]
  );
  return parseStoredByteCount(usage.rows[0]?.byte_count);
}

async function lockGlobalIngressUsage(client: PoolClient) {
  await client.query(
    `INSERT INTO vault_global_ingress_usage (usage_date, byte_count)
     VALUES ((now() AT TIME ZONE 'UTC')::date, 0)
     ON CONFLICT (usage_date) DO NOTHING`
  );
  const usage = await client.query<{ byte_count: string }>(
    `SELECT byte_count::text AS byte_count
     FROM vault_global_ingress_usage
     WHERE usage_date = (now() AT TIME ZONE 'UTC')::date
     FOR UPDATE`
  );
  return parseStoredByteCount(usage.rows[0]?.byte_count);
}

function parseStoredByteCount(value: string | undefined) {
  const byteCount = Number(value);
  if (!Number.isSafeInteger(byteCount) || byteCount < 0) {
    throw new VaultQuotaError();
  }
  return byteCount;
}

/**
 * Serialize snapshot semantics per account. Ingress bytes were committed by
 * `chargeVaultIngress` before this function is called, so validation failures,
 * replays, conflicts, and rolled-back mutations cannot erase their charge.
 */
export async function saveVaultSnapshot(
  userId: string,
  snapshot: RemoteVaultSnapshot
): Promise<VaultSaveResult> {
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
      await client.query("COMMIT");
      transactionOpen = false;
      return { idempotent: true };
    }
    if (row && row.version >= snapshot.version) {
      await client.query("COMMIT");
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
      // follow this process's per-account lock.
      await client.query("COMMIT");
      transactionOpen = false;
      throw new VaultConflictError();
    }
    // Only committed mutations consume the logical write budget. Ingress bytes
    // were already charged in their own durable transaction.
    await chargeDailyWrite(client, userId);
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

async function chargeDailyWrite(client: PoolClient, userId: string) {
  const limits = getSyncLimitConfig();
  const maxWrites = limits.dailyVaultWriteLimit;
  const usage = await client.query(
    `INSERT INTO vault_write_usage (user_id, usage_date, write_count, byte_count)
     VALUES ($1, (now() AT TIME ZONE 'UTC')::date, 1, 0)
     ON CONFLICT (user_id, usage_date) DO UPDATE SET
       write_count = vault_write_usage.write_count + 1,
       updated_at = now()
     WHERE vault_write_usage.write_count + 1 <= $2
     RETURNING write_count`,
    [userId, maxWrites]
  );
  if (usage.rowCount === 0) throw new VaultQuotaError();
}

function assertValidChargedBytes(
  chargedBytes: number
) {
  if (!Number.isSafeInteger(chargedBytes) || chargedBytes < 1) {
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
