# iCloud portfolio copies

The current macOS product, and the iOS app that shares its code, replace the
server URL, passkey account, and hosted PostgreSQL backup workflow with explicit **Save to iCloud**, **Restore from iCloud**,
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
matching provisioning, and signed two-device transfer remain unverified.

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
   Keychain. Save a fictional wallet and test-only exchange credentials on
   device A; restore on device B (a second Mac, or an iPhone or iPad once a
   signed iOS build exists) and verify both balances and credential decryption.
   Kraken keys remain bound to the device that created them; reconnect using a
   different key on device B.
6. Edit on both devices. After A saves, B's stale save must fail without overwriting A.
   Restore must require confirmation and preserve a local rollback copy. Test
   rollback, offline operation, full quota, disabled Keychain, missing cloud key,
   Apple Account switch, delete, and save after explicit connection reset.

Unsigned/ad-hoc and direct builds without CloudKit entitlements stay local and
show a clear unavailable message on explicit cloud actions. They must not
initialize CKContainer. Passing local tests does not prove signed CloudKit or
iCloud Keychain operation; record the real two-device test before release.

## iOS

The iOS app (`native/AddressAtlasiOS`) compiles the same `ICloudVaultService`
as the Mac app and targets the same container, `iCloud.com.addressatlas.mac`,
so a copy saved from a Mac is the record an iPhone or iPad would restore. Its
entitlements request CloudKit, that container, and the keychain-access-groups
`$(AppIdentifierPrefix)com.addressatlas.mac` (listed first, so it is also the
iOS app's default group) and `$(AppIdentifierPrefix)com.addressatlas.ios`. The
Mac group is required: the Mac app writes the synchronizable cloud-key item in
its default group, and iOS can only read that item through iCloud Keychain
when it shares the group.

None of this is provisioned yet. Before a signed iOS build can reach iCloud:

1. Register the explicit App ID `com.addressatlas.ios` under team
   `VWW3GZL279` with iCloud (CloudKit) and Keychain Sharing enabled, and assign
   the existing `iCloud.com.addressatlas.mac` container to it. Both App IDs
   must stay in the same team so `$(AppIdentifierPrefix)` matches.
2. Create an iOS distribution provisioning profile for that App ID. Xcode
   automatic signing uses the same team.
3. The iOS entitlements pin `com.apple.developer.icloud-container-environment`
   to **Production**, matching the Mac App Store build, so a signed Debug
   device build reads the same database as a Mac. Xcode would otherwise
   default local builds to the separate **Development** environment, where
   a Mac-saved copy is never visible. On a device the fail-closed check reads
   the embedded provisioning profile's entitlements, so the profile must grant
   exactly this container.
4. On a physical iPhone or iPad signed in to the same Apple Account as a
   signed Mac build, with iCloud Passwords & Keychain enabled on both: save on
   the Mac, restore on the iPhone, and verify balances and credential
   decryption. This Mac→iPhone restore is a release gate and has not been
   performed.
5. The iOS Simulator cannot sync iCloud Keychain, so it can never receive the
   cloud key. Simulator and unsigned builds show the unavailable message and
   must not initialize `CKContainer`; the iOS build reads its entitlements
   from the executable's `__TEXT,__entitlements` section or the embedded
   provisioning profile and fails closed when neither grants the container.
6. Kraken connections remain bound to the device that created them. A restored
   copy on an iPhone or iPad needs a separate read-only Kraken key for that
   device.

## Data and conflict model

One `primary-vault-v1` record lives in the user's **private** CloudKit database.
Only ciphertext is written as a temporary CKAsset (private directory, removed
after the operation). The local vault key never leaves the device. Exchange
credentials are rewrapped under a separate cloud key before encrypting the entire
document; a restoring device rewraps them under its own local key. Old server
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
