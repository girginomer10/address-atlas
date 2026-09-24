# Development Notes

## Product Boundary

Address Atlas is a local-first, read-only crypto portfolio tracker. It accepts public wallet addresses and balance/read-only exchange credentials. It must never request seed phrases, wallet private keys, signing permission, trading permission, or withdrawal permission.

There are three runtime components:

- `native/AddressAtlasMac`: the SwiftUI macOS product. It owns plaintext portfolio data, network scans, exchange credentials, local encryption, recovery, export, and sync encryption. Its package also hosts `AddressAtlasCore` and the shared state layer that the iOS app compiles.
- `native/AddressAtlasiOS`: the SwiftUI iOS product for iPhone and iPad. It is an xcodegen-generated Xcode project that links `AddressAtlasCore` and compiles the shared state layer and design system directly from the Mac package sources, adding only its own screens. It is source-only today: verified on the iPhone 17 Pro simulator, with no physical-device, TestFlight, or App Store Connect evidence.
- The current Mac app uses private CloudKit copies and iCloud Keychain; see `docs/ICLOUD.md`. The repository-root Next.js service plus `server/sync` is retained legacy code, no longer a native product dependency. Server-specific invariants below apply to legacy regression testing and separately maintained deployments.

The old Prisma/SQLite web portfolio and ccxt runtime no longer exist. Do not reintroduce them.

## Native Architecture

- `Sources/AddressAtlasCore/Models.swift`: durable vault schema and migration-compatible decoding.
- `Crypto/`: AES-256-GCM, purpose-separated HKDF keys, Keychain storage, exchange-credential envelopes, and recovery kits.
- `Storage/EncryptedSQLiteVaultStore.swift`: one encrypted `VaultDocument` envelope in local SQLite.
- `Storage/VaultPersistenceCoordinator.swift`: actor-isolated projection,
  encryption, persistence, and revision-aware dirty-state computation; UI code
  must not move this work back onto `MainActor`.
- `Sync/`: authenticated sync envelopes, public endpoint configuration, and the
  durable per-origin endpoint-config high-water store. Snapshot account,
  version, and schema metadata are cryptographically bound to the ciphertext.
- `Scanners/`: public-chain scanners, CoinGecko pricing, and native Binance, Coinbase Advanced Trade, and Kraken read-only clients.
- `Sources/AddressAtlasMac/AppState.swift`: UI state transitions, validation, scan orchestration, conflict-safe sync, and bounded snapshot retention.
- `Sources/AddressAtlasMac/AddressAtlasApp.swift`: SwiftUI presentation and recovery/unlock flows (macOS only).
- `Sources/AddressAtlasCore/PlatformCopy.swift`: device nouns for shared
  user-facing copy ("Mac" on macOS, "device" on iOS). Shared strings must
  use it instead of hard-coding a platform noun.
- `native/AddressAtlasiOS/Sources/AddressAtlasiOS`: the iOS entry point
  (`AddressAtlasiOSApp.swift`, `RootView.swift`, `MainShell.swift` with a tab
  shell on iPhone and `NavigationSplitView` on iPad), the Unlock/recovery
  screen, one screen per section (Portfolio, Wallets, Assets, Tokens,
  Snapshots, Exchanges, iCloud, Export, Settings), and `IOSSupport.swift`.
  The target compiles `AddressAtlasCore` and, straight from
  `native/AddressAtlasMac/Sources/AddressAtlasMac`, every `AppState*.swift`
  file plus `UserFacingErrors.swift`, `ICloudVaultService.swift`,
  `PasskeyWebAuthenticator.swift`, `AtlasDesignSystem.swift`,
  `AtlasFormatting.swift`, and `ExportPipeline.swift`. The macOS-only files
  `AddressAtlasApp.swift`, `AppShellViews.swift`, `PortfolioViews.swift`,
  `PortfolioComponents.swift`, `ExchangeSyncViews.swift`,
  `ICloudSyncView.swift`, and `PrivacySafeDiagnosticsView.swift` are
  excluded in `native/AddressAtlasiOS/project.yml`. Any other file added to
  that directory is shared by default: guard platform code with
  `#if canImport(AppKit)` or `#if os(macOS)` rather than adding a new
  exclusion, then run `npm run native:ios:generate` and commit the
  regenerated project (CI fails when a shared source is missing from it).
