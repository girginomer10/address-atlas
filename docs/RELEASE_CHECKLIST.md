# Address Atlas Public Release Checklist

The direct-download and Mac App Store channels use different certificates, packages, update destinations, and publication state. Never treat a GitHub tag/DMG as a Mac App Store action. A direct public build must be Developer ID signed and notarized; a store build must be App Store distribution signed, sandboxed, validated, uploaded, processed, reviewed, and released through App Store Connect.

## Required Secrets And Accounts

- Apple Developer account with Developer ID Application certificate.
- Local releases: a `notarytool` Keychain profile created with
  `xcrun notarytool store-credentials <profile>` and named by
  `ADDRESS_ATLAS_NOTARY_PROFILE`.
- Automated releases: a protected GitHub `release` environment containing
  `APPLE_DEVELOPER_ID_CERTIFICATE_P12_BASE64`,
  `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD`,
  `APPLE_NOTARY_KEY_P8_BASE64`, `APPLE_NOTARY_KEY_ID`,
  `APPLE_NOTARY_ISSUER_ID`, `APPLE_DEVELOPER_TEAM_ID`, and a fine-grained
  `RELEASE_ADMIN_WRITE_TOKEN` limited to this repository's Administration
  write permission. GitHub requires ruleset-write authority to return the
  `bypass_actors` field; the workflow performs no settings mutation. Add the
  protected environment variables `ADDRESS_ATLAS_PRODUCTION_ORIGIN` (the exact
  HTTPS sync origin) and `ADDRESS_ATLAS_RULESET_BYPASS_ALLOWLIST_JSON`.
- Set `ADDRESS_ATLAS_RULESET_BYPASS_ALLOWLIST_JSON` to the exact reviewed
  actor/type/mode set, for example
  `{"main":[],"releaseTags":[{"actor_id":123,"actor_type":"Integration","bypass_mode":"always"}]}`.
  Replace the example actor with the repository's real release actor. Main may
  contain only `pull_request` bypasses; an `always` bypass on main, a missing
  API field, an unexpected actor, or a mode mismatch blocks publication.
- Protect that environment with the exact reviewer policy committed in
  `.github/release-environment-policy.json`: the sole required reviewer is the
  GitHub user with immutable ID `67194558` (`girginomer10` at the time of this
  review), self-review is prevented, and **Allow administrators to bypass
  configured protection rules** is disabled. This is an external GitHub
  environment setting, not something the workflow can establish. Before a
  release, verify the live environment API reports `can_admins_bypass: false`;
  a missing field, a renamed/replaced reviewer ID, an extra reviewer, or an
  enabled administrator bypass is a release blocker. Keep the deployment-tag
  policy limited to reviewed `v*` tags. Protect `main` and release-tag creation with a
  ruleset that requires the complete CI workflow, blocks force pushes/deletion,
  and prevents direct unreviewed changes. Keep exactly one active branch
  ruleset and one active `v*` tag ruleset so the workflow can prove the complete
  bypass surface. Secrets are not safe merely because a
  workflow contains shell preflight checks: the environment policy is the
  authorization boundary.
- GitHub Release immutability enabled for `girginomer10/address-atlas`. The
  workflow proves this setting and refuses publication when it is disabled.
- Restrict Actions to approved, SHA-pinned actions and enable dependency/security
  update alerts before releasing. Treat any broader repository setting as an
  explicit release blocker, not a warning.
- VPS DNS name, `ACME_EMAIL`, independent schema-owner/runtime PostgreSQL
  passwords and URLs, strong `SYNC_SESSION_SECRET`, and a root-owned age backup
  identity with an off-host recovery copy.
- Read-only Binance, Coinbase, and Kraken test credentials kept outside the repo.

## Backend Release

- Publish native app 0.2.0 before enforcing the sync-v2 rollout. Existing sessions must sign in again because token purpose/version binding changed.
- Create `server/sync/.env.production` from `server/sync/.env.production.example`.
- Keep `SYNC_REGISTRATION_ENABLED=false` outside a deliberate enrollment
  window. Confirm the durable hourly registration limit and global/per-account
  ingress budgets are explicit.
- Run `npm run sync:backup`, `npm run sync:backup:verify`, and
  `npm run sync:restore:drill` before the first release. Install the supplied
  RPO-compliant backup, weekly restore-drill, and one-minute monitor timers.
  Block production release until the external paging integration proves that
  three consecutive nonzero monitor executions create exactly one incident,
  a subsequent healthy execution creates exactly one recovery notification,
  and the fired test evidence (event IDs or screenshots, UTC timestamps,
  routing destination, and paging rule version) has been retained.
