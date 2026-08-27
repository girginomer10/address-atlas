# App Review Notes — Address Atlas 0.2.0

Address Atlas is read-only analytics software. It does not create or custody wallets, request seed phrases or private keys, sign or execute transactions, route orders, operate an exchange, enable mining, issue crypto rewards, or provide personalized investment advice.

No account or demo credential is required for the core local experience. On first launch, select **Unlock vault**; the app creates an encrypted local vault. The reviewer can add a public address, scan supported providers, inspect assets and snapshots, create exports, and open Settings without supplying sensitive information. Please use only fictional or reviewer-controlled public addresses and read-only exchange credentials.

The **Sync** screen is an optional, self-hostable encrypted-vault transfer feature. It uses passkeys for account authentication and uploads an opaque encrypted snapshot; the server never receives the vault key. If App Review needs the hosted path rather than the fully functional local path, the production review endpoint and exact test procedure must be added in App Store Connect before submission. Do not submit with a placeholder or unavailable endpoint.

Account deletion is available inside **Sync** and requires a recent passkey-authenticated session. It cascades the account, passkeys, sessions, quota rows, and encrypted snapshot. A one-way, account-unlinked deletion-operation digest remains to make offline retry idempotent.

Network behavior:

- Public wallet addresses and balance requests go directly to configured chain RPC/REST providers.
- Read-only exchange credentials go directly to the selected exchange.
- CoinGecko receives asset identifiers for reference prices; Settings includes the required attribution.
- Optional sync receives account/security metadata and an encrypted snapshot as described in the privacy policy.

The app uses only Apple platform cryptography and HTTPS (`CryptoKit`, Keychain, and `URLSession`). `ITSAppUsesNonExemptEncryption` is set to `NO`. The Mac App Store build uses App Sandbox with outgoing-network and user-selected read/write file access only.

Update handling is distribution-specific: this App Store build opens its immutable `apps.apple.com` product page. It never directs App Store users to the separately signed GitHub DMG channel.
