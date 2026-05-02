# Address Atlas

Address Atlas is a local-first, read-only crypto portfolio tracker. Paste public wallet addresses, connect read-only exchange API keys, and keep a private portfolio ledger on your own machine.

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
- Read-only exchange balances through Binance, Coinbase, and Kraken via ccxt.
- Local SQLite persistence for watched wallets, scan runs, holdings, exchange connections, preferences, and vault metadata.
- AES-256-GCM encryption for exchange API credentials using a local vault passphrase that is never stored.
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

## Security notes

Address Atlas is designed for local or trusted self-hosted use, not public multi-user deployment. It never asks for seed phrases, private keys, signing permissions, trading permissions, or withdrawal permissions. Exchange API keys should be created with balance/read permission only; stored credentials are encrypted with your vault passphrase. Public RPC, exchange, and price endpoints can rate-limit or fail, so scan results should be treated as portfolio visibility, not accounting-grade proof.
