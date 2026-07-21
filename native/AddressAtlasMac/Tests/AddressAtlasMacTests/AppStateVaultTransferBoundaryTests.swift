import AddressAtlasCore
import CryptoKit
import Foundation
import XCTest

@testable import AddressAtlasMac

@MainActor
extension AppStateNetworkBoundaryTests {
  func testUploadBlocksBeforeVaultHTTPWhenEndpointTrustDurabilityIsUncertain() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var document = VaultDocument()
    XCTAssertTrue(
      document.syncState.connect(
        accountId: "67676767-6767-4767-8767-676767676767",
        serverURL: "https://sync.example",
        sessionToken: "uncertain-trust-upload-session"
      )
    )
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let expectedServerURL = try XCTUnwrap(
      AppState.validatedSyncURL(persisted.syncState.serverURL)
    )
    let http = RecordingHTTPStub { request in
      XCTFail("Uncertain endpoint trust must block vault HTTP: \(request)")
      throw URLError(.cancelled)
    }
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 30, refreshAfterSeconds: 300)
      ),
      endpointConfigTrustStore: ScriptedEndpointConfigTrustStore([
        .committedDurabilityUncertain
      ]),
      httpClient: http
    )

    await state.uploadEncryptedVault(expectedServerURL: expectedServerURL)

    XCTAssertTrue(http.requests.isEmpty)
    XCTAssertTrue(state.endpointConfigTrustDurabilityDegraded)
    XCTAssertTrue(state.error.contains("not crash-durable"))
    XCTAssertNil(state.pendingVaultUpload)
  }

  func testUploadEncryptedVaultSealsEncryptsAndPUTsWithBearerAuthorization() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let accountId = "66666666-6666-4666-8666-666666666666"
    let wallet = WalletRecord(
      label: "Treasury",
      address: "0x0000000000000000000000000000000000000001",
      chainKind: .evm
    )
    var document = VaultDocument(wallets: [wallet])
    XCTAssertTrue(
      document.syncState.connect(
        accountId: accountId,
        serverURL: "https://sync.example",
        sessionToken: "upload-session-token"
      ))
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let expectedServerURL = try XCTUnwrap(
      AppState.validatedSyncURL(persisted.syncState.serverURL)
    )
    let http = RecordingHTTPStub { request in
      guard request.url?.path == "/vault/latest" else {
        throw URLError(.unsupportedURL)
      }
      if request.httpMethod == "PUT" {
        return stubJSONResponse(request, #"{"ok":true}"#)
      }
      return stubJSONResponse(request, #"{"error":"vault not found"}"#, statusCode: 404)
    }
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
      ),
      httpClient: http
    )
    XCTAssertTrue(state.setWalletLabelDraft(id: wallet.id, label: "Primary Treasury"))

    await state.uploadEncryptedVault(expectedServerURL: expectedServerURL)

    XCTAssertEqual(state.error, "")
    XCTAssertEqual(state.notice, "Encrypted vault uploaded.")
    XCTAssertEqual(http.requests.map(\.httpMethod), ["GET", "PUT"])
    let put = try XCTUnwrap(http.requests.last)
    XCTAssertEqual(put.url?.path, "/vault/latest")
    XCTAssertEqual(put.value(forHTTPHeaderField: "authorization"), "Bearer upload-session-token")
    XCTAssertEqual(put.value(forHTTPHeaderField: "content-type"), "application/json")
    let snapshot = try JSONDecoder.addressAtlas.decode(
      RemoteVaultSnapshot.self,
      from: XCTUnwrap(put.httpBody)
    )
    XCTAssertEqual(snapshot.version, 1)
    XCTAssertEqual(snapshot.envelope.schemaVersion, VaultDocument.currentSchemaVersion)
    XCTAssertEqual(snapshot.envelope.cryptoVersion, 2)
    XCTAssertEqual(snapshot.envelope.keyId, "sync-v2")
    let opened = try VaultSyncCodec().open(
      snapshot: snapshot,
      vaultKey: fixture.vaultKey,
      expectedAccountId: accountId
    )
    XCTAssertFalse(opened.requiresV2Upgrade)
    XCTAssertEqual(opened.document.wallets.map(\.id), [wallet.id])
    XCTAssertEqual(opened.document.wallets.first?.label, "Primary Treasury")
    XCTAssertTrue(state.walletLabelDrafts.isEmpty)
    XCTAssertEqual(state.document.syncState.latestRemoteVersion, 1)
    XCTAssertEqual(state.document.syncState.lastChecksum, snapshot.checksum)
    XCTAssertFalse(state.hasUnsyncedLocalChanges)
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    let reloaded = try verifier.load()
    XCTAssertEqual(reloaded.syncState.latestRemoteVersion, 1)
    XCTAssertEqual(reloaded.wallets.first?.label, "Primary Treasury")
  }

  func testUploadRejectsMismatchedExpectedServerBeforeHTTP() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let document = VaultDocument(
      syncState: SyncState(
        accountId: "69696969-6969-4969-8969-696969696969",
        serverURL: "https://sync.example",
        sessionToken: "bound-session"
      )
    )
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let http = RecordingHTTPStub { request in
      XCTFail("Mismatched bound action must not send HTTP: \(request)")
      throw URLError(.cancelled)
    }
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      httpClient: http
    )

    await state.uploadEncryptedVault(
      expectedServerURL: URL(string: "https://other.example")!
    )

    XCTAssertTrue(state.error.contains("selection changed"))
    XCTAssertTrue(http.requests.isEmpty)
    XCTAssertEqual(state.document.syncState.sessionToken, "bound-session")
  }

  func testUploadEncryptedVaultStopsOnRemoteVersionConflictBeforePUT() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let accountId = "88888888-8888-4888-8888-888888888888"
    let remoteSnapshot = try VaultSyncCodec().seal(
      document: VaultDocument(
        wallets: [
          WalletRecord(
            label: "Other Mac",
            address: "0x0000000000000000000000000000000000000002",
            chainKind: .evm
          )
        ]
      ),
      vaultKey: fixture.vaultKey,
      version: 2,
      accountId: accountId
    )
    let remoteJSON = try JSONEncoder.addressAtlas.encode(remoteSnapshot)
    let staleLocalChecksum = String(repeating: "a", count: 64)
    let document = VaultDocument(
      syncState: SyncState(
        accountId: accountId,
        serverURL: "https://sync.example",
        sessionToken: "conflict-session-token",
        latestRemoteVersion: 1,
        lastSyncedAt: Date(timeIntervalSince1970: 50),
        lastChecksum: staleLocalChecksum
      )
    )
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let expectedServerURL = try XCTUnwrap(
      AppState.validatedSyncURL(persisted.syncState.serverURL)
    )
    let http = RecordingHTTPStub { request in
      guard request.url?.path == "/vault/latest", request.httpMethod == "GET" else {
        throw URLError(.unsupportedURL)
      }
      return (remoteJSON, stubHTTPResponse(request))
    }
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

    XCTAssertTrue(state.error.contains("Remote vault snapshot is newer"))
    XCTAssertEqual(http.requests.map(\.httpMethod), ["GET"])
    XCTAssertEqual(state.document.syncState.latestRemoteVersion, 1)
    XCTAssertEqual(state.document.syncState.lastChecksum, staleLocalChecksum)
  }

  func testRejectedUploadKeepsFullLocalHistoryWhileSendingPrunedWireProjection() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let accountId = "67676767-6767-4676-8676-676767676767"
    let old = ScanRunRecord(
      generatedAt: Date(timeIntervalSince1970: 100),
      totalUsd: 0,
      inputCount: 1,
      holdings: [],
      warnings: [String(repeating: "o", count: 1_000)]
    )
    let newest = ScanRunRecord(
      generatedAt: Date(timeIntervalSince1970: 200),
      totalUsd: 0,
      inputCount: 1,
      holdings: [],
      warnings: [String(repeating: "n", count: 1_000)]
    )
    var document = VaultDocument(scanRuns: [old, newest])
    XCTAssertTrue(
      document.syncState.connect(
        accountId: accountId,
        serverURL: "https://sync.example",
        sessionToken: "rejected-upload-session"
      ))
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let expectedServerURL = try XCTUnwrap(
      AppState.validatedSyncURL(persisted.syncState.serverURL)
    )
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
    XCTAssertGreaterThan(
      try codec.encodedSnapshotByteCount(document: persisted, accountId: accountId),
      syncLimit
    )
    let http = RecordingHTTPStub { request in
      guard request.url?.path == "/vault/latest" else {
        throw URLError(.unsupportedURL)
      }
      if request.httpMethod == "PUT" {
        return stubJSONResponse(
          request,
          #"{"error":"Upload temporarily unavailable."}"#,
          statusCode: 503
        )
      }
      return stubJSONResponse(request, #"{"error":"vault not found"}"#, statusCode: 404)
    }
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

    await state.uploadEncryptedVault(expectedServerURL: expectedServerURL)

    XCTAssertTrue(state.error.contains("Upload temporarily unavailable"))
    XCTAssertEqual(state.document.scanRuns.map(\.id), [old.id, newest.id])
    XCTAssertTrue(state.syncPersistencePending)
    XCTAssertNotNil(state.pendingVaultUpload)
    let put = try XCTUnwrap(http.requests.last)
    XCTAssertEqual(put.httpMethod, "PUT")
    let wireSnapshot = try JSONDecoder.addressAtlas.decode(
      RemoteVaultSnapshot.self,
      from: XCTUnwrap(put.httpBody)
    )
    let opened = try codec.open(
      snapshot: wireSnapshot,
      vaultKey: fixture.vaultKey,
      expectedAccountId: accountId
    )
    XCTAssertEqual(opened.document.scanRuns.map(\.id), [newest.id])
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(try verifier.load().scanRuns.map(\.id), [old.id, newest.id])
  }

  func testPendingUploadBlocksCompetingWriterAndRetainsPreCommitLocalDocument() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let accountId = "78787878-7878-4787-8787-787878787878"
    var document = VaultDocument(
      wallets: [
        WalletRecord(
          label: "Upload candidate",
          address: "0x0000000000000000000000000000000000000078",
          chainKind: .evm
        )
      ]
    )
    XCTAssertTrue(
      document.syncState.connect(
        accountId: accountId,
        serverURL: "https://sync.example",
        sessionToken: "upload-candidate-session"
      ))
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let expectedServerURL = try XCTUnwrap(
      AppState.validatedSyncURL(persisted.syncState.serverURL)
    )
    let competingStore = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    _ = try competingStore.load()
    let http = RecordingHTTPStub { request in
      guard request.url?.path == "/vault/latest" else {
        throw URLError(.unsupportedURL)
      }
      if request.httpMethod == "PUT" {
        var competing = try competingStore.load()
        competing.preferences.hideDust.toggle()
        try competingStore.save(competing)
        return stubJSONResponse(request, #"{"ok":true}"#)
      }
      return stubJSONResponse(request, #"{"error":"vault not found"}"#, statusCode: 404)
    }
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

    XCTAssertTrue(state.syncPersistencePending)
    XCTAssertEqual(state.document.syncState.latestRemoteVersion, 0)
    XCTAssertNil(state.document.syncState.lastChecksum)
    XCTAssertNotNil(state.pendingVaultUpload)
    XCTAssertTrue(state.error.contains("remains safely pending"))
    XCTAssertEqual(
      try EncryptedSQLiteVaultStore(
        path: fixture.database,
        vaultKey: fixture.vaultKey
      ).load().wallets.map(\.label),
      ["Upload candidate"]
    )
  }

  func testDownloadEncryptedVaultDecodesDecryptsPersistsAndMarksSynced() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let accountId = "99999999-9999-4999-8999-999999999999"
    let remoteWallet = WalletRecord(
      label: "Synced Treasury",
      address: "0x0000000000000000000000000000000000000003",
      chainKind: .evm
    )
    let snapshot = try VaultSyncCodec().seal(
      document: VaultDocument(wallets: [remoteWallet]),
      vaultKey: fixture.vaultKey,
      version: 3,
      accountId: accountId
    )
    let snapshotJSON = try JSONEncoder.addressAtlas.encode(snapshot)
    var document = VaultDocument()
    XCTAssertTrue(
      document.syncState.connect(
        accountId: accountId,
        serverURL: "https://sync.example",
        sessionToken: "download-session-token"
      ))
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let expectedServerURL = try XCTUnwrap(
      AppState.validatedSyncURL(persisted.syncState.serverURL)
    )
    let http = RecordingHTTPStub { request in
      guard request.url?.path == "/vault/latest", request.httpMethod == "GET" else {
        throw URLError(.unsupportedURL)
      }
      return (snapshotJSON, stubHTTPResponse(request))
    }
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
      ),
      httpClient: http
    )

    await state.downloadEncryptedVault(expectedServerURL: expectedServerURL)

    XCTAssertEqual(state.error, "")
    XCTAssertEqual(state.notice, "Encrypted vault downloaded.")
    XCTAssertEqual(http.requests.map(\.httpMethod), ["GET"])
    XCTAssertEqual(
      http.requests.first?.value(forHTTPHeaderField: "authorization"),
      "Bearer download-session-token"
    )
    XCTAssertEqual(state.document.wallets.map(\.id), [remoteWallet.id])
    XCTAssertEqual(state.document.wallets.first?.label, "Synced Treasury")
    XCTAssertEqual(state.document.syncState.accountId, accountId)
    XCTAssertEqual(state.document.syncState.sessionToken, "download-session-token")
    XCTAssertEqual(state.document.syncState.latestRemoteVersion, 3)
    XCTAssertEqual(state.document.syncState.lastChecksum, snapshot.checksum)
    XCTAssertFalse(state.hasUnsyncedLocalChanges)
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    let reloaded = try verifier.load()
    XCTAssertEqual(reloaded.wallets.map(\.id), [remoteWallet.id])
    XCTAssertEqual(reloaded.syncState.latestRemoteVersion, 3)
  }

  func testExplicitDiscardClearsWalletLabelDraftBeforeDownloadedVaultCanReplaceIt() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let accountId = "98989898-9898-4989-8989-989898989898"
    let walletID = UUID()
    let localWallet = WalletRecord(
      id: walletID,
      label: "Local Treasury",
      address: "0x0000000000000000000000000000000000000098",
      chainKind: .evm
    )
    let remoteWallet = WalletRecord(
      id: walletID,
      label: "Remote Treasury",
      address: localWallet.address,
      chainKind: .evm
    )
    let snapshot = try VaultSyncCodec().seal(
      document: VaultDocument(wallets: [remoteWallet]),
      vaultKey: fixture.vaultKey,
      version: 3,
      accountId: accountId
    )
    let snapshotJSON = try JSONEncoder.addressAtlas.encode(snapshot)
    var document = VaultDocument(wallets: [localWallet])
    XCTAssertTrue(
      document.syncState.connect(
        accountId: accountId,
        serverURL: "https://sync.example",
        sessionToken: "discard-session-token"
      ))
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let expectedServerURL = try XCTUnwrap(
      AppState.validatedSyncURL(persisted.syncState.serverURL)
    )
    let http = RecordingHTTPStub { request in
      guard request.url?.path == "/vault/latest" else {
        throw URLError(.unsupportedURL)
      }
      switch request.httpMethod {
      case "GET":
        return (snapshotJSON, stubHTTPResponse(request))
      case "PUT":
        return stubJSONResponse(request, #"{"ok":true}"#)
      default:
        throw URLError(.unsupportedURL)
      }
    }
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
      ),
      httpClient: http
    )
    XCTAssertTrue(state.setWalletLabelDraft(id: walletID, label: "Uncommitted Treasury"))

    await state.downloadEncryptedVault(
      discardingLocalChanges: true,
      expectedServerURL: expectedServerURL
    )

    XCTAssertEqual(state.error, "")
    XCTAssertTrue(state.walletLabelDrafts.isEmpty)
    XCTAssertEqual(state.document.wallets.first?.label, "Remote Treasury")
    XCTAssertTrue(state.hasVaultRollbackCheckpoint)
    let downloadedSyncState = state.document.syncState

    await state.restoreVaultRollbackCheckpoint()

    XCTAssertEqual(state.error, "")
    XCTAssertFalse(state.hasVaultRollbackCheckpoint)
    XCTAssertTrue(state.walletLabelDrafts.isEmpty)
    XCTAssertEqual(state.document.wallets.first?.label, "Local Treasury")
    XCTAssertEqual(state.document.syncState, downloadedSyncState)
    XCTAssertEqual(state.document.syncState.latestRemoteVersion, snapshot.version)
    XCTAssertEqual(state.document.syncState.lastChecksum, snapshot.checksum)
    XCTAssertTrue(state.hasUnsyncedLocalChanges)

    await state.uploadEncryptedVault(expectedServerURL: expectedServerURL)

    XCTAssertEqual(state.error, "")
    XCTAssertEqual(state.notice, "Encrypted vault uploaded.")
    XCTAssertEqual(http.requests.map(\.httpMethod), ["GET", "GET", "PUT"])
    let uploaded = try JSONDecoder.addressAtlas.decode(
      RemoteVaultSnapshot.self,
      from: XCTUnwrap(http.requests.last?.httpBody)
    )
    XCTAssertEqual(uploaded.version, snapshot.version + 1)
    let reopened = try VaultSyncCodec().open(
      snapshot: uploaded,
      vaultKey: fixture.vaultKey,
      expectedAccountId: accountId
    )
    XCTAssertEqual(reopened.document.wallets.first?.label, "Local Treasury")
    XCTAssertFalse(state.hasUnsyncedLocalChanges)
    XCTAssertTrue(state.beginTerminationRequest())
    let terminationPrepared = await state.prepareForTermination()
    XCTAssertTrue(terminationPrepared)
    XCTAssertEqual(state.document.wallets.first?.label, "Local Treasury")
  }

  func testFailedDiscardDownloadRestoresWalletLabelDraftWhenNothingRemoteWasAdopted() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let wallet = WalletRecord(
      label: "Local Treasury",
      address: "0x0000000000000000000000000000000000000097",
      chainKind: .evm
    )
    var document = VaultDocument(wallets: [wallet])
    XCTAssertTrue(
      document.syncState.connect(
        accountId: "97979797-9797-4979-8979-979797979797",
        serverURL: "https://sync.example",
        sessionToken: "failed-discard-session-token"
      ))
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let expectedServerURL = try XCTUnwrap(
      AppState.validatedSyncURL(persisted.syncState.serverURL)
    )
    let http = RecordingHTTPStub { _ in
      throw URLError(.cannotConnectToHost)
    }
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
      ),
      httpClient: http
    )
    XCTAssertTrue(state.setWalletLabelDraft(id: wallet.id, label: "Visible Draft"))

    await state.downloadEncryptedVault(
      discardingLocalChanges: true,
      expectedServerURL: expectedServerURL
    )

    XCTAssertEqual(state.walletLabelDrafts[wallet.id], "Visible Draft")
    XCTAssertEqual(state.document.wallets.first?.label, "Local Treasury")
    XCTAssertNil(state.pendingVaultUpload)
    XCTAssertNil(state.pendingSyncPersistence)
    XCTAssertFalse(state.syncPersistencePending)
    XCTAssertFalse(state.error.isEmpty)
  }

  func testLegacyUpgradeRevisionChangeAfterJournalStagingCancelsBeforePut() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let accountId = "70707070-7070-4070-8070-707070707070"
    let remoteWallet = WalletRecord(
      label: "Legacy remote",
      address: "0x0000000000000000000000000000000000000707",
      chainKind: .evm
    )
    let crypto = VaultCrypto()
    let syncKey = try crypto.deriveKey(from: fixture.vaultKey, purpose: .syncBlob)
    let legacyDocument = VaultDocument(
      schemaVersion: 1,
      wallets: [remoteWallet],
      syncState: SyncState(accountId: accountId, latestRemoteVersion: 0)
    )
    let legacyEnvelope = try crypto.sealJSON(
      legacyDocument,
      with: syncKey,
      keyId: "sync-v1",
      schemaVersion: 1
    )
    let encodedLegacyEnvelope = try JSONEncoder.addressAtlas.encode(legacyEnvelope)
    let legacySnapshot = RemoteVaultSnapshot(
      version: 1,
      envelope: legacyEnvelope,
      byteSize: encodedLegacyEnvelope.count,
      checksum: Data(SHA256.hash(data: encodedLegacyEnvelope)).map {
        String(format: "%02x", $0)
      }.joined()
    )
    var localDocument = VaultDocument()
    XCTAssertTrue(
      localDocument.syncState.connect(
        accountId: accountId,
        serverURL: "https://sync.example",
        sessionToken: "legacy-upgrade-revision-session"
      )
    )
    let persisted = try fixture.store.saveReturningPersistedDocument(localDocument)
    let expectedServerURL = try XCTUnwrap(
      AppState.validatedSyncURL(persisted.syncState.serverURL)
    )
    let server = RecoverableVaultHTTPState(
      remoteSnapshot: legacySnapshot,
      putBehaviors: [.accept]
    )
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
      state.document.preferences.hideDust = true
    }

    await state.downloadEncryptedVault(expectedServerURL: expectedServerURL)

    XCTAssertTrue(state.document.preferences.hideDust)
    XCTAssertTrue(state.document.wallets.isEmpty)
    XCTAssertTrue(state.error.contains("local vault changed"))
    XCTAssertNil(state.pendingVaultUpload)
    XCTAssertFalse(state.syncPersistencePending)
    XCTAssertEqual(http.requests.map(\.httpMethod), ["GET"])
    let receivedSnapshots = await server.snapshotsReceived()
    XCTAssertTrue(receivedSnapshots.isEmpty)
    XCTAssertNil(try fixture.store.loadPendingVaultUpload())
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    let reloaded = try verifier.load()
    XCTAssertFalse(reloaded.preferences.hideDust)
    XCTAssertTrue(reloaded.wallets.isEmpty)
    let currentRemote = await server.currentRemote()
    XCTAssertEqual(currentRemote, legacySnapshot)
  }

  func testCompetingWriteDuringDownloadFailsBeforeDestructiveRemoteAdoption() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let accountId = "89898989-8989-4989-8989-898989898989"
    let remoteWallet = WalletRecord(
      label: "Remote candidate",
      address: "0x0000000000000000000000000000000000000089",
      chainKind: .evm
    )
    let snapshot = try VaultSyncCodec().seal(
      document: VaultDocument(wallets: [remoteWallet]),
      vaultKey: fixture.vaultKey,
      version: 4,
      accountId: accountId
    )
    var document = VaultDocument()
    XCTAssertTrue(
      document.syncState.connect(
        accountId: accountId,
        serverURL: "https://sync.example",
        sessionToken: "download-candidate-session"
      ))
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let expectedServerURL = try XCTUnwrap(
      AppState.validatedSyncURL(persisted.syncState.serverURL)
    )
    let competingStore = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    _ = try competingStore.load()
    let snapshotJSON = try JSONEncoder.addressAtlas.encode(snapshot)
    let http = RecordingHTTPStub { request in
      var competing = try competingStore.load()
      competing.preferences.hideDust.toggle()
      try competingStore.save(competing)
      return (snapshotJSON, stubHTTPResponse(request))
    }
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
      ),
      httpClient: http
    )

    await state.downloadEncryptedVault(expectedServerURL: expectedServerURL)

    // The external write invalidates the baseline before a trustworthy local
    // rollback point can be committed. Fail closed: do not publish or queue the
    // authenticated remote candidate without that durable safety boundary.
    XCTAssertFalse(state.syncPersistencePending)
    XCTAssertNil(state.pendingSyncPersistence)
    XCTAssertNil(state.pendingVaultUpload)
    XCTAssertFalse(state.hasVaultRollbackCheckpoint)
    XCTAssertTrue(state.document.wallets.isEmpty)
    XCTAssertEqual(state.document.syncState.latestRemoteVersion, 0)
    XCTAssertNil(state.document.syncState.lastChecksum)
    XCTAssertFalse(state.error.isEmpty)

    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    let durableExternalWinner = try verifier.load()
    XCTAssertTrue(durableExternalWinner.preferences.hideDust)
    XCTAssertTrue(durableExternalWinner.wallets.isEmpty)
    XCTAssertEqual(durableExternalWinner.syncState.accountId, accountId)
    XCTAssertFalse(try verifier.containsRollbackCheckpoint())
  }

  func testRecoveryKitUnlockPublishesAndCanRestoreDurableRollbackCheckpoint() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let supportDirectory = directory.appending(path: "Application Support")
    try FileManager.default.createDirectory(
      at: supportDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let vaultURL = supportDirectory.appending(path: "vault.sqlite")
    let recoveryURL = directory.appending(path: "vault.atlas-recovery")
    let vaultKey = try VaultCrypto().generateVaultKey()
    let store = try EncryptedSQLiteVaultStore(path: vaultURL, vaultKey: vaultKey)
    _ = try store.load()
    let checkpoint = VaultDocument(wallets: [
      WalletRecord(label: "Before download", address: "0x1", chainKind: .evm)
    ])
    let persistedCheckpoint = try store.saveReturningPersistedDocument(checkpoint)
    _ = try store.saveRollbackCheckpoint(persistedCheckpoint)
    let current = try store.saveReturningPersistedDocument(
      VaultDocument(wallets: [
        WalletRecord(label: "Downloaded", address: "0x2", chainKind: .evm)
      ])
    )
    XCTAssertEqual(current.wallets.map(\.label), ["Downloaded"])

    let recoveryKit = try RecoveryKitCodec().create(vaultKey: vaultKey)
    try JSONEncoder.addressAtlas.encode(recoveryKit.document).write(
      to: recoveryURL,
      options: [.atomic]
    )
    let keyStore = AppStateTestVaultKeyStore()
    let state = AppState(
      keyStore: keyStore,
      appSupportDirectoryOverride: supportDirectory
    )

    await state.restoreRecoveryKit(
      from: recoveryURL,
      recoveryCode: recoveryKit.recoveryCode
    )

    XCTAssertTrue(state.isUnlocked)
    XCTAssertEqual(state.error, "")
    XCTAssertEqual(state.document.wallets.map(\.label), ["Downloaded"])
    XCTAssertTrue(state.hasVaultRollbackCheckpoint)
    XCTAssertEqual(try keyStore.loadVaultKey(), vaultKey)

    await state.restoreVaultRollbackCheckpoint()

    XCTAssertEqual(state.document.wallets.map(\.label), ["Before download"])
    XCTAssertFalse(state.hasVaultRollbackCheckpoint)
    XCTAssertFalse(try store.containsRollbackCheckpoint())
  }

}
