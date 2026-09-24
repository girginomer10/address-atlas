# Address Atlas iOS

Native SwiftUI iOS app for Address Atlas, for iPhone (iOS 17 or newer) and iPad. It is the same product as the Mac app with the same read-only boundary: public wallet addresses and balance-only exchange credentials, never seed phrases, private keys, signing, trading, or withdrawal permission.

This target is a **source-only preview**. It has been built and exercised on the iPhone 17 Pro simulator (the vault key is created in the Keychain, the encrypted SQLite vault initializes with the strict durability pragmas, and the tab shell renders). No physical device, signed device build, TestFlight build, App Store Connect record, or Mac-to-iPhone iCloud restore has been verified.

## Directory layout

```text
native/AddressAtlasiOS/
├── project.yml                     xcodegen spec; the single source of truth for the project
├── AddressAtlasiOS.xcodeproj       generated from project.yml and committed (CI and Xcode use it as is)
├── generate-project.sh             writes Version.xcconfig, then runs `xcodegen generate`
├── build-ios-app.sh                simulator/device build wrapper around xcodebuild
├── scripts/write-version-xcconfig.sh  derives version, build number, and source commit
├── Version.xcconfig                generated, git-ignored; never edit or commit
├── Sources/AddressAtlasiOS/        iOS-only SwiftUI code (see below)
├── Resources/
│   ├── Info.plist                  bundle metadata, update route, recovery-kit UTI
│   ├── AddressAtlasiOS.entitlements  iCloud container, CloudKit, keychain-access-groups
│   ├── Assets.xcassets             AppIcon (opaque 1024 px), AccentColor, LaunchBackground
│   └── AppIcon-iOS.svg             source for the rendered icon
└── build/                          DerivedData from build-ios-app.sh; git-ignored
```

`Sources/AddressAtlasiOS` holds `AddressAtlasiOSApp.swift` (entry point), `RootView.swift` (scene-phase handling and the background flush), `MainShell.swift` (tab shell on iPhone, `NavigationSplitView` on iPad), `UnlockScreen.swift` (unlock and recovery-kit restore), one screen per section (Portfolio, Wallets, Assets, Tokens, Snapshots, Exchanges, iCloud, Export, Settings), `AtlasSection.swift`, and `IOSSupport.swift` (iOS lifecycle helpers on the shared `AppState`). Everything else comes from the Mac package.

## Commands

Full Xcode must be selected with `xcode-select`; Command Line Tools alone cannot build iOS apps. CI uses Xcode 26.5. Run these from the repository root:

```bash
npm run native:ios:build            # Debug simulator build, ad-hoc signed by Xcode
npm run native:ios:run              # build, then install and launch on the booted simulator
npm run native:ios:build:unsigned   # compile-only check with code signing disabled (what CI runs)
npm run native:ios:generate         # regenerate AddressAtlasiOS.xcodeproj after editing project.yml
```

The underlying script accepts `./build-ios-app.sh [--simulator|--device] [--configuration Debug|Release] [--install-booted] [--unsigned]`. `--simulator` is the default; `--device` builds for a generic iOS device and needs the App ID and profile described under Signing. You can also open `AddressAtlasiOS.xcodeproj` in Xcode and run the `AddressAtlasiOS` scheme; Xcode runs the same version script through the project's configuration files.

`xcodegen` (2.46) is a local development dependency only (`brew install xcodegen`). CI never runs it: it verifies that the committed project references every shared source and every iOS source, then builds the committed project. After any `project.yml` change, or after adding a Swift file to a shared directory, run `npm run native:ios:generate` and commit the regenerated `.xcodeproj`.

The generated project also lists the package's own `AddressAtlasCore` and `AddressAtlasMac` schemes; only `-scheme AddressAtlasiOS` builds for iOS, and the AppKit executable scheme fails if selected for an iOS destination.

## Versioning

The iOS app has no version of its own. `scripts/write-version-xcconfig.sh` writes the git-ignored `Version.xcconfig` on every build with:

- `MARKETING_VERSION` from the single `static let currentAppVersion` line in `native/AddressAtlasMac/Sources/AddressAtlasMac/AppState.swift`;
- `CURRENT_PROJECT_VERSION` from `../AddressAtlasMac/build-mac-app.sh --print-build-version`, so it honors `ADDRESS_ATLAS_BUILD_NUMBER` and refuses shallow clones exactly like the Mac build;
- `ADDRESS_ATLAS_SOURCE_COMMIT` from `git rev-parse HEAD`, embedded in `Info.plist` so a bundle can be traced to its commit.

Both apps therefore report one product version and one build number. The CI job checks the built bundle for version parity with `AppState.swift` and for the source commit.

## Signing

- **Simulator builds are ad-hoc signed by Xcode on purpose.** Without an application identifier the iOS Keychain refuses every request with `errSecMissingEntitlement`, and the vault cannot unlock. `npm run native:ios:build` and `npm run native:ios:run` keep signing enabled for that reason.
- `--unsigned` (`npm run native:ios:build:unsigned`) disables code signing for a compile-only check on machines without any signing identity. The resulting app carries no entitlements, so the Keychain and iCloud paths cannot be exercised with it.
- Device builds use automatic signing with team `VWW3GZL279` (`DEVELOPMENT_TEAM` in `project.yml`, `CODE_SIGN_STYLE = Automatic`). They require the explicit App ID `com.addressatlas.ios` registered under that team with iCloud (CloudKit) and Keychain Sharing enabled and the existing container assigned, plus an iOS provisioning profile for that App ID. Neither exists yet, so `--device` cannot currently produce a signed bundle.
- There is no iOS packaging, validation, or upload script. The `native:mas:*` scripts, the Mac App Store profile, and the Mac record's numeric Apple ID are Mac-only and must not be reused.

