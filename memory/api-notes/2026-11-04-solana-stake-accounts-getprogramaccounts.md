---
title: Solana stake accounts need getProgramAccounts, which public RPCs often reject
date: 2026-11-04
status: active
tags: [api, solana, rpc, staking]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/NativeScannerSolana.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/NativeScannerModels.swift, native/AddressAtlasMac/Tests/AddressAtlasCoreTests/NativeScannerSolanaStakeTests.swift, native/AddressAtlasMac/Tests/AddressAtlasCoreTests/CoreTestSupport.swift]
---

## Contract

- There is no per-address stake-account RPC. The scan calls `getProgramAccounts` on `Stake11111111111111111111111111111111111111` with `encoding: jsonParsed`, `withContext: true`, a `dataSize: 200` filter, and one `memcmp` on the wallet address at byte 12 (staker) and again at byte 44 (withdrawer). Stake state layout: 4-byte tag, 8-byte rent reserve, staker pubkey, withdrawer pubkey.
- Both lookups are components of the coherent Solana snapshot (same `minContextSlot` rule as `getBalance` and token reads), so SOL moved into a stake account between reads cannot be double counted or missed.
- `getEpochInfo` (bound to the snapshot slot, only requested when the wallet owns a stake account) classifies each account: not delegated or deactivated before the current epoch is `inactive`; deactivation epoch equal to the current epoch is `deactivating` (`unbonding`); delegated before the current epoch is `active`; delegated this epoch is `activating`. The `getStakeActivation` method is deprecated and not used. The classification ignores the network-wide cooldown rate cap, so a rare busy epoch can label a still-cooling account inactive slightly early; the counted balance is unaffected.
- Counting rules: an account's whole lamport balance counts (rent reserve and compounded rewards included, since a withdrawal pays that out). Only accounts whose withdrawer is the address are its money; accounts where it is only the staker (a delegation manager) are reported in a warning and never counted. Active, activating, and inactive-but-unwithdrawn accounts are `staked` (inactive ones add a warning saying they await withdrawal); deactivating accounts are `unbonding`. Without an epoch every owned account is `staked` with a warning.

## Failure mode

The bundled endpoint (`https://api.mainnet-beta.solana.com`) and many free providers reject or rate-limit `getProgramAccounts` (JSON-RPC errors such as -32010, HTTP 403 or 429, timeouts). That is one stable warning (`NativeScanner.solanaStakeUnavailableWarning`: staked and unbonding SOL may be missing) and never blocks the native balance or tokens. Losing only the staker lookup is silent because it only feeds the informational "managed by this address" count. Do not turn a rejection into an empty result.

## Validation

Re-check against a real provider with a known stake account before changing filters or offsets. Tests use synthetic JSON only; the shared test stubs (`StubHTTPClient`, `ScannerHTTPStub`) auto-answer these two methods with "no stake accounts" at the requested slot, and tests of stake behavior pass `automaticallyServesEmptySolanaStakeAccounts: false` and answer them explicitly.
