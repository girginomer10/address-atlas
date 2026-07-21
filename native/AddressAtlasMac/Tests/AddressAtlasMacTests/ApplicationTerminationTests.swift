import AddressAtlasCore
import AppKit
import XCTest

@testable import AddressAtlasMac

@MainActor
final class ApplicationTerminationTests: XCTestCase {
  func testTerminationCandidateNormalizesDraftsDeterministically() throws {
    let wallet = WalletRecord(
      label: "Treasury",
      address: "0x0000000000000000000000000000000000000001",
      chainKind: .evm
    )
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    let candidate = try AppState.documentByApplyingWalletLabelDrafts(
      [wallet.id: "  Family Treasury  "],
      to: VaultDocument(wallets: [wallet]),
      updatedAt: timestamp
    )

    XCTAssertEqual(candidate.wallets[0].label, "Family Treasury")
    XCTAssertEqual(candidate.wallets[0].updatedAt, timestamp)
    XCTAssertThrowsError(
      try AppState.documentByApplyingWalletLabelDrafts(
        [wallet.id: " \n "],
        to: VaultDocument(wallets: [wallet]),
        updatedAt: timestamp
      )
    ) { error in
      XCTAssertEqual(error as? WalletLabelDraftError, .invalidLabel(wallet.id))
    }
  }

  func testJsonExportCapturesVisibleWalletLabelDraftBeforeFocusLossCommit() throws {
    let wallet = WalletRecord(
      label: "Treasury",
      address: "0x0000000000000000000000000000000000000001",
      chainKind: .evm
    )
    let state = AppState()
    state.document = VaultDocument(wallets: [wallet])
    XCTAssertTrue(state.setWalletLabelDraft(id: wallet.id, label: "Visible Draft"))

    let payload = ExportPayload.json(try state.documentForExportIncludingWalletLabelDrafts())
    let data = try ExportPipeline.data(for: payload)
    let exported = try JSONDecoder.addressAtlas.decode(VaultDocument.self, from: data)

    XCTAssertEqual(exported.wallets.first?.label, "Visible Draft")
    XCTAssertEqual(state.document.wallets.first?.label, "Treasury")
    XCTAssertEqual(state.walletLabelDrafts[wallet.id], "Visible Draft")
  }

  func testCsvExportOverlaysVisibleWalletLabelDraftWithoutMutatingSourceState() throws {
    let wallet = WalletRecord(
      label: "Treasury",
      address: "0x0000000000000000000000000000000000000001",
      chainKind: .evm
    )
    let holding = TrackedAsset(
      id: "ethereum:wallet:eth",
      address: wallet.address,
      chainId: "ethereum",
      chainName: "Ethereum",
      family: .evm,
      symbol: "ETH",
      name: "Ether",
      amount: 1,
      priceUsd: 2_000,
      valueUsd: 2_000,
      source: .native,
      walletLabel: wallet.label
    )
    let sourceDocument = VaultDocument(
      wallets: [wallet],
      scanRuns: [
        ScanRunRecord(totalUsd: 2_000, inputCount: 1, holdings: [holding])
      ]
    )
    let state = AppState()
    state.document = sourceDocument
    XCTAssertTrue(state.setWalletLabelDraft(id: wallet.id, label: "Visible Draft"))

    let exportHoldings = try state.holdingsForExportIncludingWalletLabelDrafts()
    let csv = try AddressAtlasExporter.csv(for: exportHoldings)

    XCTAssertEqual(exportHoldings.first?.walletLabel, "Visible Draft")
    XCTAssertTrue(csv.contains("Visible Draft,Ethereum,ETH"))
    XCTAssertEqual(state.document, sourceDocument)
    XCTAssertEqual(state.latestScan?.holdings.first?.walletLabel, "Treasury")
    XCTAssertEqual(state.walletLabelDrafts[wallet.id], "Visible Draft")
  }

  func testSuccessfulTerminationFlushPersistsAndClearsLifecycleDraft() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let wallet = WalletRecord(
      label: "Treasury",
      address: "0x0000000000000000000000000000000000000001",
      chainKind: .evm
    )
    let state = AppState(
      testStore: fixture.store,
      document: VaultDocument(wallets: [wallet])
    )
    XCTAssertTrue(state.setWalletLabelDraft(id: wallet.id, label: "  Family Treasury  "))

    let shouldTerminate = await state.prepareForTermination()

