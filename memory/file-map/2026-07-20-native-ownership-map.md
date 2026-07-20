---
title: Native AppState and scanner ownership map
date: 2026-07-20
status: active
tags: [file-map, macos, appstate, scanner, tests]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasMac/AppState.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/NativeScanner.swift, native/AddressAtlasMac/Tests/AddressAtlasMacTests/AppStateNetworkBoundaryTests.swift, native/AddressAtlasMac/Tests/AddressAtlasCoreTests/VaultSyncSecurityTests.swift]
---

## App state

- `AppState.swift` owns state, initialization, local persistence coordination,
  and shared mutation guards.
- `AppStateExchangeConnections.swift` owns credential validation and exchange
  connection persistence.
- `AppStateEndpointConfiguration.swift` owns endpoint refresh and compatibility
  policy application.
- `AppStateAccountLifecycle.swift` owns passkey sign-in, session revocation, and
  replay-safe account deletion.
- `AppStateVaultSync.swift` owns encrypted upload, download, recovery, and sync
  error persistence.
- `AppStateScanning.swift` owns scan task lifecycle and result merging.
- `AppStateValidation.swift` and `AppStateVaultMutations.swift` own pure
  validation and bounded vault-edit operations respectively.

## Native scanner

- `NativeScanner.swift` owns public orchestration, pricing, deadlines, and
  chain-job dispatch.
- `NativeScannerBitcoinEVM.swift`, `NativeScannerSolana.swift`,
  `NativeScannerCosmos.swift`, `NativeScannerTron.swift`, and
  `NativeScannerXRP.swift` own their chain-family transports and parsers.
- `NativeScannerSupport.swift` owns shared asset construction, token registry,
  display sanitization, and provider-error helpers.
- `NativeScannerModels.swift` owns scanner-local DTOs and work-result models.

## Tests

- AppState network tests are split into credential/scan, passkey, vault
  transfer, and account-lifecycle boundary files while retaining the shared
  XCTest class and stubs in `AppStateNetworkBoundaryTests.swift`.
- Vault-sync tests are split into authenticated metadata, migration/export,
  key recovery, Keychain, and endpoint/envelope domains.
