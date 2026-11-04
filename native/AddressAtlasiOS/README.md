# Address Atlas iOS

Native SwiftUI iOS app for Address Atlas, for iPhone (iOS 17 or newer) and iPad. It is the same product as the Mac app with the same read-only boundary: public wallet addresses and balance-only exchange credentials, never seed phrases, private keys, signing, trading, or withdrawal permission.

This target is a **preview** with its own App Store Connect record. See the [release checkpoint](../../app-store/README.md#release-checkpoint--october-6-2026) for signing, processing, and TestFlight distribution evidence. It has been built and run on the iPhone 17 Pro and iPad Pro 11 simulators (iOS 26.5) with a synthetic portfolio (see [Demo fixture](#demo-fixture-debug-builds-only)). Sheets, add forms, and toasts were reviewed in code, not by tapping through them. Physical-device acceptance and Mac-to-iPhone iCloud restore remain unverified.

## Screens

The app has five sections (`AtlasSection`): **Portfolio**, **Assets**, **Sources**, **History**, and **Settings**. On iPhone they are tabs in a tab bar the app draws itself (`IOSTabBar`, so the theme's font and shape apply); on iPad they are a sidebar. Each section keeps its own navigation stack, and choosing the tab that is already showing returns to its first screen. A coin, a saved scan, iCloud, and Export are pushed screens (`IOSRoute`), not sections.

- **Portfolio**: total value, change since the previous scan (only when both scans read the same sources), last scan time, and **Scan**. A switcher picks one of the 14 chart views, with **Group by** for the views that use it. Warnings sit next to the data they affect. Tapping a coin in a chart opens its page, a slice opens Assets limited to that slice, and a point in a history view opens that scan in History.
- **Assets**: a list of coins, with search and a filter menu (hide coins without a price, hide small balances, set the threshold). A banner with **Clear** shows the slice a chart sent here. A coin's page shows its states (liquid, staked, unbonding, rewards, on an exchange), an unlock timeline when something is unbonding, amount history, custody, and its holdings with explorer links.
- **Sources**: Wallets, Exchanges, Holdings (manual), and Tokens (custom) behind a chip switcher, with one **+** menu to add any of them. Wallets and exchanges are read-only: public addresses and read-only API keys only.
- **History**: an over-time chart and the list of saved scans; a scan opens its own page.
- **Settings**: **Theme**, preferences, **iCloud** and **Export** (each opens a pushed screen), privacy, recovery kit, support links, diagnostics, and about.

A new install with no sources shows a one-page walkthrough (`OnboardingScreen`) before Portfolio. `UnlockScreen` handles the locked state and recovery kit restore.

**Themes.** Settings > Theme chooses one of six themes: Chain colours, Candy brutal, Riso zine, Heatmap, Pixel, and Acid. The app restyles without a relaunch. Riso zine is light only, Acid is dark only, and the other four follow light and dark mode.

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

`Sources/AddressAtlasiOS` holds:

- `AddressAtlasiOSApp.swift` (entry point) and `RootView.swift` (scene-phase handling and the background flush);
- `AtlasSection.swift` (the five sections) and `MainShell.swift` (`TabShell` on iPhone, `SplitShell` with a `NavigationSplitView` on iPad, and the destination for each pushed route);
- `IOSTheme.swift` (themed title, card, chip, notice, empty state, and tab bar), `IOSComponents.swift` (navigation model, sheets, toast, privacy cover), `IOSCoinViews.swift` (coin rows, chart frame, chart taps), and `HoldingViews.swift` (holding row and detail sheet);
- one file per screen: `PortfolioScreen`, `CoinDetailScreen`, `AssetsScreen`, `HistoryScreen` (with `SnapshotDetailScreen`), `SourcesScreen` (hosting `WalletsScreen`, `ExchangesScreen`, and `TokensScreen`), `SettingsScreen` (with the pushed `ICloudScreen` and `ExportScreen`), `OnboardingScreen`, and `UnlockScreen`;
- `IOSSupport.swift` (iOS lifecycle helpers on the shared `AppState`) and `DemoFixture.swift` (Debug only, see below).

Everything else comes from the Mac package.

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

- **Simulator builds are ad-hoc signed by Xcode on purpose.** Without an application identifier the iOS Keychain refuses every request with `errSecMissingEntitlement`, and the saved portfolio cannot unlock. `npm run native:ios:build` and `npm run native:ios:run` keep signing enabled for that reason.
- `--unsigned` (`npm run native:ios:build:unsigned`) disables code signing for a compile-only check on machines without any signing identity. The resulting app carries no entitlements, so the Keychain and iCloud paths cannot be exercised with it.
- Device builds use automatic signing with team `VWW3GZL279` (`DEVELOPMENT_TEAM` in `project.yml`, `CODE_SIGN_STYLE = Automatic`). The explicit App ID `com.addressatlas.ios` and an iOS distribution profile now exist with the shared iCloud container, Production environment, and keychain groups. Verify these grants on the actual signed bundle; profile creation alone does not prove runtime iCloud operation. The [release checkpoint](../../app-store/README.md#release-checkpoint--october-6-2026) records the identities and artifact outcome.
- For a manually provisioned archive, scope `PROVISIONING_PROFILE_SPECIFIER` to the iOS app target. Passing it globally to `xcodebuild` also applies it to the SwiftPM library and causes signing to fail. The first distribution archive used a temporary copy of the Xcode project with app-target signing settings so the repository and embedded source provenance stayed unchanged.
- There is no iOS packaging, validation, or upload script. The `native:mas:*` scripts, the Mac App Store profile, and the Mac record's numeric Apple ID are Mac-only and must not be reused.

## Entitlements

`Resources/AddressAtlasiOS.entitlements` requests:

- `com.apple.developer.icloud-container-identifiers`: `iCloud.com.addressatlas.mac`, the same container the Mac app uses, so an iPhone would restore the copy a Mac saved.
- `com.apple.developer.icloud-services`: `CloudKit`.
- `com.apple.developer.icloud-container-environment`: `Production`, so a signed Debug device build reads the same CloudKit database as the Mac App Store build instead of Xcode's Development default.
- `keychain-access-groups`: `$(AppIdentifierPrefix)com.addressatlas.mac` first, then `$(AppIdentifierPrefix)com.addressatlas.ios`. The Mac app stores the synchronizable iCloud cloud-key item in its default group (`<team>.com.addressatlas.mac`). Listing that group first makes it this app's default group too, so the key written on a Mac can be read on iOS through iCloud Keychain once the App ID grants it.

At runtime the shared `ICloudVaultService` checks whether the running build actually carries the container grant. The iOS SDK has no `SecTask` API, so it reads the executable's `__TEXT,__entitlements` section (simulator builds) or the embedded `embedded.mobileprovision` (device, TestFlight, and App Store builds), and fails closed otherwise: simulator, unsigned, and unprovisioned builds show an iCloud unavailable message and never initialize `CKContainer`. The simulator also cannot sync iCloud Keychain, so even a provisioned simulator build could not receive the cloud key.

`Info.plist` sets `AddressAtlasDistributionChannel` to `app-store` and still leaves `AddressAtlasUpdateURL` at the generic `https://apps.apple.com` storefront. The iOS record now exists, but the source update URL has not been changed; configuring a verified product-page destination remains a separate task. TestFlight distribution does not prove a live public storefront. The Mac-only `AddressAtlasUseDataProtectionKeychain` key must never be added here; CI rejects a bundle that contains it.

## Storage and lifecycle

The encrypted portfolio lives at `<app container>/Library/Application Support/AddressAtlas/vault.sqlite`, the same relative layout as the Mac. Its encryption key is a Keychain item with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, so it never leaves the device or enters a backup; restoring to a new device needs the recovery kit or the iCloud copy. `KeychainVaultKeyStore` forces the macOS legacy-keychain migration off on iOS because that migration's delete query would match the freshly saved item.

Scans and iCloud transfers are foreground-only; the target declares no `UIBackgroundModes`. When the app moves to the background, `RootView` takes a background-time assertion and `AppState.flushBeforeSuspension()` writes wallet-label drafts and pending persistence through the shared termination lane. If iOS runs out of background time while a scan is still running, the scan is cancelled. There is no termination hook: iOS may suspend and later kill the process without notice, so everything must already be saved when the app moves to the background.

## What is shared with the Mac app

The target links the `AddressAtlasCore` library product from `../AddressAtlasMac` (the package declares `.iOS(.v17)` alongside `.macOS(.v14)`) and compiles these files straight from `../AddressAtlasMac/Sources/AddressAtlasMac`:

- every `AppState*.swift` file (state transitions, validation, scanning, exchange connections, iCloud, saved-data changes, persistence, diagnostics, termination lane, chart data in `AppStateCharts.swift`);
- `UserFacingErrors.swift`, `ICloudVaultService.swift`, `PasskeyWebAuthenticator.swift`, `AtlasDesignSystem.swift`, `AtlasFormatting.swift`, `ExportPipeline.swift`;
- the theme engine (`AtlasThemeModel.swift`, `AtlasThemeCatalog.swift`, `AtlasThemeRuntime.swift`, `AtlasThemePicker.swift`, `AtlasDisplayPreferences.swift`, `AtlasFonts.swift`) and the `Charts/` folder with the 14 chart views and the coin widgets;
- the bundled `Fonts/` folder, which `project.yml` excludes as sources and ships as a folder resource.

Excluded as macOS-only (the `excludes` list in `project.yml`): `AddressAtlasApp.swift`, `AppShellViews.swift`, `PortfolioViews.swift`, `PortfolioComponents.swift`, `ExchangeSyncViews.swift`, `ICloudSyncView.swift`, `PrivacySafeDiagnosticsView.swift`, and the `MacScreens/` folder (Mac navigation, Portfolio, Assets, History, and coin detail).

Platform differences inside shared files sit behind `#if canImport(AppKit)` / `#if os(macOS)`: the theme uses `UIColor` dynamic providers on iOS, accessibility announcements use `UIAccessibility`, the entitlement probe is described above, and user-facing device nouns come from `PlatformCopy` in `AddressAtlasCore` ("Mac" on macOS, "device" on iOS). Any new file in the shared directory is picked up by the iOS target by default. If it needs AppKit, guard it rather than adding an exclusion, then regenerate and commit the project; CI fails when a shared source is missing from `AddressAtlasiOS.xcodeproj`. The build uses strict concurrency checking and treats warnings as errors.

## Demo fixture (Debug builds only)

`DemoFixture.swift` starts the app on a synthetic, offline portfolio (5 wallets, a Kraken connection, a manual holding, 30 scans over 42 days, an unbonding ATOM amount, one coin without a price) so every screen can be reviewed in the simulator. It uses a throw-away temporary directory, an in-memory key, and a network client that always fails, so it never touches a real portfolio, Keychain item, or provider. Launch arguments, all optional except the first: `-AtlasDemoFixture full|empty`, `-AtlasDemoTab portfolio|assets|sources|history|settings`, `-AtlasDemoRoute coin:ATOM|snapshot:latest|iCloud|export`, `-AtlasDemoSegment wallets|exchanges|holdings|tokens`, `-AtlasDemoAction addWallet|connectExchange|addManualHolding|addCustomToken`, `-AtlasDemoSliceFilter network:ethereum|state:staked`, `-AtlasDemoUnlock error|damaged|quarantine` (with `-AtlasDemoFixture empty`), and `-AtlasDemoScrollY 700`. Theme and appearance use the normal preference keys, for example `xcrun simctl launch booted com.addressatlas.ios -AtlasDemoFixture full -display.theme.v1 candy -display.appearanceMode.v1 dark`. The review pictures taken this way are in [`docs/design/screenshots/phase3/ios/`](../../docs/design/screenshots/phase3/ios/). All of the fixture and every call to it sit inside `#if DEBUG`; the proof is that `strings -a` on a Release binary shows none of `AtlasDemo|DemoFixture`:

```bash
./build-ios-app.sh --simulator --configuration Release
strings -a "build/DerivedData/Build/Products/Release-iphonesimulator/Address Atlas.app/Address Atlas" | grep -E "AtlasDemo|DemoFixture"   # prints nothing
```

## Open external gates

The App ID, shared-container association, distribution profile, and separate App Store Connect record have been created; see the [release checkpoint](../../app-store/README.md#release-checkpoint--october-6-2026). Keep these remaining gates separate from upload, processing, and TestFlight group assignment:

1. Verify entitlements and install the distributed build on a physical iPhone or iPad; complete the manual smoke list and resolve or explicitly track the known review findings.
2. Prove a Mac→iPhone encrypted restore on a physical device with iCloud Passwords & Keychain enabled, between builds on the same CloudKit environment (the entitlements pin Production for every iOS build, matching the Mac App Store build). The simulator cannot perform this test.
3. Configure and verify the iOS product-page update destination when appropriate; the source `AddressAtlasUpdateURL` is still generic.
4. Complete the separate App Review and public-release requirements; TestFlight availability is not storefront publication.
5. Kraken connections stay bound to the device that created them; a restored copy needs a separate read-only Kraken key per device. Keep that in the review notes.

The release contract, including the manual iPhone/iPad smoke list, is in `../../docs/RELEASE_CHECKLIST.md`; the iCloud provisioning details are in `../../docs/ICLOUD.md`.
