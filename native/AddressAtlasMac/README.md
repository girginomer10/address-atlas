# Address Atlas Mac

Native SwiftUI macOS app for Address Atlas.

## Run In Development

```bash
swift run AddressAtlasMac
```

## Test

```bash
swift test
```

This requires full Xcode selected with `xcode-select`, not only Command Line Tools.

## Build A Local App Bundle

```bash
./build-mac-app.sh
open "dist/Address Atlas.app"
```

The app stores its encrypted local vault at:

```text
~/Library/Application Support/AddressAtlas/vault.sqlite
```

SQLite stores encrypted envelope JSON only. The vault key is random, 256-bit, and stored in macOS Keychain with this-device-only accessibility.
