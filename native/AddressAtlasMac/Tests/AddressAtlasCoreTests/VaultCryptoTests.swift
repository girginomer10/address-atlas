import CryptoKit
import Foundation
import XCTest
@testable import AddressAtlasCore

final class VaultCryptoTests: XCTestCase {
  func testVaultEncryptionRoundTripsAndRejectsWrongKey() throws {
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let key = try crypto.deriveKey(from: vaultKey, purpose: .syncBlob)
    let document = VaultDocument(wallets: [
      WalletRecord(label: "Vitalik", address: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", chainKind: .evm)
    ])

    let envelope = try crypto.sealJSON(document, with: key, keyId: "sync-v1")
    let opened = try crypto.openJSON(VaultDocument.self, envelope: envelope, with: key)

    XCTAssertEqual(opened.wallets.first?.address, document.wallets.first?.address)

    let wrongKey = try crypto.deriveKey(from: crypto.generateVaultKey(), purpose: .syncBlob)
    XCTAssertThrowsError(try crypto.openJSON(VaultDocument.self, envelope: envelope, with: wrongKey))
  }

  func testEnvelopeNonceChangesForSamePlaintext() throws {
    let crypto = VaultCrypto()
    let key = try crypto.deriveKey(from: crypto.generateVaultKey(), purpose: .syncBlob)
    let plaintext = Data("same plaintext".utf8)

    let first = try crypto.seal(plaintext, with: key, keyId: "sync-v1")
    let second = try crypto.seal(plaintext, with: key, keyId: "sync-v1")

    XCTAssertNotEqual(first.nonce, second.nonce)
    XCTAssertNotEqual(first.ciphertext, second.ciphertext)
  }
}

final class EncryptedSQLiteVaultStoreTests: XCTestCase {
  func testStorePersistsEncryptedDocumentWithoutPlaintextWalletLeak() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let store = try EncryptedSQLiteVaultStore(path: tempDir.appending(path: "vault.sqlite"), vaultKey: vaultKey, crypto: crypto)
    let wallet = WalletRecord(label: "Wallet", address: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", chainKind: .evm)

    try store.save(VaultDocument(wallets: [wallet]))
    let loaded = try store.load()
    let raw = try XCTUnwrap(store.rawStoredEnvelopeBytes())
    let rawText = String(decoding: raw, as: UTF8.self)

    XCTAssertEqual(loaded.wallets.first?.address, wallet.address)
    XCTAssertFalse(rawText.contains(wallet.address))
    XCTAssertTrue(rawText.contains("ciphertext"))
  }
}

final class ExchangeRequestSigningTests: XCTestCase {
  func testBinanceSignerBuildsExpectedQueryAndHeader() {
    let signed = ExchangeRequestSigner.binanceAccountRequest(
      credentials: ExchangeCredentials(apiKey: "key", secret: "secret"),
      timestampMs: 1_700_000_000_000
    )

    XCTAssertEqual(signed.method, "GET")
    XCTAssertEqual(signed.path, "/api/v3/account")
    XCTAssertTrue(signed.query.contains("timestamp=1700000000000"))
    XCTAssertTrue(signed.query.contains("signature="))
    XCTAssertEqual(signed.headers["X-MBX-APIKEY"], "key")
  }

  func testAddressDetectionRejectsSeedLikeInput() {
    let phrase = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima"
    XCTAssertFalse(AddressDetection.isSafePublicAddress(phrase))
  }
}

final class NativeScannerTokenTests: XCTestCase {
  func testErc20BalanceOfDataPadsOwnerAddress() {
    let data = NativeScanner.erc20BalanceOfData("0x000000000000000000000000000000000000dEaD")

    XCTAssertEqual(data.count, 74)
    XCTAssertTrue(data.hasPrefix("0x70a08231"))
    XCTAssertTrue(data.hasSuffix("000000000000000000000000000000000000dead"))
  }

  func testCustomTokenRegistryKeepsBuiltinOnDuplicate() {
    let duplicateUsdc = CustomTokenRecord(
      chainKind: .evm,
      chainId: "ethereum",
      address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      symbol: "FAKE",
      name: "Fake USDC",
      decimals: 6
    )
    let custom = CustomTokenRecord(
      chainKind: .evm,
      chainId: "ethereum",
      address: "0x0000000000000000000000000000000000000001",
      symbol: "ONE",
      name: "One",
      decimals: 18,
      priceUsd: 1
    )

    let registries = NativeScanner.tokenRegistries(customTokens: [duplicateUsdc, custom])
    let ethereum = registries.evm["ethereum"] ?? []

    XCTAssertEqual(ethereum.filter { $0.address.lowercased() == duplicateUsdc.address.lowercased() }.count, 1)
    XCTAssertTrue(ethereum.contains { $0.symbol == "USDC" })
    XCTAssertTrue(ethereum.contains { $0.symbol == "ONE" })
  }

