import type { Pool, PoolClient } from "pg";
import { OperationalError, operationalErrorCode } from "./diagnostics";
import {
  GUARDED_STORED_PASSKEY_CREDENTIAL_PROJECTION_SQL,
  type GuardedStoredPasskeyCredentialRow,
  STORED_PASSKEY_CREDENTIAL_SAFETY_LATERAL_SQL,
  StoredPasskeyCredentialIntegrityError,
  validateGuardedStoredPasskeyCredentialRow
} from "./stored-passkey-credential";

const RESTORE_SCAN_BATCH_SIZE = 32;
const RESTORE_SCAN_CURSOR = "address_atlas_passkey_integrity";

/**
 * Validate every restored credential without materializing unbounded fields,
 * and reject an account that has no credential with which to recover its vault.
 */
export async function assertStoredPasskeyCredentialIntegrity(pool: Pool) {
  let client: PoolClient;
  try {
    client = await pool.connect();
  } catch (error) {
    throw new OperationalError(
      operationalErrorCode(error, "database_connection_failed"),
      "Stored passkey integrity scan could not connect to PostgreSQL."
    );
  }
  let discardClient = false;
  try {
    await client.query("BEGIN TRANSACTION READ ONLY");
    const accountCoverage = await client.query<{ credentialless_user_exists: boolean }>(
      `SELECT EXISTS (
         SELECT 1
         FROM users AS account
         WHERE NOT EXISTS (
           SELECT 1
           FROM passkey_credentials AS credential
           WHERE credential.user_id = account.id
         )
       ) AS credentialless_user_exists`
    );
    if (accountCoverage.rows.length !== 1
        || accountCoverage.rows[0]?.credentialless_user_exists !== false) {
      throw new StoredPasskeyCredentialIntegrityError();
    }
    await client.query(
      `DECLARE ${RESTORE_SCAN_CURSOR} NO SCROLL CURSOR FOR
       SELECT ${GUARDED_STORED_PASSKEY_CREDENTIAL_PROJECTION_SQL}
       FROM passkey_credentials AS credential
       ${STORED_PASSKEY_CREDENTIAL_SAFETY_LATERAL_SQL}
       ORDER BY credential.ctid`
    );

    while (true) {
      const page = await client.query<GuardedStoredPasskeyCredentialRow>(
        `FETCH FORWARD ${RESTORE_SCAN_BATCH_SIZE} FROM ${RESTORE_SCAN_CURSOR}`
      );
      if (page.rows.length === 0) break;
      for (const row of page.rows) validateGuardedStoredPasskeyCredentialRow(row);
    }

    await client.query(`CLOSE ${RESTORE_SCAN_CURSOR}`);
    await client.query("COMMIT");
  } catch (error) {
    discardClient = !(await rollbackQuietly(client));
    if (error instanceof StoredPasskeyCredentialIntegrityError) throw error;
    throw new OperationalError(
      operationalErrorCode(error, "database_query_failed"),
      "Stored passkey integrity scan could not complete."
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
