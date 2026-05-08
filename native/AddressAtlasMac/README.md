# Address Atlas Mac

Native SwiftUI macOS app for Address Atlas.

## Run In Development

```bash
./check-toolchain.sh
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift run AddressAtlasMac
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
It is ad-hoc signed for local testing by default. Set `ADDRESS_ATLAS_CODESIGN_IDENTITY` to a Developer ID Application identity when building a distribution candidate.

The app stores its encrypted local vault at:

```text
~/Library/Application Support/AddressAtlas/vault.sqlite
```

SQLite stores encrypted envelope JSON only. The vault key is random, 256-bit, and stored in macOS Keychain with this-device-only accessibility.

The native app performs wallet RPC, price, token, and exchange balance requests directly from macOS. Wallet scans include native BTC/SOL/EVM/TRX/XRP/Cosmos balances, registered ERC-20/SPL/TRC20 tokens, XRP issued-currency trustlines, and Cosmos delegation/reward balances. The native ERC-20/SPL registry mirrors the web reference's common token set so scans catch the expected blue-chip and stablecoin balances. If an optional token, staking, reward, or trustline subrequest fails, the scan keeps successful balances and records a warning. Exchange credentials are sealed with a dedicated vault subkey before being saved, then decrypted only in memory when a local scan runs.
