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
    let tokenIds = customTokens.compactMap(\.coinGeckoId)
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
          let scanned = try await scanNative(address: address, chain: chain, prices: prices)
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
    switch chain.family {
    case .bitcoin:
      return try await scanBitcoin(address: address, chain: chain, prices: prices)
    case .evm:
      return try await scanEVM(address: address, chain: chain, prices: prices)
    case .solana:
      return try await scanSolana(address: address, chain: chain, prices: prices)
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

  private func scanEVM(address: String, chain: ChainConfig, prices: [String: PricePoint]) async throws -> [TrackedAsset] {
    struct Request: Encodable {
      var jsonrpc = "2.0"
      var id = 1
      var method: String
      var params: [String]
    }
    struct Response: Decodable {
      var result: String?
      var error: RPCError?
      struct RPCError: Decodable { var message: String? }
    }
    guard let rpc = chain.rpcUrl else { return [] }
    let response = try await http.post(rpc, body: Request(method: "eth_getBalance", params: [address, "latest"]), as: Response.self)
    if let message = response.error?.message { throw NSError(domain: "EVM", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    let amount = Self.hexQuantityToDouble(response.result ?? "0x0", decimals: chain.decimals)
    return assetIfPositive(amount: amount, address: address, chain: chain, prices: prices)
  }

  private func scanSolana(address: String, chain: ChainConfig, prices: [String: PricePoint]) async throws -> [TrackedAsset] {
    struct Request: Encodable {
      var jsonrpc = "2.0"
      var id = 1
      var method = "getBalance"
      var params: [SolanaParam]
    }
    enum SolanaParam: Encodable {
      case string(String)
      case config([String: String])
      func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .config(let value): try container.encode(value)
        }
      }
    }
    struct Response: Decodable {
      var result: Result?
      struct Result: Decodable { var value: Double }
    }
    guard let rpc = chain.rpcUrl else { return [] }
    let response = try await http.post(
      rpc,
      body: Request(params: [.string(address), .config(["commitment": "confirmed"])]),
      as: Response.self
    )
    return assetIfPositive(amount: (response.result?.value ?? 0) / pow(10, Double(chain.decimals)), address: address, chain: chain, prices: prices)
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

  public static func hexQuantityToDouble(_ value: String, decimals: Int) -> Double {
    let clean = value.replacingOccurrences(of: "0x", with: "")
    guard let data = try? Data(hex: clean.isEmpty ? "00" : clean) else { return 0 }
    let raw = data.reduce(0.0) { $0 * 256 + Double($1) }
    return raw / pow(10, Double(decimals))
  }
}
