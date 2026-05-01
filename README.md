# Address Atlas

Address Atlas is a read-only multi-chain portfolio tracker. Paste wallet addresses once, then scan balances across Bitcoin, EVM chains, and Cosmos-style addresses without API keys or private keys.

## Why this exists

This repo is a cleaner follow-up to earlier hackathon experiments:

- HodlTrack had useful balance fetching, chain config, CoinGecko pricing, and local portfolio UI ideas.
- FluxTranche had useful portfolio modeling ideas, a coin-to-chain registry direction, and a strong no-custody framing.
- Address Atlas keeps the reusable parts and drops fund-management, trading, auth, and AI claims.

## Current scope

- Bitcoin native balance via Blockstream.
- EVM native balances across Ethereum, Base, Arbitrum, Optimism, Polygon, BNB Chain, and Avalanche.
- Common ERC-20 stablecoins on supported EVM chains.
- Cosmos-native balances for Cosmos Hub, Osmosis, Celestia, Stargaze, and Stride.
- USD prices through CoinGecko.
- Browser-local pasted address memory.

## Local development

```bash
npm install
npm run dev
```

Then open `http://localhost:3000`.

## Production notes

Address Atlas is read-only and never asks for seed phrases, private keys, exchange API keys, or signing permissions. Public RPC and indexer endpoints can rate-limit or fail, so scan results should be treated as portfolio visibility, not accounting-grade proof.
