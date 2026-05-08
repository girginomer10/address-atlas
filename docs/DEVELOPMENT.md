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

Address Atlas avoids account creation, automated rebalancing, signing, and fund-management claims. Exchange keys are allowed only for read-only balance fetching and are encrypted locally: the legacy web reference uses a vault passphrase, while the native Mac app uses a random Keychain-backed vault key. The app should answer one question well: "What do these public wallets and read-only exchange accounts appear to hold?"

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
- `/api/tokens/metadata` prefers the built-in registry, can read ERC-20 symbol/name/decimals from the selected chain RPC, returns CoinGecko id suggestions, and reads Solana mint decimals from parsed account info. If `JUPITER_API_KEY` is configured, it also uses Jupiter Tokens API for arbitrary Solana mint symbol/name/USD price hints.
- Solana scanning includes classic SPL Token Program and Token-2022 balances from the registry. TRON scanning includes native TRX plus tracked TRC20 tokens, currently USDT. XRP Ledger scanning includes native XRP plus positive issued-currency trustline balances as unpriced `issued` assets. Cosmos scanning includes native liquid balances, delegations, and distribution rewards.

## Native Mac Track

- `native/AddressAtlasMac` is the new native SwiftUI implementation. The Next app remains a reference while the Mac app grows toward full replacement.
- `native/AddressAtlasMac/build-mac-app.sh` builds a local `dist/Address Atlas.app` bundle on Macs with full Xcode selected, or with the Homebrew Swift.org toolchain fallback when full Xcode is unavailable. The script prefers full Xcode, ad-hoc signs local app bundles by default, and can use `ADDRESS_ATLAS_CODESIGN_IDENTITY` when a Developer ID Application identity is available.
- The native vault key is a random 256-bit key stored in macOS Keychain with this-device-only accessibility. Users do not type or memorize an encryption password.
- The native local store uses SQLite as an envelope table: the app serializes `VaultDocument`, encrypts it with an HKDF-derived local database key, and stores only envelope JSON (`nonce`, `ciphertext`, checksums, versions).
- The vault key derives separate subkeys for local database encryption, encrypted server sync blobs, and field-level exchange credential encryption.
- Native scanners make public RPC/API requests directly from the Mac app. EVM scanning includes native balances plus built-in/custom ERC-20 `balanceOf` probes across the same common registry set as the web reference; Solana scanning includes native SOL plus built-in/custom SPL Token and Token-2022 account parsing. Token, staking, reward, and trustline subrequest failures are surfaced as scan warnings without discarding successfully read native balances. Binance, Coinbase, and Kraken balances use native Swift REST clients with read-only credentials decrypted only in memory for the scan. `/config/native` can rotate public RPC, price, exchange base URL, and exchange account path settings without a Mac update, but schema/signing changes still require an app release. The server sync layer is not a portfolio API and cannot decrypt user data.
- Native exchange support uses deterministic Swift request builders and mocked signing/balance tests before live balance calls. Do not reintroduce `ccxt` into the Mac runtime.

## Encrypted Sync Server

- The zero-knowledge sync surface is `POST /auth/passkey/options`, `POST /auth/passkey/verify`, `GET /vault/latest`, and `PUT /vault/latest`.
- Sync requires Postgres through `SYNC_DATABASE_URL`; keep this separate from the legacy local Prisma SQLite `DATABASE_URL`.
- Local sync development can use `npm run sync:db:up`, which starts `compose.sync.yml` with the same default URL shown in `.env.example`.
- Server tables are `users`, `passkey_credentials`, and `vault_snapshots`. Plain wallet addresses, balances, exchange credentials, token allowlists, preferences, and scan history must not be added to sync tables.
- Passkeys authenticate accounts. They are not encryption keys; encrypted vault blobs are produced and opened only by the native client.
- The native Mac app uses `ASWebAuthenticationSession` to open `/auth/native`, complete WebAuthn on the server origin, and receive the short-lived sync session token through `address-atlas://sync-auth`. The app-bundle build script registers that URL scheme.

## Gotchas

- Restart the dev server after Prisma schema/model changes. The dev process caches a global Prisma client, so newly generated delegates such as `customToken` and `manualExchangeHolding` may be missing until restart.
- Full Xcode 26.4.1 is selected and licensed in this workspace. `swift test` now runs; keep using full Xcode for native verification. The Homebrew Swift fallback remains useful only when another machine has Command Line Tools but no full Xcode/XCTest.

## Next Useful Milestones

- Add Solana metadata-program or DAS lookup if we want no-key symbol/name autofill for arbitrary Solana mints.
- Add more TRC20 registry entries and price mappings for well-known XRPL issued currencies.
- Make manual exchange entries easier to reconcile against historical snapshots if users want time-specific manual values later.
- Continue native scanner parity with broader built-in token registries, XRP issued-asset pricing rules, and token metadata autofill.
