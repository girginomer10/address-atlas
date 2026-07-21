import AddressAtlasCore
import Foundation
import XCTest

@testable import AddressAtlasMac

@MainActor
extension AppStateNetworkBoundaryTests {
  func testDangerousBinanceCredentialIsRejectedBeforeEncryptedPersistence() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let http = RecordingHTTPStub { request in
      XCTAssertEqual(request.url?.path, "/sapi/v1/account/apiRestrictions")
      return stubJSONResponse(
        request,
        #"{"enableReading":true,"enableWithdrawals":true,"enableSpotAndMarginTrading":false}"#
      )
    }
    let state = AppState(
      testStore: fixture.store,
      document: VaultDocument(),
      testVaultKey: fixture.vaultKey,
      httpClient: http
    )

    let saved = await state.saveExchangeConnection(
      provider: .binance,
      label: "Unsafe Binance",
      credentials: ExchangeCredentials(apiKey: "key", secret: "secret")
    )

    XCTAssertFalse(saved)
    XCTAssertTrue(state.document.exchangeConnections.isEmpty)
    XCTAssertTrue(state.error.contains("dangerous permissions"))
    XCTAssertEqual(http.requests.count, 1)
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertTrue(try verifier.load().exchangeConnections.isEmpty)
  }

  func testSafeBinanceCredentialPersistsVerifiedScopeAssurance() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let http = RecordingHTTPStub { request in
      stubJSONResponse(
        request,
        #"{"enableReading":true,"ipRestrict":true,"enableWithdrawals":false,"enableSpotAndMarginTrading":false,"enableMargin":false,"enableFutures":false,"permitsUniversalTransfer":false}"#
      )
    }
    let state = AppState(
      testStore: fixture.store,
      document: VaultDocument(),
      testVaultKey: fixture.vaultKey,
      httpClient: http
    )

    let saved = await state.saveExchangeConnection(
      provider: .binance,
      label: "Safe Binance",
      credentials: ExchangeCredentials(apiKey: "key", secret: "secret")
    )

    XCTAssertTrue(saved)
    XCTAssertEqual(
      state.document.exchangeConnections.first?.credentialScopeAssurance,
      .verifiedReadOnly
    )
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(
      try verifier.load().exchangeConnections.first?.credentialScopeAssurance,
      .verifiedReadOnly
    )
  }

  func testUnverifiableKrakenScopeIsExplicitAndNeverClaimedAsVerified() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let state = AppState(
      testStore: fixture.store,
      document: VaultDocument(),
      testVaultKey: fixture.vaultKey,
      krakenDeviceIdentifier: { "11111111-1111-4111-8111-111111111111" }
    )

    let saved = await state.saveExchangeConnection(
      provider: .kraken,
      label: "Kraken",
      credentials: ExchangeCredentials(
        apiKey: "key",
        secret: Data("secret".utf8).base64EncodedString()
      )
    )

    XCTAssertTrue(saved)
    XCTAssertEqual(state.document.exchangeConnections.count, 1)
    XCTAssertEqual(
      state.document.exchangeConnections.first?.credentialScopeAssurance,
      .manualVerificationRequired
    )
    XCTAssertTrue(state.notice.contains("could not be verified automatically"))
  }

  func testRemovingExchangeCredentialAtomicallyConsumesRollbackAndMarksRemoteCleanup()
    async throws
  {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let accountId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let connectionId = UUID()
    let encryptedCredentials = try ExchangeCredentialVault().seal(
      ExchangeCredentials(apiKey: "key", secret: "secret"),
      vaultKey: fixture.vaultKey,
      connectionId: connectionId
    )
    var document = VaultDocument(
      exchangeConnections: [
        ExchangeConnectionRecord(
          id: connectionId,
          provider: .binance,
          label: "Binance",
          encryptedCredentials: encryptedCredentials
        )
      ],
      syncState: SyncState(
        accountId: accountId,
        serverURL: "https://sync.example",
        sessionToken: testSessionToken(accountId: accountId)
      )
    )
    let codec = VaultSyncCodec()
    let snapshot = try codec.seal(
      document: document,
      vaultKey: fixture.vaultKey,
      version: 1,
      accountId: accountId
    )
    try codec.markSynced(document: &document, snapshot: snapshot)
    let persisted = try fixture.store.saveReturningPersistedDocument(document)
    _ = try fixture.store.saveRollbackCheckpoint(persisted)
    let state = AppState(
      testStore: fixture.store,
      document: persisted,
      testVaultKey: fixture.vaultKey
    )

    XCTAssertTrue(state.hasVaultRollbackCheckpoint)
    await state.removeExchangeConnection(id: connectionId)

    XCTAssertTrue(state.document.exchangeConnections.isEmpty)
    XCTAssertTrue(state.document.syncState.pendingExchangeCredentialCleanup)
    XCTAssertTrue(state.hasUnsyncedLocalChanges)
    XCTAssertFalse(state.hasVaultRollbackCheckpoint)
    XCTAssertTrue(state.notice.contains("last remote snapshot may still contain"))
    XCTAssertFalse(try fixture.store.containsRollbackCheckpoint())
    let reloaded = try fixture.store.load()
    XCTAssertTrue(reloaded.exchangeConnections.isEmpty)
    XCTAssertTrue(reloaded.syncState.pendingExchangeCredentialCleanup)

    let replacement = try codec.seal(
      document: reloaded,
      vaultKey: fixture.vaultKey,
      version: 2,
      accountId: accountId
    )
    let remoteCopy = try codec.open(
      snapshot: replacement,
      vaultKey: fixture.vaultKey,
      expectedAccountId: accountId
    ).document
    XCTAssertFalse(remoteCopy.syncState.pendingExchangeCredentialCleanup)
    var completed = reloaded
    try codec.markSynced(document: &completed, snapshot: replacement)
    XCTAssertFalse(completed.syncState.pendingExchangeCredentialCleanup)
  }

  func testUnsupportedAppVersionStopsScanBeforeAnyProviderRequest() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var document = VaultDocument(
      wallets: [
        WalletRecord(
          label: "Wallet",
          address: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT",
          chainKind: .bitcoin
        )
      ]
    )
    document.syncState.serverURL = "https://sync.example"
    let http = RecordingHTTPStub { _ in
      XCTFail("Unsupported builds must not contact scanner or exchange providers")
      throw URLError(.cancelled)
    }
    let state = AppState(
      testStore: fixture.store,
      document: document,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(
          configVersion: 30,
          refreshAfterSeconds: 300,
          minSupportedAppVersion: "999.0"
        )
      ),
      httpClient: http
    )

    await state.scanSavedWallets()

    XCTAssertTrue(state.error.contains("no longer supported"))
    XCTAssertTrue(state.document.scanRuns.isEmpty)
    XCTAssertTrue(http.requests.isEmpty)
    XCTAssertEqual(state.safeUpdateDownloadURL.scheme, "https")
  }

  func testRelaunchWithOnlyPolicyHighWaterFailsClosedWhenRefreshIsUnavailable() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let serverURL = URL(string: "https://sync.example")!
    let trustFile = fixture.directory.appending(path: "endpoint-config-trust.json")
    _ = try await EndpointConfigTrustStore(fileURL: trustFile).validateAndRecord(
      NativeEndpointConfig(
        configVersion: 30,
        refreshAfterSeconds: 300,
        minSupportedAppVersion: "999.0"
      ),
      for: serverURL
    )
    var document = VaultDocument(
      wallets: [
        WalletRecord(
          label: "Wallet",
          address: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT",
          chainKind: .bitcoin
        )
      ]
    )
    document.syncState.serverURL = serverURL.absoluteString
    let http = RecordingHTTPStub { request in
      XCTFail("A fresh process without the accepted policy must stay offline: \(request)")
      throw URLError(.cancelled)
    }
    let state = AppState(
      testStore: fixture.store,
      document: document,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: FailingEndpointConfigClient(),
      endpointConfigTrustStore: EndpointConfigTrustStore(fileURL: trustFile),
      httpClient: http
    )

    await state.scanSavedWallets()

    XCTAssertTrue(state.error.contains("Scanning stayed offline"))
    XCTAssertTrue(state.document.scanRuns.isEmpty)
    XCTAssertEqual(state.endpointConfigStatus, "Bundled endpoints (remote unavailable)")
    XCTAssertTrue(http.requests.isEmpty)
  }

  func testUnavailableRefreshUsesOnlySameProcessPolicyForReadOnlyScan() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var document = VaultDocument(
      wallets: [
        WalletRecord(
          label: "Wallet",
          address: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT",
          chainKind: .bitcoin
        )
      ]
    )
    document.syncState.serverURL = "https://sync.example"
    let endpointClient = FirstSuccessThenFailureEndpointConfigClient(
      config: NativeEndpointConfig(configVersion: 30, refreshAfterSeconds: 300)
    )
    let http = RecordingHTTPStub { request in
      switch request.url?.host {
      case "blockstream.info" where request.url?.path.hasSuffix("/block-height/0") == true:
        return stubJSONResponse(
          request,
          "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f"
        )
      case "blockstream.info":
        return stubJSONResponse(
          request,
          #"{"address":"1BoatSLRHtKNngkdXEeobR76b53LETtpyT","chain_stats":{"funded_txo_sum":100000000,"spent_txo_sum":0},"mempool_stats":{"funded_txo_sum":0,"spent_txo_sum":0}}"#
        )
      case "api.coingecko.com":
        return stubJSONResponse(request, #"{"bitcoin":{"usd":100000}}"#)
      default:
        throw URLError(.unsupportedURL)
      }
    }
    let state = AppState(
      testStore: fixture.store,
      document: document,
      testVaultKey: fixture.vaultKey,
      endpointConfigClient: endpointClient,
      httpClient: http
    )
    let initialRefreshAccepted = await state.refreshEndpointConfig(silent: true)
    XCTAssertTrue(initialRefreshAccepted)

    await state.scanSavedWallets()

    XCTAssertEqual(state.error, "")
    let run = try XCTUnwrap(state.document.scanRuns.first)
    XCTAssertTrue(run.warnings.contains { $0.contains("current app session") })
    XCTAssertTrue(state.endpointConfigStatus.contains("refresh unavailable"))
    XCTAssertTrue(http.requests.contains { $0.url?.host == "blockstream.info" })
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
      case "blockstream.info" where request.url?.path.hasSuffix("/block-height/0") == true:
        return stubJSONResponse(
          request,
          "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f"
        )
      case "blockstream.info":
        return stubJSONResponse(
          request,
          #"{"address":"1BoatSLRHtKNngkdXEeobR76b53LETtpyT","chain_stats":{"funded_txo_sum":100000000,"spent_txo_sum":0},"mempool_stats":{"funded_txo_sum":0,"spent_txo_sum":0}}"#
        )
      case "api.coingecko.com":
        return stubJSONResponse(request, #"{"bitcoin":{"usd":100000},"usd-coin":{"usd":1}}"#)
      case "api.binance.com" where request.url?.path == "/sapi/v1/account/apiRestrictions":
        return stubJSONResponse(
          request,
          #"{"enableReading":true,"enableWithdrawals":false,"enableSpotAndMarginTrading":false}"#
        )
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
    let holdingSummary = run.holdings.map { "\($0.chainId):\($0.symbol)" }
    let bitcoin = try XCTUnwrap(
      run.holdings.first(where: { $0.symbol == "BTC" }),
      "warnings=\(run.warnings); holdings=\(holdingSummary); requests=\(http.requests.compactMap { $0.url?.absoluteString })"
    )
    XCTAssertEqual(bitcoin.amount, 1)
    XCTAssertEqual(bitcoin.valueUsd, 100_000, accuracy: 0.000_001)
    XCTAssertEqual(bitcoin.walletLabel, "Cold Storage")
    let usdc = try XCTUnwrap(
      run.holdings.first(where: { $0.symbol == "USDC" }),
      "warnings=\(run.warnings); connectionError=\(state.document.exchangeConnections.first?.lastError ?? "nil"); requests=\(http.requests.compactMap { $0.url?.absoluteString })"
    )
    XCTAssertEqual(usdc.amount, 5, accuracy: 0.000_001)
    XCTAssertEqual(usdc.valueUsd, 5, accuracy: 0.000_001)
    XCTAssertEqual(run.totalUsd, 100_005, accuracy: 0.001)
    XCTAssertEqual(state.document.exchangeConnections.first?.status, .ok)
    XCTAssertEqual(
      state.document.exchangeConnections.first?.credentialScopeAssurance,
      .verifiedReadOnly
    )
    let verifier = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    XCTAssertEqual(try verifier.load().scanRuns.map(\.id), [run.id])
  }

}
