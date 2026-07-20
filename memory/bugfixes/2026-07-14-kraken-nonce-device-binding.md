---
title: Kraken credentials and nonce state are installation-bound
date: 2026-07-14
status: active
tags: [bugfix, kraken, nonce, security, sync]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasCore/Models.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/ExchangeClients.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AppState.swift, native/AddressAtlasMac/Tests/AddressAtlasCoreTests/ScannerHardeningTests.swift]
---

## Symptom

Kraken requires every private request nonce for one API key to be strictly greater than every previous nonce. An in-memory or wall-clock-only counter can repeat or regress across processes, restarts, clock changes, and synced Macs.

## Root cause

A synced API credential is multi-device data, but a safe Kraken nonce sequence needs one serialized local writer. Sharing one Kraken API key across installations creates coordination that the encrypted vault sync protocol cannot guarantee.

## Fix and invariant

- Every new Kraken connection is bound to the UUID in protected local nonce state. Legacy, unbound, other-device, and duplicate cross-device records fail before an HTTP request.
- Users must create a distinct read-only Kraken API key for each Mac. Deleting local nonce state creates a new installation identity, so existing Kraken connections intentionally fail closed and must be replaced.
- Nonces are serialized across processes with `flock`, persisted before network use with an atomic `fsync` and rename, and stored under owner-only files/directories. Symlinks, malformed or oversized state, and identity changes fail closed.
- Local state stores an HMAC identifier for each API key, never the raw key.

## Verification

- Keep the independent-generator, cross-client concurrency, clock-regression, deleted-state, symlink, oversized-state, legacy-record, other-device, and duplicate-device regression tests in `ScannerHardeningTests.swift`.
