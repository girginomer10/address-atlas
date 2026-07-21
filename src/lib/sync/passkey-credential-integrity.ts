import type { Pool, PoolClient } from "pg";
import { OperationalError, operationalErrorCode } from "./diagnostics";
import {
  GUARDED_STORED_PASSKEY_CREDENTIAL_PROJECTION_SQL,
  type GuardedStoredPasskeyCredentialRow,
  STORED_PASSKEY_CREDENTIAL_SAFETY_LATERAL_SQL,
  StoredPasskeyCredentialIntegrityError,
  validateGuardedStoredPasskeyCredentialRow
} from "./stored-passkey-credential";
import {
  assertWithinRestoreIntegrityDeadline,
  resolveRestoreIntegrityDeadline,
  type RestoreIntegrityScanOptions
} from "./restore-integrity-scan";

const RESTORE_SCAN_BATCH_SIZE = 2_048;

/**
 * Validate every restored credential without materializing unbounded fields,
 * and reject an account that has no credential with which to recover its vault.
 */
export async function assertStoredPasskeyCredentialIntegrity(
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
      "Stored passkey integrity scan could not connect to PostgreSQL."
    );
  }
  let discardClient = false;
  try {
    assertWithinRestoreIntegrityDeadline(deadlineAt);
    await client.query("BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY");
    assertWithinRestoreIntegrityDeadline(deadlineAt);
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
    assertWithinRestoreIntegrityDeadline(deadlineAt);
    let lastCredentialId: string | null = null;
    let rowsScanned = 0;
    let pagesScanned = 0;
    while (true) {
      assertWithinRestoreIntegrityDeadline(deadlineAt);
      const hasBoundary = lastCredentialId !== null;
      const page = await client.query<GuardedStoredPasskeyCredentialRow & { scan_key: unknown }>(
        `SELECT CASE
                  WHEN credential_safety.stored_row_valid THEN credential.id
                  ELSE NULL
                END AS scan_key,
                ${GUARDED_STORED_PASSKEY_CREDENTIAL_PROJECTION_SQL}
         FROM passkey_credentials AS credential
         ${STORED_PASSKEY_CREDENTIAL_SAFETY_LATERAL_SQL}
         ${hasBoundary ? "WHERE credential.id > $1::text" : ""}
         ORDER BY credential.id
         LIMIT ${hasBoundary ? "$2" : "$1"}`,
        hasBoundary
          ? [lastCredentialId, RESTORE_SCAN_BATCH_SIZE]
          : [RESTORE_SCAN_BATCH_SIZE]
      );
      if (page.rows.length === 0) break;
      for (const row of page.rows) {
        const validated = validateGuardedStoredPasskeyCredentialRow(row);
        if (row.scan_key !== validated.id) throw new StoredPasskeyCredentialIntegrityError();
      }
      lastCredentialId = page.rows.at(-1)!.scan_key as string;
      rowsScanned += page.rows.length;
      pagesScanned += 1;
      options.onProgress?.({ rowsScanned, pagesScanned, done: false });
      assertWithinRestoreIntegrityDeadline(deadlineAt);
    }

    await client.query("COMMIT");
    options.onProgress?.({ rowsScanned, pagesScanned, done: true });
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
