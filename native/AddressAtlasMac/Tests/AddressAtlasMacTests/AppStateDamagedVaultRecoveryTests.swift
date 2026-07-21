import AddressAtlasCore
import Foundation
import SQLite3
import XCTest

@testable import AddressAtlasMac

@MainActor
final class AppStateDamagedVaultRecoveryTests: XCTestCase {
  func testUnlockOffersValidatedRollbackAndRestoresItOnlyAfterExplicitAction() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.key
    )
    _ = try store.load()
    let rollback = try store.saveReturningPersistedDocument(
      VaultDocument(wallets: [
        WalletRecord(
          label: "Safe rollback",
          address: "0x0000000000000000000000000000000000000001",
          chainKind: .evm
        )
      ])
    )
    _ = try store.saveRollbackCheckpoint(rollback)
    _ = try store.saveReturningPersistedDocument(
      VaultDocument(wallets: [
        WalletRecord(
          label: "Broken primary",
          address: "0x0000000000000000000000000000000000000002",
          chainKind: .evm
        )
      ])
    )
    try corruptPrimaryEnvelope(at: fixture.database)
    let damagedBytes = try Data(contentsOf: fixture.database)
    let state = AppState(
      keyStore: fixture.keyStore,
      appSupportDirectoryOverride: fixture.support
    )

    await state.unlock()

    XCTAssertFalse(state.isUnlocked)
    XCTAssertEqual(
      state.damagedVaultRecoveryAvailability,
      .validatedRollbackCheckpoint
    )
    XCTAssertTrue(state.error.contains("Nothing has been reset"))
    XCTAssertEqual(try Data(contentsOf: fixture.database), damagedBytes)

    await state.recoverDamagedVaultFromRollbackCheckpoint()

    XCTAssertTrue(state.isUnlocked)
    XCTAssertNil(state.damagedVaultRecoveryAvailability)
    XCTAssertEqual(state.document.wallets.map(\.label), ["Safe rollback"])
    XCTAssertEqual(try fixture.keyStore.loadVaultKey(), fixture.key)
    XCTAssertFalse(try store.containsRollbackCheckpoint())
  }

  func testUnlockRequiresExplicitQuarantineThenStartsCleanWithSameKeyAndTruthfulCopy() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var store: EncryptedSQLiteVaultStore? = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.key
    )
    _ = try store?.load()
    _ = try store?.saveReturningPersistedDocument(
      VaultDocument(wallets: [
        WalletRecord(
          label: "Only damaged copy",
          address: "0x0000000000000000000000000000000000000001",
          chainKind: .evm
        )
      ])
    )
    try corruptPrimaryEnvelope(at: fixture.database)
    let damagedBytes = try Data(contentsOf: fixture.database)
    // A real second app process must close its store before inode-replacing
    // recovery is allowed to acquire the exclusive vault lease.
    store = nil
    let state = AppState(
      keyStore: fixture.keyStore,
      appSupportDirectoryOverride: fixture.support
    )

    await state.unlock()

    XCTAssertFalse(state.isUnlocked)
    XCTAssertEqual(state.damagedVaultRecoveryAvailability, .quarantineOnly)
    XCTAssertEqual(try Data(contentsOf: fixture.database), damagedBytes)
    XCTAssertTrue(try quarantineDirectories(in: fixture.support).isEmpty)

    await state.quarantineDamagedVaultAndStartClean()

    XCTAssertTrue(state.isUnlocked)
    XCTAssertNil(state.damagedVaultRecoveryAvailability)
    XCTAssertTrue(state.document.wallets.isEmpty)
    XCTAssertEqual(try fixture.keyStore.loadVaultKey(), fixture.key)
    XCTAssertTrue(state.notice.contains("no remote data was downloaded"))
    XCTAssertTrue(state.notice.contains("Open Sync, sign in"))
    let quarantine = try XCTUnwrap(quarantineDirectories(in: fixture.support).first)
    XCTAssertEqual(
      try Data(contentsOf: quarantine.appending(path: "vault.sqlite")),
      damagedBytes
    )
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.key
    )
    XCTAssertTrue(try verifier.load().wallets.isEmpty)
  }

  func testUnsafeSymlinkVaultNeverOffersDestructiveRecovery() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let target = fixture.root.appending(path: "external.sqlite")
    let targetBytes = Data("external".utf8)
    try targetBytes.write(to: target)
    try FileManager.default.createSymbolicLink(
      at: fixture.database,
      withDestinationURL: target
    )
    let state = AppState(
      keyStore: fixture.keyStore,
      appSupportDirectoryOverride: fixture.support
    )

    await state.unlock()

    XCTAssertFalse(state.isUnlocked)
    XCTAssertNil(state.damagedVaultRecoveryAvailability)
    XCTAssertEqual(try Data(contentsOf: target), targetBytes)
  }

  private func makeFixture() throws -> (
    root: URL,
    support: URL,
    database: URL,
    key: Data,
    keyStore: AppStateTestVaultKeyStore
  ) {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "AppStateDamagedVaultRecoveryTests-" + UUID().uuidString
    )
    let support = root.appending(path: "Application Support")
    try FileManager.default.createDirectory(
      at: support,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let database = support.appending(path: "vault.sqlite")
    let key = try VaultCrypto().generateVaultKey()
    return (root, support, database, key, AppStateTestVaultKeyStore(key: key))
  }

  private func quarantineDirectories(in support: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: support,
      includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("vault-quarantine-") }
  }

  private func corruptPrimaryEnvelope(at database: URL) throws {
    var connection: OpaquePointer?
    guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let connection
    else {
      throw EncryptedSQLiteVaultStoreError.openFailed("test")
    }
    defer { sqlite3_close(connection) }
    guard
      sqlite3_exec(
        connection,
        "UPDATE encrypted_vault_documents SET envelope_json = x'7b7d', revision = revision + 1 WHERE id = 'primary';",
        nil,
        nil,
        nil
      ) == SQLITE_OK
    else {
      throw EncryptedSQLiteVaultStoreError.stepFailed(String(cString: sqlite3_errmsg(connection)))
    }
  }
}
