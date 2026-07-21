import type { Pool, PoolClient } from "pg";
import {
  OperationalError,
  operationalErrorCode
} from "./diagnostics";
import { StoredVaultSnapshotIntegrityError } from "./envelope";
import {
  assertWithinRestoreIntegrityDeadline,
  resolveRestoreIntegrityDeadline,
  type RestoreIntegrityScanOptions
} from "./restore-integrity-scan";
import {
  GUARDED_STORED_VAULT_PROJECTION_SQL,
  type GuardedStoredVaultRow,
  STORED_VAULT_SAFETY_LATERAL_SQL,
  validateGuardedStoredVaultRow
} from "./stored-vault-row";

const RESTORE_SCAN_MAX_ROWS = 1_024;
const RESTORE_SCAN_MAX_PAGE_BYTES = 64 * 1024 * 1024;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/** Scan restored snapshots with byte-bounded keyset pages and a finite RTO. */
export async function assertStoredVaultIntegrity(
  pool: Pool,
  options: RestoreIntegrityScanOptions = {}
) {
  const deadlineAt = resolveRestoreIntegrityDeadline(options);
  assertWithinRestoreIntegrityDeadline(deadlineAt);
  let client: PoolClient;
  try {
    client = await pool.connect();
  } catch (error) {
    throw new OperationalError(
      operationalErrorCode(error, "database_connection_failed"),
      "Stored vault integrity scan could not connect to PostgreSQL."
    );
  }
  let discardClient = false;
  try {
    assertWithinRestoreIntegrityDeadline(deadlineAt);
    await client.query("BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY");
    let lastUserId: string | null = null;
    let rowsScanned = 0;
    let pagesScanned = 0;
    while (true) {
      assertWithinRestoreIntegrityDeadline(deadlineAt);
      const hasBoundary = lastUserId !== null;
      const limitParameter = hasBoundary ? "$2" : "$1";
      const byteLimitParameter = hasBoundary ? "$3" : "$2";
      const page = await client.query<GuardedStoredVaultRow & { scan_key: unknown }>(
        `WITH candidates AS MATERIALIZED (
           SELECT vault.user_id,
                  pg_catalog.pg_column_size(vault.envelope)::bigint
                    + pg_catalog.pg_column_size(vault.checksum)::bigint + 128 AS stored_bytes
           FROM vault_snapshots AS vault
           ${hasBoundary ? "WHERE vault.user_id > $1::uuid" : ""}
           ORDER BY vault.user_id
           LIMIT ${limitParameter}
         ), sized AS MATERIALIZED (
           SELECT user_id,
                  pg_catalog.sum(stored_bytes) OVER (ORDER BY user_id) AS cumulative_bytes,
                  pg_catalog.row_number() OVER (ORDER BY user_id) AS page_row
           FROM candidates
         ), bounded_keys AS MATERIALIZED (
           SELECT user_id
           FROM sized
           WHERE cumulative_bytes <= ${byteLimitParameter} OR page_row = 1
         )
         SELECT vault.user_id::text AS scan_key,
                ${GUARDED_STORED_VAULT_PROJECTION_SQL}
         FROM vault_snapshots AS vault
         JOIN bounded_keys AS page ON page.user_id = vault.user_id
         ${STORED_VAULT_SAFETY_LATERAL_SQL}
         ORDER BY vault.user_id`,
        hasBoundary
          ? [lastUserId, RESTORE_SCAN_MAX_ROWS, RESTORE_SCAN_MAX_PAGE_BYTES]
          : [RESTORE_SCAN_MAX_ROWS, RESTORE_SCAN_MAX_PAGE_BYTES]
      );
      if (page.rows.length === 0) break;
      for (const row of page.rows) {
        validateGuardedStoredVaultRow(row);
        if (typeof row.scan_key !== "string" || !UUID_RE.test(row.scan_key)) {
          throw new StoredVaultSnapshotIntegrityError();
        }
      }
      lastUserId = page.rows.at(-1)!.scan_key as string;
      rowsScanned += page.rows.length;
      pagesScanned += 1;
      options.onProgress?.({ rowsScanned, pagesScanned, done: false });
      assertWithinRestoreIntegrityDeadline(deadlineAt);
    }

    await client.query("COMMIT");
    options.onProgress?.({ rowsScanned, pagesScanned, done: true });
  } catch (error) {
    discardClient = !(await rollbackQuietly(client));
    if (error instanceof StoredVaultSnapshotIntegrityError) throw error;
    throw new OperationalError(
      operationalErrorCode(error, "database_query_failed"),
      "Stored vault integrity scan could not complete."
    );
  } finally {
    if (discardClient) client.release(true);
    else client.release();
  }
}

async function rollbackQuietly(client: { query: (sql: string) => Promise<unknown> }) {
  try {
    await client.query("ROLLBACK");
    return true;
  } catch {
    return false;
  }
}
