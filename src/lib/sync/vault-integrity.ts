import type { Pool, PoolClient } from "pg";
import {
  OperationalError,
  operationalErrorCode
} from "./diagnostics";
import { StoredVaultSnapshotIntegrityError } from "./envelope";
import {
  GUARDED_STORED_VAULT_PROJECTION_SQL,
  type GuardedStoredVaultRow,
  STORED_VAULT_SAFETY_LATERAL_SQL,
  validateGuardedStoredVaultRow
} from "./stored-vault-row";

const RESTORE_SCAN_BATCH_SIZE = 8;
const RESTORE_SCAN_CURSOR = "address_atlas_vault_integrity";

/** Scan restored snapshots with a server-side cursor to keep memory bounded. */
export async function assertStoredVaultIntegrity(pool: Pool) {
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
    await client.query("BEGIN TRANSACTION READ ONLY");
    await client.query(
      `DECLARE ${RESTORE_SCAN_CURSOR} NO SCROLL CURSOR FOR
       SELECT ${GUARDED_STORED_VAULT_PROJECTION_SQL}
       FROM vault_snapshots AS vault
       ${STORED_VAULT_SAFETY_LATERAL_SQL}
       ORDER BY vault.user_id`
    );

    while (true) {
      const page = await client.query<GuardedStoredVaultRow>(
        `FETCH FORWARD ${RESTORE_SCAN_BATCH_SIZE} FROM ${RESTORE_SCAN_CURSOR}`
      );
      if (page.rows.length === 0) break;
      for (const row of page.rows) {
        validateGuardedStoredVaultRow(row);
      }
    }

    await client.query(`CLOSE ${RESTORE_SCAN_CURSOR}`);
    await client.query("COMMIT");
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
