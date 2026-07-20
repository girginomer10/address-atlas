import AddressAtlasCore
import XCTest
@testable import AddressAtlasMac

@MainActor
final class AppStateBehaviorTests: XCTestCase {
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

  func testSuccessfulSaveRefreshesInMemoryTimestampToPersistedValue() throws {
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

    XCTAssertTrue(state.save())
    let verifier = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    let persisted = try verifier.load()
    XCTAssertGreaterThan(state.document.updatedAt, originalTimestamp)
    XCTAssertEqual(state.document.updatedAt, persisted.updatedAt)
  }

  func testFailedSaveDoesNotChangeInMemoryTimestamp() throws {
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

    XCTAssertFalse(state.save())
    XCTAssertEqual(state.document.updatedAt, originalTimestamp)
    XCTAssertEqual(state.error, EncryptedSQLiteVaultStoreError.staleDocument.localizedDescription)
  }

  func testSyncedSavePrunesOldestRunsByExactProjectedBytesAndKeepsBaselineDirty() throws {
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

    XCTAssertTrue(state.save())

    XCTAssertEqual(state.document.scanRuns.map(\.id), [new.id, middle.id])
    XCTAssertEqual(
      state.document.syncState.lastSyncedContentChecksum,
      originalContentBaseline
    )
    XCTAssertTrue(state.hasUnsyncedLocalChanges)
    XCTAssertTrue(state.notice.contains("Removed 1 oldest scan snapshot"))
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(try verifier.load().scanRuns.map(\.id), [new.id, middle.id])
  }

  func testLocalOnlySaveDoesNotPruneAtSyncLimit() throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let runs = [
      scan(generatedAt: 100, warningLength: 500),
      scan(generatedAt: 200, warningLength: 500),
      scan(generatedAt: 300, warningLength: 500)
    ]
    let document = VaultDocument(scanRuns: runs)
    let state = AppState(
      testStore: fixture.store,
      document: document,
      syncSnapshotByteLimit: 1
    )

