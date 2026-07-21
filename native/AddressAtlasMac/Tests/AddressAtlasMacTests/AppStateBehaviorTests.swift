import AddressAtlasCore
import XCTest

@testable import AddressAtlasMac

@MainActor
final class AppStateBehaviorTests: XCTestCase {
  func testSyncActivityOwnerPreservesMutualExclusionAndCannotBeClearedByAnotherActivity() {
    let state = AppState()

    XCTAssertFalse(state.syncing)
    XCTAssertTrue(state.beginSyncActivity(.uploadingVault))
    XCTAssertTrue(state.syncing)
    XCTAssertEqual(state.syncActivity, .uploadingVault)
    XCTAssertFalse(state.beginSyncActivity(.downloadingVault))

    state.finishSyncActivity(.downloadingVault)
    XCTAssertEqual(state.syncActivity, .uploadingVault)

    state.finishSyncActivity(.uploadingVault)
    XCTAssertNil(state.syncActivity)
    XCTAssertFalse(state.syncing)
  }

  func testEverySyncActivityHasAUniqueMeaningfulProgressAndAccessibilityLabel() {
    let progressTitles = SyncActivity.allCases.map(\.progressTitle)
    let accessibilityLabels = SyncActivity.allCases.map(\.accessibilityLabel)

    XCTAssertEqual(Set(progressTitles).count, SyncActivity.allCases.count)
    XCTAssertTrue(progressTitles.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    XCTAssertTrue(accessibilityLabels.allSatisfy { $0.hasSuffix(", in progress") })
  }

  func testPasskeyOperationPublishesAndClearsItsTypedActivity() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let authenticator = PausingPasskeyAuthenticator()
    let state = AppState(
      testStore: fixture.store,
      document: VaultDocument(),
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 1, refreshAfterSeconds: 300)
      ),
      passkeyAuthenticator: authenticator
    )
    let server = URL(string: "https://sync.example")!
    let operation = Task {
      await state.createPasskeyAccount(serverURL: server.absoluteString)
    }

    await authenticator.waitUntilStarted()
    XCTAssertEqual(state.syncActivity, .creatingPasskeyAccount)
    XCTAssertTrue(state.syncing)
    XCTAssertFalse(state.beginSyncActivity(.downloadingVault))

    authenticator.complete(
      with: PasskeyWebSession(
        userId: "11111111-1111-4111-8111-111111111111",
        sessionToken: "typed-activity-session",
        serverURL: server.absoluteString
      )
    )
    await operation.value

    XCTAssertNil(state.syncActivity)
    XCTAssertFalse(state.syncing)
    XCTAssertEqual(state.error, "")
  }

  func testNavigationClearsTheSourcePagesTransientNoticeOrError() {
    let state = AppState()

    state.notice = "Saved on the source page."
    state.clearTransientMessagesForNavigation()
    XCTAssertEqual(state.notice, "")
    XCTAssertEqual(state.error, "")

    state.error = "Invalid input on the source page."
    state.clearTransientMessagesForNavigation()
    XCTAssertEqual(state.notice, "")
    XCTAssertEqual(state.error, "")
  }

  func testNavigationPreservesPersistentRecoveryGuidanceUntilItsBlockerClears() {
    let state = AppState()
    state.syncPersistencePending = true
    state.notice = "Temporary page notice"

    let localSaveGuidance = state.persistentOperationGuidance
    state.clearTransientMessagesForNavigation()

    XCTAssertEqual(state.notice, "")
    XCTAssertEqual(state.error, "")
    XCTAssertEqual(state.persistentOperationGuidance, localSaveGuidance)
    XCTAssertTrue(localSaveGuidance?.contains("local save") == true)

    state.pendingVaultUploadHasRemoteConflict = true
    XCTAssertTrue(state.persistentOperationGuidance?.contains("remote conflict") == true)

    state.pendingVaultUploadHasRemoteConflict = false
    state.syncPersistencePending = false
    state.document.syncState.accountDeletionIdempotencyKey = Base64URL.encode(
      Data(repeating: 0x6B, count: AccountDeletionIdempotencyKey.decodedByteCount)
    )
    XCTAssertTrue(state.persistentOperationGuidance?.contains("deletion") == true)

    state.document.syncState.accountDeletionIdempotencyKey = nil
    XCTAssertNil(state.persistentOperationGuidance)
  }

  func testSyncServerDraftBindingAcceptsCanonicalEquivalenceAndRejectsAnotherOrigin() {
    XCTAssertTrue(
      AppState.syncServerDraftMatchesPersisted(
        "https://SYNC.EXAMPLE:443/",
        persisted: "https://sync.example"
      )
    )
    XCTAssertFalse(
      AppState.syncServerDraftMatchesPersisted(
        "https://other.example",
        persisted: "https://sync.example"
      )
    )
    XCTAssertFalse(
      AppState.syncServerDraftMatchesPersisted(
        "not a URL",
        persisted: "https://sync.example"
      )
    )
  }

  func testUserFacingErrorBoundaryNeverRendersRawFrameworkOrSwiftTypeNames() {
    let state = AppState()

    state.presentUserFacingError(
      NSError(domain: "AddressAtlasCore.KeychainVaultKeyStoreError", code: 0)
    )
    XCTAssertEqual(state.error, "Something went wrong, but no data was changed. Try again.")
    XCTAssertFalse(state.error.contains("AddressAtlasCore"))

    state.presentUserFacingError(KeychainVaultKeyStoreError.unexpectedStatus(-50))
    XCTAssertTrue(state.error.contains("Keychain"))
    XCTAssertFalse(state.error.contains("-50"))
  }

  func testSuccessfulSaveRefreshesInMemoryTimestampToPersistedValue() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let databaseURL = tempDir.appending(path: "vault.sqlite")
    let vaultKey = try VaultCrypto().generateVaultKey()
    let store = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    _ = try store.load()
    let originalTimestamp = Date(timeIntervalSince1970: 0)
    let state = AppState(
      testStore: store,
      document: VaultDocument(updatedAt: originalTimestamp)
    )

    let didSave = await state.save()
    XCTAssertTrue(didSave)
    let verifier = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    let persisted = try verifier.load()
    XCTAssertGreaterThan(state.document.updatedAt, originalTimestamp)
    XCTAssertEqual(state.document.updatedAt, persisted.updatedAt)
  }

  func testFailedSaveDoesNotChangeInMemoryTimestamp() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let databaseURL = tempDir.appending(path: "vault.sqlite")
    let vaultKey = try VaultCrypto().generateVaultKey()
    let staleStore = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    let winningStore = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    _ = try staleStore.load()
    _ = try winningStore.load()
    try winningStore.save(VaultDocument())
    let originalTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let state = AppState(
      testStore: staleStore,
      document: VaultDocument(updatedAt: originalTimestamp)
    )

    let didSave = await state.save()
    XCTAssertFalse(didSave)
    XCTAssertEqual(state.document.updatedAt, originalTimestamp)
    XCTAssertEqual(state.error, EncryptedSQLiteVaultStoreError.staleDocument.localizedDescription)
  }

  func testSyncedOrdinarySaveRetainsAllRunsDespiteWireLimit() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let codec = VaultSyncCodec()
    let accountId = "11111111-1111-4111-8111-111111111111"
    let old = scan(generatedAt: 100, warningLength: 240)
    let middle = scan(generatedAt: 200, warningLength: 240)
    let new = scan(generatedAt: 300, warningLength: 240)
    var document = VaultDocument(
      scanRuns: [old, new, middle],
      syncState: SyncState(
        accountId: accountId,
        latestRemoteVersion: 3,
        lastSyncedAt: Date(timeIntervalSince1970: 99),
        lastChecksum: String(repeating: "a", count: 64)
      )
    )
    let originalContentBaseline = try codec.contentChecksum(for: document)
    document.syncState.lastSyncedContentChecksum = originalContentBaseline
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    var newestTwo = persisted
    newestTwo.scanRuns = [new, middle]
    let limit = try requiredSyncBytes(
      codec: codec,
      document: newestTwo,
      version: 4,
      accountId: accountId
    )
    XCTAssertGreaterThan(
      try requiredSyncBytes(codec: codec, document: persisted, version: 4, accountId: accountId),
      limit
    )
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      syncSnapshotByteLimit: limit
    )

    let didSave = await state.save()
    XCTAssertTrue(didSave)

    XCTAssertEqual(state.document.scanRuns.map(\.id), [old.id, new.id, middle.id])
    XCTAssertEqual(
      state.document.syncState.lastSyncedContentChecksum,
      originalContentBaseline
    )
    XCTAssertFalse(state.hasUnsyncedLocalChanges)
    XCTAssertEqual(state.notice, "Saved locally.")
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(try verifier.load().scanRuns.map(\.id), [old.id, new.id, middle.id])
  }

  func testLocalOnlySaveDoesNotPruneAtSyncLimit() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let runs = [
      scan(generatedAt: 100, warningLength: 500),
      scan(generatedAt: 200, warningLength: 500),
      scan(generatedAt: 300, warningLength: 500),
    ]
    let document = VaultDocument(scanRuns: runs)
    let state = AppState(
      testStore: fixture.store,
      document: document,
      syncSnapshotByteLimit: 1
    )

    let didSave = await state.save()
    XCTAssertTrue(didSave)
    XCTAssertEqual(state.document.scanRuns.map(\.id), runs.map(\.id))
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(try verifier.load().scanRuns.map(\.id), runs.map(\.id))
  }

  func testExhaustedOrMalformedRemoteVersionDoesNotBlockLocalSave() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let state = AppState(
      testStore: fixture.store,
      document: VaultDocument(
        syncState: SyncState(
          accountId: "44444444-4444-4444-8444-444444444444",
          latestRemoteVersion: 2_000_000_000
        )
      )
    )

    let firstSave = await state.save()
    XCTAssertTrue(firstSave)
    state.document.syncState.latestRemoteVersion = Int.max
    let secondSave = await state.save()
    XCTAssertTrue(secondSave)

    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(try verifier.load().syncState.latestRemoteVersion, Int.max)
  }

  func testAuthenticationExpiryPersistsTokenClearingWithoutSyncPruning() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let run = scan(generatedAt: 100, warningLength: 2_000)
    let document = VaultDocument(
      scanRuns: [run],
      syncState: SyncState(
        accountId: "55555555-5555-4555-8555-555555555555",
        serverURL: "https://sync.example",
        sessionToken: "expired-token"
      )
    )
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      syncSnapshotByteLimit: 1
    )

    await state.handleSyncError(SyncClientError.authenticationRequired("Untrusted server text"))

    XCTAssertEqual(state.document.scanRuns.map(\.id), [run.id])
    XCTAssertEqual(state.document.syncState.sessionToken, "")
    XCTAssertEqual(state.error, "Sync session expired. Sign in with passkey again.")
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    let reloaded = try verifier.load()
    XCTAssertEqual(reloaded.scanRuns.map(\.id), [run.id])
    XCTAssertEqual(reloaded.syncState.sessionToken, "")
  }

  func testSyncFailureReportsHistoryAlreadyPrunedBeforeRemoteError() async {
    let state = AppState()

    await state.handleSyncError(
      SyncClientError.requestFailed(503, "Network unavailable."),
      removedScanRunCount: 2
    )

    XCTAssertEqual(
      state.error,
      "Network unavailable. Removed 2 oldest scan snapshots to stay within the sync size limit."
    )
  }

  func testNewestRunAboveWireLimitStillPersistsExactlyLocally() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let codec = VaultSyncCodec()
    let accountId = "22222222-2222-4222-8222-222222222222"
    var baseline = VaultDocument(
      scanRuns: [scan(generatedAt: 100, warningLength: 20)],
      syncState: SyncState(accountId: accountId, latestRemoteVersion: 1)
    )
    baseline.syncState.lastSyncedContentChecksum = try codec.contentChecksum(for: baseline)
    let persisted = try fixture.store.saveReturningPersistedDocument(baseline)
    let oversizedNewest = scan(generatedAt: 200, warningLength: 2_000)
    var newestOnly = persisted
    newestOnly.scanRuns = [oversizedNewest]
    let minimumRequired = try requiredSyncBytes(
      codec: codec,
      document: newestOnly,
      version: 2,
      accountId: accountId
    )
    let baselineRequired = try requiredSyncBytes(
      codec: codec,
      document: persisted,
      version: 2,
      accountId: accountId
    )
    XCTAssertLessThan(baselineRequired, minimumRequired)
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      syncSnapshotByteLimit: minimumRequired - 1
    )
    let savedOversized = await state.mutateDocument { $0.scanRuns.append(oversizedNewest) }
    XCTAssertTrue(savedOversized)

    XCTAssertEqual(
      state.document.scanRuns.map(\.id), [persisted.scanRuns[0].id, oversizedNewest.id])
    let verifierAfterSave = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(
      try verifierAfterSave.load().scanRuns.map(\.id),
      [persisted.scanRuns[0].id, oversizedNewest.id]
    )
    XCTAssertEqual(state.error, "")

    // A normal follow-up mutation proves exact local persistence retained its
    // compare-and-swap baseline despite exceeding the wire projection limit.
    let acceptedFollowUp = await state.mutateDocument { $0.preferences.autoRefresh = false }
    XCTAssertTrue(acceptedFollowUp)
    let finalVerifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertFalse(try finalVerifier.load().preferences.autoRefresh)
  }

  func testOrdinarySaveDoesNotApplyPostMarkSyncedWireProjection() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let codec = VaultSyncCodec()
    let accountId = "33333333-3333-4333-8333-333333333333"
    let old = scan(generatedAt: 100, warningLength: 1_000)
    let new = scan(generatedAt: 200, warningLength: 20)
    let initial = VaultDocument(
      scanRuns: [old, new],
      syncState: SyncState(accountId: accountId)
    )
    let persisted = try fixture.store.saveReturningPersistedDocument(initial)
    let currentFullSize = try codec.encodedSnapshotByteCount(
      document: persisted,
      accountId: accountId
    )
    let postSyncFullSize = try codec.projectedPostSyncSnapshotByteCount(
      document: persisted,
      version: 1,
      accountId: accountId
    )
    var newestOnly = persisted
    newestOnly.scanRuns = [new]
    let newestRequired = try requiredSyncBytes(
      codec: codec,
      document: newestOnly,
      version: 1,
      accountId: accountId
    )
    XCTAssertGreaterThan(postSyncFullSize, currentFullSize)
    XCTAssertLessThanOrEqual(newestRequired, currentFullSize)
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      syncSnapshotByteLimit: currentFullSize
    )

    let didSave = await state.save()
    XCTAssertTrue(didSave)
    XCTAssertEqual(state.document.scanRuns.map(\.id), [old.id, new.id])
  }

  func testConcurrentVaultMutationsSerializeAndPersistExactlyOneCandidate() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let state = AppState(testStore: fixture.store, document: VaultDocument())

    async let first = state.addWallet(address: "0x0000000000000000000000000000000000000001")
    async let second = state.addWallet(address: "0x0000000000000000000000000000000000000002")
    let results = await [first, second]

    XCTAssertEqual(results.filter { $0 }.count, 1)
    XCTAssertEqual(state.document.wallets.count, 1)
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    let reloaded = try verifier.load()
    XCTAssertEqual(reloaded.wallets.map(\.id), state.document.wallets.map(\.id))
    XCTAssertEqual(reloaded.wallets.map(\.address), state.document.wallets.map(\.address))
  }

  func testDustFilteringNeverChangesHeadlineTotalAndDisclosesHiddenValue() {
    let state = AppState()
    state.document.scanRuns = [
      ScanRunRecord(
        totalUsd: 100.50,
        inputCount: 1,
        holdings: [
          asset(id: "visible", priceUsd: 100, valueUsd: 100),
          asset(id: "dust", priceUsd: 0.5, valueUsd: 0.5),
        ]
      )
    ]
    state.document.preferences.hideDust = true
    state.document.preferences.dustThreshold = 1

    XCTAssertEqual(state.visibleLatestHoldings.map(\.id), ["visible"])
    XCTAssertEqual(state.latestTotalUsd, 100.50, accuracy: 0.000_001)
    XCTAssertEqual(state.hiddenDustHoldingCount, 1)
    XCTAssertEqual(state.hiddenDustValueUsd, 0.50, accuracy: 0.000_001)
  }

  func testTopHoldingsSortByValidatedValueWithDeterministicTieBreaks() {
    let state = AppState()
    let low = asset(id: "low", priceUsd: 1, valueUsd: 1)
    let tieLater = asset(id: "z-high", priceUsd: 10, valueUsd: 10)
    let tieEarlier = asset(id: "a-high", priceUsd: 10, valueUsd: 10)
    let invalid = asset(id: "invalid", priceUsd: 1, valueUsd: .infinity)
    state.document.scanRuns = [
      ScanRunRecord(
        totalUsd: 21,
        inputCount: 1,
        holdings: [low, tieLater, invalid, tieEarlier]
      )
    ]

    XCTAssertEqual(
      state.visibleLatestHoldings.map(\.id),
      ["a-high", "z-high", "low", "invalid"]
    )
  }

  func testValueOnlyAssetRemainsVisibleWhenHidingUnpriced() {
    let valueOnly = asset(id: "value-only", priceUsd: 0, valueUsd: 25)
    let unpriced = asset(id: "unpriced", priceUsd: 0, valueUsd: 0)

    XCTAssertTrue(AppState.isPricedForDisplay(valueOnly))
    XCTAssertFalse(AppState.isPricedForDisplay(unpriced))
  }

  func testManualPriceRequiresPositiveAmountAndFiniteResult() {
    XCTAssertNil(AppState.derivedManualPrice(amount: 0, valueUsd: 10))
    XCTAssertNil(
      AppState.derivedManualPrice(
        amount: .leastNonzeroMagnitude, valueUsd: .greatestFiniteMagnitude))
    XCTAssertEqual(AppState.derivedManualPrice(amount: 2, valueUsd: 10), 5)
  }

  func testPortfolioTotalRejectsTwoFiniteValuesWhoseAdditionOverflows() {
    let holdings = [
      asset(id: "huge-a", priceUsd: 1, valueUsd: 1e308),
      asset(id: "huge-b", priceUsd: 1, valueUsd: 1e308),
    ]
    let state = AppState()
    state.document.scanRuns = [
      ScanRunRecord(totalUsd: 0, inputCount: 1, holdings: holdings)
    ]

    XCTAssertNil(AppState.validatedPortfolioTotal(holdings))
    XCTAssertEqual(state.latestTotalUsd, 0)
    XCTAssertTrue(state.latestTotalUsd.isFinite)
  }

  func testCompatibilityPolicyUsesBoundedVersionsAndFailsClosed() {
    XCTAssertTrue(AppState.supportsAppVersion("0.2.0", minimum: nil))
    XCTAssertTrue(AppState.supportsAppVersion("0.2.0", minimum: "0.2"))
    XCTAssertFalse(AppState.supportsAppVersion("0.2.0", minimum: "0.2.1"))
    XCTAssertFalse(AppState.supportsAppVersion("", minimum: "0.2.0"))
    XCTAssertFalse(
      AppState.supportsAppVersion(
        "0.2.0",
        minimum: "999999999999999999999999999999.0"
      )
    )
    XCTAssertNil(AppState.compareVersions("0.2.0", "1..2"))
  }

  func testSwiftRunFallsBackToCompiledAppVersionWithoutWeakeningMalformedBundleChecks() {
    XCTAssertEqual(AppState.resolvedAppVersion(nil), "0.2.0")
    XCTAssertEqual(AppState.resolvedAppVersion("  \n"), "0.2.0")
    XCTAssertEqual(AppState.resolvedAppVersion("0.3.1"), "0.3.1")
    XCTAssertEqual(AppState.resolvedAppVersion("latest"), "latest")
    XCTAssertFalse(
      AppState.supportsAppVersion(AppState.resolvedAppVersion("latest"), minimum: "0.2.0"))
    XCTAssertTrue(AppState.supportsAppVersion(AppState.resolvedAppVersion(nil), minimum: "0.2.0"))
  }

  func testWalletLabelNormalizationPreservesDraftSpacesUntilCommit() {
    XCTAssertEqual(AppState.normalizedWalletLabel("  Family Treasury  "), "Family Treasury")
    XCTAssertNil(AppState.normalizedWalletLabel(" \n "))
    XCTAssertNil(AppState.normalizedWalletLabel(String(repeating: "a", count: 81)))
  }

  func testWalletLabelsAreAttributedByCanonicalAddressAndFamily() {
    let address = "0x0000000000000000000000000000000000000001"
    let wallets = [WalletRecord(label: "Treasury", address: address, chainKind: .evm)]
    let holdings = [
      asset(id: "matching", address: address, priceUsd: 1, valueUsd: 1),
      asset(
        id: "other",
        address: "0x0000000000000000000000000000000000000002",
        priceUsd: 1,
        valueUsd: 1
      ),
    ]

    let attributed = AppState.applyingWalletLabels(to: holdings, wallets: wallets)

    XCTAssertEqual(attributed[0].walletLabel, "Treasury")
    XCTAssertNil(attributed[1].walletLabel)
  }

  func testDuplicateExchangeAPIKeysAreMatchedAfterTrimmingWithinProvider() throws {
    let vaultKey = Data(repeating: 0x42, count: 32)
    let connectionID = UUID()
    let encrypted = try ExchangeCredentialVault().seal(
      ExchangeCredentials(apiKey: " saved-key ", secret: "secret", passphrase: nil),
      vaultKey: vaultKey,
      connectionId: connectionID
    )
    let connections = [
      ExchangeConnectionRecord(
        id: connectionID,
        provider: .kraken,
        label: "Kraken",
        encryptedCredentials: encrypted
      )
    ]

    XCTAssertTrue(
      try AppState.hasDuplicateExchangeAPIKey(
        provider: .kraken,
        apiKey: "saved-key\n",
        connections: connections,
        vaultKey: vaultKey
      )
    )
    XCTAssertFalse(
      try AppState.hasDuplicateExchangeAPIKey(
        provider: .binance,
        apiKey: "saved-key",
        connections: connections,
        vaultKey: vaultKey
      )
    )
  }

  func testSavingKrakenCredentialsRejectsAnInvalidDeviceIdentity() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let state = AppState(
      testStore: fixture.store,
      document: VaultDocument(),
      testVaultKey: fixture.vaultKey,
      krakenDeviceIdentifier: { "not-a-device-uuid" }
    )

    let didSave = await state.saveExchangeConnection(
      provider: .kraken,
      label: "Kraken",
      credentials: ExchangeCredentials(
        apiKey: "api-key",
        secret: Data("secret".utf8).base64EncodedString()
      )
    )
    XCTAssertFalse(didSave)
    XCTAssertTrue(state.document.exchangeConnections.isEmpty)
    XCTAssertTrue(state.error.contains("device identity is invalid"))
  }

  func testCustomTokenRejectsInvalidMixedCaseEIP55ChecksumBeforeCanonicalizing() async {
    let state = AppState()
    let invalidChecksum = "0x5AAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"

    let didAdd = await state.addCustomToken(
      chainKind: .evm,
      chainId: "ethereum",
      address: invalidChecksum,
      symbol: "TEST",
      name: "Test Token",
      decimals: "18",
      coinGeckoId: "",
      priceUsd: ""
    )
    XCTAssertFalse(didAdd)
    XCTAssertTrue(state.document.customTokens.isEmpty)
    XCTAssertEqual(state.error, "Enter a valid 0x token contract address.")
  }

  func testCustomTokenRejectsUnicodeCoinGeckoIdentifierAtEditorBoundary() async {
    let state = AppState()

    let didAdd = await state.addCustomToken(
      chainKind: .evm,
      chainId: "ethereum",
      address: "0x0000000000000000000000000000000000000001",
      symbol: "TEST",
      name: "Test Token",
      decimals: "18",
      coinGeckoId: "tökén",
      priceUsd: ""
    )
    XCTAssertFalse(didAdd)
    XCTAssertTrue(state.document.customTokens.isEmpty)
    XCTAssertEqual(
      state.error,
      "CoinGecko ID may contain lowercase letters, numbers, and hyphens only."
    )
  }

  func testLegacyUnicodeCoinGeckoIdentifierIsClearedWithoutDroppingToken() {
    let token = CustomTokenRecord(
      chainKind: .evm,
      chainId: "ethereum",
      address: "0x0000000000000000000000000000000000000001",
      symbol: "TEST",
      name: "Test Token",
      decimals: 18,
      coinGeckoId: "tökén"
    )

    let repaired = AppState.repairLegacyCoinGeckoIDs(in: [token])

    XCTAssertEqual(repaired.map(\.id), [token.id])
    XCTAssertNil(repaired.first?.coinGeckoId)
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

  private func scan(
    generatedAt: TimeInterval,
    warningLength: Int
  ) -> ScanRunRecord {
    ScanRunRecord(
      generatedAt: Date(timeIntervalSince1970: generatedAt),
      totalUsd: 0,
      inputCount: 0,
      holdings: [],
      warnings: [String(repeating: "x", count: warningLength)]
    )
  }

  private func requiredSyncBytes(
    codec: VaultSyncCodec,
    document: VaultDocument,
    version: Int,
    accountId: String
  ) throws -> Int {
    max(
      try codec.encodedSnapshotByteCount(document: document, accountId: accountId),
      try codec.projectedPostSyncSnapshotByteCount(
        document: document,
        version: version,
        accountId: accountId
      )
    )
  }

  private func asset(
    id: String,
    address: String = "0x0000000000000000000000000000000000000001",
    priceUsd: Double,
    valueUsd: Double
  ) -> TrackedAsset {
    TrackedAsset(
      id: id,
      address: address,
      chainId: "ethereum",
      chainName: "Ethereum",
      family: .evm,
      symbol: "TEST",
      name: "Test",
      amount: 1,
      priceUsd: priceUsd,
      valueUsd: valueUsd,
      source: .native
    )
  }
}

@MainActor
private final class PausingPasskeyAuthenticator: PasskeyAuthenticating {
  private var didStart = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var authenticationContinuation: CheckedContinuation<PasskeyWebSession, Error>?

  func authenticate(serverURL: URL, mode: PasskeyWebMode) async throws -> PasskeyWebSession {
    didStart = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    return try await withCheckedThrowingContinuation { continuation in
      authenticationContinuation = continuation
    }
  }

  func waitUntilStarted() async {
    guard !didStart else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func complete(with session: PasskeyWebSession) {
    authenticationContinuation?.resume(returning: session)
    authenticationContinuation = nil
  }
}
