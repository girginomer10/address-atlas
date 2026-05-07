# Address Atlas

Address Atlas is a local-first, read-only crypto portfolio tracker. Paste public wallet addresses, connect read-only exchange API keys, and keep a private portfolio ledger on your own machine.

The repo now contains two tracks:

- The existing Next.js app remains as the web/reference implementation.
- `native/AddressAtlasMac` is the new native macOS implementation. It uses a random vault key stored in macOS Keychain, writes only encrypted vault documents to local SQLite, runs RPC/API requests from the Mac app, and syncs only opaque encrypted vault snapshots to the server.

## Why this exists

This repo is a cleaner follow-up to earlier hackathon experiments:

- HodlTrack had useful balance fetching, chain config, CoinGecko pricing, and local portfolio UI ideas.
- FluxTranche had useful portfolio modeling ideas, a coin-to-chain registry direction, and a strong no-custody framing.
- Address Atlas keeps the reusable parts and drops fund-management, trading, auth, and AI claims.

## Current scope

- Bitcoin native balance via Blockstream.
- Solana native SOL balance via public Solana RPC.
- EVM native balances across Ethereum, Base, Arbitrum, Optimism, Polygon, BNB Chain, and Avalanche.
- Common ERC-20 stablecoins on supported EVM chains.
- Cosmos-native balances for Cosmos Hub, Osmosis, Celestia, Stargaze, and Stride.
- Read-only exchange balances through Binance, Coinbase, and Kraken. The web reference uses ccxt; the native Mac app uses Swift REST clients.
- Local SQLite persistence for watched wallets, scan runs, holdings, exchange connections, preferences, and vault metadata.
- AES-256-GCM encryption for exchange API credentials. The web reference uses a local vault passphrase; the native Mac app uses a Keychain-backed vault subkey.
- USD prices through CoinGecko.
- CSV and JSON export from the latest local snapshot.
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
swift test
swift run AddressAtlasMac
```

To build a local `.app` bundle on a Mac with full Xcode selected:

```bash
cd native/AddressAtlasMac
./build-mac-app.sh
open "dist/Address Atlas.app"
```

The app stores its local vault in `~/Library/Application Support/AddressAtlas/vault.sqlite`. The SQLite table stores encrypted envelope JSON only; wallet addresses, exchange credentials, scan history, token lists, and preferences are encrypted before persistence.

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

Sync endpoints are intentionally narrow: `POST /auth/passkey/options`, `POST /auth/passkey/verify`, `GET /vault/latest`, and `PUT /vault/latest`. The server stores passkey public keys plus encrypted vault snapshot metadata; it does not store decryptable keys or plaintext portfolio data.

The Mac app opens `/auth/native` in a system web authentication session for passkey account creation/sign-in, then receives only a short-lived sync session token through the `address-atlas://sync-auth` callback URL.

## Security notes

Address Atlas is designed for local or trusted self-hosted use, not public multi-user deployment. It never asks for seed phrases, private keys, signing permissions, trading permissions, or withdrawal permissions. Exchange API keys should be created with balance/read permission only. In the native app, credentials are encrypted with a vault subkey before local persistence and sync. Public RPC, exchange, and price endpoints can rate-limit or fail, so scan results should be treated as portfolio visibility, not accounting-grade proof.
