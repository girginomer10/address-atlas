import AddressAtlasCore
import Foundation
import XCTest

@testable import AddressAtlasMac

@MainActor
extension AppStateNetworkBoundaryTests {
  func testTerminationFreezeRejectsQueuedUnlockBeforeVaultRecoveryStarts() {
    let state = AppState()

    XCTAssertTrue(state.beginTerminationRequest())
    XCTAssertFalse(state.beginUnlockOperationIfAllowed())

    XCTAssertFalse(state.isUnlocking)
    XCTAssertFalse(state.isUnlocked)
  }

  func testTerminationFreezeRejectsQueuedScanAndEndpointRefreshBeforeNetwork() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let endpointClient = CountingEndpointConfigClient(
      config: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
    )
    let http = RecordingHTTPStub { request in
      XCTFail("Termination-frozen scan must not send HTTP: \(request)")
      throw URLError(.cancelled)
    }
    var document = VaultDocument(
      wallets: [
        WalletRecord(
          label: "Bitcoin",
          address: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT",
          chainKind: .bitcoin
        )
      ]
    )
    document.syncState.serverURL = "https://sync.example"
    let state = AppState(
      testStore: fixture.store,
      document: document,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: endpointClient,
      httpClient: http
    )

    XCTAssertTrue(state.beginTerminationRequest())
    state.startScan()
    await state.scanSavedWallets()
    let refreshed = await state.refreshEndpointConfig(silent: true)

