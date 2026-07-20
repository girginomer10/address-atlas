const EXACT_SYNC_PATHS = new Set([
  "/account",
  "/account/session",
  "/auth/native",
  "/auth/passkey/options",
  "/auth/passkey/verify",
  "/config/native",
  "/healthz",
  "/livez",
  "/vault/latest"
]);

export function isSyncOnlyMode() {
  // Fail closed: the gate is ON unless explicitly disabled with the exact string
  // "false". An unset/typo'd value keeps the allowlist active rather than silently
  // exposing every route. This repo ships only sync routes, so ON is always safe.
  return process.env.ADDRESS_ATLAS_SYNC_ONLY !== "false";
}

export function isSyncOnlyPathAllowed(pathname: string) {
  if (EXACT_SYNC_PATHS.has(pathname)) return true;
  return pathname.startsWith("/_next/");
}
