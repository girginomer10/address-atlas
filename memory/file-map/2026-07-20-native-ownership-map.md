---
title: Native AppState and scanner ownership map
date: 2026-07-20
status: active
tags: [file-map, macos, ios, appstate, scanner, tests]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasMac/AppState.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/NativeScanner.swift, native/AddressAtlasMac/Tests/AddressAtlasMacTests/AppStateNetworkBoundaryTests.swift, native/AddressAtlasMac/Tests/AddressAtlasCoreTests/VaultSyncSecurityTests.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/ExportPipeline.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasFormatting.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/IOSSupport.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/MainShell.swift]
---

## Shared with iOS (updated 2026-09-25)

- Every `AppState*.swift` file, `UserFacingErrors.swift`,
  `ICloudVaultService.swift`, `PasskeyWebAuthenticator.swift`,
  `AtlasDesignSystem.swift`, `AtlasFormatting.swift`, and
  `ExportPipeline.swift` are compiled into both the Mac executable and the
  iOS app target; keep them Foundation/SwiftUI-only outside
  `#if canImport(AppKit)` leaves.
- `AtlasFormatting.swift` owns locale-aware formatting used by state and UI.
- `ExportPipeline.swift` owns view-free export payloads, the render pipeline,
  the preview accessibility model, and the disclosure copy (`ExportCopy`);
  `ExportView` keeps forwarding statics for the tests.
- macOS-only presentation stays in `AddressAtlasApp.swift`,
  `AppShellViews.swift`, `PortfolioViews.swift`, `PortfolioComponents.swift`,
  `ExchangeSyncViews.swift`, `ICloudSyncView.swift`, and
  `PrivacySafeDiagnosticsView.swift` (excluded in
  `native/AddressAtlasiOS/project.yml`).

## iOS app (`native/AddressAtlasiOS/Sources/AddressAtlasiOS`)

- `AddressAtlasiOSApp.swift` builds the production `AppState`;
  `RootView.swift` owns the unlock gate, auto-refresh cadence, backup
  exclusion, and the `SuspensionCoordinator` lifecycle mapping.
- `MainShell.swift` owns the iPhone tab shell, the "More" list, and the iPad
  split shell; `AtlasSection.swift` owns section metadata and routing.
- `IOSSupport.swift` owns `IOSPage`, input-hygiene modifiers, export file
  wrappers and temp-file handling, reachability, and the iOS-only `AppState`
  lifecycle/recovery-kit extensions.
- One `*Screen.swift` per section mirrors the corresponding macOS view's
  behavior with iOS idioms.

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
