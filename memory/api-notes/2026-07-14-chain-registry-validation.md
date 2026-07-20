---
title: Chain registry entries require lifecycle and on-chain validation
date: 2026-07-14
status: active
tags: [api, chains, rpc, tokens, native-config]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/ChainRegistry.swift, native/AddressAtlasMac/Tests/AddressAtlasCoreTests/ScannerAddressValidationTests.swift, native/AddressAtlasMac/Tests/AddressAtlasCoreTests/ScannerWorkflowTests.swift, src/lib/sync/native-config.ts, src/lib/sync/native-config.test.ts]
---

## Contract

The bundled native registry and remotely served native configuration are one trust boundary and must agree. As validated on 2026-07-13, Polygon PoS uses `https://polygon.drpc.org`, Optimism USDT uses `0x94b008aA00579c1307B0EF2c499aD98a8ce58e58`, and Stargaze is not an active scannable chain. Existing `stars` addresses and Stargaze records remain decodable as retired data; removal from active discovery must never delete user data.

## Failure mode

An obsolete RPC can make an otherwise supported chain appear empty. A token address copied from another network can report the wrong asset or zero balance. Removing a retired chain from decoding as well as scanning can make saved vault data disappear.

## Validation

Before changing a chain, verify the authoritative chain lifecycle, the RPC chain ID, and deployed bytecode at each token contract. Update the native registry, the server-delivered config, and their regression tests together. Preserve a retired-data compatibility path when a chain is removed from active scanning.