    XCTAssertNil(state.scanTask)
    XCTAssertFalse(state.scanning)
    XCTAssertFalse(refreshed)
    XCTAssertTrue(http.requests.isEmpty)
    let endpointRequests = await endpointClient.requestCount
    XCTAssertEqual(endpointRequests, 0)
  }

  func testTerminationFreezeRejectsQueuedVaultTransferBeforeRemoteReadOrWrite() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let accountId = "89898989-8989-4989-8989-898989898989"
    var document = VaultDocument()
    XCTAssertTrue(
      document.syncState.connect(
        accountId: accountId,
        serverURL: "https://sync.example",
        sessionToken: testSessionToken(accountId: accountId)
      ))
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let serverURL = try XCTUnwrap(AppState.validatedSyncURL(persisted.syncState.serverURL))
    let http = RecordingHTTPStub { request in
      XCTFail("Termination-frozen sync must not send HTTP: \(request)")
      throw URLError(.cancelled)
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

    XCTAssertTrue(state.beginTerminationRequest())
    await state.uploadEncryptedVault(expectedServerURL: serverURL)
    await state.downloadEncryptedVault(expectedServerURL: serverURL)

    XCTAssertFalse(state.syncing)
    XCTAssertNil(state.pendingVaultUpload)
    XCTAssertTrue(http.requests.isEmpty)
  }

  func testTerminationFreezeRejectsQueuedPendingLocalSaveRetry() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let persisted = try fixture.store.saveReturningPersistedDocument(VaultDocument())
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey
    )
    var pendingCandidate = persisted
    pendingCandidate.preferences.hideDust = true
    state.requirePendingSyncPersistence(
      pendingCandidate,
      projectedSyncVersion: nil,
      saveExactly: true
    )

    XCTAssertTrue(state.beginTerminationRequest())
    await state.retryPendingSyncPersistence()

    XCTAssertNil(state.syncActivity)
    XCTAssertFalse(state.syncing)
    XCTAssertFalse(state.isPersisting)
    XCTAssertTrue(state.syncPersistencePending)
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertFalse(try verifier.load().preferences.hideDust)
  }

  func testTerminationFreezeRejectsQueuedPasskeyFlowBeforePolicyOrAuthentication() async {
    let endpointClient = CountingEndpointConfigClient(
      config: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
    )
    let authenticator = RecordingPasskeyAuthenticator()
    let state = AppState(
      endpointConfigClient: endpointClient,
      passkeyAuthenticator: authenticator
    )

    XCTAssertTrue(state.beginTerminationRequest())
    await state.createPasskeyAccount(serverURL: "https://sync.example")

    XCTAssertFalse(state.syncing)
    XCTAssertEqual(authenticator.callCount, 0)
    let endpointRequests = await endpointClient.requestCount
    XCTAssertEqual(endpointRequests, 0)
  }

  func testPasskeyRevocationAndDeletionFlushWalletDraftsBeforeRemoteSideEffects() async throws {
    try await assertPasskeyFlowFlushesWalletDraft()
    try await assertSessionRevocationFlushesWalletDraft()
    try await assertAccountDeletionFlushesWalletDraft()
  }

  private func assertPasskeyFlowFlushesWalletDraft() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let wallet = WalletRecord(
      label: "Treasury",
      address: "0x0000000000000000000000000000000000000001",
      chainKind: .evm
    )
    let persisted = try fixture.store.saveReturningPersistedDocument(
      VaultDocument(wallets: [wallet])
    )
    let accountId = "91919191-9191-4919-8919-919191919191"
    let authenticator = StubPasskeyAuthenticator(
      session: PasskeyWebSession(
        userId: accountId,
        sessionToken: testSessionToken(accountId: accountId),
        serverURL: "https://sync.example"
      )
    )
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
      ),
      passkeyAuthenticator: authenticator
    )
    XCTAssertTrue(state.setWalletLabelDraft(id: wallet.id, label: "Passkey Treasury"))

    await state.createPasskeyAccount(serverURL: "https://sync.example")

    XCTAssertEqual(authenticator.callCount, 1)
    XCTAssertTrue(state.walletLabelDrafts.isEmpty)
    XCTAssertEqual(state.document.wallets.first?.label, "Passkey Treasury")
  }

  private func assertSessionRevocationFlushesWalletDraft() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let wallet = WalletRecord(
      label: "Treasury",
      address: "0x0000000000000000000000000000000000000002",
      chainKind: .evm
    )
    let accountId = "92929292-9292-4929-8929-929292929292"
    var document = VaultDocument(wallets: [wallet])
    XCTAssertTrue(
      document.syncState.connect(
        accountId: accountId,
        serverURL: "https://sync.example",
        sessionToken: testSessionToken(accountId: accountId)
      ))
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let serverURL = try XCTUnwrap(AppState.validatedSyncURL(persisted.syncState.serverURL))
    let http = RecordingHTTPStub { request in
      XCTAssertEqual(request.url?.path, "/account/session")
      return stubJSONResponse(request, #"{"ok":true}"#)
    }
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      httpClient: http
    )
    XCTAssertTrue(state.setWalletLabelDraft(id: wallet.id, label: "Revoked Treasury"))

    await state.revokeCurrentSyncSession(expectedServerURL: serverURL)

    XCTAssertEqual(http.requests.count, 1)
    XCTAssertTrue(state.walletLabelDrafts.isEmpty)
    XCTAssertEqual(state.document.wallets.first?.label, "Revoked Treasury")
  }

  private func assertAccountDeletionFlushesWalletDraft() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let accountID = "93939393-9393-4939-8939-939393939393"
    let wallet = WalletRecord(
      label: "Treasury",
      address: "0x0000000000000000000000000000000000000003",
      chainKind: .evm
    )
    var document = VaultDocument(wallets: [wallet])
    let originalSessionToken = testSessionToken(accountId: accountID)
    let freshSessionToken = testSessionToken(
      accountId: accountID,
      sessionId: "93939393-9393-4939-8939-939393939394"
    )
    XCTAssertTrue(
      document.syncState.connect(
        accountId: accountID,
        serverURL: "https://sync.example",
        sessionToken: originalSessionToken
      ))
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let serverURL = try XCTUnwrap(AppState.validatedSyncURL(persisted.syncState.serverURL))
    let authenticator = StubPasskeyAuthenticator(
      session: PasskeyWebSession(
        userId: accountID,
        sessionToken: freshSessionToken,
        serverURL: "https://sync.example"
      )
    )
    let http = RecordingHTTPStub { request in
      XCTAssertEqual(request.url?.path, "/account")
      return stubJSONResponse(request, #"{"ok":true}"#)
    }
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      httpClient: http,
      passkeyAuthenticator: authenticator
    )
    XCTAssertTrue(state.setWalletLabelDraft(id: wallet.id, label: "Deleted Account Treasury"))

    await state.deleteSyncAccount(expectedServerURL: serverURL)

    XCTAssertEqual(http.requests.count, 1)
    XCTAssertTrue(state.walletLabelDrafts.isEmpty)
    XCTAssertEqual(state.document.wallets.first?.label, "Deleted Account Treasury")
    XCTAssertNil(state.document.syncState.accountId)
  }
}
