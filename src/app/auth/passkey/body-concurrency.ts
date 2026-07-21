import { acquireConcurrencyMany } from "@/lib/sync/rate-limit";

const GLOBAL_ACTIVE_BODY_LIMIT = 64;
const CLIENT_ACTIVE_BODY_LIMIT = 4;
export const PASSKEY_BODY_DEADLINE_MS = 15_000;

/** Reserve the shared options/verify body-reading budget before consuming bytes. */
export function acquirePasskeyBodyConcurrency(client: string) {
  return acquireConcurrencyMany([
    { key: "auth-body-active:global", limit: GLOBAL_ACTIVE_BODY_LIMIT },
    { key: `auth-body-active:client:${client}`, limit: CLIENT_ACTIVE_BODY_LIMIT }
  ]);
}