## Entitlements

`Resources/AddressAtlasiOS.entitlements` requests:

- `com.apple.developer.icloud-container-identifiers`: `iCloud.com.addressatlas.mac`, the same container the Mac app uses, so an iPhone would restore the copy a Mac saved.
- `com.apple.developer.icloud-services`: `CloudKit`.
- `com.apple.developer.icloud-container-environment`: `Production`, so a signed Debug device build reads the same CloudKit database as the Mac App Store build instead of Xcode's Development default.
- `keychain-access-groups`: `$(AppIdentifierPrefix)com.addressatlas.mac` first, then `$(AppIdentifierPrefix)com.addressatlas.ios`. The Mac app stores the synchronizable iCloud cloud-key item in its default group (`<team>.com.addressatlas.mac`). Listing that group first makes it this app's default group too, so the key written on a Mac can be read on iOS through iCloud Keychain once the App ID grants it.

At runtime the shared `ICloudVaultService` checks whether the running build actually carries the container grant. The iOS SDK has no `SecTask` API, so it reads the executable's `__TEXT,__entitlements` section (simulator builds) or the embedded `embedded.mobileprovision` (device, TestFlight, and App Store builds), and fails closed otherwise: simulator, unsigned, and unprovisioned builds show an iCloud unavailable message and never initialize `CKContainer`. The simulator also cannot sync iCloud Keychain, so even a provisioned simulator build could not receive the cloud key.

`Info.plist` sets `AddressAtlasDistributionChannel` to `app-store` and `AddressAtlasUpdateURL` to the generic `https://apps.apple.com` storefront on purpose: there is no iOS App Store record, so the update route fails closed until one exists. The Mac-only `AddressAtlasUseDataProtectionKeychain` key must never be added here; CI rejects a bundle that contains it.

## Storage and lifecycle

The encrypted vault lives at `<app container>/Library/Application Support/AddressAtlas/vault.sqlite`, the same relative layout as the Mac. The vault key is a Keychain item with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, so it never leaves the device or enters a backup; restoring to a new device needs the recovery kit or the iCloud copy. `KeychainVaultKeyStore` forces the macOS legacy-keychain migration off on iOS because that migration's delete query would match the freshly saved item.

Scans and iCloud transfers are foreground-only; the target declares no `UIBackgroundModes`. When the app moves to the background, `RootView` takes a background-time assertion and `AppState.flushBeforeSuspension()` writes wallet-label drafts and pending persistence through the shared termination lane. If iOS runs out of background time while a scan is still running, the scan is cancelled. There is no termination hook: iOS may suspend and later kill the process without notice, so durable state must already be flushed on backgrounding.

## What is shared with the Mac app

The target links the `AddressAtlasCore` library product from `../AddressAtlasMac` (the package declares `.iOS(.v17)` alongside `.macOS(.v14)`) and compiles these files straight from `../AddressAtlasMac/Sources/AddressAtlasMac`:

- every `AppState*.swift` file (state transitions, validation, scanning, exchange connections, iCloud, vault mutations, persistence, diagnostics, termination lane);
- `UserFacingErrors.swift`, `ICloudVaultService.swift`, `PasskeyWebAuthenticator.swift`, `AtlasDesignSystem.swift`, `AtlasFormatting.swift`, `ExportPipeline.swift`.

Excluded as macOS-only (the `excludes` list in `project.yml`): `AddressAtlasApp.swift`, `AppShellViews.swift`, `PortfolioViews.swift`, `PortfolioComponents.swift`, `ExchangeSyncViews.swift`, `ICloudSyncView.swift`, `PrivacySafeDiagnosticsView.swift`.

Platform differences inside shared files sit behind `#if canImport(AppKit)` / `#if os(macOS)`: the theme uses `UIColor` dynamic providers on iOS, accessibility announcements use `UIAccessibility`, the entitlement probe is described above, and user-facing device nouns come from `PlatformCopy` in `AddressAtlasCore` ("Mac" on macOS, "device" on iOS). Any new file in the shared directory is picked up by the iOS target by default. If it needs AppKit, guard it rather than adding an exclusion, then regenerate and commit the project; CI fails when a shared source is missing from `AddressAtlasiOS.xcodeproj`. The build uses strict concurrency checking and treats warnings as errors.

## Open external gates

None of the following has been done. Do not mark any of them complete without evidence from the Apple Developer portal or App Store Connect.

1. Register the explicit App ID `com.addressatlas.ios` under team `VWW3GZL279` with iCloud (CloudKit) and Keychain Sharing enabled, and assign the existing `iCloud.com.addressatlas.mac` container.
2. Create an iOS distribution provisioning profile for that App ID.
3. Create the App Store Connect iOS record and record its numeric Apple ID; see `../../app-store/README.md`. Point `AddressAtlasUpdateURL` at the real product page only after that.
4. Prove a Mac→iPhone encrypted restore on a physical device with iCloud Passwords & Keychain enabled, between builds on the same CloudKit environment (the entitlements pin Production for every iOS build, matching the Mac App Store build). The simulator cannot perform this test.
5. Kraken connections stay bound to the device that created them; a restored copy needs a separate read-only Kraken key per device. Keep that in the review notes.

The release contract, including the manual iPhone/iPad smoke list, is in `../../docs/RELEASE_CHECKLIST.md`; the iCloud provisioning details are in `../../docs/ICLOUD.md`.
