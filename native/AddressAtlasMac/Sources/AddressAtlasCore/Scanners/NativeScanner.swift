import Foundation

public struct NativeScanner: Sendable {
  private let http: JSONHTTPClient
  private let priceProvider: PriceProviding

  public init(http: JSONHTTPClient = JSONHTTPClient(), priceProvider: PriceProviding = CoinGeckoPriceClient()) {
    self.http = http
    self.priceProvider = priceProvider
  }

  public func scan(addresses input: String, customTokens: [CustomTokenRecord] = []) async throws -> ScanRunRecord {
    let addresses = AddressDetection.parse(input).filter(AddressDetection.isSafePublicAddress)
    let detectedChains = addresses.flatMap(AddressDetection.detectChains)
    let registries = Self.tokenRegistries(customTokens: customTokens)
    let tokenIds = Array(registries.evm.values.joined()).compactMap(\.coinGeckoId)
      + Array(registries.spl.values.joined()).compactMap(\.coinGeckoId)
    let prices = try await priceProvider.prices(for: Array(Set(detectedChains.map(\.coinGeckoId) + tokenIds)))

    var assets: [TrackedAsset] = []
    var warnings: [String] = []
    for address in addresses {
      let chains = AddressDetection.detectChains(for: address)
      if chains.isEmpty {
        warnings.append("Unsupported address skipped: \(address).")
        continue
      }
      for chain in chains {
        do {
          let scanned = try await scanNative(address: address, chain: chain, prices: prices, registries: registries)
          assets.append(contentsOf: scanned)
        } catch {
          warnings.append("\(chain.name): \(error.localizedDescription)")
        }
      }
    }

    return ScanRunRecord(
      totalUsd: assets.reduce(0) { $0 + $1.valueUsd },
      inputCount: addresses.count,
      holdings: assets,
      warnings: warnings
    )
  }

  private func scanNative(address: String, chain: ChainConfig, prices: [String: PricePoint]) async throws -> [TrackedAsset] {
    try await scanNative(
      address: address,
      chain: chain,
      prices: prices,
      registries: Self.tokenRegistries(customTokens: [])
    )
  }

  private func scanNative(
    address: String,
    chain: ChainConfig,
    prices: [String: PricePoint],
    registries: TokenRegistries
  ) async throws -> [TrackedAsset] {
    switch chain.family {
    case .bitcoin:
      return try await scanBitcoin(address: address, chain: chain, prices: prices)
    case .evm:
      return try await scanEVM(
        address: address,
        chain: chain,
        tokens: registries.evm[chain.id] ?? [],
        prices: prices
      )
    case .solana:
      return try await scanSolana(
        address: address,
        chain: chain,
        tokens: registries.spl[chain.id] ?? [],
        prices: prices
      )
    case .cosmos:
      return try await scanCosmos(address: address, chain: chain, prices: prices)
    case .tron:
      return try await scanTron(address: address, chain: chain, prices: prices)
    case .xrp:
      return try await scanXRP(address: address, chain: chain, prices: prices)
    case .exchange:
      return []
    }
  }

  private func scanBitcoin(address: String, chain: ChainConfig, prices: [String: PricePoint]) async throws -> [TrackedAsset] {
    struct Response: Decodable {
      var chainStats: Stats
      var mempoolStats: Stats?
      struct Stats: Decodable {
        var fundedTxoSum: Double
        var spentTxoSum: Double
        enum CodingKeys: String, CodingKey {
          case fundedTxoSum = "funded_txo_sum"
          case spentTxoSum = "spent_txo_sum"
        }
      }
      enum CodingKeys: String, CodingKey {
        case chainStats = "chain_stats"
        case mempoolStats = "mempool_stats"
      }
    }
    let url = chain.restUrl!.appending(path: "address/\(address)")
    let response = try await http.get(url, as: Response.self)
    let sats = (response.chainStats.fundedTxoSum - response.chainStats.spentTxoSum)
      + ((response.mempoolStats?.fundedTxoSum ?? 0) - (response.mempoolStats?.spentTxoSum ?? 0))
    return assetIfPositive(amount: sats / pow(10, Double(chain.decimals)), address: address, chain: chain, prices: prices)
  }

