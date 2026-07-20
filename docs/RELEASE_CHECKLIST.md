# Address Atlas Public v1 Release Checklist

Public v1 must not ship unsigned or unnotarized. If no Developer ID Application certificate is available, stop at local beta builds.

## Required Secrets And Accounts

- Apple Developer account with Developer ID Application certificate.
- A `notarytool` Keychain profile created with `xcrun notarytool store-credentials <profile>`; set its name in `ADDRESS_ATLAS_NOTARY_PROFILE`.
- VPS DNS name, `ACME_EMAIL`, strong `POSTGRES_PASSWORD`, matching `SYNC_DATABASE_URL`, and strong `SYNC_SESSION_SECRET`.
- Read-only Binance, Coinbase, and Kraken test credentials kept outside the repo.

## Backend Release

- Publish native app 0.2.0 before enforcing the sync-v2 rollout. Existing sessions must sign in again because token purpose/version binding changed.
- Create `server/sync/.env.production` from `server/sync/.env.production.example`.
- On upgrades, raise any existing `NATIVE_ENDPOINT_CONFIG_VERSION` to at least `5`; lower explicit values now fail closed rather than mislabeling the bundled v5 payload.
- Deploy ordering: if this release bumps the Mac app's bundled endpoint config version, set `NATIVE_ENDPOINT_CONFIG_VERSION` to at least the new bundled value and deploy the sync server BEFORE shipping the client. The Mac app fails closed (503 on both vault upload and download) whenever `/config/native` is unreachable or serves a `configVersion` lower than its bundled value (currently 5; see `NativeEndpointConfig.swift` and `src/lib/sync/native-config.ts`).
- Deploy with `npm run sync:prod:up`; do not invoke the production Compose file directly because the wrapper protects existing PostgreSQL and Caddy volumes.
- Verify `https://<domain>/livez` returns `{ "ok": true, "service": "address-atlas-sync" }`.
- Verify `https://<domain>/healthz` returns `{ "ok": true }`.
- Verify `https://<domain>/config/native` returns the current public endpoint config.
- Verify sync-only mode returns 404 for `/`, `/api/scan`, `/settings`, and other legacy app routes.
- Verify passkey registration/authentication uses the production `PASSKEY_RP_ID` and the exact `https://ADDRESS_ATLAS_DOMAIN` origin derived by Compose.
- Verify `/config/native` reports config version 5 and minimum app version 0.2.0; v1 snapshot GET remains available for migration while new v1 PUT is rejected.

## Mac Release

- Run `npm run release:doctor`; strict release environments should run `./scripts/release-doctor.sh --strict`.
- Run `npm run native:test` from the repository root.
- Run `bash native/AddressAtlasMac/Tests/build-mac-app-version-tests.sh`.
- Run `npm test`, `npm run build`, and `npx tsc --noEmit`.
- Run `npm audit --omit=dev` (also enforced as a blocking CI step) and require zero known production vulnerabilities.
- Run `ADDRESS_ATLAS_CODESIGN_IDENTITY="Developer ID Application: ..." ./native/AddressAtlasMac/build-dmg.sh`.
- Run `ADDRESS_ATLAS_CODESIGN_IDENTITY="Developer ID Application: ..." ADDRESS_ATLAS_NOTARY_PROFILE="<keychain-profile>" ./native/AddressAtlasMac/notarize-mac-app.sh`.
- Verify the app executable contains both `arm64` and `x86_64`, and `codesign --display --verbose=4` reports the runtime flag.
- Verify `spctl --assess` passes on the stapled DMG.

## Manual Smoke

- Install the notarized DMG on a clean Mac profile.
- First launch creates the Keychain-backed local vault.
- Export a recovery kit and verify the displayed code is stored separately.
- Delete the test Keychain item, confirm unlock reports recovery-required without creating a replacement key, then restore from the locked screen with the recovery file + code.
- Add a wallet, scan, and confirm optional RPC warnings are visible if any subrequest fails.
- Add Binance, Coinbase, and Kraken read-only credentials and run a scan.
- Create passkey account on the VPS domain, upload encrypted vault, restart, sign in, download, and confirm decrypt.
- Export CSV and JSON from the latest local snapshot.
- Inspect JSON export and confirm no session token, checksum, account ID, or other sync authentication state is present.

## Data-Safety Checks

- Inspect local SQLite envelope bytes for no wallet address or exchange credential plaintext.
- Inspect `vault_snapshots` rows for no wallet address, balances, credentials, token lists, scan history, or preference plaintext.
- Confirm recovery file is not uploaded to the server and does not contain the raw vault key.