- Prove one complete signed schema-v4 backup can be retrieved from immutable
  offsite storage and bootstrap a destroyed PostgreSQL volume. At least
  quarterly, time the full cross-host exercise—including recovery keys,
  environment, source/images, DNS/TLS, public smoke, and passkey vault sync—
  against the 60-minute RTO.
- On upgrades, raise any existing `NATIVE_ENDPOINT_CONFIG_VERSION` to at least `5`; lower explicit values now fail closed rather than mislabeling the bundled v5 payload.
- Deploy ordering: if this release bumps the Mac app's bundled endpoint config version, set `NATIVE_ENDPOINT_CONFIG_VERSION` to at least the new bundled value and deploy the sync server BEFORE shipping the client. The Mac app fails closed (503 on both vault upload and download) whenever `/config/native` is unreachable or serves a `configVersion` lower than its bundled value (currently 5; see `NativeEndpointConfig.swift` and `src/lib/sync/native-config.ts`).
- Deploy with `npm run sync:prod:up`; do not invoke the production Compose file directly because the wrapper protects existing PostgreSQL and Caddy volumes.
- Confirm deployment reports a verified pre-deploy backup, the exact Git SHA
  image tag, successful owner-only schema bootstrap, and validated
  `address_atlas_runtime` least-privilege grants.
- Before pushing a release tag, deploy that exact reviewed commit to the sync
  server and prove its public `/config/native` response is bound to the same
  40-character revision. The release workflow rejects a tag whose commit is not
  already the exact live server revision at `ADDRESS_ATLAS_PRODUCTION_ORIGIN`.
- Verify `https://<domain>/livez` returns `{ "ok": true, "service": "address-atlas-sync" }`.
- Verify `https://<domain>/healthz` returns `{ "ok": true, "service": "address-atlas-sync" }`.
- Verify `https://<domain>/config/native` returns the current public endpoint config.
- Verify sync-only mode returns 404 for `/`, `/api/scan`, `/settings`, and other legacy app routes.
- Verify passkey registration/authentication uses the production `PASSKEY_RP_ID` and the exact `https://ADDRESS_ATLAS_DOMAIN` origin derived by Compose.
- Verify `/config/native` reports config version 5 and minimum app version 0.2.0; v1 snapshot GET remains available for migration while new v1 PUT is rejected.
- Verify session revocation invalidates the bearer token; account deletion
  requires a passkey session issued within the last five minutes; and confirmed account
  deletion cascades passkeys, sessions, quota records, and the opaque snapshot
  while the global byte counter remains correct.
- Inspect Caddy/web JSON logs: exact IPs, Authorization/Cookie headers, auth
  callback values, bearer tokens, and user data must be absent.

## Mac Release

### Direct download (Developer ID + notarization)

- Run `npm run release:doctor`; strict release environments should run `./scripts/release-doctor.sh --strict`.
- Run `npm run native:test` from the repository root.
- Run `cd native/AddressAtlasMac && swift test --sanitize=thread`.
- Run `bash native/AddressAtlasMac/Tests/build-mac-app-version-tests.sh`.
- Run `bash native/AddressAtlasMac/Tests/notarize-mac-app-tests.sh`.
- Run `npm test`, `npm run build`, and `npx tsc --noEmit`.
- Run `npm audit` (also enforced as a blocking CI step) and require zero known vulnerabilities in production and build/test dependencies.
- Run `ADDRESS_ATLAS_CODESIGN_IDENTITY="Developer ID Application: ..." ./native/AddressAtlasMac/build-dmg.sh`.
- Run `ADDRESS_ATLAS_CODESIGN_IDENTITY="Developer ID Application: ..." ADDRESS_ATLAS_NOTARY_PROFILE="<keychain-profile>" ./native/AddressAtlasMac/notarize-mac-app.sh`.
- Verify the app executable contains both `arm64` and `x86_64`, and `codesign --display --verbose=4` reports the runtime flag.
- Verify `spctl --assess` passes on the stapled DMG.
- Create and push `v<currentAppVersion>` only from a reviewed commit already on
  `main`. The workflow is tag-push-only: let `.github/workflows/release.yml`
  stage, verify, and publish exactly once; never replace an existing release or
  asset and never add an unprotected manual-dispatch path.
- Confirm GitHub's immutable-release attestation verifies for all three assets:
  the signed/notarized DMG, SHA-256 file, and JSON provenance manifest. Verify
  the app's hard-pinned “Get Latest Version” action opens that exact repository's
  latest-release page.

