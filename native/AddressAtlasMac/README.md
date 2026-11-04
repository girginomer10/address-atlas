# Address Atlas Mac

Native SwiftUI macOS app for Address Atlas. This package also hosts `AddressAtlasCore` and the shared state layer and design system that the iOS app in [`../AddressAtlasiOS`](../AddressAtlasiOS/README.md) compiles directly; see [iOS target](#ios-target) for the shared/Mac-only split.

## Screens

The sidebar has seven sections (`MainView.Section` in `Sources/AddressAtlasMac/AppShellViews.swift`), opened with ⌘1 to ⌘7 in this order:

1. **Portfolio**: total value, change since the previous scan (only when both scans read the same sources), **Scan** (⌘R), a switcher over the 14 chart views with **Group by** for the views that use it, and the eight largest coins. Unpriced coins and scan warnings are explained in plain sentences next to the total.
2. **Assets**: every coin with search (⌘F), filters, and the slice a chart sent.
3. **History**: an over-time chart and the saved scans; a scan opens its holdings.
4. **Wallets**: saved wallets and the add form (⌘N). A **Tokens** pane holds custom tokens and manual holdings.
5. **Exchanges**: connect Binance, Coinbase Advanced Trade, or Kraken with a read-only API key.
6. **Export**: CSV and JSON, share-safer or full.
7. **Settings**: Theme (six themes), portfolio preferences, iCloud, Privacy, recovery kit, and diagnostics. The same view is also the macOS Settings window.

A coin opens over the current section (Esc or the back button returns) with its state strip, unlock timeline, amount history, change, custody, and holdings. Navigation state lives in `MacNavigationModel` (`MacScreens/MacNavigation.swift`); the Mac-only screens are in `Sources/AddressAtlasMac/MacScreens/`.

## Run In Development

```bash
./check-toolchain.sh
PATH="$(brew --prefix swift)/bin:$PATH" swift run AddressAtlasMac
```

## Test

```bash
swift test
```

This requires full Xcode selected with `xcode-select`, not only Command Line Tools.
The Homebrew Swift fallback can build the app, but it does not provide XCTest.

The tests are in `Tests/AddressAtlasCoreTests` (scanners, exchange clients, encryption, storage, recovery kit, export, analytics) and `Tests/AddressAtlasMacTests` (state layer, themes, the 14 chart views, and `MacScreenRenderTests`, which renders the real window). The shell and Python checks for packaging sit next to them: `build-mac-app-version-tests.sh`, `mas-release-contract-tests.sh`, `notarize-mac-app-tests.sh`, and `icloud-entitlements-tests.py`. `swift test --sanitize=thread` runs the same suite under Thread Sanitizer.

`MacScreenRenderTests` also writes the review pictures in `../../docs/design/screenshots/phase3/mac/` when you run it from this folder:

```bash
ATLAS_WRITE_SCREENSHOTS=1 swift test --filter MacScreenRenderTests    # the committed review set
ATLAS_WRITE_SCREENSHOTS=all swift test --filter MacScreenRenderTests  # every screen in every theme
```

`ATLAS_SCREENSHOT_DIR` changes the output folder and `ATLAS_SCREENSHOT_NAMES` (comma-separated file-name prefixes) limits which files are written. Without these variables the test only renders a few screens as a smoke test.

## Build A Local App Bundle

```bash
./build-mac-app.sh
open "dist/Address Atlas.app"
```

The current product uses optional private iCloud copies. The former passkey/server UI and automatic server requests are retired. See [iCloud setup](../../docs/ICLOUD.md); unsigned local builds cannot access CloudKit.
It is built as a universal `arm64` + `x86_64` binary with hardened runtime and ad-hoc signed for local testing by default. Set `ADDRESS_ATLAS_CODESIGN_IDENTITY` to a Developer ID Application identity when building a direct-download distribution candidate. Set `ADDRESS_ATLAS_ARCHS=arm64` only for an explicitly local single-architecture build; signed distribution flows reject artifacts unless their executable contains exactly both supported architectures.
`CFBundleVersion` defaults to the full Git commit count. A shallow checkout must set a unique `ADDRESS_ATLAS_BUILD_NUMBER`; run `bash Tests/build-mac-app-version-tests.sh` before packaging.

## Build A Mac App Store Package

The Mac App Store and direct-download channels are intentionally separate. A store package requires the App Store Connect numeric Apple ID, an Apple/Mac App Distribution certificate, a Mac Installer Distribution certificate, and a Mac App Store Connect distribution provisioning profile for `com.addressatlas.mac` authorizing the Production CloudKit container `iCloud.com.addressatlas.mac`:

```bash
ADDRESS_ATLAS_APP_STORE_ID="<numeric Apple ID>" \
ADDRESS_ATLAS_MAS_CODESIGN_IDENTITY="Apple Distribution: ..." \
ADDRESS_ATLAS_MAS_INSTALLER_IDENTITY="Mac Installer Distribution: ..." \
ADDRESS_ATLAS_PROVISIONING_PROFILE="/absolute/path/AddressAtlas_Mac_App_Store.provisionprofile" \
  ./build-mas-pkg.sh
```

From a clean `main` checkout that matches `origin/main`, the builder derives `com.apple.application-identifier` and `com.apple.developer.team-identifier` from the decoded profile, verifies they match `com.addressatlas.mac`, embeds the profile, signs the sandboxed app, and produces `dist/Address Atlas-AppStore.pkg` plus a read-only source/package provenance plist. The App Store build uses App Sandbox, outgoing-network access, user-selected read/write access, Data Protection Keychain, and an `apps.apple.com` update route. Run `./validate-mas-artifact.sh` and the source-bound App Store Connect validation/upload scripts described in [`../../app-store/README.md`](../../app-store/README.md) before submission.

The direct development/download channel stores the encrypted portfolio at:

```text
~/Library/Application Support/AddressAtlas/vault.sqlite
```

The sandboxed Mac App Store build stores the same relative path inside its app container and migrates a legacy non-sandboxed `Application Support/AddressAtlas` directory on first launch. SQLite stores encrypted envelope JSON only. The encryption key is random and 256-bit. Mac App Store builds use Data Protection Keychain with this-device-only accessibility; the direct channel retains the legacy Keychain backend for compatibility. If the key is missing while a saved portfolio exists, the app stops at the locked screen and offers recovery-file import instead of creating an unrelated key.

The native app performs wallet RPC, price, token, and exchange balance requests directly from macOS. Wallet scans include native BTC/SOL/EVM/TRX/XRP/Cosmos balances, registered ERC-20/SPL/TRC20 tokens, XRP issued-currency trustlines, and Cosmos delegation/reward balances. If an optional token, price, staking, reward, trustline, or pagination subrequest fails, the scan keeps successful balances and presents a visible warning. Exchange credentials are sealed with a dedicated subkey of the portfolio key before being saved, then decrypted only in memory when a local scan runs. Exchange origins and credential-bearing paths are pinned in the app and cannot be redirected by sync-server configuration.

TLS certificate pinning is deliberately not used: the app talks only to third-party services (chain RPCs, price API, exchanges, sync server) that rotate certificates on their own schedule, so pins would turn routine rotations into outages. The transport boundary is instead the system trust store plus HTTPS-only host/scheme/port allowlisting, sessions that refuse to follow redirects, bounded response sizes, and request timeouts (see `Sources/AddressAtlasCore/Scanners/HTTPClient.swift`).

## iOS target

The iOS app lives in [`../AddressAtlasiOS`](../AddressAtlasiOS/README.md). It is an xcodegen-generated Xcode project, not a second SwiftPM package: it links the `AddressAtlasCore` library product from this package (which declares `.iOS(.v17)` alongside `.macOS(.v14)`) and compiles most of `Sources/AddressAtlasMac` as its own sources. It now has a separate App Store Connect record; see the [release checkpoint](../../app-store/README.md#release-checkpoint--october-6-2026) for its build and TestFlight state. Physical-device acceptance remains unverified.

Shared with iOS (every file in `Sources/AddressAtlasMac` is shared unless it is listed in the exclusion list in `../AddressAtlasiOS/project.yml`):

- every `AppState*.swift` file
- `UserFacingErrors.swift`, `ICloudVaultService.swift`, `PasskeyWebAuthenticator.swift`, `AtlasDesignSystem.swift`, `AtlasFormatting.swift`, `ExportPipeline.swift`
- the theme engine (`AtlasThemeModel.swift`, `AtlasThemeCatalog.swift`, `AtlasThemeRuntime.swift`, `AtlasThemePicker.swift`, `AtlasDisplayPreferences.swift`, `AtlasFonts.swift`), the `Charts/` folder (14 chart views and the coin widgets), and the bundled `Fonts/` folder

Mac-only (excluded from the iOS target): `AddressAtlasApp.swift`, `AppShellViews.swift`, `PortfolioViews.swift`, `PortfolioComponents.swift`, `ExchangeSyncViews.swift`, `ICloudSyncView.swift`, `PrivacySafeDiagnosticsView.swift`, and the `MacScreens/` folder. A new Mac-only file under `MacScreens/` needs no project change.

Platform differences inside shared files sit behind `#if canImport(AppKit)` or `#if os(macOS)`, and user-facing device nouns come from `PlatformCopy` in `AddressAtlasCore` ("Mac" here, "device" on iOS). When you add a shared Swift file to this directory, run `npm run native:ios:generate` and commit the regenerated `AddressAtlasiOS.xcodeproj`; CI fails when a shared source is missing from it. The iOS build derives its version from `currentAppVersion` in `AppState.swift` and its build number from `./build-mac-app.sh --print-build-version`, so both apps always report one product version and one build number.
