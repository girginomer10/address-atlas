import AddressAtlasCore
import Foundation
import XCTest
@testable import AddressAtlasMac

private actor TestCloud: ICloudVaultSyncing {
  var stored: VaultDocument
  let failure: Bool
  init(_ stored: VaultDocument = VaultDocument(), failure: Bool = false) {
    self.stored = stored
    self.failure = failure
  }
  func save(_ document: VaultDocument, localKey: Data) throws -> ICloudVaultState {
    if failure { throw ICloudVaultError.conflict }
    stored = document
    return ICloudVaultState(account: "test-account", revision: "test-revision")
  }
  func restore(localKey: Data, expectedAccount: String?) throws -> VaultDocument {
    if failure { throw ICloudVaultError.missingKey }
    var result = stored
    result.iCloudState = ICloudVaultState(account: "test-account", revision: "test-revision")
    return result
  }
  func delete(expectedAccount: String?) throws {
    if failure { throw ICloudVaultError.accountChanged }
    stored = VaultDocument()
  }
}

@MainActor
final class ICloudWorkflowTests: XCTestCase {
  private func fixture(_ document: VaultDocument = VaultDocument()) throws -> AppState {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let key = try VaultCrypto().generateVaultKey()
    let store = try EncryptedSQLiteVaultStore(path: directory.appendingPathComponent("vault.sqlite"), vaultKey: key)
    _ = try store.load()
    let persisted = try store.saveReturningPersistedDocument(document)
    let state = AppState(testStore: store, document: persisted, testVaultKey: key)
    state.legacyServerSyncEnabled = false
    return state
  }

  func testSavePersistsReceiptAndRetiresServerBinding() async throws {
    let state = try fixture()
    state.iCloudService = TestCloud()
    await state.saveToICloud()
    XCTAssertEqual(state.document.iCloudState?.revision, "test-revision")
    XCTAssertEqual(state.document.syncState, SyncState())
    XCTAssertFalse(state.syncing)
    let saved = try await state.persistence!.load()
    XCTAssertEqual(saved.document.iCloudState, state.document.iCloudState)
  }

  func testConflictAndMissingKeyKeepLocalPortfolio() async throws {
    let state = try fixture()
    let before = state.document
    state.iCloudService = TestCloud(failure: true)
    await state.saveToICloud()
    XCTAssertEqual(state.document, before)
    XCTAssertTrue(state.error.contains("changed on another Mac"))
    await state.restoreFromICloud()
    XCTAssertEqual(state.document, before)
    XCTAssertTrue(state.error.contains("Keychain"))
    XCTAssertFalse(state.syncing)
  }

  func testRestoreCreatesRecoverableLocalRollback() async throws {
    var old = VaultDocument()
    old.preferences.hideDust = false
    var incoming = old
    incoming.preferences.hideDust = true
    let state = try fixture(old)
    state.iCloudService = TestCloud(incoming)
    await state.restoreFromICloud()
    XCTAssertTrue(state.document.preferences.hideDust)
    XCTAssertTrue(state.hasVaultRollbackCheckpoint)
    await state.restoreVaultRollbackCheckpoint()
    XCTAssertFalse(state.document.preferences.hideDust)
    XCTAssertEqual(state.document.iCloudState?.revision, "test-revision")
    XCTAssertFalse(state.syncing)
  }

  func testDeleteAndResetKeepLocalPortfolio() async throws {
    var document = VaultDocument()
    document.preferences.hideDust = false
    document.iCloudState = ICloudVaultState(account: "test-account", revision: "r")
    let state = try fixture(document)
    state.iCloudService = TestCloud()
    await state.deleteICloudCopy()
    XCTAssertNil(state.document.iCloudState)
    XCTAssertFalse(state.document.preferences.hideDust)
  }

  func testDefaultAppHasNoLegacyEndpointNetworkPath() async {
    let state = AppState()
    state.document.syncState.serverURL = "https://retired.example"
    XCTAssertFalse(state.legacyServerSyncEnabled)
    let accepted = await state.refreshEndpointConfig()
    XCTAssertFalse(accepted)
    XCTAssertNil(state.endpointConfigRefreshRequest)
  }

  func testCloudOperationsRespectActiveEdits() async throws {
    let state = try fixture()
    state.iCloudService = TestCloud()
    state.scanning = true
    await state.saveToICloud()
    XCTAssertNil(state.document.iCloudState)
    XCTAssertFalse(state.syncing)
  }
}
