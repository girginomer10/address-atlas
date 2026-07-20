# Address Atlas

Address Atlas is a local-first, read-only crypto portfolio tracker for macOS. Paste public wallet addresses, connect read-only exchange API keys, and keep a private, encrypted portfolio ledger on your own Mac.

The repo is organized as a small monorepo:

- `native/AddressAtlasMac` is the macOS app — the product users run. It uses a random vault key stored in macOS Keychain, writes only encrypted vault documents to local SQLite, runs RPC/API requests from the Mac app, and syncs only opaque encrypted vault snapshots to the server.
- The Next.js project at the repo root, together with `server/sync`, is the **encrypted sync-only server** — the backend the Mac app talks to for passkey auth and cross-device vault sync. It exposes only the native auth/config, vault, health, session-revocation, and account-deletion surface; stores opaque encrypted snapshots; and never sees plaintext. `server/sync` packages it with Docker, Caddy TLS, and Postgres.

## Why this exists

This repo is a cleaner follow-up to earlier hackathon experiments:

- HodlTrack had useful balance fetching, chain config, CoinGecko pricing, and local portfolio UI ideas.
- FluxTranche had useful portfolio modeling ideas, a coin-to-chain registry direction, and a strong no-custody framing.
- Address Atlas keeps the reusable parts and drops fund-management, trading, auth, and AI claims.

## Current scope

- Bitcoin native balance via Blockstream.
- Solana native SOL balance plus common SPL tokens via public Solana RPC.
- EVM native balances across Ethereum, Base, Arbitrum, Optimism, Polygon, BNB Chain, Avalanche, Gnosis, Linea, Mantle, Scroll, and ZKsync Era.
- Common ERC-20 stablecoins, wrapped assets, and blue-chip/ecosystem tokens on supported EVM chains.
- TRON native TRX plus tracked TRC20 tokens.
- XRP Ledger native XRP plus positive issued-currency trustline balances.
- Cosmos liquid, delegated, and reward balances for Cosmos Hub, Osmosis, Celestia, and Stride. Legacy Stargaze records remain readable but are retained without scanning because that network is retired.
- Read-only exchange balances through Binance, Coinbase Advanced Trade (CDP ES256 JWT), and Kraken via native Swift REST clients.
- A local encrypted SQLite vault for watched wallets, holdings, exchange connections, and preferences.
- AES-256-GCM encryption for the vault, using a Keychain-backed vault subkey.
- Crypto USD prices and BTC-relative fiat conversion rates through CoinGecko; unsupported or unavailable rates remain visibly unpriced.
- CSV and redacted JSON export from the latest local snapshot; sync sessions and authentication metadata are never exported.
- Visible partial-scan warnings when optional token, price, staking, reward, trustline, or pagination requests fail.
- Working 15-minute in-app auto-refresh and an optional USD dust filter.
- Native macOS UI: Portfolio, Wallets, Assets, Snapshots, Export, and Settings.

## Sync server (local) development

The repo root is the encrypted sync-only server (Next.js). For local development, start the bundled Postgres, set the env, and run the server:

```bash
npm install
cp .env.example .env   # set SYNC_SESSION_SECRET and the Postgres URL
npm run sync:db:up
npm run dev
```

`npm test` runs the server unit tests and `npm run typecheck` runs the TypeScript checks. The macOS app (below) is what end users actually run.

## Native macOS development

The native app lives in `native/AddressAtlasMac` as a Swift Package with an executable SwiftUI target and testable core library:

```bash
cd native/AddressAtlasMac
./check-toolchain.sh
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift run AddressAtlasMac
```

`swift test` requires full Xcode for XCTest. The local `.app` bundle is universal (`arm64` + `x86_64`), hardened-runtime, and ad-hoc signed by default; it can be built with either full Xcode or the Homebrew Swift.org toolchain:

```bash
cd native/AddressAtlasMac
./build-mac-app.sh
open "dist/Address Atlas.app"
```

Set `ADDRESS_ATLAS_CODESIGN_IDENTITY` before running `./build-mac-app.sh` when a Developer ID Application identity is available for distribution signing.
The script derives `CFBundleVersion` from the full Git commit count. Shallow CI/release checkouts must supply a unique `ADDRESS_ATLAS_BUILD_NUMBER`; the script fails closed instead of reusing an ambiguous build number.

Public macOS distribution uses a signed, notarized, create-once GitHub Release.
The release workflow accepts only a version tag whose commit is already on
`main`, imports signing material into an ephemeral Keychain, verifies Apple's
notarization/stapling result, and publishes a DMG with checksums and a provenance
manifest. GitHub release immutability must be enabled, and the protected
`release` environment must contain the Apple and Administration-read secrets
listed in `docs/RELEASE_CHECKLIST.md`.

For an operator-driven local notarization, use a Keychain profile without
placing credentials in arguments:

```bash
cd native/AddressAtlasMac
xcrun notarytool store-credentials address-atlas-notary
ADDRESS_ATLAS_CODESIGN_IDENTITY="Developer ID Application: ..." \
ADDRESS_ATLAS_NOTARY_PROFILE="address-atlas-notary" \
./notarize-mac-app.sh
```

