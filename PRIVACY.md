# Address Atlas Privacy Model

**Effective date:** August 27, 2026
**Operator:** Ömer Girgin, the maintainer of Address Atlas

Address Atlas is built to reduce custody and data exposure, not to promise anonymity. It is a local-first, read-only portfolio viewer for public wallet addresses and supported exchange accounts.

## What stays on your Mac

While the app is unlocked, the native process handles wallet addresses, labels, balances, scan history, preferences, and supported exchange credentials. The local SQLite database stores a single encrypted vault document rather than plaintext portfolio rows.

The vault uses AES-256-GCM with purpose-separated keys derived from a random vault key. macOS Keychain stores that vault key with this-device-only accessibility. Address Atlas does not ask for or store seed phrases, wallet private keys, or signing material.

Exchange credentials are encrypted before persistence and decrypted only inside the native process when validation or local credential and balance operations require them. Plaintext credentials are never sent to the sync service. They must be balance/read-only credentials with no trading, transfer, margin, futures, or withdrawal capability.

## What network providers can observe

Local-first does not mean offline or anonymous. To retrieve balances and prices, the Mac app contacts third-party services:

- Chain RPC and REST providers receive the public address and requests needed for the selected network.
- Supported exchanges receive authenticated read-only balance requests and the network metadata inherent in a direct connection.
- CoinGecko receives asset identifiers and fiat-rate lookup requests.

Those providers can observe normal connection metadata such as the source IP address, timing, and user agent. Their own terms and privacy practices apply. Address Atlas does not proxy these requests through the optional sync service.

Address Atlas does not use advertising SDKs, cross-app tracking, data brokers, or analytics SDKs. It does not sell personal data.

## Optional encrypted sync

Sync is optional and self-hostable. The Mac app encrypts vault snapshots before upload. The sync service stores passkey public credentials, account and snapshot metadata, and opaque encrypted snapshots in PostgreSQL.

The sync service does not receive plaintext portfolio contents, plaintext exchange credentials, recovery material, or a decryptable vault key. It can still observe operational metadata such as account identifiers, snapshot versions and sizes, request timing, source IP addresses at the network edge, and service health data. This is server-blind encrypted sync, not a claim that the service stores no metadata.

To enforce service limits, the hosted sync implementation retains per-account daily write counts and byte counts. Its bounded access logs retain request status and duration together with a masked network prefix for availability, security, and incident diagnosis; headers, request URI, exact IP addresses, and authentication material are removed before the record reaches the log stream. These records are disclosed conservatively as linked Other Usage Data, Other Diagnostic Data, and Other Data Types for app functionality, and are not used for tracking.

The app opens a system web authentication session for passkey registration and sign-in. The callback carries a one-time authorization code, request state, and canonical server origin; the app exchanges that code with a PKCE verifier for a short-lived sync session.

For App Store privacy disclosure, optional sync is treated conservatively as collection for app functionality: an opaque account identifier, passkey public credential material, operational/security/usage/diagnostic metadata, and encrypted portfolio content are transmitted off the Mac and retained by the chosen sync operator. The Address Atlas service cannot decrypt the portfolio snapshot, but the encrypted blob is still stored on a server and is therefore disclosed rather than treated as purely on-device processing.

## Retention and deletion

- Local vault data remains on the Mac until the user removes it or removes the app's container. User-created CSV, JSON, and recovery exports remain wherever the user saved them.
- A sync server retains the current encrypted snapshot, account record, and passkey public credentials until the user deletes the sync account in the app. Account deletion cascades the account, passkeys, sessions, quota records, and encrypted snapshot.
- Session grants stop working at expiration and are removed by bounded cleanup. Operational backups may retain encrypted records for up to 30 days before scheduled expiry.
- To make deletion retries safe for an offline Mac, the service retains a one-way digest of the deletion operation identifier and its timestamp. That receipt contains no account identifier or portfolio content and is not used for tracking.

The **Sync** screen includes **Delete sync account**. A recent passkey-authenticated session is required so a stolen unlocked session cannot silently delete the account. Users of a self-hosted server should contact that server's operator for backup or infrastructure-specific retention questions.

## Recovery

A recovery kit contains a `.atlas-recovery` file and a high-entropy recovery code shown once. Both are required to unwrap the Mac vault key. Neither is uploaded to the sync service. Anyone who obtains both may be able to unlock the protected vault; store them separately and securely.

## Exports

Address Atlas offers two export classes:

- Recommended **share-safer** CSV and JSON summaries omit addresses, labels, exact balances, and history, using coarse groups and ranges. They reduce disclosure but are not anonymous and may still reveal sensitive portfolio characteristics.
- **Full identifying** CSV and JSON reports include public addresses, labels, exact balances, asset identifiers, and—where applicable—history. They remain behind an explicit disclosure and must be handled as sensitive data.

Exports omit sync bearer sessions and encrypted exchange credentials. They are reports, not vault backups.

## User choices

Network scanning begins only after the user adds a public address or read-only exchange connection and starts a scan (or enables automatic refresh). Sync is optional. A user can keep the app local-only, remove saved sources, revoke exchange credentials at the exchange, delete a sync account in the app, and delete any exported files they control.

## Security

Mac App Store builds use App Sandbox, Data Protection Keychain with this-device-only accessibility for the vault and Kraken installation secrets, encrypted local storage, bounded network clients, and user-selected file access. No security measure eliminates all risk; users should keep recovery material separate and protect their Mac login.

## No product AI

Address Atlas has no OpenAI runtime dependency and does not send portfolio data to OpenAI. OpenAI Codex has been used as an engineering collaborator during development, not as a product feature.

## Security reports

Do not post suspected data exposure or leaked credentials in a public issue. Follow the private process in the [Security Policy](.github/SECURITY.md).

## Contact and policy changes

For privacy or support questions, email [girginomer10@gmail.com](mailto:girginomer10@gmail.com) or use the [support tracker](https://github.com/girginomer10/address-atlas/issues) without posting wallet inventories, credentials, recovery material, or other sensitive data. Security vulnerabilities belong in the private reporting flow above.

Material policy changes will be published in this file and reflected by a new effective date. If a future change requires new consent, Address Atlas will request it before enabling the affected processing. Use of the app is also governed by the [Terms of Use](TERMS.md).
