# Address Atlas Public v1 Release Checklist

Public v1 must not ship unsigned or unnotarized. If no Developer ID Application certificate is available, stop at local beta builds.

## Required Secrets And Accounts

- Apple Developer account with Developer ID Application certificate.
- Notary credentials: `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_SPECIFIC_PASSWORD`.
- VPS DNS name, `ACME_EMAIL`, strong `POSTGRES_PASSWORD`, matching `SYNC_DATABASE_URL`, and strong `SYNC_SESSION_SECRET`.
- Read-only Binance, Coinbase, and Kraken test credentials kept outside the repo.

## Backend Release

- Create `server/sync/.env.production` from `server/sync/.env.production.example`.
- Deploy with `docker compose --env-file server/sync/.env.production -f server/sync/compose.prod.yml up -d --build`.
- Verify `https://<domain>/healthz` returns `{ "ok": true }`.
- Verify `https://<domain>/config/native` returns the current public endpoint config.
- Verify sync-only mode returns 404 for `/`, `/api/scan`, `/settings`, and other legacy app routes.
- Verify passkey registration/authentication uses the production `PASSKEY_RP_ID` and `PASSKEY_ORIGIN`.

## Mac Release

- Run `npm run release:doctor`; strict release environments should run `./scripts/release-doctor.sh --strict`.
- Run `swift test`.
- Run `npm test`, `npm run build`, and `npx tsc --noEmit`.
- Run `ADDRESS_ATLAS_CODESIGN_IDENTITY="Developer ID Application: ..." ./native/AddressAtlasMac/build-dmg.sh`.
- Run `./native/AddressAtlasMac/notarize-mac-app.sh`.
- Verify `spctl --assess` passes on the stapled DMG.

## Manual Smoke

- Install the notarized DMG on a clean Mac profile.
- First launch creates the Keychain-backed local vault.
- Export a recovery kit and verify the displayed code is stored separately.
- Restore from recovery file + code after deleting the test Keychain item.
- Add a wallet, scan, and confirm optional RPC warnings are visible if any subrequest fails.
- Add Binance, Coinbase, and Kraken read-only credentials and run a scan.
- Create passkey account on the VPS domain, upload encrypted vault, restart, sign in, download, and confirm decrypt.
- Export CSV and JSON from the latest local snapshot.

## Data-Safety Checks

- Inspect local SQLite envelope bytes for no wallet address or exchange credential plaintext.
- Inspect `vault_snapshots` rows for no wallet address, balances, credentials, token lists, scan history, or preference plaintext.
- Confirm recovery file is not uploaded to the server and does not contain the raw vault key.
