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

  func testPendingUploadJournalIsEncryptedRoundTripsAndFailsClosedWhenCorrupted() throws {
    let fixture = try makeJournalFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let pending = try makePendingUpload(document: fixture.document, vaultKey: fixture.vaultKey)

    try fixture.store.savePendingVaultUpload(pending)
    let loaded = try XCTUnwrap(fixture.store.loadPendingVaultUpload())
    let raw = try XCTUnwrap(fixture.store.rawStoredPendingVaultUploadEnvelopeBytes())
    let rawText = String(decoding: raw, as: UTF8.self)

    XCTAssertEqual(loaded.operationId, pending.operationId)
    XCTAssertEqual(loaded.snapshot.checksum, pending.snapshot.checksum)
    XCTAssertEqual(loaded.postCommitDocument.wallets.map(\.label), ["Journal secret label"])
    XCTAssertFalse(rawText.contains("Journal secret label"))
    XCTAssertFalse(rawText.contains("0x00000000000000000000000000000000000000aa"))
    XCTAssertFalse(rawText.contains("journal-session-secret"))
    XCTAssertFalse(rawText.contains(pending.accountId))

    var envelope = try JSONDecoder.addressAtlas.decode(EncryptedVaultEnvelope.self, from: raw)
    envelope.checksum = String(repeating: "0", count: 64)
    try overwritePendingUploadEnvelope(
      at: fixture.database,
      envelopeBytes: JSONEncoder.addressAtlas.encode(envelope)
    )
    XCTAssertThrowsError(try fixture.store.loadPendingVaultUpload())
  }

  func testPendingUploadGuardsBlockWritersLoadedBeforeAndAfterStaging() throws {
    let fixture = try makeJournalFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let loadedBeforeStaging = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    _ = try loadedBeforeStaging.load()
    let pending = try makePendingUpload(document: fixture.document, vaultKey: fixture.vaultKey)
    try fixture.store.savePendingVaultUpload(pending)
    let loadedAfterStaging = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    var afterDocument = try loadedAfterStaging.load()
    afterDocument.preferences.hideDust.toggle()
    var beforeDocument = fixture.document
    beforeDocument.preferences.autoRefresh.toggle()

    XCTAssertThrowsError(try fixture.store.save(beforeDocument))
    XCTAssertThrowsError(try loadedBeforeStaging.save(beforeDocument))
    XCTAssertThrowsError(try loadedAfterStaging.save(afterDocument))
    XCTAssertNotNil(try fixture.store.loadPendingVaultUpload())
  }

  func testPendingUploadStagingFailsIfPrimaryChangedAfterBaselineLoad() throws {
    let fixture = try makeJournalFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let stale = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    let staleDocument = try stale.load()
    var winner = fixture.document
    winner.preferences.hideDust.toggle()
    try fixture.store.save(winner)
    let pending = try makePendingUpload(document: staleDocument, vaultKey: fixture.vaultKey)

    XCTAssertThrowsError(try stale.savePendingVaultUpload(pending)) { error in
      XCTAssertEqual(error as? EncryptedSQLiteVaultStoreError, .staleDocument)
    }
    XCTAssertNil(try stale.loadPendingVaultUpload())
  }

  func testPendingUploadCompletionAtomicallyPersistsStoredCandidateAndFreshSession() throws {
    let fixture = try makeJournalFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let pending = try makePendingUpload(document: fixture.document, vaultKey: fixture.vaultKey)
    try fixture.store.savePendingVaultUpload(pending)
    let storedPending = try XCTUnwrap(fixture.store.loadPendingVaultUpload())

    let completed = try fixture.store.completePendingVaultUpload(
      storedPending,
      localSessionToken: "fresh-session-token"
    )

    XCTAssertEqual(completed.syncState.latestRemoteVersion, storedPending.snapshot.version)
    XCTAssertEqual(completed.syncState.lastChecksum, storedPending.snapshot.checksum)
    XCTAssertEqual(completed.syncState.sessionToken, "fresh-session-token")
    XCTAssertNil(try fixture.store.loadPendingVaultUpload())
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(try verifier.load(), completed)
  }

  func testPendingUploadCompletionCasFailureRollsBackIntentDeletion() throws {
    let fixture = try makeJournalFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let pending = try makePendingUpload(document: fixture.document, vaultKey: fixture.vaultKey)
    try fixture.store.savePendingVaultUpload(pending)
    let storedPending = try XCTUnwrap(fixture.store.loadPendingVaultUpload())

    // Simulate a mixed-version writer by removing only the pending-update gate.
    // The ordinary revision guard remains and requires the competing revision
    // advance, which completion must detect before consuming the intent.
    try executeVaultSQL(
      at: fixture.database,
      sql: "DROP TRIGGER encrypted_vault_documents_pending_update_guard;"
    )
    let crypto = VaultCrypto()
    let localKey = try crypto.deriveKey(from: fixture.vaultKey, purpose: .localDatabase)
    var competing = fixture.document
    competing.wallets[0].label = "Competing process"
    let competingEnvelope = try crypto.sealJSON(
      competing,
      with: localKey,
      keyId: "local-db"
    )
    try overwriteVaultAdvancingRevision(
      at: fixture.database,
      envelopeBytes: JSONEncoder.addressAtlas.encode(competingEnvelope)
    )

    XCTAssertThrowsError(try fixture.store.completePendingVaultUpload(storedPending)) { error in
      XCTAssertEqual(error as? EncryptedSQLiteVaultStoreError, .staleDocument)
    }
    XCTAssertEqual(
      try fixture.store.loadPendingVaultUpload()?.operationId,
      storedPending.operationId
    )
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(try verifier.load().wallets.map(\.label), ["Competing process"])
  }

  func testExplicitPendingUploadAbandonKeepsFullLocalDocument() throws {
    let fixture = try makeJournalFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let pending = try makePendingUpload(document: fixture.document, vaultKey: fixture.vaultKey)
    try fixture.store.savePendingVaultUpload(pending)
    let storedPending = try XCTUnwrap(fixture.store.loadPendingVaultUpload())

    let abandoned = try fixture.store.abandonPendingVaultUpload(storedPending)

    XCTAssertNil(try fixture.store.loadPendingVaultUpload())
    XCTAssertEqual(abandoned.wallets.map(\.label), ["Journal secret label"])
    XCTAssertTrue(abandoned.syncState.remoteOutcomeUncertain)
    XCTAssertNil(abandoned.syncState.lastSyncedContentChecksum)
    XCTAssertEqual(try fixture.store.load(), abandoned)
  }

  func testCancelBeforePutRemovesIntentWithoutMarkingRemoteOutcomeUncertain() throws {
    let fixture = try makeJournalFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let pending = try makePendingUpload(document: fixture.document, vaultKey: fixture.vaultKey)
    try fixture.store.savePendingVaultUpload(pending)
    let storedPending = try XCTUnwrap(fixture.store.loadPendingVaultUpload())

    try fixture.store.cancelPendingVaultUploadBeforeUpload(storedPending)

    XCTAssertNil(try fixture.store.loadPendingVaultUpload())
    XCTAssertFalse(try fixture.store.load().syncState.remoteOutcomeUncertain)
    var followUp = try fixture.store.load()
    followUp.preferences.hideDust.toggle()
    XCTAssertNoThrow(try fixture.store.save(followUp))
  }

  func testCoordinatorRejectsVersionGapCiphertextCandidateMismatchAndInvalidSession() async throws {
    let fixture = try makeJournalFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let coordinator = VaultPersistenceCoordinator(store: fixture.store)
    let codec = VaultSyncCodec()
    let accountId = try XCTUnwrap(fixture.document.syncState.accountId)

    var versionGap = try makePendingUpload(
      document: fixture.document,
      vaultKey: fixture.vaultKey
    )
    let versionTwo = try codec.seal(
      document: fixture.document,
      vaultKey: fixture.vaultKey,
      version: 2,
      accountId: accountId
    )
    versionGap.snapshot = versionTwo
    versionGap.postCommitDocument.syncState.markSynced(
      version: 2,
      snapshotChecksum: versionTwo.checksum,
      contentChecksum: try codec.contentChecksum(for: fixture.document)
    )
    do {
      try await coordinator.savePendingVaultUpload(versionGap, vaultKey: fixture.vaultKey)
      XCTFail("A nil predecessor must require snapshot version 1.")
    } catch {
      XCTAssertEqual(error as? PendingVaultUploadError, .invalidOperation)
    }

    var differentDocument = fixture.document
    differentDocument.wallets[0].label = "Different encrypted content"
    let mismatchedSnapshot = try codec.seal(
      document: differentDocument,
      vaultKey: fixture.vaultKey,
      version: 1,
      accountId: accountId
    )
    var mismatchedPair = try makePendingUpload(
      document: fixture.document,
      vaultKey: fixture.vaultKey
    )
    mismatchedPair.snapshot = mismatchedSnapshot
    mismatchedPair.postCommitDocument.syncState.markSynced(
      version: 1,
      snapshotChecksum: mismatchedSnapshot.checksum,
      contentChecksum: try codec.contentChecksum(for: fixture.document)
    )
    do {
      try await coordinator.savePendingVaultUpload(mismatchedPair, vaultKey: fixture.vaultKey)
      XCTFail("Ciphertext and post-commit content must describe the same vault.")
    } catch {
      XCTAssertEqual(error as? PendingVaultUploadError, .invalidOperation)
    }

    var invalidSession = try makePendingUpload(
      document: fixture.document,
      vaultKey: fixture.vaultKey
    )
    invalidSession.postCommitDocument.syncState.sessionToken = ""
    do {
      try await coordinator.savePendingVaultUpload(invalidSession, vaultKey: fixture.vaultKey)
      XCTFail("A pending candidate must retain a valid local session token.")
    } catch {
      XCTAssertEqual(error as? PendingVaultUploadError, .invalidOperation)
    }
    XCTAssertNil(try fixture.store.loadPendingVaultUpload())
  }

  private func makeJournalFixture() throws -> (
    directory: URL,
    database: URL,
    vaultKey: Data,
    store: EncryptedSQLiteVaultStore,
    document: VaultDocument
  ) {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = directory.appending(path: "vault.sqlite")
    let vaultKey = try VaultCrypto().generateVaultKey()
    let store = try EncryptedSQLiteVaultStore(path: database, vaultKey: vaultKey)
    _ = try store.load()
    var document = VaultDocument(wallets: [
      WalletRecord(
        label: "Journal secret label",
        address: "0x00000000000000000000000000000000000000aa",
        chainKind: .evm
      )
    ])
    XCTAssertTrue(
      document.syncState.connect(
        accountId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        serverURL: "https://sync.example",
        sessionToken: "journal-session-secret"
      )
    )
    document = try store.saveReturningPersistedDocument(document)
    return (directory, database, vaultKey, store, document)
  }

  private func makePendingUpload(
    document: VaultDocument,
    vaultKey: Data
  ) throws -> PendingVaultUpload {
    let codec = VaultSyncCodec()
    let accountId = try XCTUnwrap(document.syncState.accountId)
    let snapshot = try codec.seal(
      document: document,
      vaultKey: vaultKey,
      version: 1,
      accountId: accountId
    )
    var postCommit = document
    postCommit.syncState.markSynced(
      version: snapshot.version,
      snapshotChecksum: snapshot.checksum,
      contentChecksum: try codec.contentChecksum(for: document),
      at: Date(timeIntervalSince1970: 100)
    )
    return PendingVaultUpload(
      serverOrigin: "https://sync.example",
      accountId: accountId,
      expectedRemoteVersion: nil,
      expectedRemoteChecksum: nil,
      snapshot: snapshot,
      postCommitDocument: postCommit,
      baseLocalContentChecksum: try codec.contentChecksum(for: document),
      removedScanRunCount: 0,
      createdAt: Date(timeIntervalSince1970: 200)
    )
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

  private func overwriteVaultAdvancingRevision(at url: URL, envelopeBytes: Data) throws {
    try executeVaultSQL(
      at: url,
      sql: """
        UPDATE encrypted_vault_documents
        SET envelope_json = X'\(envelopeBytes.hexString)',
            updated_at = '2026-07-01T00:00:02Z',
            revision = revision + 1
        WHERE id = 'primary';
        """
    )
  }

  private func overwritePendingUploadEnvelope(at url: URL, envelopeBytes: Data) throws {
    try executeVaultSQL(
      at: url,
      sql: """
        UPDATE encrypted_pending_sync_operations
        SET envelope_json = X'\(envelopeBytes.hexString)'
        WHERE id = 'vault-upload';
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