  func testSolanaTokenAccountParserReadsJsonParsedBalances() throws {
    let json = """
    {
      "result": {
        "value": [
          {
            "account": {
              "data": {
                "parsed": {
                  "info": {
                    "mint": "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
                    "tokenAmount": {
                      "amount": "1234500",
                      "decimals": 6
                    }
                  }
                }
              }
            }
          }
        ]
      }
    }
    """
    let response = try JSONDecoder.addressAtlas.decode(SolanaTokenAccountsResponse.self, from: Data(json.utf8))
    let parsed = NativeScanner.parseSolanaTokenAccounts(response.result?.value ?? [])

    XCTAssertEqual(parsed, [
      ParsedSplAccount(
        mint: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
        rawAmount: 1_234_500,
        decimals: 6
      )
    ])
  }

  func testCosmosParsersReadLiquidStakedAndRewardsBalances() throws {
    let bankJSON = """
    { "balances": [{ "denom": "uatom", "amount": "1200000" }] }
    """
    let delegationJSON = """
    {
      "delegation_responses": [
        { "balance": { "denom": "uatom", "amount": "2500000" } },
        { "balance": { "denom": "uother", "amount": "9999999" } }
      ]
    }
    """
    let rewardsJSON = """
    { "total": [{ "denom": "uatom", "amount": "340000" }] }
    """

    let bank = try JSONDecoder.addressAtlas.decode(CosmosBankResponse.self, from: Data(bankJSON.utf8))
    let delegations = try JSONDecoder.addressAtlas.decode(CosmosDelegationResponse.self, from: Data(delegationJSON.utf8))
    let rewards = try JSONDecoder.addressAtlas.decode(CosmosRewardsResponse.self, from: Data(rewardsJSON.utf8))

    XCTAssertEqual(NativeScanner.parseCosmosLiquid(bank, denom: "uatom", decimals: 6), 1.2)
    XCTAssertEqual(NativeScanner.parseCosmosDelegations(delegations, denom: "uatom", decimals: 6), 2.5)
    XCTAssertEqual(NativeScanner.parseCosmosRewards(rewards, denom: "uatom", decimals: 6), 0.34)
  }

  func testTronTrc20ParserReadsRegisteredBalances() {
    let token = TokenConfig(
      symbol: "USDT",
      name: "Tether",
      address: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
      decimals: 6,
      coinGeckoId: "tether"
    )

    let parsed = NativeScanner.parseTronTrc20Balances(
      [
        ["TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t": "1250000"],
        ["other": "999999"]
      ],
      tokens: [token]
    )

    XCTAssertEqual(parsed.count, 1)
    XCTAssertEqual(parsed.first?.token.symbol, "USDT")
    XCTAssertEqual(parsed.first?.amount, 1.25)
  }

