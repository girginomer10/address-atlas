# Address Atlas Privacy Model

**Effective date:** September 25, 2026
**Operator:** Ömer Girgin, the maintainer of Address Atlas

Address Atlas is a local-first, read-only portfolio viewer for public wallet addresses and supported exchange accounts. It reduces custody and data exposure. It does not make you anonymous.

## What stays on your device

While the app is unlocked, it handles your wallet addresses, labels, balances, scan history, preferences, and exchange API keys on your device. The local SQLite database stores one encrypted portfolio document, not plaintext portfolio rows.

The portfolio is encrypted with AES-256-GCM. Separate keys for separate purposes are derived from one random portfolio key. The device Keychain (macOS Keychain on a Mac, iOS Keychain on an iPhone or iPad) stores that key as this-device-only, so it does not move to another device through backups or iCloud Keychain. Address Atlas does not ask for or store seed phrases, wallet private keys, or signing material.

Exchange API keys are encrypted before they are saved. The app decrypts them only inside the app, and only when it needs them to validate a key or to run local key and balance operations. Plaintext API keys are never sent to iCloud. They must be balance-only (read-only) keys with no trading, transfer, margin, futures, or withdrawal capability.

## What network providers can observe

Local-first does not mean offline or anonymous. To read balances and prices, the app contacts third-party services directly from your device:

- Chain RPC and REST providers receive the public address and the requests needed for the network you scan.
- Supported exchanges receive authenticated read-only balance requests and the network metadata that any direct connection reveals.
- CoinGecko receives asset identifiers and fiat-rate lookup requests.

These providers can see normal connection metadata such as your IP address, request timing, and user agent. Their own terms and privacy practices apply. Address Atlas does not route these requests through a backup server.

Address Atlas does not use advertising SDKs, cross-app tracking, data brokers, or analytics SDKs. It does not sell personal data.

## Optional encrypted iCloud copies

The app can save an encrypted copy of your portfolio to your private iCloud (CloudKit) database and restore it on another device. You start every transfer. No Address Atlas account, passkey sign-in, developer-operated sync service, PostgreSQL database, or hosted backup is required. Save, restore, and delete happen only when you choose them on the iCloud screen. Nothing merges automatically, and there is no versioned backup history.

Your device encrypts the whole portfolio before upload, including exchange API keys that are already encrypted. The API keys are re-encrypted with a separate random cloud key. The local portfolio key is never uploaded. The cloud key syncs through iCloud Keychain, tied to your CloudKit user and a random key identifier. Another device (Mac, iPhone, or iPad) decrypts the copy and re-encrypts the API keys with its own local key. Kraken keys stay bound to one device, so a restored copy needs a separate read-only Kraken key on each device.

Apple receives the encrypted copy and normal CloudKit metadata: record identifiers, sizes, versions, timestamps, and the account and network information iCloud needs to run. The copy counts against your iCloud storage and is subject to Apple's iCloud terms and privacy practices. The Address Atlas operator does not run a copy of this backup database and does not receive your plaintext portfolio or the cloud key. CloudKit storage and iCloud Keychain key delivery are separate, so the key can arrive later than the record.

## Retention and deletion

- Your local portfolio, exports, recovery kits, and local backup copies stay on the device, or wherever you saved them, until you remove them.
- **iCloud → Delete iCloud copy** removes this app's private cloud snapshot, after you confirm. It does not delete portfolios on other devices, exports, your Apple Account, or other iCloud data. Small Keychain encryption-key items stay available so that a restore already under way can finish.
- A device that still has the old state does not recreate a deleted cloud copy on its own. You must reset the local iCloud connection before you save a new copy.
- Data that an older version left on a server is not deleted by this update. Contact the previous server operator about retained snapshots, account records, or infrastructure backups. The current app no longer contacts that service.

## Recovery

A recovery kit is a `.atlas-recovery` file plus a high-entropy recovery code that is shown once. You need both to unwrap the device's local portfolio key. Neither is uploaded to iCloud. The kit does not recover the separate iCloud key. Protect your iCloud Keychain access and keep a recovery kit for the local portfolio; the operator cannot recover a missing cloud key. Anyone who has both the recovery file and its code may be able to unlock the matching local portfolio, so store them apart.

## Exports

There are two kinds of export:

- **Share-safer** CSV and JSON summaries (recommended) leave out addresses, labels, exact balances, and history, and use coarse groups and ranges. They reduce what you disclose but are not anonymous, and they can still reveal sensitive traits of your portfolio.
- **Full identifying** CSV and JSON reports include public addresses, labels, exact balances, asset identifiers, and, where applicable, history. They stay behind an explicit warning. Handle them as sensitive data.

Exports leave out sync bearer sessions and encrypted exchange API keys. They are reports, not portfolio backups.

## User choices

Scanning starts only after you add a public address or a read-only exchange connection and start a scan, or turn on automatic refresh. iCloud transfers are optional. You can keep the app local-only, remove saved sources, revoke exchange API keys at the exchange, delete the iCloud copy in the app, and delete exported files you control.

## Security

- Mac App Store builds use App Sandbox, Data Protection Keychain with this-device-only accessibility for the portfolio key and Kraken installation secrets, encrypted local storage, bounded network clients, and user-selected file access.
- iOS builds use the iOS app sandbox, the device Keychain with this-device-only accessibility, the same encrypted local storage and bounded network clients, and the system share sheet and Files for exports and recovery kits. The portfolio key never leaves the device or enters a backup, so restoring to a new iPhone or iPad needs the recovery kit or an iCloud copy.

No security measure removes all risk. Keep recovery material separate and protect your device login (Mac login, or iPhone or iPad passcode).

## No product AI

Address Atlas has no OpenAI runtime dependency and does not send portfolio data to OpenAI. OpenAI Codex has been used as an engineering collaborator during development, not as a product feature.

## Security reports

Do not post suspected data exposure or leaked credentials in a public issue. Follow the private process in the [Security Policy](.github/SECURITY.md).

## Contact and policy changes

For privacy or support questions, email [girginomer10@gmail.com](mailto:girginomer10@gmail.com) or use the [support tracker](https://github.com/girginomer10/address-atlas/issues). Do not post wallet inventories, credentials, recovery material, or other sensitive data there. Security vulnerabilities belong in the private reporting flow above.

Material policy changes will be published in this file with a new effective date. If a future change requires new consent, Address Atlas will ask for it before turning on the affected processing. Use of the app is also governed by the [Terms of Use](TERMS.md).
