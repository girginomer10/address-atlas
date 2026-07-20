# Development Notes

## Product Boundary

Address Atlas is a local-first, read-only crypto portfolio tracker. It accepts public wallet addresses and balance/read-only exchange credentials. It must never request seed phrases, wallet private keys, signing permission, trading permission, or withdrawal permission.

There are two runtime components:

- `native/AddressAtlasMac`: the SwiftUI macOS product. It owns plaintext portfolio data, network scans, exchange credentials, local encryption, recovery, export, and sync encryption.
- The repository-root Next.js service plus `server/sync`: a passkey-authenticated sync service. It stores passkey public keys and opaque encrypted vault snapshots in Postgres. It must not receive plaintext addresses, balances, token lists, exchange credentials, preferences, or recovery material.

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
- `Sources/AddressAtlasMac/AddressAtlasApp.swift`: SwiftUI presentation and recovery/unlock flows.

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
  GitHub release page.
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
