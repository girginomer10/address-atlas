import AddressAtlasCore
import Foundation
import SQLite3
import XCTest

@testable import AddressAtlasMac

@MainActor
extension AppStateNetworkBoundaryTests {
  func testCorruptPendingJournalKeepsPrimaryReadOnlyUntilExactExplicitDiscard() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let persisted = try connectedUploadDocument(
      store: fixture.store,
      accountId: "91919191-9191-4191-8191-919191919191",
      label: "Primary survives quarantine",
      sessionToken: "quarantine-session"
    )
    let codec = VaultSyncCodec()
    let accountID = try XCTUnwrap(persisted.syncState.accountId)
    let snapshot = try codec.seal(
      document: persisted,
      vaultKey: fixture.vaultKey,
      version: 1,
      accountId: accountID
    )
    var postCommit = persisted
    postCommit.syncState.markSynced(
      version: 1,
      snapshotChecksum: snapshot.checksum,
      contentChecksum: try codec.contentChecksum(for: persisted)
    )
    try fixture.store.savePendingVaultUpload(
      PendingVaultUpload(
        serverOrigin: "https://sync.example",
        accountId: accountID,
        expectedRemoteVersion: nil,
        expectedRemoteChecksum: nil,
        snapshot: snapshot,
        postCommitDocument: postCommit,
        baseLocalContentChecksum: try codec.contentChecksum(for: persisted),
        removedScanRunCount: 0
      ))
    let network = RecordingHTTPStub { request in
      XCTFail("Quarantine unlock must not auto-replay: \(request.url?.absoluteString ?? "nil")")
      return (Data("{}".utf8), stubHTTPResponse(request))
    }
    let alreadyUnlocked = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
      ),
      httpClient: network
    )
    XCTAssertNotNil(alreadyUnlocked.pendingVaultUpload)
    let originalCorruption = Data("{}".utf8)
    try overwritePendingUploadEnvelope(at: fixture.database, with: originalCorruption)

    await alreadyUnlocked.retryPendingSyncPersistence()

    XCTAssertNil(alreadyUnlocked.pendingVaultUpload)
    XCTAssertNotNil(alreadyUnlocked.quarantinedPendingVaultUpload)
    XCTAssertTrue(alreadyUnlocked.syncPersistencePending)
    XCTAssertTrue(network.requests.isEmpty)

    let state = AppState(
      httpClient: network,
      keyStore: AppStateTestVaultKeyStore(key: fixture.vaultKey),
      appSupportDirectoryOverride: fixture.directory
    )
    await state.unlock()

    XCTAssertTrue(state.isUnlocked)
    XCTAssertEqual(state.document.wallets.map(\.label), ["Primary survives quarantine"])
    XCTAssertNotNil(state.quarantinedPendingVaultUpload)
    XCTAssertTrue(state.syncPersistencePending)
    XCTAssertTrue(state.persistentOperationGuidance?.contains("read-only") == true)
    XCTAssertTrue(network.requests.isEmpty)
    let quarantinedStore = try XCTUnwrap(state.persistence)
    guard case .quarantined = try await quarantinedStore.inspectPendingVaultUpload(
      vaultKey: fixture.vaultKey)
    else {
      return XCTFail("Unlock must leave the corrupt journal in place")
    }
    let mutationWhileQuarantined = await state.addWallet(
      address: "0x0000000000000000000000000000000000000092")
    XCTAssertFalse(mutationWhileQuarantined)
    let recoveryURL = fixture.directory.appending(path: "quarantine.atlas-recovery")
    XCTAssertFalse(try state.exportRecoveryKit(to: recoveryURL).isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryURL.path))
    XCTAssertTrue(state.beginTerminationRequest())
    let terminationAllowed = await state.prepareForTermination()
    XCTAssertTrue(terminationAllowed)
    state.setTerminationInProgress(false)

    // A replacement row must defeat the destructive CAS without touching the
    // primary document or silently updating the user's confirmation target.
    let replacementCorruption = Data("[]".utf8)
    try overwritePendingUploadEnvelope(at: fixture.database, with: replacementCorruption)
    await state.discardQuarantinedPendingVaultUpload()
    XCTAssertNotNil(state.quarantinedPendingVaultUpload)
    XCTAssertTrue(state.syncPersistencePending)
    XCTAssertEqual(state.document.wallets.map(\.label), ["Primary survives quarantine"])
    let staleVerifier = try EncryptedSQLiteVaultStore(
      path: fixture.database, vaultKey: fixture.vaultKey)
    _ = try staleVerifier.load()
    XCTAssertEqual(
      try staleVerifier.rawStoredPendingVaultUploadEnvelopeBytes(),
      replacementCorruption
    )

    // Restore the exact row the confirmation named, then exercise the explicit
    // discard path. The full primary remains and only remote certainty changes.
    try overwritePendingUploadEnvelope(at: fixture.database, with: originalCorruption)

    await state.discardQuarantinedPendingVaultUpload()

    XCTAssertNil(state.quarantinedPendingVaultUpload)
    XCTAssertFalse(state.syncPersistencePending)
    XCTAssertEqual(state.document.wallets.map(\.label), ["Primary survives quarantine"])
    XCTAssertTrue(state.document.syncState.remoteOutcomeUncertain)
    XCTAssertNil(try staleVerifier.rawStoredPendingVaultUploadEnvelopeBytes())
    let mutationAfterDiscard = await state.addWallet(
      address: "0x0000000000000000000000000000000000000092")
    XCTAssertTrue(mutationAfterDiscard)
  }

  func testCommittedUploadWithLostResponseRecoversAfterRelaunchWithoutSecondPut() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let persisted = try connectedUploadDocument(
      store: fixture.store,
      accountId: "10101010-1010-4010-8010-101010101010",
      label: "Timeout commit",
      sessionToken: "timeout-commit-session"
    )
    let server = RecoverableVaultHTTPState(putBehaviors: [.commitThenTimeout])
    let http = RecordingHTTPStub { request in try await server.handle(request) }
    let expectedServerURL = try XCTUnwrap(
      AppState.validatedSyncURL(persisted.syncState.serverURL)
    )
    let firstState = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
      ),
      httpClient: http
    )

    await firstState.uploadEncryptedVault(expectedServerURL: expectedServerURL)
    let journaled = try XCTUnwrap(firstState.pendingVaultUpload)
    XCTAssertTrue(firstState.syncPersistencePending)
    XCTAssertEqual(firstState.document.syncState.latestRemoteVersion, 0)

    let relaunchedStore = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    let relaunchedDocument = try relaunchedStore.load()
    let relaunched = AppState(
      testStore: relaunchedStore,
      document: relaunchedDocument,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
      ),
      httpClient: http
    )
    await relaunched.retryPendingSyncPersistence()

    XCTAssertNil(relaunched.pendingVaultUpload)
    XCTAssertFalse(relaunched.syncPersistencePending)
    XCTAssertEqual(relaunched.document.syncState.lastChecksum, journaled.snapshot.checksum)
    let committedSnapshots = await server.snapshotsReceived()
    XCTAssertEqual(committedSnapshots.count, 1)
    XCTAssertNil(try relaunchedStore.loadPendingVaultUpload())
  }

  func testUncommittedUploadReplaysExactSnapshotAfterRelaunch() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let persisted = try connectedUploadDocument(
      store: fixture.store,
      accountId: "20202020-2020-4020-8020-202020202020",
      label: "Replay exact",
      sessionToken: "replay-exact-session"
    )
    let server = RecoverableVaultHTTPState(putBehaviors: [.timeoutBeforeCommit, .accept])
    let http = RecordingHTTPStub { request in try await server.handle(request) }
    let expectedServerURL = try XCTUnwrap(
      AppState.validatedSyncURL(persisted.syncState.serverURL)
    )
    let firstState = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
      ),
      httpClient: http
    )
    await firstState.uploadEncryptedVault(expectedServerURL: expectedServerURL)
    let journaled = try XCTUnwrap(firstState.pendingVaultUpload)

    let relaunchedStore = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    let relaunched = AppState(
      testStore: relaunchedStore,
      document: try relaunchedStore.load(),
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
      ),
      httpClient: http
    )
    await relaunched.retryPendingSyncPersistence()

    let received = await server.snapshotsReceived()
    XCTAssertEqual(received.count, 2)
    XCTAssertEqual(received[0].checksum, received[1].checksum)
    XCTAssertEqual(received[0].envelope, received[1].envelope)
    XCTAssertEqual(received[0].envelope.nonce, journaled.snapshot.envelope.nonce)
    XCTAssertNil(relaunched.pendingVaultUpload)
    XCTAssertFalse(relaunched.hasUnsyncedLocalChanges)
  }

  func testDivergentRemoteRetainsIntentAndStopRecoveryForcesConfirmedDownload() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let accountId = "30303030-3030-4030-8030-303030303030"
    let persisted = try connectedUploadDocument(
      store: fixture.store,
      accountId: accountId,
      label: "Full local history",
      sessionToken: "divergent-remote-session"
    )
    let server = RecoverableVaultHTTPState(putBehaviors: [.timeoutBeforeCommit])
    let http = RecordingHTTPStub { request in try await server.handle(request) }
    let expectedServerURL = try XCTUnwrap(
      AppState.validatedSyncURL(persisted.syncState.serverURL)
    )
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
      ),
      httpClient: http
    )
    await state.uploadEncryptedVault(expectedServerURL: expectedServerURL)
    let remoteWallet = WalletRecord(
      label: "Competing remote",
      address: "0x0000000000000000000000000000000000000303",
      chainKind: .evm
    )
    let competing = try VaultSyncCodec().seal(
      document: VaultDocument(wallets: [remoteWallet]),
      vaultKey: fixture.vaultKey,
      version: 1,
      accountId: accountId
    )
    await server.replaceRemote(with: competing)

    await state.retryPendingSyncPersistence()
    XCTAssertTrue(state.pendingVaultUploadHasRemoteConflict)
    XCTAssertNotNil(state.pendingVaultUpload)
    XCTAssertEqual(state.document.wallets.map(\.label), ["Full local history"])

    await state.abandonPendingVaultUpload(expectedServerURL: expectedServerURL)
    XCTAssertNil(state.pendingVaultUpload)
    XCTAssertTrue(state.document.syncState.remoteOutcomeUncertain)
    XCTAssertTrue(state.hasUnsyncedLocalChanges)
    let relaunchedStore = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    let relaunched = AppState(
      testStore: relaunchedStore,
      document: try relaunchedStore.load(),
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
      ),
      httpClient: http
    )
    XCTAssertTrue(relaunched.document.syncState.remoteOutcomeUncertain)
    XCTAssertTrue(relaunched.hasUnsyncedLocalChanges)
    XCTAssertTrue(relaunched.persistentOperationGuidance?.contains("may or may not") == true)
    relaunched.notice = "Transient"
    relaunched.clearTransientMessagesForNavigation()
    XCTAssertTrue(relaunched.persistentOperationGuidance?.contains("reconcile") == true)
    let requestCountBeforeBlockedDownload = http.requests.count

    await relaunched.downloadEncryptedVault(expectedServerURL: expectedServerURL)
    XCTAssertTrue(relaunched.error.contains("last upload outcome is unknown"))
    XCTAssertEqual(http.requests.count, requestCountBeforeBlockedDownload)

    await relaunched.downloadEncryptedVault(
      discardingLocalChanges: true,
      expectedServerURL: expectedServerURL
    )
    XCTAssertEqual(relaunched.document.wallets.map(\.id), [remoteWallet.id])
    XCTAssertFalse(relaunched.document.syncState.remoteOutcomeUncertain)
    XCTAssertFalse(relaunched.hasUnsyncedLocalChanges)
  }

  func testSuccessfulUploadPrunesOnlyAfterRemoteConfirmation() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let accountId = "40404040-4040-4040-8040-404040404040"
    let old = ScanRunRecord(
      generatedAt: Date(timeIntervalSince1970: 100),
      totalUsd: 0,
      inputCount: 1,
      holdings: [],
      warnings: testCanonicalWarnings(totalLength: 1_000)
    )
    let newest = ScanRunRecord(
      generatedAt: Date(timeIntervalSince1970: 200),
      totalUsd: 0,
      inputCount: 1,
      holdings: [],
      warnings: testCanonicalWarnings(totalLength: 1_000).map { "new \($0)" }
    )
    var document = VaultDocument(scanRuns: [old, newest])
    XCTAssertTrue(
      document.syncState.connect(
        accountId: accountId,
        serverURL: "https://sync.example",
        sessionToken: testSessionToken(accountId: accountId)
      )
    )
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    var newestOnly = persisted
    newestOnly.scanRuns = [newest]
    let codec = VaultSyncCodec()
    let syncLimit = max(
      try codec.encodedSnapshotByteCount(document: newestOnly, accountId: accountId),
      try codec.projectedPostSyncSnapshotByteCount(
        document: newestOnly,
        version: 1,
        accountId: accountId
      )
    )
    let server = RecoverableVaultHTTPState(putBehaviors: [.accept])
    let http = RecordingHTTPStub { request in try await server.handle(request) }
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      syncSnapshotByteLimit: syncLimit,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
      ),
      httpClient: http
    )
    let expectedServerURL = try XCTUnwrap(
      AppState.validatedSyncURL(persisted.syncState.serverURL)
    )

    await state.uploadEncryptedVault(expectedServerURL: expectedServerURL)

    XCTAssertEqual(state.document.scanRuns.map(\.id), [newest.id])
    XCTAssertNil(state.pendingVaultUpload)
    XCTAssertFalse(state.hasUnsyncedLocalChanges)
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(try verifier.load().scanRuns.map(\.id), [newest.id])
  }

  func testRevisionChangeAfterJournalStagingCancelsIntentBeforePut() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let persisted = try connectedUploadDocument(
      store: fixture.store,
      accountId: "50505050-5050-4050-8050-505050505050",
      label: "Revision guarded",
      sessionToken: "revision-guard-session"
    )
    let server = RecoverableVaultHTTPState(putBehaviors: [.accept])
    let http = RecordingHTTPStub { request in try await server.handle(request) }
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
      ),
      httpClient: http
    )
    state.pendingUploadStagedHook = {
      state.document.preferences.hideDust.toggle()
    }
    let expectedServerURL = try XCTUnwrap(
      AppState.validatedSyncURL(persisted.syncState.serverURL)
    )

    await state.uploadEncryptedVault(expectedServerURL: expectedServerURL)

    XCTAssertTrue(state.document.preferences.hideDust)
    XCTAssertNil(state.pendingVaultUpload)
    XCTAssertFalse(state.syncPersistencePending)
    let receivedSnapshots = await server.snapshotsReceived()
    XCTAssertTrue(receivedSnapshots.isEmpty)
    XCTAssertNil(try fixture.store.loadPendingVaultUpload())
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertFalse(try verifier.load().preferences.hideDust)
  }

  func testRevisionChangeAfterAtomicCompletionPreservesNewLocalEditAsDirty() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let accountId = "60606060-6060-4060-8060-606060606060"
    let persisted = try connectedUploadDocument(
      store: fixture.store,
      accountId: accountId,
      label: "Post commit merge",
      sessionToken: "post-commit-merge-session"
    )
    let server = RecoverableVaultHTTPState(putBehaviors: [.accept])
    let http = RecordingHTTPStub { request in try await server.handle(request) }
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
      ),
      httpClient: http
    )
    state.pendingUploadCompletedPersistenceHook = {
      state.document.preferences.hideDust = true
    }
    let expectedServerURL = try XCTUnwrap(
      AppState.validatedSyncURL(persisted.syncState.serverURL)
    )

    await state.uploadEncryptedVault(expectedServerURL: expectedServerURL)

    XCTAssertNil(state.pendingVaultUpload)
    XCTAssertFalse(state.syncPersistencePending)
    XCTAssertTrue(state.document.preferences.hideDust)
    XCTAssertTrue(state.hasUnsyncedLocalChanges)
    XCTAssertEqual(state.document.syncState.latestRemoteVersion, 1)
    XCTAssertTrue(state.notice.contains("Newer local changes were preserved"))
    XCTAssertFalse(state.notice.contains("Removed"))
    let currentRemote = await server.currentRemote()
    let remote = try XCTUnwrap(currentRemote)
    let opened = try VaultSyncCodec().open(
      snapshot: remote,
      vaultKey: fixture.vaultKey,
      expectedAccountId: accountId
    )
    XCTAssertFalse(opened.document.preferences.hideDust)
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    let reloaded = try verifier.load()
    XCTAssertTrue(reloaded.preferences.hideDust)
    XCTAssertTrue(reloaded.syncState.lastSyncedContentChecksum != nil)
    XCTAssertNil(try verifier.loadPendingVaultUpload())
  }

  private func connectedUploadDocument(
    store: EncryptedSQLiteVaultStore,
    accountId: String,
    label: String,
    sessionToken: String
  ) throws -> VaultDocument {
    _ = sessionToken  // Human-readable scenario marker; bearer shape is generated below.
    var document = VaultDocument(wallets: [
      WalletRecord(
        label: label,
        address: "0x00000000000000000000000000000000000000ab",
        chainKind: .evm
      )
    ])
    XCTAssertTrue(
      document.syncState.connect(
        accountId: accountId,
        serverURL: "https://sync.example",
        sessionToken: testSessionToken(accountId: accountId)
      )
    )
    return try store.saveReturningPersistedDocument(document)
  }

  private func overwritePendingUploadEnvelope(at url: URL, with data: Data) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let db
    else {
      throw EncryptedSQLiteVaultStoreError.openFailed("Could not open quarantine fixture.")
    }
    defer { sqlite3_close(db) }
    guard
      sqlite3_exec(
        db,
        "UPDATE encrypted_pending_sync_operations SET envelope_json = X'\(data.hexString)' WHERE id = 'vault-upload';",
        nil,
        nil,
        nil
      ) == SQLITE_OK
    else {
      throw EncryptedSQLiteVaultStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
    }
  }

}
