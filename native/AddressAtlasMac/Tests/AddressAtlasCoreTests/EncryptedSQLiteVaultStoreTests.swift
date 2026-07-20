import CryptoKit
import Foundation
import SQLite3
import XCTest

@testable import AddressAtlasCore

final class EncryptedSQLiteVaultStoreTests: XCTestCase {
  func testStorePersistsEncryptedDocumentWithoutPlaintextWalletLeak() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let store = try EncryptedSQLiteVaultStore(
      path: tempDir.appending(path: "vault.sqlite"), vaultKey: vaultKey, crypto: crypto)
    let wallet = WalletRecord(
      label: "Wallet", address: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", chainKind: .evm)

    try store.save(VaultDocument(wallets: [wallet]))
    let loaded = try store.load()
    let raw = try XCTUnwrap(store.rawStoredEnvelopeBytes())
    let rawText = String(decoding: raw, as: UTF8.self)

    XCTAssertEqual(loaded.wallets.first?.address, wallet.address)
    XCTAssertFalse(rawText.contains(wallet.address))
    XCTAssertTrue(rawText.contains("ciphertext"))
  }

  func testOversizedSavePreservesReadableRowAndStoreBaseline() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let databaseURL = tempDir.appending(path: "vault.sqlite")
    let crypto = VaultCrypto(maximumEnvelopeBodyByteCount: 2_048)
    let vaultKey = try crypto.generateVaultKey()
    let store = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey, crypto: crypto)
    _ = try store.load()
    var baseline = VaultDocument(wallets: [
      WalletRecord(label: "Readable", address: "0x1", chainKind: .evm)
    ])
    baseline = try store.saveReturningPersistedDocument(baseline)
    let envelopeBeforeRejectedSave = try XCTUnwrap(store.rawStoredEnvelopeBytes())

    let oversized = VaultDocument(wallets: [
      WalletRecord(
        label: String(repeating: "x", count: 4_096),
        address: "0x2",
        chainKind: .evm
      )
    ])
    XCTAssertThrowsError(try store.save(oversized)) { error in
      XCTAssertNotNil(error as? VaultCryptoPlaintextTooLargeError)
    }
    XCTAssertEqual(try store.rawStoredEnvelopeBytes(), envelopeBeforeRejectedSave)

    let verifierAfterFailure = try EncryptedSQLiteVaultStore(
      path: databaseURL,
      vaultKey: vaultKey,
      crypto: crypto
    )
    XCTAssertEqual(try verifierAfterFailure.load().wallets.map(\.label), ["Readable"])

    // A normal follow-up save through the original store proves the failed
    // preflight did not advance or invalidate its compare-and-swap baseline.
    baseline.wallets[0].label = "Saved after rejection"
    try store.save(baseline)
    let finalVerifier = try EncryptedSQLiteVaultStore(
      path: databaseURL, vaultKey: vaultKey, crypto: crypto)
    XCTAssertEqual(try finalVerifier.load().wallets.map(\.label), ["Saved after rejection"])
  }

  func testSaveReturningPersistedDocumentReturnsTheExactPersistedTimestamp() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let databaseURL = tempDir.appending(path: "vault.sqlite")
    let vaultKey = try VaultCrypto().generateVaultKey()
    let store = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    let originalTimestamp = Date(timeIntervalSince1970: 0)

    let saved = try store.saveReturningPersistedDocument(
      VaultDocument(updatedAt: originalTimestamp)
    )
    let verifier = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    let loaded = try verifier.load()

    XCTAssertGreaterThan(saved.updatedAt, originalTimestamp)
    XCTAssertEqual(saved.updatedAt, loaded.updatedAt)

    // Keep the original public API source-compatible for callers that expect
    // a Void-returning persistence operation.
    let voidSave: (VaultDocument) throws -> Void = store.save
    try voidSave(saved)
  }

  func testStoreCreatesAndRepairsDatabaseAsOwnerOnly() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let databaseURL = tempDir.appending(path: "vault.sqlite")
    let store = try EncryptedSQLiteVaultStore(
      path: databaseURL,
      vaultKey: try VaultCrypto().generateVaultKey()
    )

    try store.initialize()
    var attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: databaseURL.path)
    try store.initialize()
    attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testSequentialWholeDocumentSavesAdvanceWithoutConflict() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let databaseURL = tempDir.appending(path: "vault.sqlite")
    let vaultKey = try VaultCrypto().generateVaultKey()
    let store = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    _ = try store.load()

    var document = VaultDocument(wallets: [
      WalletRecord(label: "First", address: "0x1", chainKind: .evm)
    ])
    try store.save(document)
    document.wallets.append(WalletRecord(label: "Second", address: "0x2", chainKind: .evm))
    try store.save(document)

    let verifier = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    XCTAssertEqual(try verifier.load().wallets.map(\.label), ["First", "Second"])
  }

  func testStaleStoreCannotOverwriteAnotherProcessChanges() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let databaseURL = tempDir.appending(path: "vault.sqlite")
    let vaultKey = try VaultCrypto().generateVaultKey()
    let firstProcess = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    let secondProcess = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    _ = try firstProcess.load()
    _ = try secondProcess.load()

    try firstProcess.save(
      VaultDocument(wallets: [
        WalletRecord(label: "First process", address: "0x1", chainKind: .evm)
      ]))
    XCTAssertThrowsError(
      try secondProcess.save(
        VaultDocument(wallets: [
          WalletRecord(label: "Second process", address: "0x2", chainKind: .evm)
        ]))
    ) { error in
      XCTAssertEqual(error as? EncryptedSQLiteVaultStoreError, .staleDocument)
    }

    let verifier = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    XCTAssertEqual(try verifier.load().wallets.map(\.label), ["First process"])
  }

  func testStoreCannotOverwriteExistingDocumentWithoutLoadingABaseline() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let databaseURL = tempDir.appending(path: "vault.sqlite")
    let vaultKey = try VaultCrypto().generateVaultKey()
    let seededStore = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    try seededStore.save(
      VaultDocument(wallets: [
        WalletRecord(label: "Existing", address: "0x1", chainKind: .evm)
      ]))

    let unbasedStore = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    XCTAssertThrowsError(
      try unbasedStore.save(
        VaultDocument(wallets: [
          WalletRecord(label: "Blind overwrite", address: "0x2", chainKind: .evm)
        ]))
    ) { error in
      XCTAssertEqual(error as? EncryptedSQLiteVaultStoreError, .staleDocument)
    }

    let verifier = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    XCTAssertEqual(try verifier.load().wallets.map(\.label), ["Existing"])
  }

  func testRevisionGuardRejectsLegacyWriterThatDoesNotIncrementRevision() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let databaseURL = tempDir.appending(path: "vault.sqlite")
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let currentProcess = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    try currentProcess.save(
      VaultDocument(wallets: [
        WalletRecord(label: "Current writer", address: "0x1", chainKind: .evm)
      ]))
    let localKey = try crypto.deriveKey(from: vaultKey, purpose: .localDatabase)
    let legacyEnvelope = try crypto.sealJSON(
      VaultDocument(wallets: [WalletRecord(label: "Legacy writer", address: "0x2", chainKind: .evm)]
      ),
      with: localKey,
      keyId: "local-db"
    )

    XCTAssertThrowsError(
      try overwriteVaultWithoutRevisionIncrement(
        at: databaseURL,
        envelopeBytes: JSONEncoder.addressAtlas.encode(legacyEnvelope)
      )
    )
    let verifier = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    XCTAssertEqual(try verifier.load().wallets.map(\.label), ["Current writer"])
  }

  func testBlobCasDetectsLegacyWriterIfRevisionGuardIsMissing() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let databaseURL = tempDir.appending(path: "vault.sqlite")
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let seededStore = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    try seededStore.save(
      VaultDocument(wallets: [
        WalletRecord(label: "Initial", address: "0x1", chainKind: .evm)
      ]))

    let currentProcess = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    let staleDocument = try currentProcess.load()
    try dropRevisionGuard(at: databaseURL)
    let localKey = try crypto.deriveKey(from: vaultKey, purpose: .localDatabase)
    let legacyEnvelope = try crypto.sealJSON(
      VaultDocument(wallets: [WalletRecord(label: "Legacy writer", address: "0x2", chainKind: .evm)]
      ),
      with: localKey,
      keyId: "local-db"
    )
    try overwriteVaultWithoutRevisionIncrement(
      at: databaseURL,
      envelopeBytes: JSONEncoder.addressAtlas.encode(legacyEnvelope)
    )

    XCTAssertThrowsError(try currentProcess.save(staleDocument)) { error in
      XCTAssertEqual(error as? EncryptedSQLiteVaultStoreError, .staleDocument)
    }
    let verifier = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    XCTAssertEqual(try verifier.load().wallets.map(\.label), ["Legacy writer"])
  }

  func testLegacyDatabaseMigratesRevisionWithoutLosingDocument() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let databaseURL = tempDir.appending(path: "vault.sqlite")
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let localKey = try crypto.deriveKey(from: vaultKey, purpose: .localDatabase)
    let legacyDocument = VaultDocument(wallets: [
      WalletRecord(label: "Legacy", address: "0x1", chainKind: .evm)
    ])
    let envelope = try crypto.sealJSON(legacyDocument, with: localKey, keyId: "local-db")
    try createLegacyVaultDatabase(
      at: databaseURL,
      envelopeBytes: JSONEncoder.addressAtlas.encode(envelope)
    )

    let migratedStore = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    var migrated = try migratedStore.load()
    XCTAssertEqual(migrated.wallets.map(\.label), ["Legacy"])
    migrated.wallets.append(WalletRecord(label: "After migration", address: "0x2", chainKind: .evm))
    try migratedStore.save(migrated)

    let verifier = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    XCTAssertEqual(try verifier.load().wallets.map(\.label), ["Legacy", "After migration"])
  }

  private func createLegacyVaultDatabase(at url: URL, envelopeBytes: Data) throws {
    var db: OpaquePointer?
    guard
      sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let db
    else {
      throw EncryptedSQLiteVaultStoreError.openFailed("Could not create legacy test database.")
    }
    defer { sqlite3_close(db) }
    let sql = """
      CREATE TABLE encrypted_vault_documents (
        id TEXT PRIMARY KEY NOT NULL,
        envelope_json BLOB NOT NULL,
        updated_at TEXT NOT NULL
      );
      INSERT INTO encrypted_vault_documents (id, envelope_json, updated_at)
      VALUES ('primary', X'\(envelopeBytes.hexString)', '2026-07-01T00:00:00Z');
      """
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw EncryptedSQLiteVaultStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
    }
  }

  private func overwriteVaultWithoutRevisionIncrement(at url: URL, envelopeBytes: Data) throws {
    try executeVaultSQL(
      at: url,
      sql: """
        UPDATE encrypted_vault_documents
        SET envelope_json = X'\(envelopeBytes.hexString)', updated_at = '2026-07-01T00:00:01Z'
        WHERE id = 'primary';
        """
    )
  }

  private func dropRevisionGuard(at url: URL) throws {
    try executeVaultSQL(
      at: url,
      sql: "DROP TRIGGER encrypted_vault_documents_revision_guard;"
    )
  }

  private func executeVaultSQL(at url: URL, sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let db
    else {
      throw EncryptedSQLiteVaultStoreError.openFailed("Could not open test database.")
    }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw EncryptedSQLiteVaultStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
    }
  }
}