  func testXrpTrustLineParserDecodesIssuedAssets() {
    let lines = [
      XrpTrustLine(
        account: "rIssuer111111111111111111111111111111111",
        balance: "42.5",
        currency: "5553440000000000000000000000000000000000"
      ),
      XrpTrustLine(
        account: "rIssuer222222222222222222222222222222222",
        balance: "-1",
        currency: "IGNORED"
      )
    ]

    let parsed = NativeScanner.parseXrpTrustLines(
      lines,
      address: "rWallet111111111111111111111111111111111",
      chain: ChainRegistry.xrp
    )

    XCTAssertEqual(NativeScanner.decodeXrplCurrency("5553440000000000000000000000000000000000"), "USD")
    XCTAssertEqual(parsed.count, 1)
    XCTAssertEqual(parsed.first?.symbol, "USD")
    XCTAssertEqual(parsed.first?.source, .issued)
    XCTAssertEqual(parsed.first?.amount, 42.5)
  }
}

final class ExchangeCredentialVaultTests: XCTestCase {
  func testExchangeCredentialsUseDedicatedSubkey() throws {
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let credentialVault = ExchangeCredentialVault(crypto: crypto)
    let credentials = ExchangeCredentials(apiKey: "api", secret: "secret", passphrase: "pass")

    let envelope = try credentialVault.seal(credentials, vaultKey: vaultKey, connectionId: UUID())
    let opened = try credentialVault.open(envelope, vaultKey: vaultKey)

    XCTAssertEqual(opened, credentials)

    let localKey = try crypto.deriveKey(from: vaultKey, purpose: .localDatabase)
    XCTAssertThrowsError(try crypto.openJSON(ExchangeCredentials.self, envelope: envelope, with: localKey))
  }
}

final class NativeExchangeClientTests: XCTestCase {
  func testBinanceClientSignsRequestAndParsesBalances() async throws {
    let http = StubHTTPClient { request in
      XCTAssertEqual(request.url?.path, "/api/v3/account")
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-MBX-APIKEY"), "key")
      XCTAssertTrue(request.url?.query?.contains("timestamp=1700000000000") == true)
      XCTAssertTrue(request.url?.query?.contains("signature=") == true)
      let json = """
      {
        "balances": [
          { "asset": "BTC", "free": "0.25", "locked": "0.25" },
          { "asset": "EMPTY", "free": "0", "locked": "0" }
        ]
      }
      """
      return (Data(json.utf8), httpResponse(for: request))
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    let balance = try await client.fetchBalance(
      provider: .binance,
      credentials: ExchangeCredentials(apiKey: "key", secret: "secret")
    )

    XCTAssertEqual(balance.total["BTC"], 0.5)
    XCTAssertEqual(balance.free["BTC"], 0.25)
    XCTAssertNil(balance.total["EMPTY"])
  }

  func testExchangeBalanceNormalizerPricesStablecoinsAndKnownAssets() {
    let id = UUID()
    let holdings = ExchangeBalanceNormalizer.normalize(
      balance: ExchangeBalance(total: ["USDC": 42, "XBT": 0.5]),
      id: id,
      provider: .kraken,
      label: "Kraken main",
      prices: ["bitcoin": PricePoint(usd: 100_000, usd24hChange: 1.5)]
    )

    XCTAssertEqual(holdings.map(\.symbol), ["BTC", "USDC"])
    XCTAssertEqual(holdings.first(where: { $0.symbol == "BTC" })?.valueUsd, 50_000)
    XCTAssertEqual(holdings.first(where: { $0.symbol == "USDC" })?.valueUsd, 42)
    XCTAssertEqual(holdings.first?.source, .exchange)
  }

  func testNativeExchangeScannerDecryptsCredentialsAndUpdatesConnection() async throws {
    let http = StubHTTPClient { request in
      let json = """
      {
        "balances": [
          { "asset": "USDC", "free": "10", "locked": "0" }
        ]
      }
      """
      return (Data(json.utf8), httpResponse(for: request))
    }
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let connectionId = UUID()
    let credentials = try ExchangeCredentialVault(crypto: crypto).seal(
      ExchangeCredentials(apiKey: "key", secret: "secret"),
      vaultKey: vaultKey,
      connectionId: connectionId
    )
    let connection = ExchangeConnectionRecord(
      id: connectionId,
      provider: .binance,
      label: "Binance main",
      encryptedCredentials: credentials
    )
    let scanner = NativeExchangeScanner(
      client: NativeExchangeBalanceClient(http: http, now: { Date(timeIntervalSince1970: 1_700_000_000) }),
      credentialVault: ExchangeCredentialVault(crypto: crypto),
      priceProvider: StaticPriceProvider(values: [:])
    )

    let result = await scanner.scan(connections: [connection], vaultKey: vaultKey)

    XCTAssertEqual(result.holdings.first?.symbol, "USDC")
    XCTAssertEqual(result.holdings.first?.valueUsd, 10)
    XCTAssertEqual(result.connections.first?.status, .ok)
    XCTAssertNil(result.connections.first?.lastError)
    XCTAssertTrue(result.warnings.isEmpty)
  }
}

private struct StubHTTPClient: HTTPClient, @unchecked Sendable {
  let handler: (URLRequest) throws -> (Data, HTTPURLResponse)

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try handler(request)
  }
}

private func httpResponse(for request: URLRequest, statusCode: Int = 200) -> HTTPURLResponse {
  HTTPURLResponse(
    url: request.url ?? URL(string: "https://example.com")!,
    statusCode: statusCode,
    httpVersion: "HTTP/1.1",
    headerFields: ["content-type": "application/json"]
  )!
}
