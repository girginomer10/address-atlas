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

final class RecoveryKitTests: XCTestCase {
  func testRecoveryKitWrapsAndRestoresVaultKey() throws {
    let vaultKey = try VaultCrypto().generateVaultKey()
    let codec = RecoveryKitCodec()

    let export = try codec.create(vaultKey: vaultKey)
    let restored = try codec.open(export.document, recoveryCode: export.recoveryCode)

    XCTAssertEqual(restored, vaultKey)
    XCTAssertEqual(try RecoveryKitCodec.recoveryCodeBytes(export.recoveryCode).count, 32)
    XCTAssertFalse(export.recoveryCode.isEmpty)
    XCTAssertFalse(export.document.wrappedVaultKey.contains(vaultKey.hexString))
  }

  func testRecoveryKitRejectsWrongCodeAndMissingCode() throws {
    let codec = RecoveryKitCodec()
    let vaultKey = try VaultCrypto().generateVaultKey()
    let export = try codec.create(vaultKey: vaultKey)
    let otherCode = try codec.create(vaultKey: try VaultCrypto().generateVaultKey()).recoveryCode

    XCTAssertThrowsError(try codec.open(export.document, recoveryCode: otherCode))
    XCTAssertThrowsError(try codec.open(export.document, recoveryCode: ""))
  }

  func testRecoveryKitRejectsTamperedFile() throws {
    let codec = RecoveryKitCodec()
    let vaultKey = try VaultCrypto().generateVaultKey()
    let export = try codec.create(vaultKey: vaultKey)
    var document = export.document
    var wrapped = try Base64URL.decode(document.wrappedVaultKey)

    wrapped[0] ^= 0x01
    document.wrappedVaultKey = Base64URL.encode(wrapped)

    XCTAssertThrowsError(try codec.open(document, recoveryCode: export.recoveryCode)) { error in
      XCTAssertEqual(error as? RecoveryKitError, .checksumMismatch)
    }
  }
}

final class NativeEndpointConfigTests: XCTestCase {
  func testBundledEndpointConfigCoversExpandedEvmChains() {
    XCTAssertEqual(NativeEndpointConfig.bundled.configVersion, 3)
    XCTAssertEqual(
      NativeEndpointConfig.bundled.chains["scroll"]?.rpcURL?.absoluteString,
      "https://rpc.scroll.io"
    )
    XCTAssertEqual(
      NativeEndpointConfig.bundled.chains["zksync-era"]?.rpcURL?.absoluteString,
      "https://mainnet.era.zksync.io"
    )
  }

  func testEndpointConfigOverridesChainsButKeepsExchangeEndpointsFixed() throws {
    let config = NativeEndpointConfig(
      configVersion: 3,
      priceBaseURL: URL(string: "https://prices.example/simple/price")!,
      chains: [
        "ethereum": ChainEndpointOverride(rpcURL: URL(string: "https://eth.llamarpc.com/rotated-rpc"))
      ],
      exchanges: [
        ExchangeProvider.binance.rawValue: ExchangeEndpointOverride(
          baseURL: URL(string: "https://binance.example")!,
          accountPath: "/api/v4/account"
        )
      ]
    )

    let chain = config.applying(to: ChainRegistry.evmChains.first { $0.id == "ethereum" }!)

    XCTAssertEqual(config.configVersion, 3)
    XCTAssertEqual(chain.rpcUrl?.absoluteString, "https://eth.llamarpc.com/rotated-rpc")
    XCTAssertEqual(config.exchangeBaseURL(for: .binance)?.absoluteString, "https://api.binance.com")
    XCTAssertEqual(config.exchangeAccountPath(for: .binance), "/api/v3/account")
    XCTAssertEqual(config.exchangeBaseURL(for: .coinbase)?.absoluteString, "https://api.coinbase.com")
  }

