# Address Atlas

Address Atlas is a local-first, read-only crypto portfolio tracker. Paste public wallet addresses, connect read-only exchange API keys, and keep a private portfolio ledger on your own machine.

The repo is organized as a small monorepo:

- The existing Next.js app remains as the web/reference implementation.
- `native/AddressAtlasMac` is the new native macOS implementation. It uses a random vault key stored in macOS Keychain, writes only encrypted vault documents to local SQLite, runs RPC/API requests from the Mac app, and syncs only opaque encrypted vault snapshots to the server.
- `server/sync` is the production deployment target for the public sync/auth server. It packages the Next server with Docker, Caddy TLS, Postgres, and sync-only route exposure.

## Why this exists

This repo is a cleaner follow-up to earlier hackathon experiments:

- HodlTrack had useful balance fetching, chain config, CoinGecko pricing, and local portfolio UI ideas.
- FluxTranche had useful portfolio modeling ideas, a coin-to-chain registry direction, and a strong no-custody framing.
- Address Atlas keeps the reusable parts and drops fund-management, trading, auth, and AI claims.

## Current scope

- Bitcoin native balance via Blockstream.
- Solana native SOL balance via public Solana RPC.
- EVM native balances across Ethereum, Base, Arbitrum, Optimism, Polygon, BNB Chain, and Avalanche.
- Common ERC-20 stablecoins and blue-chip tokens on supported EVM chains.
- TRON native TRX plus tracked TRC20 tokens.
- XRP Ledger native XRP plus positive issued-currency trustline balances.
- Cosmos liquid, delegated, and reward balances for Cosmos Hub, Osmosis, Celestia, Stargaze, and Stride.
- Read-only exchange balances through Binance, Coinbase, and Kraken. The web reference uses ccxt; the native Mac app uses Swift REST clients.
- Local SQLite persistence for watched wallets, scan runs, holdings, exchange connections, preferences, and vault metadata.
- AES-256-GCM encryption for exchange API credentials. The web reference uses a local vault passphrase; the native Mac app uses a Keychain-backed vault subkey.
- USD prices through CoinGecko.
- CSV and JSON export from the latest local snapshot.
- Partial scan warnings when optional token, staking, reward, or trustline requests fail.
- Route-based UI: Portfolio, Wallets, Assets, Snapshots, Export, and Settings.

## Local development

```bash
npm install
npm run db:push
npm run dev
```

Then open `http://localhost:3000` or the port printed by Next.js.

The default SQLite database is `.data/address-atlas.db`. You can override it with `DATABASE_URL`, for example:

```bash
DATABASE_URL="file:./.data/address-atlas.db"
```

## Native macOS development

The native app lives in `native/AddressAtlasMac` as a Swift Package with an executable SwiftUI target and testable core library:

```bash
cd native/AddressAtlasMac
./check-toolchain.sh
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift run AddressAtlasMac
```

`swift test` requires full Xcode for XCTest. The local `.app` bundle is ad-hoc signed by default and can be built with either full Xcode or the Homebrew Swift.org toolchain:

```bash
cd native/AddressAtlasMac
./build-mac-app.sh
open "dist/Address Atlas.app"
```

Set `ADDRESS_ATLAS_CODESIGN_IDENTITY` before running `./build-mac-app.sh` when a Developer ID Application identity is available for distribution signing.

Public macOS distribution uses a signed, notarized DMG. A public release is blocked until an Apple Developer ID Application certificate is available:

```bash
cd native/AddressAtlasMac
./build-dmg.sh
ADDRESS_ATLAS_CODESIGN_IDENTITY="Developer ID Application: ..." \
APPLE_ID="apple-id@example.com" \
APPLE_TEAM_ID="TEAMID" \
APPLE_APP_SPECIFIC_PASSWORD="app-specific-password" \
./notarize-mac-app.sh
```

The app stores its local vault in `~/Library/Application Support/AddressAtlas/vault.sqlite`. The SQLite table stores encrypted envelope JSON only; wallet addresses, exchange credentials, scan history, token lists, and preferences are encrypted before persistence.

Settings includes a recovery kit flow. Export creates a `.atlas-recovery` file plus a high-entropy recovery code shown once. The file and code are both required to unwrap the Mac vault key; neither is uploaded to the sync server.

The encrypted sync server uses these environment variables:

```bash
SYNC_DATABASE_URL="postgres://..."
SYNC_SESSION_SECRET="long-random-secret"
PASSKEY_RP_ID="example.com"
PASSKEY_RP_NAME="Address Atlas"
PASSKEY_ORIGIN="https://example.com"
```

For local sync development, start the bundled Postgres service first:

```bash
npm run sync:db:up
```

For a production VPS, copy `.env.production.example` to `.env.production`, fill the production domain and secrets, keep `POSTGRES_PASSWORD` and `SYNC_DATABASE_URL` in agreement, then start the sync-only stack:

```bash
cp server/sync/.env.production.example server/sync/.env.production
npm run sync:prod:up
curl https://your-domain.example/healthz
```

`server/sync/compose.prod.yml` runs Caddy, the Next sync/auth server, and Postgres. `ADDRESS_ATLAS_SYNC_ONLY=true` limits the public VPS to `/auth/native`, `/auth/passkey/*`, `/config/native`, `/vault/latest`, and `/healthz`.

Sync endpoints are intentionally narrow: `POST /auth/passkey/options`, `POST /auth/passkey/verify`, `GET /vault/latest`, and `PUT /vault/latest`. The server stores passkey public keys plus encrypted vault snapshot metadata; it does not store decryptable keys or plaintext portfolio data.

The Mac app opens `/auth/native` in a system web authentication session for passkey account creation/sign-in, then receives only a short-lived sync session token through the `address-atlas://sync-auth` callback URL.

`GET /config/native` returns public endpoint config for blockchain RPC, price, and exchange base URLs. This lets the server operator rotate public providers without shipping a new Mac app. The Mac app still sends scan requests client-side; the config endpoint does not receive wallet addresses or vault data. If a provider URL changes, users get it after refreshing endpoint config or before the next scan.

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
