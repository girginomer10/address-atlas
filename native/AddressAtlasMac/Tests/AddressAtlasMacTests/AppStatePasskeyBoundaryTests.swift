import AddressAtlasCore
import Foundation
import XCTest

@testable import AddressAtlasMac

@MainActor
extension AppStateNetworkBoundaryTests {
  func testPasskeyBindingRejectsVisibleButNotDurableEndpointTrust() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let accountId = "18181818-1818-4818-8818-181818181818"
    let authenticator = StubPasskeyAuthenticator(
      session: PasskeyWebSession(
        userId: accountId,
        sessionToken: "uncertain-trust-session",
        serverURL: "https://sync.example"
      )
    )
    let state = AppState(
      testStore: fixture.store,
      document: VaultDocument(),
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 30, refreshAfterSeconds: 300)
      ),
      endpointConfigTrustStore: ScriptedEndpointConfigTrustStore([
        .committedDurabilityUncertain
      ]),
      passkeyAuthenticator: authenticator
    )

    await state.createPasskeyAccount(serverURL: "https://sync.example")

    XCTAssertEqual(authenticator.callCount, 1)
    XCTAssertNil(state.document.syncState.accountId)
    XCTAssertTrue(state.document.syncState.sessionToken.isEmpty)
    XCTAssertEqual(state.endpointConfig, .bundled)
    XCTAssertFalse(state.endpointConfigTrustDurabilityDegraded)
    XCTAssertTrue(state.error.contains("crash-durability check failed"))
  }

  func testIntentionalPasskeyCancellationIsNeutralAndDoesNotChangeVault() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let state = AppState(
      testStore: fixture.store,
      document: VaultDocument(),
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
      ),
      passkeyAuthenticator: CancelledPasskeyAuthenticator()
    )

    await state.createPasskeyAccount(serverURL: "https://sync.example")

    XCTAssertEqual(state.error, "")
    XCTAssertEqual(state.notice, "Passkey sign-in cancelled.")
    XCTAssertNil(state.document.syncState.accountId)
    XCTAssertTrue(state.document.syncState.sessionToken.isEmpty)
    XCTAssertEqual(state.endpointConfig, .bundled)
    XCTAssertEqual(state.endpointConfigStatus, "Bundled endpoints")
    XCTAssertNil(state.acceptedEndpointConfigServerURL)
  }

  func testCancelledVersion20CandidateDoesNotBlockLegitimateVersion19AfterRelaunch()
    async throws
  {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let server = URL(string: "https://sync.example")!
    let trustFile = fixture.directory.appending(path: "endpoint-config-trust.json")
    let cancelledState = AppState(
      testStore: fixture.store,
      document: VaultDocument(),
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 20, refreshAfterSeconds: 300)
      ),
      endpointConfigTrustStore: EndpointConfigTrustStore(fileURL: trustFile),
      passkeyAuthenticator: CancelledPasskeyAuthenticator()
    )

    await cancelledState.createPasskeyAccount(serverURL: server.absoluteString)

    XCTAssertEqual(cancelledState.notice, "Passkey sign-in cancelled.")
    XCTAssertFalse(FileManager.default.fileExists(atPath: trustFile.path))

    let accountId = "19191919-1919-4919-8919-191919191919"
    let relaunchedState = AppState(
      testStore: fixture.store,
      document: VaultDocument(),
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 19, refreshAfterSeconds: 300)
      ),
      endpointConfigTrustStore: EndpointConfigTrustStore(fileURL: trustFile),
      passkeyAuthenticator: StubPasskeyAuthenticator(
        session: PasskeyWebSession(
          userId: accountId,
          sessionToken: "version-19-session",
          serverURL: server.absoluteString
        )
      )
    )

    await relaunchedState.createPasskeyAccount(serverURL: server.absoluteString)

    XCTAssertEqual(relaunchedState.error, "")
    XCTAssertEqual(relaunchedState.document.syncState.accountId, accountId)
    XCTAssertEqual(relaunchedState.endpointConfig.configVersion, 19)
    do {
      try await EndpointConfigTrustStore(fileURL: trustFile).validate(
        NativeEndpointConfig(configVersion: 18, refreshAfterSeconds: 300),
        for: server
      )
      XCTFail("Expected the authenticated version 19 policy to be durable")
    } catch {
      XCTAssertEqual(
        error as? EndpointConfigTrustStoreError,
        .rollback(previous: 19, received: 18)
      )
    }
  }

  func testUnsupportedAppVersionStopsPasskeyCeremonyBeforeAuthentication() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let authenticator = RecordingPasskeyAuthenticator()
    let state = AppState(
      testStore: fixture.store,
      document: VaultDocument(),
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(
          configVersion: 40,
          refreshAfterSeconds: 300,
          minSupportedAppVersion: "999.0"
        )
      ),
      passkeyAuthenticator: authenticator
    )

    await state.createPasskeyAccount(serverURL: "https://sync.example")

    XCTAssertEqual(authenticator.callCount, 0)
    XCTAssertNil(state.document.syncState.accountId)
    XCTAssertTrue(state.error.contains("no longer supported"))
    XCTAssertEqual(state.endpointConfig, .bundled)
    XCTAssertEqual(state.endpointConfigStatus, "Bundled endpoints")
    XCTAssertNil(state.acceptedEndpointConfigServerURL)
  }

  func testDurableVersion20HighWaterRejectsVersion19BeforePasskeyCeremony() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let server = URL(string: "https://sync.example")!
    let trustFile = fixture.directory.appending(path: "endpoint-config-trust.json")
    try await EndpointConfigTrustStore(fileURL: trustFile).validateAndRecord(
      NativeEndpointConfig(configVersion: 20, refreshAfterSeconds: 300),
      for: server
    )
    let authenticator = RecordingPasskeyAuthenticator()
    let state = AppState(
      testStore: fixture.store,
      document: VaultDocument(),
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 19, refreshAfterSeconds: 300)
      ),
      endpointConfigTrustStore: EndpointConfigTrustStore(fileURL: trustFile),
      passkeyAuthenticator: authenticator
    )

    await state.createPasskeyAccount(serverURL: server.absoluteString)

    XCTAssertEqual(authenticator.callCount, 0)
    XCTAssertNil(state.document.syncState.accountId)
    XCTAssertTrue(state.document.syncState.sessionToken.isEmpty)
    XCTAssertTrue(state.error.contains("compatibility policy could not be verified"))
  }

  func testConnectedAccountRejectsImplicitPasskeyServerSwitchBeforeAuthentication() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let existingServer = URL(string: "https://existing.example")!
    let existingConfig = NativeEndpointConfig(
      configVersion: 12,
      refreshAfterSeconds: 600,
      message: "Existing authority"
    )
    let document = VaultDocument(
      syncState: SyncState(
        accountId: "abababab-abab-4bab-8bab-abababababab",
        serverURL: existingServer.absoluteString,
        sessionToken: "existing-session"
      )
    )
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let authenticator = RecordingPasskeyAuthenticator()
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 20, refreshAfterSeconds: 300)
      ),
      passkeyAuthenticator: authenticator
    )
    state.endpointConfig = existingConfig
    state.endpointConfigStatus = "Remote v12"
    state.acceptedEndpointConfigServerURL = existingServer

    await state.signInWithPasskey(serverURL: "https://candidate.example")

    XCTAssertEqual(authenticator.callCount, 0)
    XCTAssertTrue(state.error.contains("Disconnect it explicitly"))
    XCTAssertEqual(state.document.syncState.serverURL, existingServer.absoluteString)
    XCTAssertEqual(state.document.syncState.sessionToken, "existing-session")
    XCTAssertEqual(state.endpointConfig, existingConfig)
    XCTAssertEqual(state.endpointConfigStatus, "Remote v12")
    XCTAssertEqual(state.acceptedEndpointConfigServerURL, existingServer)
    XCTAssertEqual(state.operatorMessage, "Existing authority")
  }

  func testConnectedAccountRejectsDifferentReturnedAccountWithoutChangingBaseline() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let originalAccount = "abababab-abab-4bab-8bab-abababababab"
    let server = URL(string: "https://sync.example")!
    var document = VaultDocument()
    XCTAssertTrue(
      document.syncState.connect(
        accountId: originalAccount,
        serverURL: server.absoluteString,
        sessionToken: "original-session-token"
      )
    )
    document.syncState.latestRemoteVersion = 7
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let authenticator = StubPasskeyAuthenticator(
      session: PasskeyWebSession(
        userId: "cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd",
        sessionToken: "different-account-session",
        serverURL: server.absoluteString
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

    await state.signInWithPasskey(serverURL: server.absoluteString)

    XCTAssertEqual(authenticator.callCount, 1)
    XCTAssertTrue(state.error.contains("different sync account"))
    XCTAssertEqual(state.document.syncState.accountId, originalAccount)
    XCTAssertEqual(state.document.syncState.sessionToken, "original-session-token")
    XCTAssertEqual(state.document.syncState.latestRemoteVersion, 7)
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(try verifier.load().syncState.accountId, originalAccount)
  }

  func testConnectedAccountRejectsRegistrationAndServerSaveUntilExplicitDisconnect() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var document = VaultDocument()
    XCTAssertTrue(
      document.syncState.connect(
        accountId: "abababab-abab-4bab-8bab-abababababab",
        serverURL: "https://sync.example",
        sessionToken: "connected-session-token"
      )
    )
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let authenticator = RecordingPasskeyAuthenticator()
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
      ),
      passkeyAuthenticator: authenticator
    )

    await state.createPasskeyAccount(serverURL: "https://sync.example")
    let saved = await state.saveSyncSettings(serverURL: "https://other.example")

    XCTAssertEqual(authenticator.callCount, 0)
    XCTAssertFalse(saved)
    XCTAssertEqual(state.document.syncState.serverURL, "https://sync.example")
    XCTAssertEqual(
      state.document.syncState.accountId,
      "abababab-abab-4bab-8bab-abababababab"
    )
    XCTAssertTrue(state.error.contains("Disconnect the current sync account"))
  }

  func testCancelledSameServerReauthenticationDoesNotPublishStagedPolicy() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let server = URL(string: "https://sync.example")!
    let existingConfig = NativeEndpointConfig(configVersion: 14, refreshAfterSeconds: 600)
    let document = VaultDocument(
      syncState: SyncState(
        accountId: "cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd",
        serverURL: server.absoluteString,
        sessionToken: "same-server-session"
      )
    )
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 15, refreshAfterSeconds: 300)
      ),
      passkeyAuthenticator: CancelledPasskeyAuthenticator()
    )
    state.endpointConfig = existingConfig
    state.endpointConfigStatus = "Remote v14"
    state.acceptedEndpointConfigServerURL = server

    await state.signInWithPasskey(serverURL: server.absoluteString)

    XCTAssertEqual(state.endpointConfig, existingConfig)
    XCTAssertEqual(state.endpointConfigStatus, "Remote v14")
    XCTAssertEqual(state.acceptedEndpointConfigServerURL, server)
  }

  func testPasskeyAuthenticationInstallsSessionAndPublishesOperatorMessage() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let accountId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let authenticator = StubPasskeyAuthenticator(
      session: PasskeyWebSession(
        userId: accountId,
        sessionToken: "passkey-session-token",
        serverURL: "https://sync.example"
      )
    )
    let state = AppState(
      testStore: fixture.store,
      document: VaultDocument(),
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(
          configVersion: 9,
          refreshAfterSeconds: 300,
          message: "Welcome to the sync beta."
        )
      ),
      passkeyAuthenticator: authenticator
    )

    await state.createPasskeyAccount(serverURL: "https://sync.example")

    XCTAssertEqual(state.error, "")
    XCTAssertTrue(state.notice.hasPrefix("Passkey account connected."))
    XCTAssertEqual(state.document.syncState.accountId, accountId)
    XCTAssertEqual(state.document.syncState.sessionToken, "passkey-session-token")
    XCTAssertEqual(state.endpointConfig.configVersion, 9)
    XCTAssertEqual(state.endpointConfigStatus, "Remote v9")
    XCTAssertEqual(
      state.acceptedEndpointConfigServerURL,
      URL(string: "https://sync.example")
    )
    XCTAssertEqual(state.operatorMessage, "Welcome to the sync beta.")
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(try verifier.load().syncState.accountId, accountId)
  }

  func testPendingUploadCanReauthenticateSameAccountAndRecoverWithoutOrdinarySave()
    async throws
  {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let server = URL(string: "https://sync.example")!
    let accountId = "78787878-7878-4878-8878-787878787878"
    var document = VaultDocument()
    XCTAssertTrue(
      document.syncState.connect(
        accountId: accountId,
        serverURL: server.absoluteString,
        sessionToken: "expired-upload-session"
      )
    )
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let interruptedHTTP = RecordingHTTPStub { request in
      if request.httpMethod == "GET" {
        return stubJSONResponse(request, #"{"error":"vault not found"}"#, statusCode: 404)
      }
      throw URLError(.timedOut)
    }
    let interruptedState = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
      ),
      httpClient: interruptedHTTP
    )

    await interruptedState.uploadEncryptedVault(expectedServerURL: server)

    let pendingUpload = try XCTUnwrap(fixture.store.loadPendingVaultUpload())
    XCTAssertTrue(interruptedState.syncPersistencePending)
    let snapshotData = try JSONEncoder.addressAtlas.encode(pendingUpload.snapshot)
    let recoveryHTTP = RecordingHTTPStub { request in
      guard request.httpMethod == "GET", request.url?.path == "/vault/latest" else {
        throw URLError(.unsupportedURL)
      }
      return (snapshotData, stubHTTPResponse(request))
    }
    let authenticator = StubPasskeyAuthenticator(
      session: PasskeyWebSession(
        userId: accountId,
        sessionToken: "fresh-recovery-session",
        serverURL: server.absoluteString
      )
    )
    let relaunchedState = AppState(
      testStore: fixture.store,
      document: try fixture.store.load(),
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 10, refreshAfterSeconds: 300)
      ),
      httpClient: recoveryHTTP,
      passkeyAuthenticator: authenticator
    )

    await relaunchedState.signInWithPasskey(serverURL: "https://other.example")

    XCTAssertEqual(authenticator.callCount, 0)
    XCTAssertTrue(relaunchedState.syncPersistencePending)
    XCTAssertTrue(recoveryHTTP.requests.isEmpty)

    await relaunchedState.signInWithPasskey(serverURL: server.absoluteString)

    XCTAssertEqual(authenticator.callCount, 1)
    XCTAssertFalse(relaunchedState.syncPersistencePending)
    XCTAssertNil(relaunchedState.pendingVaultUpload)
    XCTAssertEqual(relaunchedState.error, "")
    XCTAssertEqual(relaunchedState.notice, "Interrupted encrypted vault upload recovered.")
    XCTAssertEqual(recoveryHTTP.requests.map(\.httpMethod), ["GET"])
    XCTAssertEqual(relaunchedState.endpointConfig.configVersion, 10)
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    let recovered = try verifier.load()
    XCTAssertEqual(recovered.syncState.accountId, accountId)
    XCTAssertEqual(recovered.syncState.serverURL, server.absoluteString)
    XCTAssertEqual(recovered.syncState.sessionToken, "fresh-recovery-session")
    XCTAssertEqual(recovered.syncState.latestRemoteVersion, pendingUpload.snapshot.version)
    XCTAssertNil(try verifier.loadPendingVaultUpload())
  }

}
