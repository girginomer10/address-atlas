import Darwin
import Foundation
import SQLite3
import XCTest

@testable import AddressAtlasCore

final class DamagedVaultRecoveryTests: XCTestCase {
  func testValidatedRollbackAtomicallyReplacesCorruptPrimaryAndIsConsumed() throws {
    let fixture = try makeStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let syncState = SyncState(
      accountId: "11111111-1111-4111-8111-111111111111",
      serverURL: "https://sync.addressatlas.app"
    )
    let rollback = try fixture.store.saveReturningPersistedDocument(
      VaultDocument(wallets: [
        WalletRecord(
          label: "Validated rollback",
          address: "0x0000000000000000000000000000000000000001",
          chainKind: .evm
        )
      ], syncState: syncState)
    )
    _ = try fixture.store.saveRollbackCheckpoint(rollback)
    _ = try fixture.store.saveReturningPersistedDocument(
      VaultDocument(wallets: [
        WalletRecord(
          label: "Damaged primary",
          address: "0x0000000000000000000000000000000000000002",
          chainKind: .evm
        )
      ], syncState: syncState)
    )
    try corruptPrimaryEnvelope(at: fixture.database)
    try insertCorruptPendingUpload(at: fixture.database)

    let recoveryStore = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertTrue(try recoveryStore.canRecoverDamagedPrimaryFromRollbackCheckpoint())

    let restored = try recoveryStore.recoverDamagedPrimaryFromRollbackCheckpoint()

    XCTAssertEqual(restored.wallets.map(\.label), ["Validated rollback"])
    XCTAssertTrue(restored.syncState.remoteOutcomeUncertain)
    XCTAssertNil(restored.syncState.lastSyncedContentChecksum)
    XCTAssertNil(try recoveryStore.rawStoredPendingVaultUploadEnvelopeBytes())
    XCTAssertFalse(try recoveryStore.containsRollbackCheckpoint())
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(try verifier.load().wallets.map(\.label), ["Validated rollback"])
  }

  func testReadablePrimaryCanNeverBeOverwrittenByDamageRecovery() throws {
    let fixture = try makeStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let primary = try fixture.store.saveReturningPersistedDocument(
      VaultDocument(wallets: [
        WalletRecord(
          label: "Readable",
          address: "0x0000000000000000000000000000000000000001",
          chainKind: .evm
        )
      ])
    )
    _ = try fixture.store.saveRollbackCheckpoint(primary)

    XCTAssertFalse(try fixture.store.canRecoverDamagedPrimaryFromRollbackCheckpoint())
    XCTAssertThrowsError(try fixture.store.recoverDamagedPrimaryFromRollbackCheckpoint()) {
      XCTAssertEqual(
        $0 as? EncryptedSQLiteVaultStoreError,
        .primaryDocumentIsReadable
      )
    }
    XCTAssertTrue(try fixture.store.containsRollbackCheckpoint())
    XCTAssertEqual(try fixture.store.load().wallets.map(\.label), ["Readable"])
  }

  func testInvalidRollbackIsNeverOfferedForCorruptPrimary() throws {
    let fixture = try makeStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let primary = try fixture.store.saveReturningPersistedDocument(
      VaultDocument(wallets: [
        WalletRecord(
          label: "Before",
          address: "0x0000000000000000000000000000000000000001",
          chainKind: .evm
        )
      ])
    )
    _ = try fixture.store.saveRollbackCheckpoint(primary)
    try corruptPrimaryEnvelope(at: fixture.database)
    try corruptRollbackEnvelope(at: fixture.database)
    let recoveryStore = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )

