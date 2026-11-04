# App Review Notes — Address Atlas 0.2.0

Address Atlas is read-only portfolio software. It does not create or custody wallets, ask for seed phrases or private keys, sign transactions, trade, mine, issue crypto rewards, or give personal investment advice.

## How to try it

No account, sign-in, or demo credential is needed. Unlock the app on first launch, add a public address (for example the Bitcoin address `1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa`), run a scan, look at Assets and Snapshots, and try an export. Do not use production exchange API keys in review.

## iCloud

The **iCloud** screen has three optional, manual actions: Save to iCloud, Restore from iCloud, and Delete iCloud copy. It uses the reviewer's system Apple Account, the CloudKit private database, and iCloud Passwords & Keychain. There is no separate Address Atlas registration or hosted server.

- Restore asks for confirmation and keeps a local backup copy.
- If the cloud copy changed elsewhere, the app shows a conflict message and does not overwrite it.
- Nothing merges in the background.
- Live CloudKit transfers work only on an iCloud-enabled signed build. Local and ad-hoc builds cannot show them.

Before submission (internal): complete the Production schema and two-Mac checks in [docs/ICLOUD.md](../docs/ICLOUD.md). Do not say they passed based on local unit tests alone.

## Network behavior

- Public wallet addresses and requests go directly to chain RPC and REST providers.
- Read-only exchange API keys go directly to the selected exchange.
- CoinGecko receives asset identifiers and fiat-rate requests. Settings keeps the attribution.
- Apple stores an encrypted copy of the portfolio in the user's private iCloud database. The local portfolio key is not uploaded. A separate cloud key travels through iCloud Keychain.
- The retired Address Atlas sync server is not contacted by this build.

The app uses Apple cryptography, HTTPS, App Sandbox, Data Protection Keychain, user-selected file access, and the provisioned CloudKit container. Store builds open their App Store product page for updates. Provider usage permissions are a separate release check. No paid subscription was added.

## iOS

The iOS app (`com.addressatlas.ios`) uses App Store Connect record `6819783390` (`Address Atlas iOS`). These notes are a submission draft. They are not evidence that the app was submitted to or approved by App Review. The app shares the Mac app's state layer and has the same read-only boundary: it does not create or custody wallets, ask for seed phrases or private keys, sign transactions, trade, mine, issue crypto rewards, or give personal investment advice.

- The portfolio key is a this-device-only iOS Keychain item. It never leaves the device or enters a backup. To move to a new device, use the recovery kit (exported and restored through Files) or an iCloud copy.
- The iCloud copy is optional and manual, and uses the same private CloudKit container as the Mac app. Restore asks for confirmation. Conflicts are reported, not merged silently.
- Simulator and unsigned builds show an iCloud unavailable message and make no CloudKit request. Live transfers can be reviewed only on a signed, provisioned build on a physical device with iCloud Passwords & Keychain turned on. The [release checkpoint](README.md#release-checkpoint--october-6-2026) has the artifact and distribution evidence. A physical-device iCloud transfer is not verified.
- Kraken connections are bound to the device that created them. A restored copy needs a separate read-only Kraken key on the iPhone or iPad.
- Scans and iCloud transfers run in the foreground only. Exports use the system share sheet.
