---
title: Unbonding is its own AssetSource and carries an optional unlock time
date: 2026-11-04
status: active
tags: [decision, models, vault, cosmos, solana, staking]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasCore/Models.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/VaultDocumentSemanticValidator.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/NativeScannerCosmos.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/NativeScannerSolana.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/Exporters.swift, native/AddressAtlasMac/Tests/AddressAtlasCoreTests/VaultUnbondingCompatibilityTests.swift]
---

## Context

Staking funds that have left a validator but are not yet spendable were invisible: Cosmos unbonding delegations were never read and Solana stake accounts were not scanned at all. The redesign needs both, with a date for when unbonding funds free up.

## Decision

- `AssetSource.unbonding` (raw value `"unbonding"`, persisted) and `TrackedAsset.unlocksAt: Date?` were added with no vault schema bump. An absent `unlocksAt` key decodes to nil and nil is never encoded, so existing vaults re-encode byte for byte. An unknown source still fails closed at decode.
- The semantic validator allows `staked` and `unbonding` for Cosmos and Solana holdings, keeps `rewards` Cosmos-only, allows `unlocksAt` only on `unbonding` holdings, and bounds it to 1970 through 9999 (what the ISO-8601 vault encoder round-trips). Scanners emit whole-second dates like every other persisted date.
- Cosmos emits one `unbonding` holding per distinct completion time (whole seconds), id `<address>-<chain>-<symbol>-unbonding-<epoch seconds>` or `-undated`, so each holding's `unlocksAt` is exact for its whole amount. Aggregating into one holding with the earliest time was rejected because it would show 110 coins as free on a day when only 10 are. The count is capped at 20 (`maximumCosmosUnbondingHoldings`): later times fold into one holding with the earliest of their times plus a warning, so a hostile provider cannot exceed the vault's per-scan holding limit.
- A completion time that is missing or not a strict `YYYY-MM-DDTHH:MM:SS[.fraction]Z` (Foundation silently normalizes February 30 and hour 24, so the parser round-trips the components) is counted in an undated bucket with a warning. An unusable `balance` fails the whole unbonding part with the usual partial-scan warning rather than undercounting.
- Solana stake accounts map to `staked` and `unbonding` holdings with `unlocksAt` nil: Solana publishes no completion timestamp and cooldown depends on network-wide limits, so no date is guessed.
- The share-safer export is unchanged in shape: `unbonding` is one more coarse `source` value and the unlock time has no field there. The full CSV gained a trailing `unlocks_at` column (ISO-8601 UTC, blank otherwise); the full JSON export carries `unlocksAt`.

## Consequences

- Any new switch over `AssetSource` must handle `unbonding` (the iOS `atlasIOSKindLabel` switch was the only exhaustive one outside Core).
- Analytics maps `unbonding` to `HoldingState.unbonding` and reads `unlocksAt` for per-coin unlock timelines; see the portfolio-analytics file-map note.
- Do not make `unlocksAt` required for `unbonding`: Solana holdings never have one.