    XCTAssertFalse(try recoveryStore.canRecoverDamagedPrimaryFromRollbackCheckpoint())
    XCTAssertThrowsError(try recoveryStore.recoverDamagedPrimaryFromRollbackCheckpoint())
  }

  func testQuarantinePreservesDatabaseAndSidecarsThenActivatesCleanVaultWithSameKey() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appending(path: "vault.sqlite")
    let originals: [String: Data] = [
      "vault.sqlite": Data("damaged database".utf8),
      "vault.sqlite-wal": Data("damaged wal".utf8),
      "vault.sqlite-shm": Data("damaged shm".utf8),
    ]
    try writeSourceGroup(originals, in: directory)
    let key = try VaultCrypto().generateVaultKey()

    let recovered = try DamagedVaultRecoveryService().quarantineAndCreateCleanVault(
      at: database,
      vaultKey: key
    )

    XCTAssertTrue(recovered.document.wallets.isEmpty)
    XCTAssertEqual(try recovered.store.load().wallets, [])
    for (name, bytes) in originals {
      XCTAssertEqual(
        try Data(contentsOf: recovered.quarantineDirectory.appending(path: name)),
        bytes
      )
      let attributes = try FileManager.default.attributesOfItem(
        atPath: recovered.quarantineDirectory.appending(path: name).path
      )
      XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    let quarantineAttributes = try FileManager.default.attributesOfItem(
      atPath: recovered.quarantineDirectory.path
    )
    XCTAssertEqual((quarantineAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + "-wal"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + "-shm"))
    let verifier = try EncryptedSQLiteVaultStore(path: database, vaultKey: key)
    XCTAssertTrue(try verifier.load().wallets.isEmpty)
  }

  func testQuarantineFailsClosedWhileAnotherStoreRetainsVaultAccessLease() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appending(path: "vault.sqlite")
    let key = try VaultCrypto().generateVaultKey()
    var activeStore: EncryptedSQLiteVaultStore? = try EncryptedSQLiteVaultStore(
      path: database,
      vaultKey: key
    )
    _ = try activeStore?.load()
    try corruptPrimaryEnvelope(at: database)
    let damagedBytes = try Data(contentsOf: database)

    XCTAssertThrowsError(
      try DamagedVaultRecoveryService().quarantineAndCreateCleanVault(
        at: database,
        vaultKey: key
      )
    ) { error in
      XCTAssertEqual(error as? DamagedVaultRecoveryError, .vaultInUse)
    }
    XCTAssertEqual(try Data(contentsOf: database), damagedBytes)
    XCTAssertTrue(
      try visibleNames(in: directory).allSatisfy { !$0.hasPrefix("vault-quarantine-") }
    )

    activeStore = nil
    let recovered = try DamagedVaultRecoveryService().quarantineAndCreateCleanVault(
      at: database,
      vaultKey: key
    )
    XCTAssertTrue(recovered.document.wallets.isEmpty)
  }

  func testQuarantineCopyFailureLeavesEveryOriginalByteAndNameUntouched() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appending(path: "vault.sqlite")
    let originals: [String: Data] = [
      "vault.sqlite": Data("damaged database".utf8),
      "vault.sqlite-wal": Data("damaged wal".utf8),
      "vault.sqlite-shm": Data("damaged shm".utf8),
    ]
    try writeSourceGroup(originals, in: directory)
    let originalNames = try visibleNames(in: directory)
    var operations = AtomicFilePublicationOperations.production
    operations.write = { _, _, _ in 0 }

    XCTAssertThrowsError(
      try DamagedVaultRecoveryService(operations: operations)
        .quarantineAndCreateCleanVault(
          at: database,
          vaultKey: VaultCrypto().generateVaultKey()
        )
    ) { error in
      XCTAssertEqual(error as? DamagedVaultRecoveryError, .quarantineCopyFailed)
    }
    XCTAssertEqual(try visibleNames(in: directory), originalNames)
    for (name, bytes) in originals {
      XCTAssertEqual(try Data(contentsOf: directory.appending(path: name)), bytes)
    }
  }

  func testQuarantineRejectsSymlinkedSidecarWithoutTouchingAnySource() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appending(path: "vault.sqlite")
    let databaseBytes = Data("damaged database".utf8)
    try databaseBytes.write(to: database)
    try setOwnerOnly(database)
    let external = directory.appending(path: "external")
    let externalBytes = Data("external must remain".utf8)
    try externalBytes.write(to: external)
    let wal = directory.appending(path: "vault.sqlite-wal")
    try FileManager.default.createSymbolicLink(at: wal, withDestinationURL: external)

    XCTAssertThrowsError(
      try DamagedVaultRecoveryService().quarantineAndCreateCleanVault(
        at: database,
        vaultKey: VaultCrypto().generateVaultKey()
      )
    ) { error in
      XCTAssertEqual(error as? DamagedVaultRecoveryError, .unsafeVaultPath)
    }
    XCTAssertEqual(try Data(contentsOf: database), databaseBytes)
    XCTAssertEqual(try Data(contentsOf: external), externalBytes)
    XCTAssertTrue(try wal.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
  }

  private func makeStoreFixture() throws -> (
    directory: URL,
    database: URL,
    vaultKey: Data,
    store: EncryptedSQLiteVaultStore
  ) {
    let directory = try makeDirectory()
    let database = directory.appending(path: "vault.sqlite")
    let key = try VaultCrypto().generateVaultKey()
    let store = try EncryptedSQLiteVaultStore(path: database, vaultKey: key)
    _ = try store.load()
    return (directory, database, key, store)
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "DamagedVaultRecoveryTests-" + UUID().uuidString
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    return directory
  }

  private func writeSourceGroup(_ files: [String: Data], in directory: URL) throws {
    for (name, bytes) in files {
      let url = directory.appending(path: name)
      try bytes.write(to: url)
      try setOwnerOnly(url)
    }
  }

  private func setOwnerOnly(_ url: URL) throws {
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o600))],
      ofItemAtPath: url.path
    )
  }

  private func visibleNames(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    ).map(\.lastPathComponent)
      .filter { !$0.hasSuffix(".address-atlas.lock") }
      .sorted()
  }

  private func corruptPrimaryEnvelope(at database: URL) throws {
    try execute(
      "UPDATE encrypted_vault_documents SET envelope_json = x'7b7d', revision = revision + 1 WHERE id = 'primary';",
      at: database
    )
  }

  private func corruptRollbackEnvelope(at database: URL) throws {
    try execute(
      "UPDATE encrypted_vault_checkpoints SET envelope_json = x'7b7d' WHERE id = 'pre-destructive-sync';",
      at: database
    )
  }

  private func insertCorruptPendingUpload(at database: URL) throws {
    try execute(
      "INSERT INTO encrypted_pending_sync_operations (id, envelope_json, updated_at) VALUES ('vault-upload', x'00', '2026-07-21T00:00:00Z');",
      at: database
    )
  }

  private func execute(_ sql: String, at database: URL) throws {
    var connection: OpaquePointer?
    guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let connection
    else {
      throw EncryptedSQLiteVaultStoreError.openFailed("test")
    }
    defer { sqlite3_close(connection) }
    guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
      throw EncryptedSQLiteVaultStoreError.stepFailed(String(cString: sqlite3_errmsg(connection)))
    }
  }
}
