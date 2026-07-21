import AddressAtlasCore
import Foundation
import XCTest

@testable import AddressAtlasMac

@MainActor
extension AppStateNetworkBoundaryTests {
  func testLifecycleActionsRejectMismatchedExpectedServerBeforeHTTP() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let document = VaultDocument(
      syncState: SyncState(
        accountId: "10101010-1010-4010-8010-101010101010",
        serverURL: "https://sync.example",
        sessionToken: "origin-bound-session"
      )
    )
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let http = RecordingHTTPStub { request in
      XCTFail("Mismatched lifecycle action must not send HTTP: \(request)")
      throw URLError(.cancelled)
    }
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      httpClient: http
    )
    let otherServerURL = try XCTUnwrap(URL(string: "https://other.example"))

    await state.revokeCurrentSyncSession(expectedServerURL: otherServerURL)
    XCTAssertTrue(state.error.contains("selection changed"))
    XCTAssertEqual(state.document.syncState.sessionToken, "origin-bound-session")

    await state.deleteSyncAccount(expectedServerURL: otherServerURL)
    XCTAssertTrue(state.error.contains("selection changed"))
    XCTAssertEqual(state.document.syncState.accountId, "10101010-1010-4010-8010-101010101010")
    XCTAssertTrue(http.requests.isEmpty)
  }

  func testRevokingCurrentSessionCallsLifecycleEndpointAndPersistsOnlyTokenRemoval() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let accountId = "12121212-1212-4212-8212-121212121212"
    let document = VaultDocument(
      wallets: [WalletRecord(label: "Local", address: "0x123", chainKind: .evm)],
      syncState: SyncState(
        accountId: accountId,
        serverURL: "https://sync.example",
        sessionToken: "revoke-session-token",
        latestRemoteVersion: 7,
        lastChecksum: String(repeating: "a", count: 64),
        lastSyncedContentChecksum: String(repeating: "b", count: 64)
      )
    )
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let http = RecordingHTTPStub { request in
      guard request.url?.path == "/account/session", request.httpMethod == "DELETE" else {
        throw URLError(.unsupportedURL)
      }
      return stubJSONResponse(request, #"{"ok":true}"#)
    }
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      httpClient: http
    )
    let expectedServerURL = try XCTUnwrap(
      AppState.validatedSyncURL(persisted.syncState.serverURL)
    )

    await state.revokeCurrentSyncSession(expectedServerURL: expectedServerURL)

    XCTAssertEqual(state.error, "")
    XCTAssertEqual(state.notice, "This Mac's sync session was revoked.")
    XCTAssertEqual(http.requests.count, 1)
    let request = try XCTUnwrap(http.requests.first)
    XCTAssertEqual(request.url?.path, "/account/session")
    XCTAssertEqual(request.httpMethod, "DELETE")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "authorization"),
      "Bearer revoke-session-token"
    )
    XCTAssertNil(request.value(forHTTPHeaderField: "x-address-atlas-confirm"))
    XCTAssertEqual(state.document.syncState.accountId, accountId)
    XCTAssertEqual(state.document.syncState.sessionToken, "")
    XCTAssertEqual(state.document.syncState.latestRemoteVersion, 7)
    XCTAssertEqual(state.document.syncState.lastChecksum, String(repeating: "a", count: 64))
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    let reloaded = try verifier.load()
    XCTAssertEqual(reloaded.wallets.map(\.label), ["Local"])
    XCTAssertEqual(reloaded.syncState.accountId, accountId)
    XCTAssertEqual(reloaded.syncState.sessionToken, "")
    XCTAssertEqual(reloaded.syncState.latestRemoteVersion, 7)
  }

  func testDeletingSyncAccountUsesConfirmedEndpointAndKeepsLocalVault() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let wallet = WalletRecord(label: "Kept locally", address: "0x456", chainKind: .evm)
    let document = VaultDocument(
      wallets: [wallet],
      syncState: SyncState(
        accountId: "34343434-3434-4434-8434-343434343434",
        serverURL: "https://sync.example",
        sessionToken: "delete-session-token",
        latestRemoteVersion: 12,
        lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastChecksum: String(repeating: "c", count: 64),
        lastSyncedContentChecksum: String(repeating: "d", count: 64)
      )
    )
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    _ = try fixture.store.saveRollbackCheckpoint(persisted)
    let authenticator = StubPasskeyAuthenticator(
      session: PasskeyWebSession(
        userId: "34343434-3434-4434-8434-343434343434",
        sessionToken: "fresh-delete-session-token",
        serverURL: "https://sync.example"
      )
    )
    let endpointClient = CountingEndpointConfigClient(
      config: NativeEndpointConfig(
        configVersion: 99,
        refreshAfterSeconds: 300,
        minSupportedAppVersion: "999.0.0"
      )
    )
    let http = RecordingHTTPStub { request in
      guard request.url?.path == "/account", request.httpMethod == "DELETE" else {
        throw URLError(.unsupportedURL)
      }
      return stubJSONResponse(request, #"{"ok":true}"#)
    }
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: endpointClient,
      httpClient: http,
      passkeyAuthenticator: authenticator
    )
    XCTAssertTrue(state.hasVaultRollbackCheckpoint)
    let expectedServerURL = try XCTUnwrap(
      AppState.validatedSyncURL(persisted.syncState.serverURL)
    )

    await state.deleteSyncAccount(expectedServerURL: expectedServerURL)

    XCTAssertEqual(state.error, "")
    XCTAssertTrue(state.notice.hasPrefix("Sync account deleted."))
    XCTAssertTrue(state.notice.contains("rollback point was removed"))
    XCTAssertFalse(state.hasVaultRollbackCheckpoint)
    XCTAssertEqual(http.requests.count, 1)
    let request = try XCTUnwrap(http.requests.first)
    XCTAssertEqual(request.url?.path, "/account")
    XCTAssertEqual(request.httpMethod, "DELETE")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "authorization"),
      "Bearer fresh-delete-session-token"
    )
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "x-address-atlas-confirm"),
      "delete-account"
    )
    let operationKey = try XCTUnwrap(
      request.value(forHTTPHeaderField: "Idempotency-Key")
    )
    XCTAssertEqual(operationKey.count, 43)
    XCTAssertEqual(AccountDeletionIdempotencyKey.normalized(operationKey), operationKey)
    XCTAssertEqual(authenticator.callCount, 1)
    XCTAssertEqual(authenticator.lastMode, .authenticate)
    let endpointRequestCount = await endpointClient.requestCount
    XCTAssertEqual(endpointRequestCount, 0)
    XCTAssertEqual(state.document.wallets.map(\.id), [wallet.id])
    XCTAssertNil(state.document.syncState.accountId)
    XCTAssertEqual(state.document.syncState.serverURL, "https://sync.example")
    XCTAssertEqual(state.document.syncState.sessionToken, "")
    XCTAssertEqual(state.document.syncState.latestRemoteVersion, 0)
    XCTAssertNil(state.document.syncState.lastSyncedAt)
    XCTAssertNil(state.document.syncState.lastChecksum)
    XCTAssertNil(state.document.syncState.lastSyncedContentChecksum)
    XCTAssertNil(state.document.syncState.accountDeletionIdempotencyKey)
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    let reloaded = try verifier.load()
    XCTAssertEqual(reloaded.wallets.map(\.id), [wallet.id])
    XCTAssertNil(reloaded.syncState.accountId)
    XCTAssertEqual(reloaded.syncState.serverURL, "https://sync.example")
    XCTAssertEqual(reloaded.syncState.latestRemoteVersion, 0)
    XCTAssertNil(reloaded.syncState.accountDeletionIdempotencyKey)
    XCTAssertFalse(try verifier.containsRollbackCheckpoint())

    await state.restoreVaultRollbackCheckpoint()
    XCTAssertEqual(state.error, "No local rollback checkpoint is available.")
    XCTAssertNil(state.document.syncState.accountId)
    XCTAssertTrue(state.document.syncState.sessionToken.isEmpty)
  }

  func testUncertainAccountDeletionReplaysPersistedOperationWithoutAnotherPasskey()
    async throws
  {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let accountId = "45454545-4545-4545-8545-454545454545"
    let document = VaultDocument(
      syncState: SyncState(
        accountId: accountId,
        serverURL: "https://sync.example",
        sessionToken: "older-sync-session"
      )
    )
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let authenticator = StubPasskeyAuthenticator(
      session: PasskeyWebSession(
        userId: accountId,
        sessionToken: "fresh-delete-session",
        serverURL: "https://sync.example"
      )
    )
    let attempts = DeletionAttemptCounter()
    let http = RecordingHTTPStub { request in
      let attempt = await attempts.next()
      if attempt == 1 {
        throw URLError(.timedOut)
      }
      return stubJSONResponse(request, #"{"ok":true}"#)
    }
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      httpClient: http,
      passkeyAuthenticator: authenticator
    )
    let expectedServerURL = try XCTUnwrap(
      AppState.validatedSyncURL(persisted.syncState.serverURL)
    )

    await state.deleteSyncAccount(expectedServerURL: expectedServerURL)

    let pendingKey = try XCTUnwrap(
      state.document.syncState.accountDeletionIdempotencyKey
    )
    XCTAssertEqual(AccountDeletionIdempotencyKey.normalized(pendingKey), pendingKey)
    XCTAssertEqual(state.document.syncState.accountId, accountId)
    XCTAssertEqual(authenticator.callCount, 1)
    let verifierAfterTimeout = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(
      try verifierAfterTimeout.load().syncState.accountDeletionIdempotencyKey,
      pendingKey
    )

    await state.deleteSyncAccount(expectedServerURL: expectedServerURL)

    XCTAssertEqual(state.error, "")
    XCTAssertNil(state.document.syncState.accountId)
    XCTAssertNil(state.document.syncState.accountDeletionIdempotencyKey)
    XCTAssertEqual(authenticator.callCount, 1)
    XCTAssertEqual(http.requests.count, 2)
    XCTAssertEqual(
      http.requests.map { $0.value(forHTTPHeaderField: "Idempotency-Key") },
      [pendingKey, pendingKey]
    )
  }

  func testPendingDeletionReceiptReplaysWithoutBearerOrPasskey() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let operationKey = Base64URL.encode(Data(repeating: 0x6B, count: 32))
    let document = VaultDocument(
      syncState: SyncState(
        accountId: "67676767-6767-4676-8676-676767676767",
        serverURL: "https://sync.example",
        sessionToken: "",
        accountDeletionIdempotencyKey: operationKey
      )
    )
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let authenticator = RecordingPasskeyAuthenticator()
    let http = RecordingHTTPStub { request in
      XCTAssertNil(request.value(forHTTPHeaderField: "authorization"))
      XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), operationKey)
      return stubJSONResponse(request, #"{"ok":true}"#)
    }
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      httpClient: http,
      passkeyAuthenticator: authenticator
    )
    let expectedServerURL = try XCTUnwrap(
      AppState.validatedSyncURL(persisted.syncState.serverURL)
    )

    await state.deleteSyncAccount(expectedServerURL: expectedServerURL)

    XCTAssertEqual(state.error, "")
    XCTAssertNil(state.document.syncState.accountId)
    XCTAssertEqual(authenticator.callCount, 0)
  }

  func testCompletedSessionRevocationClearsMemoryAndBlocksEditsWhenLocalSaveFails() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let document = VaultDocument(
      syncState: SyncState(
        accountId: "56565656-5656-4565-8565-565656565656",
        serverURL: "https://sync.example",
        sessionToken: "revoked-server-token"
      )
    )
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      httpClient: RecordingHTTPStub { request in
        stubJSONResponse(request, #"{"ok":true}"#)
      }
    )
    let winningStore = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    var externalWinner = try winningStore.load()
    externalWinner.preferences.hideDust.toggle()
    try winningStore.save(externalWinner)
    let expectedServerURL = try XCTUnwrap(
      AppState.validatedSyncURL(persisted.syncState.serverURL)
    )

    await state.revokeCurrentSyncSession(expectedServerURL: expectedServerURL)

    XCTAssertEqual(state.document.syncState.sessionToken, "")
    XCTAssertTrue(state.syncPersistencePending)
    XCTAssertTrue(state.vaultEditsDisabled)
    XCTAssertTrue(
      state.error.hasPrefix(
        "The server session was revoked, but removing its local token is pending persistence."
      )
    )
    let reloaded = try winningStore.load()
    XCTAssertEqual(reloaded.syncState.sessionToken, "revoked-server-token")
  }

  func testExplicitDisconnectRevokesThisMacAndDiscardsOldAccountRollbackPoint() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let wallet = WalletRecord(label: "Kept locally", address: "0x789", chainKind: .evm)
    let document = VaultDocument(
      wallets: [wallet],
      syncState: SyncState(
        accountId: "78787878-7878-4878-8878-787878787878",
        serverURL: "https://sync.example",
        sessionToken: "switch-session-token",
        latestRemoteVersion: 17,
        lastChecksum: String(repeating: "a", count: 64),
        lastSyncedContentChecksum: String(repeating: "b", count: 64)
      )
    )
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    _ = try fixture.store.saveRollbackCheckpoint(persisted)
    XCTAssertTrue(try fixture.store.containsRollbackCheckpoint())
    let http = RecordingHTTPStub { request in
      guard request.url?.path == "/account/session", request.httpMethod == "DELETE" else {
        throw URLError(.unsupportedURL)
      }
      return stubJSONResponse(request, #"{"ok":true}"#)
    }
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      httpClient: http
    )
    XCTAssertTrue(state.hasVaultRollbackCheckpoint)
    let expectedServerURL = try XCTUnwrap(
      AppState.validatedSyncURL(persisted.syncState.serverURL)
    )

    await state.disconnectSyncAccountForSwitch(expectedServerURL: expectedServerURL)

    XCTAssertEqual(state.error, "")
    XCTAssertTrue(state.notice.contains("disconnected from the sync account"))
    XCTAssertNil(state.syncActivity)
    XCTAssertFalse(state.hasVaultRollbackCheckpoint)
    XCTAssertEqual(http.requests.count, 1)
    XCTAssertEqual(
      http.requests.first?.value(forHTTPHeaderField: "authorization"),
      "Bearer switch-session-token"
    )
    XCTAssertEqual(state.document.wallets.map(\.id), [wallet.id])
    XCTAssertNil(state.document.syncState.accountId)
    XCTAssertEqual(state.document.syncState.serverURL, expectedServerURL.absoluteString)
    XCTAssertTrue(state.document.syncState.sessionToken.isEmpty)
    XCTAssertEqual(state.document.syncState.latestRemoteVersion, 0)
    XCTAssertNil(state.document.syncState.lastChecksum)
    XCTAssertNil(state.document.syncState.lastSyncedContentChecksum)

    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    let reloaded = try verifier.load()
    XCTAssertEqual(reloaded.wallets.map(\.id), [wallet.id])
    XCTAssertNil(reloaded.syncState.accountId)
    XCTAssertEqual(reloaded.syncState.serverURL, expectedServerURL.absoluteString)
    XCTAssertEqual(reloaded.syncState.latestRemoteVersion, 0)
    XCTAssertFalse(try verifier.containsRollbackCheckpoint())

    await state.restoreVaultRollbackCheckpoint()
    XCTAssertEqual(state.error, "No local rollback checkpoint is available.")
    XCTAssertNil(state.document.syncState.accountId)
    XCTAssertTrue(state.document.syncState.sessionToken.isEmpty)
  }

}
