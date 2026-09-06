# App Review Notes — Address Atlas 0.2.0

Address Atlas is read-only portfolio software. It does not create or custody
wallets, request seed phrases or private keys, sign transactions, trade, mine,
issue crypto rewards, or provide personalized investment advice.

No account or demo credential is required for the local experience. Unlock the
vault, add a reviewer-controlled public address, scan, inspect assets and
snapshots, and export. Do not use production exchange credentials in review.

The **iCloud** screen provides optional, manual Save to iCloud, Restore from
iCloud, and Delete iCloud copy actions. It uses the reviewer's system Apple
Account, CloudKit private database, and iCloud Passwords & Keychain. No separate
Address Atlas registration or hosted server endpoint exists. Restore requires
confirmation and keeps a local rollback copy. Concurrent remote changes cause a
conflict message instead of silent overwrite. Review on an iCloud-enabled signed
build; local/ad-hoc builds cannot demonstrate live CloudKit transfers.

Before submission, complete the Production schema and two-Mac checks in
[docs/ICLOUD.md](../docs/ICLOUD.md). Never claim these checks passed based only on
local unit tests. The screen does not promise automatic background merging.

Network behavior:

- Public wallet addresses and requests go directly to chain RPC/REST providers.
- Read-only exchange credentials go directly to the selected exchange.
- CoinGecko receives asset identifiers and fiat-rate requests; Settings retains attribution.
- Apple stores an encrypted portfolio asset in the user's private iCloud database.
  The local vault key is not uploaded; a separate cloud key uses iCloud Keychain.
- The retired Address Atlas sync server is not contacted by this build.

The app uses Apple cryptography, HTTPS, App Sandbox, Data Protection Keychain,
user-selected file access, and the specifically provisioned CloudKit container.
Store builds open their App Store product page for updates. Provider usage
permissions remain a separate release check; no paid subscription was added.
