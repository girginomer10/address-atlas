import AddressAtlasCore
import XCTest
@testable import AddressAtlasMac

@MainActor
final class AppStateBehaviorTests: XCTestCase {
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
