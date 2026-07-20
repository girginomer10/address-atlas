---
title: Native remote side effects require durable replay state and point-in-time trust
date: 2026-07-20
status: active
tags: [bugfix, macos, sync, idempotency, xrpl, binance]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasMac/AppStateAccountLifecycle.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AppStateVaultSync.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Sync/SyncClient.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Models.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/ExchangeOrchestration.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/NativeScannerXRP.swift]
---

## Invariants

- After a remote upload, download, session revoke, or account delete commits,
  retain the exact post-remote `VaultDocument` candidate and its persistence
  strategy. A retry must never save the stale document that preceded the
  remote side effect.
- Account deletion is a replayable operation, not a one-shot request. Persist
  a canonical 43-character unpadded base64url key representing 32 random bytes
  before the first DELETE, reuse the same `Idempotency-Key` until an
  acknowledgement is durable locally, and strip the key from remote snapshots.
  Replay an existing receipt before requiring passkey authentication because a
  committed deletion has already removed the account and passkey.
- The first account-delete attempt requires a fresh same-account passkey
  session. This privacy path must remain available even when the app version is
  below the server compatibility minimum.
- Binance read-only assurance is point-in-time. Revalidate the authoritative
  permission document before every balance request; clear assurance whenever
  validation or the scan fails or times out.
- XRPL JSON uses three-character text for standard currency codes. Every
  40-hex currency value is a nonstandard 160-bit identity and must render as
  its complete `HEX:<40 uppercase characters>` value, even if its prefix spells
  a familiar ticker.

## Verification

Native unit/integration suite: 243 tests executed, 2 live credential-gated
tests skipped, 0 failures. The same suite passes under Thread Sanitizer. The
release builder produced a strictly valid ad-hoc signed universal x86_64/arm64
application bundle.
