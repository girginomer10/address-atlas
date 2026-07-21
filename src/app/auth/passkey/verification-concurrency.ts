import { acquireAuthenticationDatabaseConcurrency } from "@/lib/sync/auth-database-concurrency";

const CLIENT_ACTIVE_VERIFICATION_LIMIT = 2;
const CLIENT_ACTIVE_NATIVE_EXCHANGE_LIMIT = 2;

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
  return acquireAuthenticationDatabaseConcurrency(poolSize, [
    { key: `auth-verify-active:client:${client}`, limit: CLIENT_ACTIVE_VERIFICATION_LIMIT },
    { key: `auth-verify-active:credential:${credentialId}`, limit: 1 }
  ]);
}

/**
 * Bound native authorization-code exchanges before they can queue for a pool
 * client. The global key is deliberately shared with passkey verification so
 * all public authentication database work together consumes at most half of
 * the runtime pool. A per-code permit rejects parallel replay attempts before
 * PostgreSQL row/transaction work begins.
 */
export function acquireNativeAuthorizationExchangeConcurrency(
  client: string,
  consumptionKey: string,
  poolSize: number
) {
  return acquireAuthenticationDatabaseConcurrency(poolSize, [
    {
      key: `auth-native-exchange-active:client:${client}`,
      limit: CLIENT_ACTIVE_NATIVE_EXCHANGE_LIMIT
    },
    { key: `auth-native-exchange-active:code:${consumptionKey}`, limit: 1 }
  ]);
}
