import AddressAtlasCore
import Foundation
import XCTest

@testable import AddressAtlasMac

@MainActor
extension AppStateNetworkBoundaryTests {
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
    XCTAssertEqual(state.endpointConfigStatus, "Update required")
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
    XCTAssertEqual(state.operatorMessage, "Welcome to the sync beta.")
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(try verifier.load().syncState.accountId, accountId)
  }

}
