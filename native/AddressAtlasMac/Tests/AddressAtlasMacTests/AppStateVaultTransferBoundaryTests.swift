import AddressAtlasCore
import Foundation
import XCTest

@testable import AddressAtlasMac

@MainActor
extension AppStateNetworkBoundaryTests {
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

    await state.uploadEncryptedVault()

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
    XCTAssertEqual(state.document.syncState.latestRemoteVersion, 1)
    XCTAssertEqual(state.document.syncState.lastChecksum, snapshot.checksum)
    XCTAssertFalse(state.hasUnsyncedLocalChanges)
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(try verifier.load().syncState.latestRemoteVersion, 1)
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

    await state.uploadEncryptedVault()

    XCTAssertTrue(state.error.contains("Remote vault snapshot is newer"))
    XCTAssertEqual(http.requests.map(\.httpMethod), ["GET"])
    XCTAssertEqual(state.document.syncState.latestRemoteVersion, 1)
    XCTAssertEqual(state.document.syncState.lastChecksum, staleLocalChecksum)
  }

  func testUploadSaveFailureRetainsExactPostRemoteCandidateForRetry() async throws {
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

    await state.uploadEncryptedVault()

    XCTAssertTrue(state.syncPersistencePending)
    XCTAssertEqual(state.document.syncState.latestRemoteVersion, 1)
    XCTAssertNotNil(state.document.syncState.lastChecksum)
    XCTAssertTrue(state.error.contains("remote vault was uploaded"))
    let remoteChecksum = state.document.syncState.lastChecksum

    await state.retryPendingSyncPersistence()

    XCTAssertTrue(state.syncPersistencePending)
    XCTAssertEqual(state.document.syncState.latestRemoteVersion, 1)
    XCTAssertEqual(state.document.syncState.lastChecksum, remoteChecksum)
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

    await state.downloadEncryptedVault()

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

  func testDownloadSaveFailureRetainsExactOpenedVaultCandidateForRetry() async throws {
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

    await state.downloadEncryptedVault()

    XCTAssertTrue(state.syncPersistencePending)
    XCTAssertEqual(state.document.wallets.map(\.id), [remoteWallet.id])
    XCTAssertEqual(state.document.syncState.latestRemoteVersion, 4)
    XCTAssertEqual(state.document.syncState.lastChecksum, snapshot.checksum)
    XCTAssertTrue(state.error.contains("remote vault was opened"))

    await state.retryPendingSyncPersistence()

    XCTAssertTrue(state.syncPersistencePending)
    XCTAssertEqual(state.document.wallets.map(\.id), [remoteWallet.id])
    XCTAssertEqual(state.document.syncState.latestRemoteVersion, 4)
  }

}
