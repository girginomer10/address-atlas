# Development Notes

## Imported Know-How

Address Atlas intentionally borrows ideas, not whole subsystems, from the earlier projects.

From HodlTrack:

- Public RPC balance scans for EVM native assets.
- ERC-20 `balanceOf` probing with common token registries.
- Bitcoin and Cosmos balance fetch patterns.
- CoinGecko simple-price mapping.
- Local-first portfolio state.

From FluxTranche:

- Portfolio entities should distinguish chain, coin, address, liquid balance, and future staked/reward fields.
- Chain support should be registry-driven, not hardcoded inside UI components.
- The public positioning should stay read-only and no-custody.

## Product Constraint

Address Atlas avoids account creation, automated rebalancing, signing, and fund-management claims. Exchange keys are allowed only for read-only balance fetching and are encrypted locally with a vault passphrase. The app should answer one question well: "What do these public wallets and read-only exchange accounts appear to hold?"

## Local-First Architecture

- Next.js app routes power Portfolio, Wallets, Assets, Snapshots, Export, and Settings.
- Prisma 7 + SQLite store local state in `.data/address-atlas.db`.
- Prisma Client is generated into `src/generated/prisma` during `npm run dev`, `npm run build`, and `npm test`; generated output is ignored by git.
- Exchange connections use ccxt adapters for Binance, Coinbase, and Kraken. Only `fetchBalance` is used.
- Vault encryption uses AES-256-GCM with a PBKDF2-derived key. The passphrase is verified, not stored.
- Scan history is read from persisted `ScanRun` rows and exposed via `/api/scan/history`.
- Manual exchange entries live in `ManualExchangeHolding` and are merged into the latest scan response at read time; they are not persisted as historical `Holding` rows.
- Custom token allowlist entries live in `CustomToken` and can target either EVM contracts or Solana mints. They are merged with built-in token registries during scans, and built-in registry entries win on duplicate addresses/mints.
- Custom tokens can use either a CoinGecko id, a manual USD price, both, or neither. If both are present, live CoinGecko prices win and manual price is the fallback.
- `/api/tokens/metadata` reads ERC-20 symbol/name/decimals from the selected chain RPC and reads Solana mint decimals from parsed account info. Solana symbol/name still need user input unless we add a metadata-program/DAS lookup later.
- Solana scanning includes classic SPL Token Program and Token-2022 balances from the registry. Cosmos scanning includes native liquid balances, delegations, and distribution rewards.

## Gotchas

- Restart the dev server after Prisma schema/model changes. The dev process caches a global Prisma client, so newly generated delegates such as `customToken` and `manualExchangeHolding` may be missing until restart.

## Next Useful Milestones

- Consider auto-suggesting CoinGecko ids from token symbol/name after metadata lookup.
- Add Solana metadata-program or DAS lookup if we want symbol/name autofill for arbitrary Solana mints.
- Make manual exchange entries easier to reconcile against historical snapshots if users want time-specific manual values later.
