# iCloud portfolio copies

The current macOS product replaces the server URL, passkey account, and hosted
PostgreSQL backup workflow with explicit **Save to iCloud**, **Restore from iCloud**,
and **Delete iCloud copy** actions. This is whole-vault transfer, not automatic
record merging or a versioned backup history. Local scanning does not need iCloud.

## Apple setup and release evidence

Apple portal checkpoint (September 7, 2026): team `VWW3GZL279` now has the
explicit `com.addressatlas.mac` App ID with CloudKit enabled and one assigned
container, `iCloud.com.addressatlas.mac`. `EncryptedVault` with the three fields
below was created and the console confirmed **Changes Deployed** to Production.
For this type, `_world` has no access, `_icloud` has create only, and `_creator`
has read/write. The app still uses the private database; these schema role
settings do not replace private-database isolation. Distribution signing,
matching provisioning, and signed two-Mac transfer remain unverified.

1. Enable CloudKit for App ID `com.addressatlas.mac` in the existing developer team.
2. Register and associate `iCloud.com.addressatlas.mac` with that App ID.
3. In CloudKit Console, create `EncryptedVault` in the development schema, with
   `payload` (Asset), `keyID` (String), and `revision` (String). Use the normal
   creator-only permissions; do not grant public read/write access. Deploy this
   schema to Production before submitting the app.
4. Regenerate the Mac App Store distribution profile with that container,
   `CloudKit` service, and `Production` environment. The package scripts verify
   these grants before signing and validate them again on the actual signed app.
5. On two signed builds using the same Apple Account, enable iCloud Passwords &
   Keychain. Save a fictional wallet and test-only exchange credentials on Mac A;
   restore on Mac B and verify both balances and credential decryption. Kraken
   keys remain installation-bound; reconnect using a different key on Mac B.
6. Edit on both Macs. After A saves, B's stale save must fail without overwriting A.
   Restore must require confirmation and preserve a local rollback copy. Test
   rollback, offline operation, full quota, disabled Keychain, missing cloud key,
   Apple Account switch, delete, and save after explicit connection reset.

Unsigned/ad-hoc and direct builds without CloudKit entitlements stay local and
show a clear unavailable message on explicit cloud actions. They must not
initialize CKContainer. Passing local tests does not prove signed CloudKit or
iCloud Keychain operation; record the real two-Mac test before release.

## Data and conflict model

One `primary-vault-v1` record lives in the user's **private** CloudKit database.
Only ciphertext is written as a temporary CKAsset (private directory, removed
after the operation). The local vault key never leaves the Mac. Exchange
credentials are rewrapped under a separate cloud key before encrypting the entire
document; a restoring Mac rewraps them under its own local key. Old server
sessions and connection metadata are omitted from the payload.

The cloud key is a random 256-bit synchronizable Keychain item scoped to the
hashed CloudKit user identity and an immutable key UUID. Missing keys for existing
records cause an error, never replacement keys. Account identity and snapshot
revision are authenticated by AES-GCM. CloudKit's change-tag conditional write
and the locally persisted revision prevent stale overwrite. An ambiguous upload
or failure saving its local receipt can require restore before the next save.

CloudKit and iCloud Keychain are separate services: a cloud record can arrive
before its key. A recovery kit for the local vault does not recover the separate
iCloud key. Keep a local vault/recovery kit; the operator cannot recover cloud
keys. Deleting the iCloud copy preserves local vaults and small Keychain items.

## Retired server

The app makes no automatic requests to the old sync/config service. It clears
old session bindings during ordinary unlock. An interrupted upload journal is
preserved until the user explicitly finishes local migration; no old upload is
replayed in production. Legacy server source remains for migration regression
tests and does not need deployment. Previously deployed data/backups are not
deleted by a client update: inspect the actual deployment and retention before
separately retiring infrastructure. This change neither provisions a server nor
purchases any API plan.