CI uses the script's alternative App Store Connect key-file contract. Run
`bash Tests/notarize-mac-app-tests.sh` after changing release tooling.

The app stores its local vault in `~/Library/Application Support/AddressAtlas/vault.sqlite`. The SQLite table stores encrypted envelope JSON only; wallet addresses, exchange credentials, scan history, token lists, and preferences are encrypted before persistence.

Settings includes a recovery kit flow. Export creates a `.atlas-recovery` file plus a high-entropy recovery code shown once. The file and code are both required to unwrap the Mac vault key; neither is uploaded to the sync server. If the Keychain key is missing, recovery is available directly from the locked screen and the app does not create an unrelated replacement key.

The encrypted sync server uses a schema-owner connection only during the
one-shot bootstrap and a separate DML-only connection while serving requests:

```bash
SYNC_SCHEMA_DATABASE_URL="postgres://address_atlas:owner-password@..."
SYNC_DATABASE_URL="postgres://address_atlas_runtime:runtime-password@..."
SYNC_SESSION_SECRET="long-random-secret"
PASSKEY_RP_ID="example.com"
PASSKEY_RP_NAME="Address Atlas"
PASSKEY_ORIGIN="https://example.com"
```

For local sync development, start the bundled Postgres service first:

```bash
npm run sync:db:up
```

For a production VPS, copy `.env.production.example` to `.env.production`, fill
the production domain and secrets, configure the age backup recipient/identity,
and then start the sync-only stack. Generate independent owner and runtime
PostgreSQL passwords with `openssl rand -hex 32`:

```bash
cp server/sync/.env.production.example server/sync/.env.production
npm run sync:prod:up
curl https://your-domain.example/healthz
```

Always deploy through `npm run sync:prod:up`. Its preflight reconnects the authoritative PostgreSQL and Caddy volumes across historical Compose project names and refuses ambiguous selections; invoking the production Compose file directly bypasses that safeguard.

The same gate requires a fresh encrypted and decrypt-verified database backup,
builds an image tagged with the exact clean Git SHA, bootstraps schema through
the owner-only job, verifies the DML-only runtime role, and then replaces the
web service. Scheduled backup, restore drill, monitoring, rollback, and incident
procedures live in [docs/OPERATIONS.md](docs/OPERATIONS.md). Its separately
gated fresh-cluster path restores only signed schema-v4 artifacts, resumes
across power loss, and does not declare success until the current web release
passes public smoke and persists its native-config receipt.

`server/sync/compose.prod.yml` runs Caddy, the Next sync/auth server, and Postgres. `ADDRESS_ATLAS_SYNC_ONLY=true` limits the public VPS to `/auth/native`, `/auth/passkey/*`, `/config/native`, `/vault/latest`, and `/healthz`.

Startup readiness validates the session secret, Postgres URL and timeouts, passkey RP/origin, capacity limits, and explicit native endpoint configuration. Missing required values or malformed explicit overrides keep `/healthz` at 503 instead of silently using production fallbacks.

Sync endpoints are intentionally narrow: passkey options/verification,
encrypted vault GET/PUT, bearer-session revocation, and confirmed account
deletion. The server stores passkey public keys plus encrypted vault snapshot
metadata; it does not store decryptable keys or plaintext portfolio data.

The Mac app opens `/auth/native` in a system web authentication session for passkey account creation/sign-in, then receives only a short-lived sync session token through the `address-atlas://sync-auth` callback URL.

`GET /config/native` returns public endpoint config for approved blockchain RPC and price providers. Exchange origins, credential-bearing routes, and request methods are pinned in the native binary and cannot be redirected by the sync server. The Mac app still sends scan requests client-side; the config endpoint does not receive wallet addresses or vault data.

Opt-in live exchange smoke tests are available for release QA. They run only when explicitly enabled and credentials are supplied out of band:

```bash
cd native/AddressAtlasMac
ADDRESS_ATLAS_LIVE_EXCHANGE_TESTS=1 \
ADDRESS_ATLAS_BINANCE_API_KEY="..." \
ADDRESS_ATLAS_BINANCE_SECRET="..." \
ADDRESS_ATLAS_COINBASE_API_KEY="..." \
ADDRESS_ATLAS_COINBASE_SECRET="..." \
ADDRESS_ATLAS_COINBASE_PASSPHRASE="..." \
ADDRESS_ATLAS_KRAKEN_API_KEY="..." \
ADDRESS_ATLAS_KRAKEN_SECRET="..." \
swift test
```

## Security notes

Address Atlas never asks for seed phrases, private keys, signing permissions, trading permissions, or withdrawal permissions. Exchange API keys should be created with balance/read permission only. In the native app, credentials are encrypted with a vault subkey before local persistence and sync. Public RPC, exchange, and price endpoints can rate-limit or fail, so scan results should be treated as portfolio visibility, not accounting-grade proof.
