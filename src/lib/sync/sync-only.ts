const EXACT_SYNC_PATHS = new Set([
  "/auth/native",
  "/auth/passkey/options",
  "/auth/passkey/verify",
  "/healthz",
  "/vault/latest"
]);

export function isSyncOnlyMode() {
  return process.env.ADDRESS_ATLAS_SYNC_ONLY === "true";
}

export function isSyncOnlyPathAllowed(pathname: string) {
  if (EXACT_SYNC_PATHS.has(pathname)) return true;
  return pathname.startsWith("/_next/");
}
