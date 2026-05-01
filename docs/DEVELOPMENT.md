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

## First Product Constraint

The first version avoids account creation, exchange API keys, automated rebalancing, signing, and fund-management claims. The app should answer one question well: "What do these public wallet addresses appear to hold?"

## Next Useful Milestones

- Add staked and reward balances for Cosmos chains.
- Add SPL token support for Solana.
- Add token allowlist editing in the UI.
- Add optional historical snapshots in local storage.