- Existing platform splits: the theme uses `UIColor` dynamic providers on
  iOS; accessibility announcements use `UIAccessibility`; the iCloud
  entitlement probe in `ICloudVaultService.swift` reads the executable's
  `__TEXT,__entitlements` section or the embedded `embedded.mobileprovision`
  instead of `SecTask` and fails closed when neither grants the container;
  `KeychainVaultKeyStore` forces the macOS legacy-keychain migration off on
  iOS because its delete query would match the freshly saved item.

Exchange origins and sensitive request paths are pinned in the native app. Remote `/config/native` data may change only paths on each chain's bundled HTTPS origin; it cannot change RPC origins. The CoinGecko price origin and path are both fixed. Remote config must never redirect signed exchange requests or credential-bearing headers.

## Local Development

Sync service:

```bash
npm ci
cp .env.example .env
npm run sync:db:up
npm run dev
```

Native app:

```bash
cd native/AddressAtlasMac
./check-toolchain.sh
swift run AddressAtlasMac
```

Native iOS app (full Xcode selected with `xcode-select`; the committed project
needs `xcodegen` only after editing `native/AddressAtlasiOS/project.yml`):

```bash
npm run native:ios:build      # simulator build, Xcode ad-hoc signed
npm run native:ios:run        # build, install, and launch on the booted simulator
npm run native:ios:generate   # after editing project.yml; commit the result
```

The local Postgres port is bound to loopback only. `SYNC_SESSION_SECRET` must be at least 32 random bytes; published example/placeholder values are rejected.

## Service Health And Boot Validation

- `GET /livez` is the edge liveness probe: it returns `{"ok":true,"service":"address-atlas-sync"}` without touching the database or configuration. Caddy's active health check targets it in production so a Postgres blip cannot take every route down at the proxy.
- `GET /healthz` is the deep readiness probe: database connectivity, required schema, and full configuration. The production container healthcheck and external monitoring use it.
- In production, `src/instrumentation.ts` validates configuration at boot and fails fast on a bad `SYNC_SESSION_SECRET`, `PASSKEY_*`, or database configuration, so a misconfigured container exits at start instead of serving requests.
- Production request handling uses a DML-only database role. Schema bootstrap
  is an explicit owner-only one-shot entrypoint; request code must never regain
  DDL or schema-owner credentials.

The deploy, backup, restore, monitoring, and incident contract is documented in
[OPERATIONS.md](OPERATIONS.md).

## Verification

Run the complete local gate before handoff:

```bash
npm test
npm run typecheck
npm run build
npm audit
npm run native:test
(cd native/AddressAtlasMac && swift test --sanitize=thread)
bash native/AddressAtlasMac/Tests/build-mac-app-version-tests.sh
bash native/AddressAtlasMac/Tests/notarize-mac-app-tests.sh
./native/AddressAtlasMac/build-mac-app.sh
npm run native:ios:build:unsigned
./scripts/release-doctor.sh --strict
```

The Postgres integration suite additionally requires `TEST_SYNC_DATABASE_URL`. Live exchange smoke tests are opt-in and require externally supplied read-only credentials. Never store those credentials in the repository, handoff notes, command output, fixtures, or environment examples.

## Vault And Recovery Invariants

- A new vault key may be created only when no existing encrypted vault is present.
- If a vault exists but its Keychain key is missing, unlock must report that recovery is required. It must not create an unrelated replacement key.
- Recovery is available from the locked screen. The recovery file is decrypted and proven against the existing vault before Keychain is changed.
- Keychain replacement must be atomic; a failed update must leave the previous working key intact.
- JSON exports use a redacted DTO and must never contain the sync bearer token, checksums, or other session state.

## Sync Invariants

- The local document tracks whether it differs from the last authenticated remote base.
- Download must never overwrite local changes implicitly. A destructive replacement requires an explicit user decision.
- Upload must compare against the last authenticated remote checksum/version and fail closed on conflicts.
- Changing the sync server or account clears the old bearer token and remote-base metadata.
- Endpoint configuration accepts neither rollback nor same-version
  equivocation across process relaunches. Preserve the durable per-origin
  version+digest high-water record and its cross-process atomicity.