    XCTAssertTrue(shouldTerminate)
    XCTAssertTrue(state.isTerminationInProgress)
    XCTAssertTrue(state.walletLabelDrafts.isEmpty)
    XCTAssertEqual(state.document.wallets[0].label, "Family Treasury")
    XCTAssertFalse(state.setWalletLabelDraft(id: wallet.id, label: "Blocked mutation"))
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(try verifier.load().wallets[0].label, "Family Treasury")
  }

  func testDelegateReturnsTerminateLaterAndCancelsWhenDraftSaveFails() async throws {
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
    let state = AppState(testStore: fixture.store, document: persisted)
    XCTAssertTrue(state.setWalletLabelDraft(id: wallet.id, label: "Family Treasury"))

    let competingStore = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    var competingDocument = try competingStore.load()
    competingDocument.preferences.autoRefresh.toggle()
    try competingStore.save(competingDocument)

    let delegate = AddressAtlasApplicationDelegate(state: state)
    let recorder = TerminationReplyRecorder()
    let immediateReply = delegate.requestTermination { result in
      recorder.record(result)
    }

    XCTAssertEqual(immediateReply, .terminateLater)
    let delegateReply = await recorder.waitForReply()
    XCTAssertFalse(delegateReply)
    XCTAssertFalse(state.isTerminationInProgress)
    XCTAssertEqual(state.walletLabelDrafts[wallet.id], "Family Treasury")
    XCTAssertTrue(state.error.contains("could not save the wallet label before quitting"))
    XCTAssertEqual(try competingStore.load().wallets[0].label, "Treasury")
  }

  func testTerminationWaitsForInFlightPersistenceThenFlushesFrozenDraft() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let wallet = WalletRecord(
      label: "Treasury",
      address: "0x0000000000000000000000000000000000000001",
      chainKind: .evm
    )
    let state = AppState(
      testStore: fixture.store,
      document: VaultDocument(wallets: [wallet])
    )
    XCTAssertTrue(state.setWalletLabelDraft(id: wallet.id, label: "Family Treasury"))
    let gate = PersistenceGate()
    state.persistenceStartedHook = {
      await gate.pause()
    }

    let existingSave = Task { @MainActor in
      await state.save()
    }
    await gate.waitUntilPaused()
    XCTAssertTrue(state.isPersisting)
    XCTAssertTrue(state.beginTerminationRequest())

    let termination = Task { @MainActor in
      await state.prepareForTermination()
    }
    for _ in 0..<100 where state.persistenceCompletionWaiters.isEmpty {
      await Task.yield()
    }
    XCTAssertEqual(state.persistenceCompletionWaiters.count, 1)
    XCTAssertFalse(state.setWalletLabelDraft(id: wallet.id, label: "Late mutation"))

    await gate.release()
    let existingSaveSucceeded = await existingSave.value
    let terminationSucceeded = await termination.value
    XCTAssertTrue(existingSaveSucceeded)
    XCTAssertTrue(terminationSucceeded)
    XCTAssertFalse(state.isPersisting)
    XCTAssertTrue(state.isTerminationInProgress)
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(try verifier.load().wallets[0].label, "Family Treasury")
  }

  func testTerminationCancelsWhenInFlightPersistenceFails() async throws {
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
    let state = AppState(testStore: fixture.store, document: persisted)
    XCTAssertTrue(state.setWalletLabelDraft(id: wallet.id, label: "Family Treasury"))
    let gate = PersistenceGate()
    state.persistenceStartedHook = {
      await gate.pause()
    }

    let existingSave = Task { @MainActor in
      await state.save()
    }
    await gate.waitUntilPaused()
    XCTAssertTrue(state.isPersisting)

    let competingStore = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    var competingDocument = try competingStore.load()
    competingDocument.preferences.autoRefresh.toggle()
    try competingStore.save(competingDocument)

    XCTAssertTrue(state.beginTerminationRequest())
    let termination = Task { @MainActor in
      await state.prepareForTermination()
    }
    for _ in 0..<100 where state.persistenceCompletionWaiters.isEmpty {
      await Task.yield()
    }
    XCTAssertEqual(state.persistenceCompletionWaiters.count, 1)

    await gate.release()
    let existingSaveSucceeded = await existingSave.value
    let terminationSucceeded = await termination.value

    XCTAssertFalse(existingSaveSucceeded)
    XCTAssertFalse(terminationSucceeded)
    XCTAssertFalse(state.isPersisting)
    XCTAssertFalse(state.isTerminationInProgress)
    XCTAssertEqual(state.walletLabelDrafts[wallet.id], "Family Treasury")
    XCTAssertTrue(state.error.contains("could not finish the active local save before quitting"))
    XCTAssertEqual(try competingStore.load().wallets[0].label, "Treasury")
  }

  func testTerminationFlushesInMemoryPendingSyncCandidateBeforeQuitting() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let persisted = try fixture.store.saveReturningPersistedDocument(VaultDocument())
    let state = AppState(testStore: fixture.store, document: persisted)
    var pendingCandidate = persisted
    pendingCandidate.preferences.autoRefresh.toggle()
    state.requirePendingSyncPersistence(
      pendingCandidate,
      projectedSyncVersion: 7,
      saveExactly: true
    )

    let shouldTerminate = await state.prepareForTermination()

    XCTAssertTrue(shouldTerminate)
    XCTAssertTrue(state.isTerminationInProgress)
    XCTAssertFalse(state.syncPersistencePending)
    XCTAssertNil(state.pendingSyncPersistence)
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(
      try verifier.load().preferences.autoRefresh,
      pendingCandidate.preferences.autoRefresh
    )
  }

  func testTerminationRetainsPendingSyncCandidateWhenItsFlushFails() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let persisted = try fixture.store.saveReturningPersistedDocument(VaultDocument())
    let state = AppState(testStore: fixture.store, document: persisted)
    var pendingCandidate = persisted
    pendingCandidate.preferences.hideDust.toggle()
    state.requirePendingSyncPersistence(
      pendingCandidate,
      projectedSyncVersion: 9,
      saveExactly: true
    )

    let competingStore = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    var competingDocument = try competingStore.load()
    competingDocument.preferences.autoRefresh.toggle()
    try competingStore.save(competingDocument)

    let shouldTerminate = await state.prepareForTermination()

    XCTAssertFalse(shouldTerminate)
    XCTAssertFalse(state.isTerminationInProgress)
    XCTAssertTrue(state.syncPersistencePending)
    XCTAssertEqual(state.pendingSyncPersistence?.document, pendingCandidate)
    XCTAssertEqual(state.pendingSyncPersistence?.projectedSyncVersion, 9)
    XCTAssertEqual(state.pendingSyncPersistence?.saveExactly, true)
    XCTAssertTrue(state.error.contains("could not save the pending sync state before quitting"))
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(
      try verifier.load().preferences.autoRefresh,
      competingDocument.preferences.autoRefresh
    )
  }

  func testTerminationFailsClosedForUnrecoverablePendingSyncFlag() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let state = AppState(testStore: fixture.store, document: VaultDocument())
    state.syncPersistencePending = true

    let shouldTerminate = await state.prepareForTermination()

    XCTAssertFalse(shouldTerminate)
    XCTAssertFalse(state.isTerminationInProgress)
    XCTAssertTrue(state.syncPersistencePending)
    XCTAssertNil(state.pendingSyncPersistence)
    XCTAssertNil(state.pendingVaultUpload)
    XCTAssertTrue(state.error.contains("pending sync state cannot be saved safely"))
  }

  func testTerminationCancelsUntilLifecycleOwnedExportFinishes() async {
    let state = AppState()
    XCTAssertTrue(state.beginExportOperation())
    XCTAssertTrue(state.isExportOperationInProgress)

    let blockedTermination = await state.prepareForTermination()

    XCTAssertFalse(blockedTermination)
    XCTAssertFalse(state.isTerminationInProgress)
    XCTAssertTrue(state.isExportOperationInProgress)
    XCTAssertTrue(state.error.contains("active export"))

    state.finishExportOperation()
    let completedTermination = await state.prepareForTermination()

    XCTAssertTrue(completedTermination)
    XCTAssertTrue(state.isTerminationInProgress)
    XCTAssertFalse(state.isExportOperationInProgress)
  }

  private func makeTemporaryStore() throws -> (
    directory: URL,
    database: URL,
    vaultKey: Data,
    store: EncryptedSQLiteVaultStore
  ) {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = directory.appending(path: "vault.sqlite")
    let vaultKey = try VaultCrypto().generateVaultKey()
    let store = try EncryptedSQLiteVaultStore(path: database, vaultKey: vaultKey)
    _ = try store.load()
    return (directory, database, vaultKey, store)
  }
}

@MainActor
private final class TerminationReplyRecorder {
  private var reply: Bool?
  private var waiter: CheckedContinuation<Bool, Never>?

  func record(_ reply: Bool) {
    self.reply = reply
    waiter?.resume(returning: reply)
    waiter = nil
  }

  func waitForReply() async -> Bool {
    if let reply { return reply }
    return await withCheckedContinuation { continuation in
      waiter = continuation
    }
  }
}

private actor PersistenceGate {
  private var isPaused = false
  private var isReleased = false
  private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiter: CheckedContinuation<Void, Never>?

  func pause() async {
    isPaused = true
    for waiter in pauseWaiters {
      waiter.resume()
    }
    pauseWaiters.removeAll()
    guard !isReleased else { return }
    await withCheckedContinuation { continuation in
      releaseWaiter = continuation
    }
  }

  func waitUntilPaused() async {
    guard !isPaused else { return }
    await withCheckedContinuation { continuation in
      pauseWaiters.append(continuation)
    }
  }

  func release() {
    isReleased = true
    releaseWaiter?.resume()
    releaseWaiter = nil
  }
}
