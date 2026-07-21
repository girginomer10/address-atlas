# Address Atlas Privacy Model

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

## Optional encrypted sync

Sync is optional and self-hostable. The Mac app encrypts vault snapshots before upload. The sync service stores passkey public credentials, account and snapshot metadata, and opaque encrypted snapshots in PostgreSQL.

The sync service does not receive plaintext portfolio contents, plaintext exchange credentials, recovery material, or a decryptable vault key. It can still observe operational metadata such as account identifiers, snapshot versions and sizes, request timing, source IP addresses at the network edge, and service health data. This is server-blind encrypted sync, not a claim that the service stores no metadata.

The app opens a system web authentication session for passkey registration and sign-in. The callback carries a one-time authorization code, request state, and canonical server origin; the app exchanges that code with a PKCE verifier for a short-lived sync session.

## Recovery

A recovery kit contains a `.atlas-recovery` file and a high-entropy recovery code shown once. Both are required to unwrap the Mac vault key. Neither is uploaded to the sync service. Anyone who obtains both may be able to unlock the protected vault; store them separately and securely.

## Exports

Address Atlas offers two export classes:

- Recommended **share-safer** CSV and JSON summaries omit addresses, labels, exact balances, and history, using coarse groups and ranges. They reduce disclosure but are not anonymous and may still reveal sensitive portfolio characteristics.
- **Full identifying** CSV and JSON reports include public addresses, labels, exact balances, asset identifiers, and—where applicable—history. They remain behind an explicit disclosure and must be handled as sensitive data.

Exports omit sync bearer sessions and encrypted exchange credentials. They are reports, not vault backups.

## No product AI

Address Atlas has no OpenAI runtime dependency and does not send portfolio data to OpenAI. OpenAI Codex has been used as an engineering collaborator during development, not as a product feature.

## Security reports

Do not post suspected data exposure or leaked credentials in a public issue. Follow the private process in the [Security Policy](.github/SECURITY.md).
