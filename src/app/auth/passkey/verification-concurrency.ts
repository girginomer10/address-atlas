import { acquireConcurrencyMany } from "@/lib/sync/rate-limit";

const CLIENT_ACTIVE_VERIFICATION_LIMIT = 2;

/**
 * Bound the phase that can hold a PostgreSQL client and credential row lock.
 * At most half of this process's pool may serve public passkey verification,
 * preserving capacity for vault, account, and readiness traffic. A credential
 * permit also rejects parallel assertion replays before they queue on SQL.
 */
export function acquirePasskeyVerificationConcurrency(
  client: string,
  credentialId: string,
  poolSize: number
) {
  if (!Number.isSafeInteger(poolSize) || poolSize < 2) {
    throw new Error("Passkey verification requires a database pool with reserved capacity.");
  }
  const globalLimit = Math.floor(poolSize / 2);
  return acquireConcurrencyMany([
    { key: "auth-verify-active:global", limit: globalLimit },
    { key: `auth-verify-active:client:${client}`, limit: CLIENT_ACTIVE_VERIFICATION_LIMIT },
    { key: `auth-verify-active:credential:${credentialId}`, limit: 1 }
  ]);
}
