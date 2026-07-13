import AddressAtlasCore
import XCTest
@testable import AddressAtlasMac

@MainActor
final class AppStateBehaviorTests: XCTestCase {
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
    let accountId = "prune-account"
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
          accountId: "exhausted-version-account",
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
        accountId: "expired-account",
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
    let accountId = "reject-account"
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
    let accountId = "headroom-account"
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
}