- A remotely enforced minimum app version blocks passkey ceremonies, network
  scans, upload, and download before provider/auth traffic. Local viewing,
  export, and recovery remain available, and the UI must expose the hard-pinned
  GitHub release page. With a sync server configured, a policy-refresh failure
  may use only the last policy accepted for that exact authority in the current
  process, and only while it supports the running app version. A fresh process
  must not use bundled endpoints because the version+digest high-water record
  cannot reconstruct a previously accepted minimum-version rule.
- A policy file that is visible after atomic rename but whose directory sync
  fails remains applied for read-only scans, with a degraded status. Passkey
  binding and every vault upload/download (including interrupted-upload replay)
  remain blocked until a later refresh proves the trust record crash-durable.
- Snapshot version, account ID, schema version, nonce, and ciphertext are authenticated together. Relabeling an old ciphertext with a higher version must fail.
- Scan history is bounded so the encrypted envelope cannot grow forever.

## Scanner Invariants

- Successful balances survive optional token, price, staking, rewards, trustline, or pagination failures and carry visible warnings.
- Network workflows have bounded concurrency and deadlines, and cancellation propagates to outstanding requests.
- Unpriced assets remain visible as unpriced; they are not silently dropped or reported as successfully valued at zero.
- Non-USD fiat balances use CoinGecko's BTC-relative exchange rates to derive USD value. A missing or failed rate must leave the balance unpriced with a visible warning.
- Chain-specific address validation is authoritative. Case-sensitive base58 identifiers must not be lowercased for identity or deduplication.
- Coinbase Advanced Trade uses CDP ES256 JWT authentication. Legacy `CB-ACCESS-SIGN` HMAC must not be used with `/api/v3/brokerage` routes.
- Binance credentials must pass the signed, pinned API-restrictions check before
  they are persisted or scanned; any trading, withdrawal, transfer, margin,
  futures, or unknown capability fails closed. Providers without an
  authoritative scope endpoint must remain visibly `SCOPE UNVERIFIED`.
- XRPL raw 160-bit currency code plus issuer is the durable asset identity.
  Decoded printable text is presentation only and may never collapse distinct
  issued currencies into the same row ID.

## iOS Lifecycle

- Scans and iCloud transfers are foreground-only. The iOS target declares no
  `UIBackgroundModes`.
- When the scene moves to the background, `RootView` takes a UIKit
  background-time assertion and `AppState.flushBeforeSuspension()` writes
  wallet-label drafts and pending persistence through the shared termination
  lane. If iOS expires that time while a scan is still running, the scan is
  cancelled. A scan is also cancelled when the device locks, because the vault
  key and the Kraken installation secret are readable only while the device is
  unlocked. Returning to the foreground clears the shared termination flag so
  the UI is re-enabled. The local store directory is excluded from device
  backups (the key never restores, so a restored database could only block
  first launch); the iCloud copy and the recovery kit are the cross-device
  paths.
- There is no termination hook. iOS may suspend and later kill the process
  without notice, so nothing may depend on the macOS quit path running on
  iOS; durable state must already be flushed when the app is backgrounded.

## Distribution

`build-mac-app.sh` creates a universal `arm64` + `x86_64` app by default and signs it with hardened runtime. Set `ADDRESS_ATLAS_ARCHS=arm64` only for an explicitly local Apple-Silicon build. Its default `CFBundleVersion` is the full Git commit count; supply a unique `ADDRESS_ATLAS_BUILD_NUMBER` in shallow CI or release checkouts.

For public notarization, first save credentials in Keychain without placing the password in process arguments:

```bash
xcrun notarytool store-credentials address-atlas-notary
```

Then set `ADDRESS_ATLAS_CODESIGN_IDENTITY` and
`ADDRESS_ATLAS_NOTARY_PROFILE=address-atlas-notary`. In isolated CI, the same
script accepts `ADDRESS_ATLAS_NOTARY_KEY_PATH`,
`ADDRESS_ATLAS_NOTARY_KEY_ID`, and `ADDRESS_ATLAS_NOTARY_ISSUER_ID` together;
it refuses mixed or partial credential modes. Public distribution is blocked
until signing, an explicit Apple `Accepted` result, stapling, Gatekeeper, and
DMG verification all succeed.

The create-once release workflow is `.github/workflows/release.yml`. It requires
an existing `v<currentAppVersion>` tag on `main`, a protected `release`
environment, GitHub release immutability, and the secrets documented in
`docs/RELEASE_CHECKLIST.md`.
