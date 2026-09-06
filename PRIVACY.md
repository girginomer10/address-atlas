# Address Atlas Privacy Model

**Effective date:** September 7, 2026
**Operator:** Ömer Girgin, the maintainer of Address Atlas

Address Atlas is built to reduce custody and data exposure, not to promise anonymity. It is a local-first, read-only portfolio viewer for public wallet addresses and supported exchange accounts.

## What stays on your Mac

While the app is unlocked, the native process handles wallet addresses, labels, balances, scan history, preferences, and supported exchange credentials. The local SQLite database stores a single encrypted vault document rather than plaintext portfolio rows.

The vault uses AES-256-GCM with purpose-separated keys derived from a random vault key. macOS Keychain stores that vault key with this-device-only accessibility. Address Atlas does not ask for or store seed phrases, wallet private keys, or signing material.

Exchange credentials are encrypted before persistence and decrypted only inside the native process when validation or local credential and balance operations require them. Plaintext credentials are never sent to iCloud. They must be balance/read-only credentials with no trading, transfer, margin, futures, or withdrawal capability.

## What network providers can observe

Local-first does not mean offline or anonymous. To retrieve balances and prices, the Mac app contacts third-party services:

- Chain RPC and REST providers receive the public address and requests needed for the selected network.
- Supported exchanges receive authenticated read-only balance requests and the network metadata inherent in a direct connection.
- CoinGecko receives asset identifiers and fiat-rate lookup requests.

Those providers can observe normal connection metadata such as the source IP address, timing, and user agent. Their own terms and privacy practices apply. Address Atlas does not proxy these requests through a backup server.

Address Atlas does not use advertising SDKs, cross-app tracking, data brokers, or analytics SDKs. It does not sell personal data.

## Optional encrypted iCloud copies

The app uses Apple's CloudKit private database for user-initiated encrypted portfolio transfers. No Address Atlas account, passkey sign-in, developer-operated sync service, PostgreSQL database, or hosted backup is required. Save, restore, and delete happen only when selected in the iCloud screen; this is not automatic merging or versioned backup history.

The Mac encrypts the whole portfolio before uploading, including already-encrypted exchange credentials. Credentials are rewrapped with a separate random cloud key; the original local vault key is never uploaded. The cloud key is synchronized through iCloud Keychain, scoped to the CloudKit user and a random key identifier. A different Mac decrypts the copy and re-encrypts credentials with its own local key. Kraken's installation binding remains intact.

Apple receives the encrypted asset and normal CloudKit metadata (record identifiers, sizes, versions, timestamps, account and network information needed to operate iCloud). The data uses the user's iCloud storage quota and is subject to Apple's iCloud terms and privacy practices. The Address Atlas operator does not run a copy of this backup database or receive the plaintext portfolio or cloud key. CloudKit storage and iCloud Keychain key delivery are distinct; the key may arrive later than the record.

## Retention and deletion

- Local vaults, exports, recovery kits, and local rollback copies remain on the Mac or where the user saved them until removed by the user.
- **iCloud → Delete iCloud copy** removes this app's private cloud snapshot, after confirmation. It does not delete portfolios on other Macs, exports, the Apple Account, or other iCloud data. Small Keychain encryption-key items remain available for in-flight restores.
- A stale Mac does not automatically recreate a deleted cloud copy. An explicit reset of the local iCloud connection is required before saving a fresh copy.
- Data left on a server by an older version is not deleted by this app update. Contact the previous server operator about retained snapshots, account records, or infrastructure backups. The current Mac app no longer contacts that service.

## Recovery

A recovery kit contains a .atlas-recovery file and a high-entropy recovery code shown once. Both are required to unwrap the Mac's local vault key. They are not uploaded to iCloud. This kit does not recover the separate iCloud key. Protect iCloud Keychain access and keep a local vault/recovery kit; the operator cannot recover a missing cloud key. Anyone who obtains the recovery file and its code may be able to unlock the corresponding local vault, so keep them separately.

## Exports

Address Atlas offers two export classes:

- Recommended **share-safer** CSV and JSON summaries omit addresses, labels, exact balances, and history, using coarse groups and ranges. They reduce disclosure but are not anonymous and may still reveal sensitive portfolio characteristics.
- **Full identifying** CSV and JSON reports include public addresses, labels, exact balances, asset identifiers, and—where applicable—history. They remain behind an explicit disclosure and must be handled as sensitive data.

Exports omit sync bearer sessions and encrypted exchange credentials. They are reports, not vault backups.

## User choices

Network scanning begins only after the user adds a public address or read-only exchange connection and starts a scan (or enables automatic refresh). iCloud transfers are optional. A user can keep the app local-only, remove saved sources, revoke exchange credentials at the exchange, delete the iCloud copy in the app, and delete exported files they control.

## Security

Mac App Store builds use App Sandbox, Data Protection Keychain with this-device-only accessibility for the vault and Kraken installation secrets, encrypted local storage, bounded network clients, and user-selected file access. No security measure eliminates all risk; users should keep recovery material separate and protect their Mac login.

## No product AI

Address Atlas has no OpenAI runtime dependency and does not send portfolio data to OpenAI. OpenAI Codex has been used as an engineering collaborator during development, not as a product feature.

## Security reports

Do not post suspected data exposure or leaked credentials in a public issue. Follow the private process in the [Security Policy](.github/SECURITY.md).

## Contact and policy changes

For privacy or support questions, email [girginomer10@gmail.com](mailto:girginomer10@gmail.com) or use the [support tracker](https://github.com/girginomer10/address-atlas/issues) without posting wallet inventories, credentials, recovery material, or other sensitive data. Security vulnerabilities belong in the private reporting flow above.

Material policy changes will be published in this file and reflected by a new effective date. If a future change requires new consent, Address Atlas will request it before enabling the affected processing. Use of the app is also governed by the [Terms of Use](TERMS.md).