  func testEndpointConfigClientFetchesNativeConfig() async throws {
    let expected = NativeEndpointConfig(
      configVersion: 4,
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      priceBaseURL: URL(string: "https://api.coingecko.com/api/v3/simple/price")!,
      chains: ["solana": ChainEndpointOverride(rpcURL: URL(string: "https://api.mainnet-beta.solana.com/rotated"))],
      exchanges: [:]
    )
    let http = StubHTTPClient { request in
      XCTAssertEqual(request.url?.path, "/config/native")
      return (try JSONEncoder.addressAtlas.encode(expected), httpResponse(for: request))
    }
    let client = NativeEndpointConfigClient(http: http)

    let config = try await client.fetch(from: URL(string: "https://sync.example")!)

    XCTAssertEqual(config, expected)
  }

  func testEndpointConfigClientRejectsUnsafeURLsAndPaths() async throws {
    let invalid = NativeEndpointConfig(
      priceBaseURL: URL(string: "file:///tmp/prices")!,
      exchanges: [
        ExchangeProvider.binance.rawValue: ExchangeEndpointOverride(
          baseURL: URL(string: "https://binance.example")!,
          accountPath: "https://bad.example/account"
        )
      ]
    )
    let http = StubHTTPClient { request in
      (try JSONEncoder.addressAtlas.encode(invalid), httpResponse(for: request))
    }
    let client = NativeEndpointConfigClient(http: http)

    do {
      _ = try await client.fetch(from: URL(string: "https://sync.example")!)
      XCTFail("Expected unsafe endpoint config to fail.")
    } catch NativeEndpointConfigError.invalidEndpoint(_) {
      // Expected.
    }
  }

  func testEndpointConfigClientRejectsRemoteExchangeOverrides() async throws {
    let invalid = NativeEndpointConfig(
      exchanges: [
        ExchangeProvider.binance.rawValue: ExchangeEndpointOverride(
          baseURL: URL(string: "https://api.binance.com")!,
          accountPath: "/api/v3/account"
        )
      ]
    )
    let http = StubHTTPClient { request in
      (try JSONEncoder.addressAtlas.encode(invalid), httpResponse(for: request))
    }
    let client = NativeEndpointConfigClient(http: http)

    do {
      _ = try await client.fetch(from: URL(string: "https://sync.example")!)
      XCTFail("Expected plain HTTP exchange endpoint config to fail.")
    } catch NativeEndpointConfigError.invalidEndpoint(let field) {
      XCTAssertEqual(field, "exchanges")
    }
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

  func testKrakenSignerAcceptsStandardBase64SecretAndMatchesExpectedSignature() throws {
    // Kraken's published example secret contains '/', '+' and '=' characters,
    // so this also guards against accidentally using Base64URL decoding again.
    let signed = try ExchangeRequestSigner.krakenBalanceRequest(
      credentials: ExchangeCredentials(
        apiKey: "key",
        secret: "kQH5HW/8p1uGOVjbgWA7FunAmGO8lsSUXNsu3eow76sz84Q18fWxnyRzBHCd3pd5nE9qa99HAZtuZuj6F1huXg=="
      ),
      nonce: "1616492376594"
    )

    XCTAssertEqual(signed.body, "nonce=1616492376594")
    XCTAssertEqual(
      signed.headers["API-Sign"],
      "1nH4vwR+8FHiYh1QT649xXkGd3JR3x0DWkgv3u9Ed/Qqv6KPtgQpEU4m+Emb/VgpEji3j1XNwI+HCbfXxmrTOg=="
    )
  }

  func testAddressDetectionRejectsSeedLikeInput() {
    let phrase = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima"
    XCTAssertFalse(AddressDetection.isSafePublicAddress(phrase))
  }

  func testAddressDetectionPrefersSpecificBase58ChainsBeforeSolana() {
    XCTAssertEqual(
      AddressDetection.detectChains(for: "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7").map(\.id),
      ["tron"]
    )
    XCTAssertEqual(
      AddressDetection.detectChains(for: "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn").map(\.id),
      ["xrp"]
    )
  }
}

final class NativeScannerTokenTests: XCTestCase {
  func testErc20BalanceOfDataPadsOwnerAddress() {
    let data = NativeScanner.erc20BalanceOfData("0x000000000000000000000000000000000000dEaD")

    XCTAssertEqual(data.count, 74)
    XCTAssertTrue(data.hasPrefix("0x70a08231"))
    XCTAssertTrue(data.hasSuffix("000000000000000000000000000000000000dead"))
  }

