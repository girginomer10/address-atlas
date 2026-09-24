---
title: iOS app shares the Mac state layer and core; native screens on top
date: 2026-09-25
status: active
tags: [decision, ios, macos, xcodegen, keychain, icloud, entitlements, release]
related_files: [native/AddressAtlasMac/Package.swift, native/AddressAtlasiOS/project.yml, native/AddressAtlasiOS/build-ios-app.sh, native/AddressAtlasiOS/scripts/write-version-xcconfig.sh, native/AddressAtlasiOS/Sources/AddressAtlasiOS/RootView.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/IOSSupport.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/PlatformCopy.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Crypto/KeychainVaultKeyStore.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/ICloudVaultService.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasDesignSystem.swift]
---

## Context

The product needed an iPhone/iPad app without forking the vault, recovery,
scanning, exchange, and iCloud-copy logic that the macOS app already proves
with 500 tests. AddressAtlasCore imports only Foundation, CryptoKit, Darwin,
Security, and SQLite3, so it compiles for iOS once the package declares the
platform; the Mac target's state layer is Foundation-only except for a few
AppKit leaves.

## Decision

- `Package.swift` declares `.iOS(.v17)` next to `.macOS(.v14)`. No SwiftPM
  target is added for iOS: CI runs `swift test` over every package target on
  macOS, so iOS UI must stay out of the package.
- The iOS app lives in `native/AddressAtlasiOS` as an xcodegen project whose
  generated `.xcodeproj` is committed (CI and Xcode users need no xcodegen).
  Its target compiles `Sources/AddressAtlasMac` from the Mac package directly,
  excluding the seven macOS-only files (`AddressAtlasApp`, `AppShellViews`,
  `PortfolioViews`, `PortfolioComponents`, `ExchangeSyncViews`,
  `ICloudSyncView`, `PrivacySafeDiagnosticsView`), and links the
  `AddressAtlasCore` product. Every screen is written natively for iOS on the
  shared `AppState` and design-system primitives.
- Platform differences are `#if canImport(AppKit)` / `#if os(macOS)` leaves
  whose macOS branch is byte-identical to the previous code: UIColor dynamic
  providers and UIAccessibility announcements in the design system, a UIWindow
  passkey presentation anchor, `PlatformCopy` nouns ("Mac" on macOS, "device"
  on iOS) in shared strings, and an iOS entitlement probe that reads the
  executable's `__TEXT,__entitlements` section (located via `dladdr`, never by
  comparing dyld paths) or `embedded.mobileprovision` because the iOS SDK has
  no SecTask API.
- `KeychainVaultKeyStore` forces the macOS legacy-file-keychain migration off
  on iOS: with one keychain, its delete query would match the item just saved.
  The iOS Info.plist must never carry `AddressAtlasUseDataProtectionKeychain`.
- Version metadata is single-sourced: `scripts/write-version-xcconfig.sh`
  reads the one `currentAppVersion` line in `AppState.swift` and the Mac
  script's `--print-build-version`, writing the git-ignored
  `Version.generated.xcconfig` that the committed `Version.xcconfig` includes.
- Simulator builds are ad-hoc signed by Xcode so the app carries
  `application-identifier`; unsigned simulator builds cannot use the Keychain
  (errSecMissingEntitlement) and the vault never unlocks.
- iOS entitlements request the same `iCloud.com.addressatlas.mac` container,
  CloudKit, the Production environment, and `keychain-access-groups` listing
  `$(AppIdentifierPrefix)com.addressatlas.mac` first so the Mac's
  synchronizable cloud-key item is visible without changing the Mac app.
- The iOS app excludes `Library/Application Support/AddressAtlas` from device
  backups because the vault key is `WhenUnlockedThisDeviceOnly` and a restored
  database would only block first launch; the iCloud copy and the recovery
  kit remain the cross-device paths.
- iOS lifecycle: scans and iCloud transfers are foreground-only; moving to the
  background runs the shared termination lane only when no operation is
  active (it is a quit gate, not a flush) inside a UIKit background task,
  resets the termination flag on return, cancels a scan when the device locks
  or background time expires, and auto-refresh uses a one-minute tick against
  a last-refresh timestamp instead of restarting the 15-minute sleep.

## Consequences

- Adding a shared Swift file to `Sources/AddressAtlasMac` requires
  `./generate-project.sh` and committing the regenerated project; CI checks
  that every shared and iOS source is referenced.
- A new Mac-only file must be added to the `excludes` list in `project.yml`,
  otherwise the iOS build fails on the AppKit import.
- There is no iOS App Store Connect record, App ID registration, iCloud
  container association, distribution profile, physical-device run, or
  Mac-to-iPhone iCloud restore evidence. Do not claim any of them; the
  simulator cannot sync iCloud Keychain, so the shared cloud key is a
  physical-device gate.
- Kraken connections stay bound to the device that created them; a restored
  copy needs a separate read-only Kraken key per device.