    XCTAssertTrue(state.save())
    XCTAssertEqual(state.document.scanRuns.map(\.id), runs.map(\.id))
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(try verifier.load().scanRuns.map(\.id), runs.map(\.id))
  }

  func testExhaustedOrMalformedRemoteVersionDoesNotBlockLocalSave() throws {
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

    XCTAssertTrue(state.save())
    state.document.syncState.latestRemoteVersion = Int.max
    XCTAssertTrue(state.save())

    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(try verifier.load().syncState.latestRemoteVersion, Int.max)
  }

  func testAuthenticationExpiryPersistsTokenClearingWithoutSyncPruning() throws {
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

    state.handleSyncError(SyncClientError.authenticationRequired("Untrusted server text"))

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

  func testSyncFailureReportsHistoryAlreadyPrunedBeforeRemoteError() {
    let state = AppState()

    state.handleSyncError(
      SyncClientError.requestFailed(503, "Network unavailable."),
      removedScanRunCount: 2
    )

    XCTAssertEqual(
      state.error,
      "Network unavailable. Removed 2 oldest scan snapshots to stay within the sync size limit."
    )
  }

  func testNewestRunTooLargeRejectsBeforeSQLiteAndPreservesMemoryRowAndCAS() throws {
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
    let envelopeBeforeRejectedSave = try XCTUnwrap(fixture.store.rawStoredEnvelopeBytes())

    XCTAssertFalse(state.mutateDocument { $0.scanRuns.append(oversizedNewest) })

    XCTAssertEqual(state.document, persisted)
    XCTAssertEqual(try fixture.store.rawStoredEnvelopeBytes(), envelopeBeforeRejectedSave)
    let verifierAfterFailure = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(try verifierAfterFailure.load(), persisted)
    XCTAssertTrue(state.error.contains("sync snapshot is too large"))

    // A normal follow-up mutation through the same store proves the rejected
    // preflight did not advance or invalidate its compare-and-swap baseline.
    XCTAssertTrue(state.mutateDocument { $0.preferences.autoRefresh = false })
    let finalVerifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertFalse(try finalVerifier.load().preferences.autoRefresh)
  }

  func testSaveUsesPostMarkSyncedHeadroomBeforePersisting() throws {
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

    XCTAssertTrue(state.save())
    XCTAssertEqual(state.document.scanRuns.map(\.id), [new.id])
  }

  func testDustFilteringKeepsHeadlineTotalAndVisibleRowsInSync() {
    let state = AppState()
    state.document.scanRuns = [
      ScanRunRecord(
        totalUsd: 100.50,
        inputCount: 1,
        holdings: [
          asset(id: "visible", priceUsd: 100, valueUsd: 100),
          asset(id: "dust", priceUsd: 0.5, valueUsd: 0.5)
        ]
      )
    ]
    state.document.preferences.hideDust = true
    state.document.preferences.dustThreshold = 1

    XCTAssertEqual(state.visibleLatestHoldings.map(\.id), ["visible"])
    XCTAssertEqual(state.visibleLatestTotalUsd, 100, accuracy: 0.000_001)
  }

  func testValueOnlyAssetRemainsVisibleWhenHidingUnpriced() {
    let valueOnly = asset(id: "value-only", priceUsd: 0, valueUsd: 25)
    let unpriced = asset(id: "unpriced", priceUsd: 0, valueUsd: 0)

    XCTAssertTrue(AppState.isPricedForDisplay(valueOnly))
    XCTAssertFalse(AppState.isPricedForDisplay(unpriced))
  }

  func testManualPriceRequiresPositiveAmountAndFiniteResult() {
    XCTAssertNil(AppState.derivedManualPrice(amount: 0, valueUsd: 10))
    XCTAssertNil(AppState.derivedManualPrice(amount: .leastNonzeroMagnitude, valueUsd: .greatestFiniteMagnitude))
    XCTAssertEqual(AppState.derivedManualPrice(amount: 2, valueUsd: 10), 5)
  }

  func testPortfolioTotalRejectsTwoFiniteValuesWhoseAdditionOverflows() {
    let holdings = [
      asset(id: "huge-a", priceUsd: 1, valueUsd: 1e308),
      asset(id: "huge-b", priceUsd: 1, valueUsd: 1e308)
    ]
    let state = AppState()
    state.document.scanRuns = [
      ScanRunRecord(totalUsd: 0, inputCount: 1, holdings: holdings)
    ]

    XCTAssertNil(AppState.validatedPortfolioTotal(holdings))
    XCTAssertEqual(state.visibleLatestTotalUsd, 0)
    XCTAssertTrue(state.visibleLatestTotalUsd.isFinite)
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
    XCTAssertFalse(AppState.supportsAppVersion(AppState.resolvedAppVersion("latest"), minimum: "0.2.0"))
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
      )
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

  func testSavingKrakenCredentialsRejectsAnInvalidDeviceIdentity() throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let state = AppState(
      testStore: fixture.store,
      document: VaultDocument(),
      testVaultKey: fixture.vaultKey,
      krakenDeviceIdentifier: { "not-a-device-uuid" }
    )

    XCTAssertFalse(
      state.saveExchangeConnection(
        provider: .kraken,
        label: "Kraken",
        credentials: ExchangeCredentials(
          apiKey: "api-key",
          secret: Data("secret".utf8).base64EncodedString()
        )
      )
    )
    XCTAssertTrue(state.document.exchangeConnections.isEmpty)
    XCTAssertTrue(state.error.contains("device identity is invalid"))
  }

  func testCustomTokenRejectsInvalidMixedCaseEIP55ChecksumBeforeCanonicalizing() {
    let state = AppState()
    let invalidChecksum = "0x5AAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"

    XCTAssertFalse(
      state.addCustomToken(
        chainKind: .evm,
        chainId: "ethereum",
        address: invalidChecksum,
        symbol: "TEST",
        name: "Test Token",
        decimals: "18",
        coinGeckoId: "",
        priceUsd: ""
      )
    )
    XCTAssertTrue(state.document.customTokens.isEmpty)
    XCTAssertEqual(state.error, "Enter a valid 0x token contract address.")
  }

  func testCustomTokenRejectsUnicodeCoinGeckoIdentifierAtEditorBoundary() {
    let state = AppState()

    XCTAssertFalse(
      state.addCustomToken(
        chainKind: .evm,
        chainId: "ethereum",
        address: "0x0000000000000000000000000000000000000001",
        symbol: "TEST",
        name: "Test Token",
        decimals: "18",
        coinGeckoId: "tökén",
        priceUsd: ""
      )
    )
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
final class EndpointConfigRefreshTests: XCTestCase {
  func testAcceptedConfigMessagePublishesOperatorMessageAndAbsenceClearsIt() async {
    let client = ControllableEndpointConfigClient()
    let state = AppState(endpointConfigClient: client)
    state.document.syncState.serverURL = "https://sync.example"
    XCTAssertNil(state.operatorMessage)

    let withMessage = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://sync.example")
    await client.resolve(
      "https://sync.example",
      with: NativeEndpointConfig(
        configVersion: 8,
        refreshAfterSeconds: 300,
        message: "  Scheduled\u{0000} maintenance\n tonight.  "
      )
    )
    let withMessageResult = await withMessage.value
    XCTAssertTrue(withMessageResult)
    XCTAssertEqual(state.operatorMessage, "Scheduled maintenance tonight.")

    let withoutMessage = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://sync.example")
    await client.resolve(
      "https://sync.example",
      with: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
    )
    let withoutMessageResult = await withoutMessage.value
    XCTAssertTrue(withoutMessageResult)
    XCTAssertNil(state.operatorMessage)

    let whitespaceOnly = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://sync.example")
    await client.resolve(
      "https://sync.example",
      with: NativeEndpointConfig(configVersion: 10, refreshAfterSeconds: 300, message: " \n\t ")
    )
    let whitespaceOnlyResult = await whitespaceOnly.value
    XCTAssertTrue(whitespaceOnlyResult)
    XCTAssertNil(state.operatorMessage)
  }

  func testConcurrentRefreshesForSameServerShareOneRequest() async {
    let client = CountingEndpointConfigClient(
      config: NativeEndpointConfig(configVersion: 24, refreshAfterSeconds: 300)
    )
    let state = AppState(endpointConfigClient: client)
    state.document.syncState.serverURL = "https://sync.example"

    async let first = state.refreshEndpointConfig(silent: true)
    async let second = state.refreshEndpointConfig(silent: true)
    let results = await (first, second)
    let requestCount = await client.requestCount

    XCTAssertTrue(results.0)
    XCTAssertTrue(results.1)
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(state.endpointConfig.configVersion, 24)
  }

  func testRefreshLoopFetchesConfigProactivelyAfterUnlock() async {
    let client = ControllableEndpointConfigClient()
    let state = AppState(endpointConfigClient: client)
    state.isUnlocked = true
    state.document.syncState.serverURL = "https://sync.example"

    let refreshLoop = Task { await state.runEndpointConfigRefreshLoop() }
    await client.waitUntilRequested("https://sync.example")
    await client.resolve(
      "https://sync.example",
      with: NativeEndpointConfig(configVersion: 23, refreshAfterSeconds: 300)
    )
    refreshLoop.cancel()
    await refreshLoop.value

    XCTAssertEqual(state.endpointConfig.configVersion, 23)
    XCTAssertEqual(state.endpointConfig.refreshAfterSeconds, 300)
  }

  func testStaleResponseCannotReplaceConfigForNewServer() async {
    let client = ControllableEndpointConfigClient()
    let state = AppState(endpointConfigClient: client)
    state.document.syncState.serverURL = "https://first.example"

    let firstRefresh = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://first.example")

    state.document.syncState.serverURL = "https://second.example"
    let secondRefresh = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://second.example")

    await client.resolve("https://second.example", with: NativeEndpointConfig(configVersion: 22))
    let secondResult = await secondRefresh.value
    XCTAssertTrue(secondResult)
    XCTAssertEqual(state.endpointConfig.configVersion, 22)

    await client.resolve("https://first.example", with: NativeEndpointConfig(configVersion: 11))
    let firstResult = await firstRefresh.value
    XCTAssertFalse(firstResult)
    XCTAssertEqual(state.endpointConfig.configVersion, 22)
  }

  func testSameServerRejectsRollbackAndPreservesAcceptedConfigOnFailure() async {
    let client = ControllableEndpointConfigClient()
    let state = AppState(endpointConfigClient: client)
    state.document.syncState.serverURL = "https://sync.example"

    let first = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://sync.example")
    let accepted = NativeEndpointConfig(
      configVersion: 7,
      refreshAfterSeconds: 300,
      message: "accepted"
    )
    await client.resolve("https://sync.example", with: accepted)
    let firstResult = await first.value
    XCTAssertTrue(firstResult)

    let rollback = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://sync.example")
    await client.resolve(
      "https://sync.example",
      with: NativeEndpointConfig(configVersion: 6, refreshAfterSeconds: 300, message: "stale")
    )
    let rollbackResult = await rollback.value
    XCTAssertFalse(rollbackResult)
    XCTAssertEqual(state.endpointConfig, accepted)
    XCTAssertTrue(state.endpointConfigStatus.contains("stale v6 rejected"))

    let unavailable = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://sync.example")
    await client.reject("https://sync.example", with: URLError(.cannotConnectToHost))
    let unavailableResult = await unavailable.value
    XCTAssertFalse(unavailableResult)
    XCTAssertEqual(state.endpointConfig, accepted)
    XCTAssertEqual(state.endpointConfigStatus, "Remote v7 (refresh unavailable)")
  }

  func testUnsupportedAcceptedConfigKeepsUpdateRequiredAcrossRollbackEquivocationAndFailure() async {
    let client = ControllableEndpointConfigClient()
    let state = AppState(endpointConfigClient: client)
    state.document.syncState.serverURL = "https://sync.example"
    let unsupported = NativeEndpointConfig(
      configVersion: 7,
      refreshAfterSeconds: 300,
      minSupportedAppVersion: "999.0",
      message: "unsupported"
    )

    let initial = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://sync.example")
    await client.resolve("https://sync.example", with: unsupported)
    let initialResult = await initial.value
    XCTAssertTrue(initialResult)
    XCTAssertFalse(state.isAppVersionSupported)
    XCTAssertEqual(state.endpointConfigStatus, "Update required")

    let rollback = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://sync.example")
    await client.resolve(
      "https://sync.example",
      with: NativeEndpointConfig(configVersion: 6, refreshAfterSeconds: 300)
    )
    let rollbackResult = await rollback.value
    XCTAssertFalse(rollbackResult)
    XCTAssertEqual(state.endpointConfig, unsupported)
    XCTAssertTrue(state.endpointConfigStatus.contains("Update required"))
    XCTAssertTrue(state.endpointConfigStatus.contains("stale v6 rejected"))

    let equivocation = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://sync.example")
    await client.resolve(
      "https://sync.example",
      with: NativeEndpointConfig(
        configVersion: 7,
        refreshAfterSeconds: 300,
        minSupportedAppVersion: "999.0",
        message: "changed without version"
      )
    )
    let equivocationResult = await equivocation.value
    XCTAssertFalse(equivocationResult)
    XCTAssertEqual(state.endpointConfig, unsupported)
    XCTAssertTrue(state.endpointConfigStatus.contains("Update required"))
    XCTAssertTrue(state.endpointConfigStatus.contains("conflicting refresh rejected"))

    let unavailable = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://sync.example")
    await client.reject("https://sync.example", with: URLError(.cannotConnectToHost))
    let unavailableResult = await unavailable.value
    XCTAssertFalse(unavailableResult)
    XCTAssertEqual(state.endpointConfig, unsupported)
    XCTAssertTrue(state.endpointConfigStatus.contains("Update required"))
    XCTAssertTrue(state.endpointConfigStatus.contains("refresh unavailable"))
  }

  func testServerSwitchResetsVersionMonotonicityButRejectsSameVersionEquivocation() async {
    let client = ControllableEndpointConfigClient()
    let state = AppState(endpointConfigClient: client)
    state.document.syncState.serverURL = "https://first.example"

    let first = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://first.example")
    await client.resolve(
      "https://first.example",
      with: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300, message: "first")
    )
    let firstResult = await first.value
    XCTAssertTrue(firstResult)

    state.document.syncState.serverURL = "https://second.example"
    let second = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://second.example")
    let secondAccepted = NativeEndpointConfig(
      configVersion: 6,
      refreshAfterSeconds: 300,
      message: "second"
    )
    await client.resolve("https://second.example", with: secondAccepted)
    let secondResult = await second.value
    XCTAssertTrue(secondResult)
    XCTAssertEqual(state.endpointConfig, secondAccepted)

    let equivocation = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://second.example")
    await client.resolve(
      "https://second.example",
      with: NativeEndpointConfig(configVersion: 6, refreshAfterSeconds: 300, message: "changed")
    )
    let equivocationResult = await equivocation.value
    XCTAssertFalse(equivocationResult)
    XCTAssertEqual(state.endpointConfig, secondAccepted)
    XCTAssertTrue(state.endpointConfigStatus.contains("conflicting refresh rejected"))
  }
}