  func testHexQuantityParserAcceptsOddLengthRpcQuantities() {
    XCTAssertEqual(NativeScanner.hexQuantityToDouble("0xf", decimals: 0), 15)
    XCTAssertEqual(NativeScanner.hexQuantityToDouble("0x280de80", decimals: 6), 42)
  }

  func testHexQuantityParserRejectsMalformedOrUnprefixedValues() {
    XCTAssertNil(NativeScanner.hexQuantityToDouble("0x10x20", decimals: 0))
    XCTAssertNil(NativeScanner.hexQuantityToDouble("120", decimals: 0))
    XCTAssertNil(NativeScanner.hexQuantityToDouble("0x", decimals: 0))
    XCTAssertNil(NativeScanner.hexQuantityToDouble("0x12", decimals: 37))
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

  func testEvmTokenBalancesUseJsonRpcBatchAndWarnOnPartialErrors() async throws {
    let address = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
    let recorder = BatchRequestRecorder()
    let http = StubHTTPClient { request in
      let bodyData = request.httpBody ?? Data()
      let bodyText = String(data: bodyData, encoding: .utf8) ?? ""

      if bodyText.contains("\"eth_getBalance\"") {
        return (Data(#"{"result":"0x0"}"#.utf8), httpResponse(for: request))
      }

      if bodyText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
        let payload = try JSONSerialization.jsonObject(with: bodyData) as? [[String: Any]] ?? []
        recorder.append(payload.count)
        let responses: [[String: Any]] = payload.map { item in
          let id = item["id"] as? Int ?? 0
          let params = item["params"] as? [Any] ?? []
          let call = params.first as? [String: Any] ?? [:]
          let tokenAddress = (call["to"] as? String ?? "").lowercased()

          if tokenAddress == "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" {
            return ["jsonrpc": "2.0", "id": id, "result": "0x" + String(42_000_000, radix: 16)]
          }
          if tokenAddress == "0xd533a949740bb3306d119cc777fa900ba034cd52" {
            return ["jsonrpc": "2.0", "id": id, "error": ["message": "token-rpc-down"]]
          }
          return ["jsonrpc": "2.0", "id": id, "result": "0x0"]
        }
        return (try JSONSerialization.data(withJSONObject: responses), httpResponse(for: request))
      }

      XCTFail("Unexpected EVM scanner request: \(bodyText)")
      return (Data("{}".utf8), httpResponse(for: request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: ["usd-coin": PricePoint(usd: 1)])
    )

    let result = try await scanner.scan(addresses: address)
    let usdc = result.holdings.first { $0.chainId == "ethereum" && $0.symbol == "USDC" }

    XCTAssertTrue(recorder.snapshot().contains { $0 > 1 })
    XCTAssertEqual(usdc?.amount, 42)
    XCTAssertEqual(usdc?.valueUsd, 42)
    XCTAssertTrue(result.warnings.contains { warning in
      warning.contains("Ethereum") && warning.contains("CRV")
    })
  }

  func testChainRegistryIncludesExpandedNetworksAndAssets() {
    let evmIds = Set(ChainRegistry.evmChains.map(\.id))
    XCTAssertTrue(evmIds.isSuperset(of: ["gnosis", "linea", "mantle", "scroll", "zksync-era"]))
    XCTAssertEqual(ChainRegistry.commonErc20Tokens["gnosis"]?.first { $0.symbol == "GNO" }?.decimals, 18)
    XCTAssertEqual(
      ChainRegistry.commonErc20Tokens["scroll"]?.first { $0.symbol == "USDC" }?.address,
      "0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4"
    )
    XCTAssertEqual(
      ChainRegistry.commonErc20Tokens["zksync-era"]?.first { $0.symbol == "ZK" }?.address,
      "0x5A7d6b2F92C77FAD6CCaBd7EE0624E64907Eaf3E"
    )
    XCTAssertEqual(ChainRegistry.commonSplTokens["solana"]?.first { $0.symbol == "PYTH" }?.decimals, 6)
    XCTAssertEqual(ExchangeBalanceNormalizer.coinGeckoIds["ZK"], "zksync")
    XCTAssertEqual(ExchangeBalanceNormalizer.coinGeckoIds["SCR"], "scroll")
  }

  func testBuiltinRegistriesCoverReferenceTokenSet() {
    let registries = NativeScanner.tokenRegistries(customTokens: [])

    XCTAssertTrue(registries.evm["base"]?.contains { $0.symbol == "cbBTC" } == true)
    XCTAssertTrue(registries.evm["arbitrum"]?.contains { $0.symbol == "ARB" } == true)
    XCTAssertTrue(registries.evm["optimism"]?.contains { $0.symbol == "OP" } == true)
    XCTAssertTrue(registries.evm["bsc"]?.contains { $0.symbol == "CAKE" } == true)
    XCTAssertTrue(registries.evm["avalanche"]?.contains { $0.symbol == "BTC.b" } == true)

    let solana = registries.spl["solana"] ?? []
    XCTAssertEqual(
      solana.first(where: { $0.symbol == "USDT" })?.address,
      "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB"
    )
    XCTAssertEqual(
      solana.first(where: { $0.symbol == "BONK" })?.address,
      "DezXAZ8z7PnrnRJjz3JpPZsM1pPB263KGg1W53WZyQb"
    )
    XCTAssertTrue(solana.contains { $0.symbol == "JitoSOL" })
    XCTAssertTrue(solana.contains { $0.symbol == "WIF" })
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

  func testSolanaScannerSurfacesPartialTokenProgramWarnings() async throws {
    let address = "So11111111111111111111111111111111111111112"
    let http = StubHTTPClient { request in
      let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      if body.contains("getBalance") {
        let json = """
        { "result": { "value": 1000000000 } }
        """
        return (Data(json.utf8), httpResponse(for: request))
      }
      if body.contains("getTokenAccountsByOwner") {
        throw URLError(.timedOut)
      }
      XCTFail("Unexpected scanner request: \(body)")
      return (Data("{}".utf8), httpResponse(for: request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: ["solana": PricePoint(usd: 10)])
    )

    let result = try await scanner.scan(addresses: address)

    XCTAssertEqual(result.holdings.first?.symbol, "SOL")
    XCTAssertEqual(result.holdings.first?.valueUsd, 10)
    XCTAssertTrue(result.warnings.contains { warning in
      warning.contains("Solana") && warning.contains("SPL Token token account scan failed")
    })
    XCTAssertTrue(result.warnings.contains { warning in
      warning.contains("Solana") && warning.contains("Token-2022 token account scan failed")
    })
  }

  func testSolanaJsonRpcErrorsDoNotBecomeZeroBalances() async throws {
    let address = "So11111111111111111111111111111111111111112"
    let http = StubHTTPClient { request in
      let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      if body.contains("getBalance") {
        let json = """
        { "error": { "code": -32000, "message": "node is behind" } }
        """
        return (Data(json.utf8), httpResponse(for: request))
      }
      if body.contains("getTokenAccountsByOwner") {
        let json = """
        { "result": { "value": [] } }
        """
        return (Data(json.utf8), httpResponse(for: request))
      }
      XCTFail("Unexpected scanner request: \(body)")
      return (Data("{}".utf8), httpResponse(for: request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: ["solana": PricePoint(usd: 10)])
    )

    let result = try await scanner.scan(addresses: address)

    XCTAssertFalse(result.holdings.contains { $0.symbol == "SOL" })
    XCTAssertTrue(result.warnings.contains { warning in
      warning.contains("Solana") && warning.contains("node is behind")
    })
  }

  func testXrpJsonRpcErrorsDoNotBecomeZeroBalances() async throws {
    let address = "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn"
    let http = StubHTTPClient { request in
      let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      if body.contains("account_info") {
        let json = """
        {
          "result": {
            "status": "error",
            "error": "internal",
            "error_message": "ledger unavailable"
          }
        }
        """
        return (Data(json.utf8), httpResponse(for: request))
      }
      XCTFail("Unexpected scanner request: \(body)")
      return (Data("{}".utf8), httpResponse(for: request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: ["ripple": PricePoint(usd: 2)])
    )

    let result = try await scanner.scan(addresses: address)

    XCTAssertTrue(result.holdings.isEmpty)
    XCTAssertTrue(result.warnings.contains { warning in
      warning.contains("XRP Ledger") && warning.contains("ledger unavailable")
    })
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

  func testExchangeClientIgnoresRemoteEndpointConfigForSignedRequests() async throws {
    let config = NativeEndpointConfig(
      exchanges: [
        ExchangeProvider.binance.rawValue: ExchangeEndpointOverride(
          baseURL: URL(string: "https://binance.example")!,
          accountPath: "/api/v4/account"
        )
      ]
    )
    let http = StubHTTPClient { request in
      XCTAssertEqual(request.url?.host, "api.binance.com")
      XCTAssertEqual(request.url?.path, "/api/v3/account")
      return (Data("{\"balances\":[]}".utf8), httpResponse(for: request))
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      endpointConfig: config,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    _ = try await client.fetchBalance(
      provider: .binance,
      credentials: ExchangeCredentials(apiKey: "key", secret: "secret")
    )
  }

  func testExchangeClientReportsHTTPErrorBody() async throws {
    let http = StubHTTPClient { request in
      let json = """
      { "msg": "Invalid API-key, IP, or permissions for action." }
      """
      return (Data(json.utf8), httpResponse(for: request, statusCode: 401))
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    do {
      _ = try await client.fetchBalance(
        provider: .binance,
        credentials: ExchangeCredentials(apiKey: "key", secret: "secret")
      )
      XCTFail("Expected exchange HTTP error.")
    } catch ExchangeClientError.httpError(let statusCode, let message) {
      XCTAssertEqual(statusCode, 401)
      XCTAssertEqual(message, "Invalid API-key, IP, or permissions for action.")
    }
  }

  func testExchangeClientRedactsAndCapsUntrustedErrorBody() async throws {
    let rawSecret = String(repeating: "s", count: 80)
    let http = StubHTTPClient { request in
      let data = try JSONSerialization.data(withJSONObject: [
        "message": "authorization: Bearer \(rawSecret)\n\(String(repeating: "x", count: 1_000))"
      ])
      return (data, httpResponse(for: request, statusCode: 401))
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    do {
      _ = try await client.fetchBalance(
        provider: .binance,
        credentials: ExchangeCredentials(apiKey: "key", secret: "secret")
      )
      XCTFail("Expected exchange HTTP error.")
    } catch ExchangeClientError.httpError(_, let message) {
      XCTAssertFalse(message.contains(rawSecret))
      XCTAssertFalse(message.contains("\n"))
      XCTAssertTrue(message.contains("[redacted]"))
      XCTAssertLessThanOrEqual(message.unicodeScalars.count, ProviderErrorSanitizer.maximumScalarCount + 1)
    }
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

  func testLiveExchangeReadOnlySmokeWhenConfigured() async throws {
    let credentials = try liveExchangeCredentials()
    let client = NativeExchangeBalanceClient()

    for (provider, credential) in credentials {
      let balance = try await client.fetchBalance(provider: provider, credentials: credential)
      let entries = ExchangeBalanceNormalizer.balanceEntries(balance)
      XCTAssertTrue(
        entries.allSatisfy { _, amount in amount.isFinite && amount > 0 },
        "\(provider.label) returned non-finite balance entries."
      )
    }
  }

  func testLiveInvalidExchangeCredentialsFailCleanlyWhenConfigured() async throws {
    _ = try liveExchangeCredentials()
    let client = NativeExchangeBalanceClient()
    let invalidCredentials: [(ExchangeProvider, ExchangeCredentials)] = [
      (.binance, ExchangeCredentials(apiKey: "invalid", secret: "invalid")),
      (.coinbase, ExchangeCredentials(apiKey: "invalid", secret: "invalid", passphrase: "invalid")),
      (.kraken, ExchangeCredentials(apiKey: "invalid", secret: Data("invalid".utf8).base64EncodedString()))
    ]

    for (provider, credentials) in invalidCredentials {
      do {
        _ = try await client.fetchBalance(provider: provider, credentials: credentials)
        XCTFail("Expected \(provider.label) invalid credentials to fail.")
      } catch {
        XCTAssertFalse(error.localizedDescription.isEmpty)
      }
    }
  }

  private func liveExchangeCredentials() throws -> [(ExchangeProvider, ExchangeCredentials)] {
    let environment = ProcessInfo.processInfo.environment
    guard environment["ADDRESS_ATLAS_LIVE_EXCHANGE_TESTS"] == "1" else {
      throw XCTSkip("Set ADDRESS_ATLAS_LIVE_EXCHANGE_TESTS=1 to run live exchange smoke tests.")
    }

    var missing: [String] = []
    func require(_ name: String) -> String {
      guard let value = environment[name], !value.isEmpty else {
        missing.append(name)
        return ""
      }
      return value
    }

    let binance = ExchangeCredentials(
      apiKey: require("ADDRESS_ATLAS_BINANCE_API_KEY"),
      secret: require("ADDRESS_ATLAS_BINANCE_SECRET")
    )
    let coinbase = ExchangeCredentials(
      apiKey: require("ADDRESS_ATLAS_COINBASE_API_KEY"),
      secret: require("ADDRESS_ATLAS_COINBASE_SECRET"),
      passphrase: environment["ADDRESS_ATLAS_COINBASE_PASSPHRASE"]
    )
    let kraken = ExchangeCredentials(
      apiKey: require("ADDRESS_ATLAS_KRAKEN_API_KEY"),
      secret: require("ADDRESS_ATLAS_KRAKEN_SECRET")
    )

    guard missing.isEmpty else {
      throw XCTSkip("Missing live exchange smoke credentials: \(missing.sorted().joined(separator: ", ")).")
    }

    return [
      (.binance, binance),
      (.coinbase, coinbase),
      (.kraken, kraken)
    ]
  }
}

final class SyncClientTests: XCTestCase {
  func testSyncClientSurfacesExpiredSession() async throws {
    let http = StubHTTPClient { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer expired")
      let json = """
      { "error": "Token expired." }
      """
      return (Data(json.utf8), httpResponse(for: request, statusCode: 401))
    }
    let client = ZeroKnowledgeSyncClient(baseURL: URL(string: "https://sync.example")!, http: http)
    await client.setBearerToken("expired")

    do {
      _ = try await client.latestVault()
      XCTFail("Expected expired session to throw.")
    } catch SyncClientError.authenticationRequired(let message) {
      XCTAssertEqual(message, "Token expired.")
    }
  }

  func testSyncClientSurfacesStaleUploadConflict() async throws {
    let http = StubHTTPClient { request in
      XCTAssertEqual(request.httpMethod, "PUT")
      let json = """
      { "error": "Remote vault snapshot is newer. Download before uploading again." }
      """
      return (Data(json.utf8), httpResponse(for: request, statusCode: 409))
    }
    let snapshot = RemoteVaultSnapshot(
      version: 1,
      envelope: EncryptedVaultEnvelope(
        keyId: "sync-v1",
        nonce: "abc",
        ciphertext: "ciphertext",
        checksum: String(repeating: "a", count: 64)
      ),
      byteSize: 128,
      checksum: String(repeating: "b", count: 64)
    )
    let client = ZeroKnowledgeSyncClient(baseURL: URL(string: "https://sync.example")!, http: http)
    await client.setBearerToken("current")

    do {
      try await client.upload(snapshot: snapshot)
      XCTFail("Expected stale upload conflict.")
    } catch SyncClientError.requestFailed(let statusCode, let message) {
      XCTAssertEqual(statusCode, 409)
      XCTAssertTrue(message.contains("Remote vault snapshot is newer"))
    }
  }
}

private struct StubHTTPClient: HTTPClient, @unchecked Sendable {
  let handler: (URLRequest) throws -> (Data, HTTPURLResponse)

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try handler(request)
  }
}

private final class BatchRequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var sizes: [Int] = []

  func append(_ size: Int) {
    lock.lock()
    defer { lock.unlock() }
    sizes.append(size)
  }

  func snapshot() -> [Int] {
    lock.lock()
    defer { lock.unlock() }
    return sizes
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