### Mac App Store

- Complete every code/test/data-safety gate in this checklist, then run `npm run native:mas:contracts` and `npm run native:mas:screenshots`.
- Inspect all five exact `1440x900`, no-alpha, English (U.S.) screenshots under `app-store/screenshots/en-US/`; they must show fictional data, a full unclipped app shell, and no placeholder service represented as production.
- Create the App Store Connect macOS record before the first build. Verify the explicit App ID, record, and signed bundle all use `com.addressatlas.mac`; record the numeric Apple ID rather than inventing one.
- Install an Apple/Mac App Distribution identity and Mac Installer Distribution identity. Provide a Mac App Store Connect distribution provisioning profile for `com.addressatlas.mac`; the custom build path requires it to authorize the signed App ID used by Data Protection Keychain.
- On a clean `main` checkout whose `HEAD` matches `origin/main`, set `ADDRESS_ATLAS_APP_STORE_ID`, `ADDRESS_ATLAS_MAS_CODESIGN_IDENTITY`, `ADDRESS_ATLAS_MAS_INSTALLER_IDENTITY`, and `ADDRESS_ATLAS_PROVISIONING_PROFILE`, then run `npm run native:mas:package`. Preserve the generated read-only provenance plist alongside the package; the source commit is embedded in the signed app and bound to the package SHA-256, version, bundle, signing team, and App Store record.
- Verify the package contains the universal app at `/Applications`, the app and package authorities belong to the intended team, the signed App ID/team entitlements match the embedded profile, App Sandbox has only outgoing network plus user-selected read/write access, and no debug/temporary-exception entitlement is present.
- Complete App Store Connect contracts, DSA status, age rating, category, price/tax, storefront availability, privacy answers, privacy/support URLs, review contact, review notes, screenshots, and data-source/brand authorization evidence. Confirm CoinGecko licensing covers a public-facing product; endpoint availability alone is not license evidence.
- On a clean macOS account, prove sandbox network requests, file import/export, recovery, and account deletion. Separately prove legacy Application Support container migration and legacy-to-Data-Protection-Keychain migration without touching a real user's only vault.
- Confirm `xcrun altool --help` works. Configure exactly one supported least-privilege authentication mode: a team API key with issuer UUID plus an explicit owner-private absolute `ADDRESS_ATLAS_ASC_P8_PATH`, or an individual Apple ID plus an app-specific password stored in Keychain and referenced by `ADDRESS_ATLAS_ASC_PASSWORD_KEYCHAIN_ITEM`. Never pass the password itself through an environment variable. Run `npm run native:mas:validate`, then `npm run native:mas:upload` only for the final reviewed commit/build number.
- Re-read the build in App Store Connect. A successful upload is not a processed build; a processed build is not App Review approval; approval is not storefront availability. Submit the completed version for review and release it only after the configured manual-release gate.
- Do **not** push a `v*` tag as part of this sequence; that invokes the separate Developer ID DMG workflow.

## Manual Smoke

- Install the notarized DMG on a clean Mac profile.
- First launch creates the Keychain-backed local vault.
- Export a recovery kit and verify the displayed code is stored separately.
- Delete the test Keychain item, confirm unlock reports recovery-required without creating a replacement key, then restore from the locked screen with the recovery file + code.
- Add a wallet, scan, and confirm optional RPC warnings are visible if any subrequest fails.
- Add Binance, Coinbase, and Kraken read-only credentials and run a scan.
- Confirm Binance rejects every trading/withdrawal/transfer/margin/futures or
  unknown permission before saving. Confirm Coinbase/Kraken show the honest
  `SCOPE UNVERIFIED` state rather than claiming server-verified safety.
- Raise the server minimum above the installed build and verify passkey auth,
  scanning, upload, and download all stop before network/provider traffic while
  viewing/export/recovery and the pinned update action remain available.
- Relaunch after accepting a higher endpoint-config version; verify an older or
  same-version/different-digest response remains rejected across the relaunch.
- Create passkey account on the VPS domain, upload encrypted vault, restart, sign in, download, and confirm decrypt.
- Export CSV and JSON from the latest local snapshot.
- Inspect JSON export and confirm no session token, checksum, account ID, or other sync authentication state is present.

## Data-Safety Checks

- Inspect local SQLite envelope bytes for no wallet address or exchange credential plaintext.
- Inspect `vault_snapshots` rows for no wallet address, balances, credentials, token lists, scan history, or preference plaintext.
- Confirm recovery file is not uploaded to the server and does not contain the raw vault key.