private actor CountingEndpointConfigClient: EndpointConfigFetching {
  let config: NativeEndpointConfig
  private(set) var requestCount = 0

  init(config: NativeEndpointConfig) {
    self.config = config
  }

  func fetch(from serverURL: URL) async throws -> NativeEndpointConfig {
    requestCount += 1
    try await Task.sleep(for: .milliseconds(20))
    return config
  }
}

/// Exercises the real AppState orchestration glue (encrypt/decode/persist/merge)
/// with stubs installed only at the HTTP transport boundary.
@MainActor
final class AppStateNetworkBoundaryTests: XCTestCase {
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
    XCTAssertTrue(document.syncState.connect(
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
    XCTAssertTrue(document.syncState.connect(
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

  func testScanSavedWalletsMergesStubbedChainAndExchangeResultsIntoState() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let bitcoinAddress = "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
    let connectionId = UUID()
    let envelope = try ExchangeCredentialVault().seal(
      ExchangeCredentials(apiKey: "binance-key", secret: "binance-secret", passphrase: nil),
      vaultKey: fixture.vaultKey,
      connectionId: connectionId
    )
    let document = VaultDocument(
      wallets: [WalletRecord(label: "Cold Storage", address: bitcoinAddress, chainKind: .bitcoin)],
      exchangeConnections: [
        ExchangeConnectionRecord(
          id: connectionId,
          provider: .binance,
          label: "Binance",
          encryptedCredentials: envelope
        )
      ]
    )
    let http = RecordingHTTPStub { request in
      switch request.url?.host {
      case "blockstream.info":
        return stubJSONResponse(
          request,
          #"{"chain_stats":{"funded_txo_sum":100000000,"spent_txo_sum":0},"mempool_stats":{"funded_txo_sum":0,"spent_txo_sum":0}}"#
        )
      case "api.coingecko.com":
        return stubJSONResponse(request, #"{"bitcoin":{"usd":100000},"usd-coin":{"usd":1}}"#)
      case "api.binance.com" where request.url?.path == "/api/v3/account":
        return stubJSONResponse(
          request,
          #"{"balances":[{"asset":"USDC","free":"5","locked":"0"}]}"#
        )
      default:
        throw URLError(.unsupportedURL)
      }
    }
    let state = AppState(
      testStore: fixture.store,
      document: document,
      testVaultKey: fixture.vaultKey,
      httpClient: http
    )

    await state.scanSavedWallets()

    XCTAssertEqual(state.error, "")
    XCTAssertTrue(state.notice.hasPrefix("Snapshot saved"))
    let run = try XCTUnwrap(state.document.scanRuns.first)
    let bitcoin = try XCTUnwrap(run.holdings.first(where: { $0.symbol == "BTC" }))
    XCTAssertEqual(bitcoin.amount, 1)
    XCTAssertEqual(bitcoin.valueUsd, 100_000, accuracy: 0.000_001)
    XCTAssertEqual(bitcoin.walletLabel, "Cold Storage")
    let usdc = try XCTUnwrap(run.holdings.first(where: { $0.symbol == "USDC" }))
    XCTAssertEqual(usdc.amount, 5, accuracy: 0.000_001)
    XCTAssertEqual(usdc.valueUsd, 5, accuracy: 0.000_001)
    XCTAssertEqual(run.totalUsd, 100_005, accuracy: 0.001)
    XCTAssertEqual(state.document.exchangeConnections.first?.status, .ok)
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(try verifier.load().scanRuns.map(\.id), [run.id])
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

private struct FixedEndpointConfigClient: EndpointConfigFetching {
  var config: NativeEndpointConfig

  func fetch(from serverURL: URL) async throws -> NativeEndpointConfig {
    config
  }
}

@MainActor
private final class StubPasskeyAuthenticator: PasskeyAuthenticating {
  private let session: PasskeyWebSession

  init(session: PasskeyWebSession) {
    self.session = session
  }

  func authenticate(serverURL: URL, mode: PasskeyWebMode) async throws -> PasskeyWebSession {
    session
  }
}

private final class RecordingHTTPStub: HTTPClient, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [URLRequest] = []
  private let handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
    self.handler = handler
  }

  var requests: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    record(request)
    return try await handler(request)
  }

  private func record(_ request: URLRequest) {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(request)
  }
}

private func stubJSONResponse(
  _ request: URLRequest,
  _ json: String,
  statusCode: Int = 200
) -> (Data, HTTPURLResponse) {
  (Data(json.utf8), stubHTTPResponse(request, statusCode: statusCode))
}

private func stubHTTPResponse(
  _ request: URLRequest,
  statusCode: Int = 200
) -> HTTPURLResponse {
  HTTPURLResponse(
    url: request.url ?? URL(string: "https://example.com")!,
    statusCode: statusCode,
    httpVersion: "HTTP/1.1",
    headerFields: ["content-type": "application/json"]
  )!
}

private actor ControllableEndpointConfigClient: EndpointConfigFetching {
  private var requests: [String: CheckedContinuation<NativeEndpointConfig, Error>] = [:]
  private var requestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

  func fetch(from serverURL: URL) async throws -> NativeEndpointConfig {
    let origin = serverURL.absoluteString
    return try await withCheckedThrowingContinuation { continuation in
      requests[origin] = continuation
      let waiters = requestWaiters.removeValue(forKey: origin) ?? []
      waiters.forEach { $0.resume() }
    }
  }

  func waitUntilRequested(_ origin: String) async {
    guard requests[origin] == nil else { return }
    await withCheckedContinuation { continuation in
      requestWaiters[origin, default: []].append(continuation)
    }
  }

  func resolve(_ origin: String, with config: NativeEndpointConfig) {
    requests.removeValue(forKey: origin)?.resume(returning: config)
  }

  func reject(_ origin: String, with error: Error) {
    requests.removeValue(forKey: origin)?.resume(throwing: error)
  }
}
