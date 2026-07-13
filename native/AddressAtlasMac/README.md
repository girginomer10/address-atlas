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
It is built as a universal `arm64` + `x86_64` binary with hardened runtime and ad-hoc signed for local testing by default. Set `ADDRESS_ATLAS_CODESIGN_IDENTITY` to a Developer ID Application identity when building a distribution candidate. Set `ADDRESS_ATLAS_ARCHS=arm64` only for an explicitly local single-architecture build.

The app stores its encrypted local vault at:

```text
~/Library/Application Support/AddressAtlas/vault.sqlite
```

SQLite stores encrypted envelope JSON only. The vault key is random, 256-bit, and stored in macOS Keychain with this-device-only accessibility. If that key is missing while a vault exists, the app stops at the locked screen and offers recovery-file import instead of creating an unrelated key.

The native app performs wallet RPC, price, token, and exchange balance requests directly from macOS. Wallet scans include native BTC/SOL/EVM/TRX/XRP/Cosmos balances, registered ERC-20/SPL/TRC20 tokens, XRP issued-currency trustlines, and Cosmos delegation/reward balances. If an optional token, price, staking, reward, trustline, or pagination subrequest fails, the scan keeps successful balances and presents a visible warning. Exchange credentials are sealed with a dedicated vault subkey before being saved, then decrypted only in memory when a local scan runs. Exchange origins and credential-bearing paths are pinned in the app and cannot be redirected by sync-server configuration.
