import type { PoolClient } from "pg";

/**
 * Authentication transactions that subsequently lock an account-owned child
 * row must lock the parent account first. Account deletion follows the same
 * parent-first order before ON DELETE CASCADE reaches credentials or grants.
 * FOR KEY SHARE allows concurrent authentication but conflicts with deletion.
 */
export async function lockAccountForAuthentication(
  client: Pick<PoolClient, "query">,
  userId: string
) {
  const account = await client.query(
    `SELECT account.id
     FROM users AS account
     WHERE account.id = $1
     FOR KEY SHARE OF account`,
    [userId]
  );
  return account.rowCount === 1;
}