  private func scanEVM(
    address: String,
    chain: ChainConfig,
    tokens: [TokenConfig],
    prices: [String: PricePoint]
  ) async throws -> [TrackedAsset] {
    struct Response: Decodable {
      var result: String?
      var error: RPCError?
      struct RPCError: Decodable { var message: String? }
    }
    guard let rpc = chain.rpcUrl else { return [] }
    let response = try await http.post(
      rpc,
      body: JSONRPCRequest(method: "eth_getBalance", params: [.string(address), .string("latest")]),
      as: Response.self
    )
    if let message = response.error?.message { throw NSError(domain: "EVM", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    let amount = Self.hexQuantityToDouble(response.result ?? "0x0", decimals: chain.decimals)
    var assets = assetIfPositive(amount: amount, address: address, chain: chain, prices: prices)

    for token in tokens {
      do {
        if let tokenAsset = try await scanErc20(address: address, chain: chain, token: token, prices: prices) {
          assets.append(tokenAsset)
        }
      } catch {
        continue
      }
    }

    return assets
  }

  private func scanErc20(address: String, chain: ChainConfig, token: TokenConfig, prices: [String: PricePoint]) async throws -> TrackedAsset? {
    struct Response: Decodable {
      var result: String?
      var error: RPCError?
      struct RPCError: Decodable { var message: String? }
    }
    guard let rpc = chain.rpcUrl else { return nil }
    let response = try await http.post(
      rpc,
      body: JSONRPCRequest(
        method: "eth_call",
        params: [
          .object([
            "to": .string(token.address),
            "data": .string(Self.erc20BalanceOfData(address))
          ]),
          .string("latest")
        ]
      ),
      as: Response.self
    )
    if response.error != nil { return nil }
    let amount = Self.hexQuantityToDouble(response.result ?? "0x0", decimals: token.decimals)
    guard amount > 0 else { return nil }
    return tokenAsset(amount: amount, address: address, chain: chain, token: token, prices: prices, source: .erc20)
  }

  private func scanSolana(
    address: String,
    chain: ChainConfig,
    tokens: [TokenConfig],
    prices: [String: PricePoint]
  ) async throws -> [TrackedAsset] {
    struct Response: Decodable {
      var result: NativeBalance?
      struct NativeBalance: Decodable { var value: Double }
    }
    guard let rpc = chain.rpcUrl else { return [] }
    let response = try await http.post(
      rpc,
      body: JSONRPCRequest(method: "getBalance", params: [.string(address), .object(["commitment": .string("confirmed")])]),
      as: Response.self
    )
    var assets = assetIfPositive(amount: (response.result?.value ?? 0) / pow(10, Double(chain.decimals)), address: address, chain: chain, prices: prices)
    let splBalances = try await fetchSolanaTokenBalances(rpc: rpc, owner: address, registry: tokens)
    assets.append(contentsOf: splBalances.compactMap { balance in
      tokenAsset(amount: balance.amount, address: address, chain: chain, token: balance.token, prices: prices, source: .spl)
    })
    return assets
  }

  private func scanCosmos(address: String, chain: ChainConfig, prices: [String: PricePoint]) async throws -> [TrackedAsset] {
    struct Response: Decodable {
      var balances: [Balance]?
      struct Balance: Decodable {
        var denom: String
        var amount: String
      }
    }
    guard let rest = chain.restUrl, let denom = chain.nativeDenom else { return [] }
    let url = rest.appending(path: "cosmos/bank/v1beta1/balances/\(address)")
    let response = try await http.get(url, as: Response.self)
    let raw = Double(response.balances?.first(where: { $0.denom == denom })?.amount ?? "0") ?? 0
    return assetIfPositive(amount: raw / pow(10, Double(chain.decimals)), address: address, chain: chain, prices: prices)
  }

  private func scanTron(address: String, chain: ChainConfig, prices: [String: PricePoint]) async throws -> [TrackedAsset] {
    struct Response: Decodable {
      var data: [Account]?
      struct Account: Decodable { var balance: Double? }
    }
    guard let rest = chain.restUrl else { return [] }
    let url = rest.appending(path: "v1/accounts/\(address)")
    let response = try await http.get(url, as: Response.self)
    return assetIfPositive(amount: (response.data?.first?.balance ?? 0) / pow(10, Double(chain.decimals)), address: address, chain: chain, prices: prices)
  }

  private func scanXRP(address: String, chain: ChainConfig, prices: [String: PricePoint]) async throws -> [TrackedAsset] {
    struct Request: Encodable {
      var method = "account_info"
      var params: [[String: String]]
    }
    struct Response: Decodable {
      var result: Result?
      struct Result: Decodable {
        var status: String?
        var accountData: Account?
        var error: String?
        var errorMessage: String?
        enum CodingKeys: String, CodingKey {
          case status
          case accountData = "account_data"
          case error
          case errorMessage = "error_message"
        }
      }
      struct Account: Decodable { var Balance: String? }
    }
    guard let rpc = chain.rpcUrl else { return [] }
    let response = try await http.post(rpc, body: Request(params: [["account": address, "ledger_index": "validated"]]), as: Response.self)
    if response.result?.error == "actNotFound" { return [] }
    let drops = Double(response.result?.accountData?.Balance ?? "0") ?? 0
    return assetIfPositive(amount: drops / pow(10, Double(chain.decimals)), address: address, chain: chain, prices: prices)
  }

  private func assetIfPositive(amount: Double, address: String, chain: ChainConfig, prices: [String: PricePoint]) -> [TrackedAsset] {
    guard amount > 0 else { return [] }
    let price = prices[chain.coinGeckoId] ?? PricePoint(usd: 0)
    return [
      TrackedAsset(
        id: "\(address)-\(chain.id)-\(chain.symbol)-native",
        address: address,
        chainId: chain.id,
        chainName: chain.name,
        family: chain.family,
        symbol: chain.symbol,
        name: chain.name,
        amount: amount,
        priceUsd: price.usd,
        valueUsd: amount * price.usd,
        change24h: price.usd24hChange,
        explorerUrl: chain.explorerUrl.appending(path: address).absoluteString,
        source: .native
      )
    ]
  }

  private func tokenAsset(
    amount: Double,
    address: String,
    chain: ChainConfig,
    token: TokenConfig,
    prices: [String: PricePoint],
    source: AssetSource
  ) -> TrackedAsset? {
    guard amount > 0 else { return nil }
    let price = token.coinGeckoId.flatMap { prices[$0] }
    let priceUsd = price?.usd ?? token.priceUsd ?? 0
    return TrackedAsset(
      id: "\(address)-\(chain.id)-\(token.symbol)-\(token.address)",
      address: address,
      chainId: chain.id,
      chainName: chain.name,
      family: chain.family,
      symbol: token.symbol,
      name: token.name,
      amount: amount,
      priceUsd: priceUsd,
      valueUsd: amount * priceUsd,
      change24h: price?.usd24hChange,
      explorerUrl: chain.explorerUrl.appending(path: address).absoluteString,
      source: source
    )
  }

  private func fetchSolanaTokenBalances(
    rpc: URL,
    owner: String,
    registry: [TokenConfig]
  ) async throws -> [(token: TokenConfig, amount: Double)] {
    guard !registry.isEmpty else { return [] }
    let programs = [
      "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
      "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"
    ]
    var parsedAccounts: [ParsedSplAccount] = []
    for program in programs {
      do {
        let response = try await http.post(
          rpc,
          body: JSONRPCRequest(
            method: "getTokenAccountsByOwner",
            params: [
              .string(owner),
              .object(["programId": .string(program)]),
              .object([
                "encoding": .string("jsonParsed"),
                "commitment": .string("confirmed")
              ])
            ]
          ),
          as: SolanaTokenAccountsResponse.self
        )
        parsedAccounts.append(contentsOf: Self.parseSolanaTokenAccounts(response.result?.value ?? []))
      } catch {
        continue
      }
    }

    let registryByMint = Dictionary(uniqueKeysWithValues: registry.map { ($0.address, $0) })
    var totals: [String: Double] = [:]
    for account in parsedAccounts {
      guard let token = registryByMint[account.mint], token.decimals == account.decimals else {
        continue
      }
      totals[account.mint, default: 0] += account.rawAmount
    }
    return totals.compactMap { mint, raw in
      guard let token = registryByMint[mint] else { return nil }
      return (token, raw / pow(10, Double(token.decimals)))
    }
  }

  public static func parseSolanaTokenAccounts(_ accounts: [SolanaTokenAccount]) -> [ParsedSplAccount] {
    accounts.compactMap { account in
      guard
        let info = account.account.data.parsed?.info,
        let amount = Double(info.tokenAmount.amount)
      else {
        return nil
      }
      return ParsedSplAccount(mint: info.mint, rawAmount: amount, decimals: info.tokenAmount.decimals)
    }
  }

  public static func erc20BalanceOfData(_ owner: String) -> String {
    let normalized = owner.replacingOccurrences(of: "0x", with: "").lowercased()
    return "0x70a08231\(String(repeating: "0", count: max(0, 64 - normalized.count)))\(normalized)"
  }

  public static func tokenRegistries(customTokens: [CustomTokenRecord]) -> TokenRegistries {
    var evm = ChainRegistry.commonErc20Tokens
    var spl = ChainRegistry.commonSplTokens

    for token in customTokens where token.enabled {
      let config = TokenConfig(
        symbol: token.symbol,
        name: token.name,
        address: token.address,
        decimals: token.decimals,
        coinGeckoId: token.coinGeckoId,
        priceUsd: token.priceUsd
      )
      if token.chainKind == .evm {
        appendUnique(config, to: &evm[token.chainId, default: []])
      } else if token.chainKind == .solana {
        appendUnique(config, to: &spl[token.chainId, default: []])
      }
    }

    return TokenRegistries(evm: evm, spl: spl)
  }

  private static func appendUnique(_ token: TokenConfig, to tokens: inout [TokenConfig]) {
    guard !tokens.contains(where: { $0.address.lowercased() == token.address.lowercased() }) else {
      return
    }
    tokens.append(token)
  }

  public static func hexQuantityToDouble(_ value: String, decimals: Int) -> Double {
    let clean = value.replacingOccurrences(of: "0x", with: "")
    guard let data = try? Data(hex: clean.isEmpty ? "00" : clean) else { return 0 }
    let raw = data.reduce(0.0) { $0 * 256 + Double($1) }
    return raw / pow(10, Double(decimals))
  }
}

public struct TokenRegistries: Sendable {
  public var evm: [String: [TokenConfig]]
  public var spl: [String: [TokenConfig]]
}

public struct ParsedSplAccount: Equatable, Sendable {
  public var mint: String
  public var rawAmount: Double
  public var decimals: Int
}

public struct SolanaTokenAccountsResponse: Decodable, Sendable {
  public var result: Result?

  public struct Result: Decodable, Sendable {
    public var value: [SolanaTokenAccount]
  }
}

public struct SolanaTokenAccount: Decodable, Sendable {
  public var account: Account

  public struct Account: Decodable, Sendable {
    public var data: AccountData
  }

  public struct AccountData: Decodable, Sendable {
    public var parsed: Parsed?
  }

  public struct Parsed: Decodable, Sendable {
    public var info: Info
  }

  public struct Info: Decodable, Sendable {
    public var mint: String
    public var tokenAmount: TokenAmount
  }

  public struct TokenAmount: Decodable, Sendable {
    public var amount: String
    public var decimals: Int
  }
}

private struct JSONRPCRequest: Encodable {
  var jsonrpc = "2.0"
  var id = 1
  var method: String
  var params: [RPCValue]
}

private enum RPCValue: Encodable {
  case string(String)
  case number(Double)
  case object([String: RPCValue])
  case array([RPCValue])

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    }
  }
}
