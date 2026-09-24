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

## iOS

The iOS app (`com.addressatlas.ios`) has no App Store Connect record yet; these
notes apply once one exists. It compiles the Mac app's shared state layer and
keeps the same read-only boundary: it does not create or custody wallets,
request seed phrases or private keys, sign transactions, trade, mine, issue
crypto rewards, or provide personalized investment advice.

- The vault key is a this-device-only iOS Keychain item that never leaves the
  device or enters a backup. A reviewer moving to a new device needs the
  recovery kit (exported and restored through Files) or an iCloud copy.
- The iCloud copy is optional and manual, using the same private CloudKit
  container as the Mac app. Restore requires confirmation and conflicts are
  reported, not merged silently.
- Simulator and unsigned builds show a clear iCloud unavailable message and make
  no CloudKit request. Live transfers can only be reviewed on a signed,
  provisioned build on a physical device with iCloud Passwords & Keychain
  enabled; that build has not been produced yet.
- Kraken connections are bound to the device that created them; a restored copy
  needs a separate read-only Kraken key on the iPhone or iPad.
- Scans and iCloud transfers run in the foreground only. Exports use the system
  share sheet.
