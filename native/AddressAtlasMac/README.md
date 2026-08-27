# Address Atlas Mac

Native SwiftUI macOS app for Address Atlas.

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

## Build A Local App Bundle

```bash
./build-mac-app.sh
open "dist/Address Atlas.app"
```

The app bundle registers the `address-atlas://sync-auth` callback URL used by the encrypted sync passkey flow.
It is built as a universal `arm64` + `x86_64` binary with hardened runtime and ad-hoc signed for local testing by default. Set `ADDRESS_ATLAS_CODESIGN_IDENTITY` to a Developer ID Application identity when building a direct-download distribution candidate. Set `ADDRESS_ATLAS_ARCHS=arm64` only for an explicitly local single-architecture build; signed distribution flows reject artifacts unless their executable contains exactly both supported architectures.
`CFBundleVersion` defaults to the full Git commit count. A shallow checkout must set a unique `ADDRESS_ATLAS_BUILD_NUMBER`; run `bash Tests/build-mac-app-version-tests.sh` before packaging.

## Build A Mac App Store Package

The Mac App Store and direct-download channels are intentionally separate. A store package requires the App Store Connect numeric Apple ID, an Apple/Mac App Distribution certificate, a Mac Installer Distribution certificate, and a Mac App Store Connect distribution provisioning profile for `com.addressatlas.mac`:

```bash
ADDRESS_ATLAS_APP_STORE_ID="<numeric Apple ID>" \
ADDRESS_ATLAS_MAS_CODESIGN_IDENTITY="Apple Distribution: ..." \
ADDRESS_ATLAS_MAS_INSTALLER_IDENTITY="Mac Installer Distribution: ..." \
ADDRESS_ATLAS_PROVISIONING_PROFILE="/absolute/path/AddressAtlas_Mac_App_Store.provisionprofile" \
  ./build-mas-pkg.sh
```

From a clean `main` checkout that matches `origin/main`, the builder derives `com.apple.application-identifier` and `com.apple.developer.team-identifier` from the decoded profile, verifies they match `com.addressatlas.mac`, embeds the profile, signs the sandboxed app, and produces `dist/Address Atlas-AppStore.pkg` plus a read-only source/package provenance plist. The App Store build uses App Sandbox, outgoing-network access, user-selected read/write access, Data Protection Keychain, and an `apps.apple.com` update route. Run `./validate-mas-artifact.sh` and the source-bound App Store Connect validation/upload scripts described in [`../../app-store/README.md`](../../app-store/README.md) before submission.

The direct development/download channel stores its encrypted local vault at:

```text
~/Library/Application Support/AddressAtlas/vault.sqlite
```

The sandboxed Mac App Store build stores the same relative path inside its app container and migrates a legacy non-sandboxed `Application Support/AddressAtlas` directory on first launch. SQLite stores encrypted envelope JSON only. The vault key is random and 256-bit. Mac App Store builds use Data Protection Keychain with this-device-only accessibility; the direct channel retains the legacy Keychain backend for compatibility. If the key is missing while a vault exists, the app stops at the locked screen and offers recovery-file import instead of creating an unrelated key.

The native app performs wallet RPC, price, token, and exchange balance requests directly from macOS. Wallet scans include native BTC/SOL/EVM/TRX/XRP/Cosmos balances, registered ERC-20/SPL/TRC20 tokens, XRP issued-currency trustlines, and Cosmos delegation/reward balances. If an optional token, price, staking, reward, trustline, or pagination subrequest fails, the scan keeps successful balances and presents a visible warning. Exchange credentials are sealed with a dedicated vault subkey before being saved, then decrypted only in memory when a local scan runs. Exchange origins and credential-bearing paths are pinned in the app and cannot be redirected by sync-server configuration.

TLS certificate pinning is deliberately not used: the app talks only to third-party services (chain RPCs, price API, exchanges, sync server) that rotate certificates on their own schedule, so pins would turn routine rotations into outages. The transport boundary is instead the system trust store plus HTTPS-only host/scheme/port allowlisting, sessions that refuse to follow redirects, bounded response sizes, and request timeouts (see `Sources/AddressAtlasCore/Scanners/HTTPClient.swift`).
