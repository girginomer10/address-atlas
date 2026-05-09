import Foundation

public struct NativeScanner: Sendable {
  private let http: JSONHTTPClient
  private let priceProvider: PriceProviding
  private let endpointConfig: NativeEndpointConfig

  public init(
    http: JSONHTTPClient = JSONHTTPClient(),
    endpointConfig: NativeEndpointConfig = .bundled,
    priceProvider: PriceProviding? = nil
  ) {
    self.http = http
    self.endpointConfig = endpointConfig
    self.priceProvider = priceProvider ?? CoinGeckoPriceClient(baseURL: endpointConfig.priceBaseURL, http: http)
  }

  public func scan(addresses input: String, customTokens: [CustomTokenRecord] = []) async throws -> ScanRunRecord {
    let addresses = AddressDetection.parse(input).filter(AddressDetection.isSafePublicAddress)
    let detectedChains = addresses.flatMap(AddressDetection.detectChains).map { endpointConfig.applying(to: $0) }
    let registries = Self.tokenRegistries(customTokens: customTokens)
    let tokenIds = Array(registries.evm.values.joined()).compactMap(\.coinGeckoId)
      + Array(registries.spl.values.joined()).compactMap(\.coinGeckoId)
      + Array(registries.trc20.values.joined()).compactMap(\.coinGeckoId)
    let prices = try await priceProvider.prices(for: Array(Set(detectedChains.map(\.coinGeckoId) + tokenIds)))

    var assets: [TrackedAsset] = []
    var warnings: [String] = []
    for address in addresses {
      let chains = AddressDetection.detectChains(for: address)
      if chains.isEmpty {
        warnings.append("Unsupported address skipped: \(address).")
        continue
      }
      for detectedChain in chains {
        let chain = endpointConfig.applying(to: detectedChain)
        do {
          let scanned = try await scanNative(address: address, chain: chain, prices: prices, registries: registries)
          assets.append(contentsOf: scanned.assets)
          warnings.append(contentsOf: scanned.warnings.map { "\(chain.name): \($0)" })
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

  private func scanNative(address: String, chain: ChainConfig, prices: [String: PricePoint]) async throws -> NativeScanResult {
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
  ) async throws -> NativeScanResult {
    switch chain.family {
    case .bitcoin:
      return NativeScanResult(assets: try await scanBitcoin(address: address, chain: chain, prices: prices))
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
      return try await scanTron(
        address: address,
        chain: chain,
        tokens: registries.trc20[chain.id] ?? [],
        prices: prices
      )
    case .xrp:
      return try await scanXRP(address: address, chain: chain, prices: prices)
    case .exchange:
      return NativeScanResult()
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
  ) async throws -> NativeScanResult {
    struct Response: Decodable {
      var result: String?
      var error: RPCError?
      struct RPCError: Decodable { var message: String? }
    }
    guard let rpc = chain.rpcUrl else { return NativeScanResult() }
    let response = try await http.post(
      rpc,
      body: JSONRPCRequest(method: "eth_getBalance", params: [.string(address), .string("latest")]),
      as: Response.self
    )
    if let message = response.error?.message { throw NSError(domain: "EVM", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    let amount = Self.hexQuantityToDouble(response.result ?? "0x0", decimals: chain.decimals)
    var assets = assetIfPositive(amount: amount, address: address, chain: chain, prices: prices)
    let tokenScan = await scanErc20Balances(address: address, chain: chain, tokens: tokens, prices: prices)
    assets.append(contentsOf: tokenScan.assets)
    return NativeScanResult(assets: assets, warnings: tokenScan.warnings)
  }

  private func scanErc20Balances(
    address: String,
    chain: ChainConfig,
    tokens: [TokenConfig],
    prices: [String: PricePoint]
  ) async -> NativeScanResult {
    guard let rpc = chain.rpcUrl, !tokens.isEmpty else { return NativeScanResult() }

    do {
      let requests = tokens.enumerated().map { index, token in
        JSONRPCRequest(
          id: index + 1,
          method: "eth_call",
          params: [
            .object([
              "to": .string(token.address),
              "data": .string(Self.erc20BalanceOfData(address))
            ]),
            .string("latest")
          ]
        )
      }
      let responses = try await http.post(rpc, body: requests, as: [EvmTokenBatchResponse].self)
      return buildErc20TokenScan(
        address: address,
        chain: chain,
        tokens: tokens,
        responses: responses,
        prices: prices
      )
    } catch {
      return await scanErc20Individually(address: address, chain: chain, tokens: tokens, prices: prices)
    }
  }

  private func scanErc20Individually(
    address: String,
    chain: ChainConfig,
    tokens: [TokenConfig],
    prices: [String: PricePoint]
  ) async -> NativeScanResult {
    var assets: [TrackedAsset] = []
    var failedTokens: [String] = []

    for token in tokens {
      do {
        if let tokenAsset = try await scanErc20(address: address, chain: chain, token: token, prices: prices) {
          assets.append(tokenAsset)
        }
      } catch {
        failedTokens.append(token.symbol)
      }
    }

    let warnings = failedTokens.isEmpty
      ? []
      : ["ERC-20 token balance checks failed for \(Self.formattedSymbols(failedTokens)); token balances may be incomplete."]
    return NativeScanResult(assets: assets, warnings: warnings)
  }

  private func buildErc20TokenScan(
    address: String,
    chain: ChainConfig,
    tokens: [TokenConfig],
    responses: [EvmTokenBatchResponse],
    prices: [String: PricePoint]
  ) -> NativeScanResult {
    let responsesById = Dictionary(grouping: responses, by: \.id).compactMapValues(\.first)
    var assets: [TrackedAsset] = []
    var failedTokens: [String] = []

    for (index, token) in tokens.enumerated() {
      guard let response = responsesById[index + 1] else {
        failedTokens.append(token.symbol)
        continue
      }
      if response.error != nil {
        failedTokens.append(token.symbol)
        continue
      }
      guard let rawResult = response.result else {
        failedTokens.append(token.symbol)
        continue
      }
      let amount = Self.hexQuantityToDouble(rawResult, decimals: token.decimals)
      guard let tokenAsset = tokenAsset(amount: amount, address: address, chain: chain, token: token, prices: prices, source: .erc20) else {
        continue
      }
      assets.append(tokenAsset)
    }

    let warnings = failedTokens.isEmpty
      ? []
      : ["ERC-20 token balance checks failed for \(Self.formattedSymbols(failedTokens)); token balances may be incomplete."]
    return NativeScanResult(assets: assets, warnings: warnings)
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
    if let message = response.error?.message {
      throw NSError(domain: "EVMToken", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    let amount = Self.hexQuantityToDouble(response.result ?? "0x0", decimals: token.decimals)
    guard amount > 0 else { return nil }
    return tokenAsset(amount: amount, address: address, chain: chain, token: token, prices: prices, source: .erc20)
  }

  private func scanSolana(
    address: String,
    chain: ChainConfig,
    tokens: [TokenConfig],
    prices: [String: PricePoint]
  ) async throws -> NativeScanResult {
    struct Response: Decodable {
      var result: NativeBalance?
      var error: JSONRPCError?
      struct NativeBalance: Decodable { var value: Double }
    }
    guard let rpc = chain.rpcUrl else { return NativeScanResult() }
    var assets: [TrackedAsset] = []
    var warnings: [String] = []

    do {
      let response = try await http.post(
        rpc,
        body: JSONRPCRequest(method: "getBalance", params: [.string(address), .object(["commitment": .string("confirmed")])]),
        as: Response.self
      )
      if let error = response.error {
        throw Self.rpcError(domain: "Solana", error: error, fallback: "Native SOL balance lookup failed.")
      }
      guard let lamports = response.result?.value else {
        throw Self.messageError(domain: "Solana", message: "Native SOL balance lookup returned an empty result.")
      }
      assets.append(contentsOf: assetIfPositive(amount: lamports / pow(10, Double(chain.decimals)), address: address, chain: chain, prices: prices))
    } catch {
      warnings.append("Native SOL balance could not be read: \(error.localizedDescription)")
    }

    do {
      let splScan = try await fetchSolanaTokenBalances(rpc: rpc, owner: address, registry: tokens)
      assets.append(contentsOf: splScan.balances.compactMap { balance in
        tokenAsset(amount: balance.amount, address: address, chain: chain, token: balance.token, prices: prices, source: .spl)
      })
      warnings.append(contentsOf: splScan.warnings)
    } catch {
      warnings.append("SPL token balances failed: \(error.localizedDescription)")
    }

    return NativeScanResult(assets: assets, warnings: warnings)
  }

  private func scanCosmos(address: String, chain: ChainConfig, prices: [String: PricePoint]) async throws -> NativeScanResult {
    guard let rest = chain.restUrl, let denom = chain.nativeDenom else { return NativeScanResult() }
    let url = rest.appending(path: "cosmos/bank/v1beta1/balances/\(address)")
    let response = try await http.get(url, as: CosmosBankResponse.self)
    var assets = assetIfPositive(
      amount: Self.parseCosmosLiquid(response, denom: denom, decimals: chain.decimals),
      address: address,
      chain: chain,
      prices: prices
    )
    var warnings: [String] = []

    let delegationURL = Self.cosmosURL(
      rest: rest,
      path: "cosmos/staking/v1beta1/delegations/\(address)",
      queryItems: [URLQueryItem(name: "pagination.limit", value: "500")]
    )
    do {
      let delegationResponse = try await http.get(delegationURL, as: CosmosDelegationResponse.self)
      assets.append(contentsOf: assetIfPositive(
        amount: Self.parseCosmosDelegations(delegationResponse, denom: denom, decimals: chain.decimals),
        address: address,
        chain: chain,
        prices: prices,
        name: "\(chain.name) Staked",
        source: .staked
      ))
    } catch {
      warnings.append("Delegations could not be read; staked balance may be missing.")
    }

    let rewardsURL = rest.appending(path: "cosmos/distribution/v1beta1/delegators/\(address)/rewards")
    do {
      let rewardsResponse = try await http.get(rewardsURL, as: CosmosRewardsResponse.self)
      assets.append(contentsOf: assetIfPositive(
        amount: Self.parseCosmosRewards(rewardsResponse, denom: denom, decimals: chain.decimals),
        address: address,
        chain: chain,
        prices: prices,
        name: "\(chain.name) Rewards",
        source: .rewards
      ))
    } catch {
      warnings.append("Rewards could not be read; claimable rewards may be missing.")
    }

    return NativeScanResult(assets: assets, warnings: warnings)
  }

  private func scanTron(
    address: String,
    chain: ChainConfig,
    tokens: [TokenConfig],
    prices: [String: PricePoint]
  ) async throws -> NativeScanResult {
    guard let rest = chain.restUrl else { return NativeScanResult() }
    let url = rest.appending(path: "v1/accounts/\(address)")
    let response = try await http.get(url, as: TronAccountResponse.self)
    let account = response.data?.first
    var assets = assetIfPositive(
      amount: (account?.balance ?? 0) / pow(10, Double(chain.decimals)),
      address: address,
      chain: chain,
      prices: prices
    )

    let tokenAmounts = Self.parseTronTrc20Balances(account?.trc20 ?? [], tokens: tokens)
    assets.append(contentsOf: tokenAmounts.compactMap { entry in
      tokenAsset(amount: entry.amount, address: address, chain: chain, token: entry.token, prices: prices, source: .trc20)
    })
    return NativeScanResult(assets: assets)
  }

  private func scanXRP(address: String, chain: ChainConfig, prices: [String: PricePoint]) async throws -> NativeScanResult {
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
    guard let rpc = chain.rpcUrl else { return NativeScanResult() }
    let response = try await http.post(
      rpc,
      body: XRPRequest(
        method: "account_info",
        params: [[
          "account": .string(address),
          "ledger_index": .string("validated")
        ]]
      ),
      as: Response.self
    )
    guard let result = response.result else {
      throw Self.messageError(domain: "XRP", message: "XRP account lookup returned an empty result.")
    }
    if result.error == "actNotFound" { return NativeScanResult() }
    if result.status == "error" || result.error != nil {
      throw Self.messageError(
        domain: "XRP",
        message: result.errorMessage ?? result.error ?? "XRP account lookup failed."
      )
    }
    guard let rawBalance = result.accountData?.Balance else {
      throw Self.messageError(domain: "XRP", message: "XRP account lookup returned no balance.")
    }
    let drops = Double(rawBalance) ?? 0
    var assets = assetIfPositive(amount: drops / pow(10, Double(chain.decimals)), address: address, chain: chain, prices: prices)
    var warnings: [String] = []

    do {
      let linesResponse = try await http.post(
        rpc,
        body: XRPRequest(
          method: "account_lines",
          params: [[
            "account": .string(address),
            "ledger_index": .string("validated"),
            "limit": .number(200)
          ]]
        ),
        as: XrpAccountLinesResponse.self
      )
      if let error = linesResponse.result?.error {
        throw Self.messageError(
          domain: "XRP",
          message: linesResponse.result?.errorMessage ?? error
        )
      }
      if linesResponse.result?.status == "error" {
        throw Self.messageError(
          domain: "XRP",
          message: linesResponse.result?.errorMessage ?? "XRP trust lines lookup failed."
        )
      }
      guard let lines = linesResponse.result?.lines else {
        throw Self.messageError(domain: "XRP", message: "XRP trust lines lookup returned an empty result.")
      }
      assets.append(contentsOf: Self.parseXrpTrustLines(lines, address: address, chain: chain))
    } catch {
      warnings.append("Issued-currency trustlines could not be read; only native XRP is shown.")
    }
    return NativeScanResult(assets: assets, warnings: warnings)
  }

  private func assetIfPositive(
    amount: Double,
    address: String,
    chain: ChainConfig,
    prices: [String: PricePoint],
    name: String? = nil,
    source: AssetSource = .native
  ) -> [TrackedAsset] {
    guard amount > 0 else { return [] }
    let price = prices[chain.coinGeckoId] ?? PricePoint(usd: 0)
    return [
      TrackedAsset(
        id: "\(address)-\(chain.id)-\(chain.symbol)-\(source.rawValue)",
        address: address,
        chainId: chain.id,
        chainName: chain.name,
        family: chain.family,
        symbol: chain.symbol,
        name: name ?? chain.name,
        amount: amount,
        priceUsd: price.usd,
        valueUsd: amount * price.usd,
        change24h: price.usd24hChange,
        explorerUrl: chain.explorerUrl.appending(path: address).absoluteString,
        source: source
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
  ) async throws -> SolanaTokenBalanceScan {
    guard !registry.isEmpty else { return SolanaTokenBalanceScan() }
    let programs = [
      "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
      "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"
    ]
    var parsedAccounts: [ParsedSplAccount] = []
    var warnings: [String] = []
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
        if let error = response.error {
          throw Self.rpcError(domain: "SolanaTokenAccounts", error: error, fallback: "Token account lookup failed.")
        }
        guard let accounts = response.result?.value else {
          throw Self.messageError(domain: "SolanaTokenAccounts", message: "Token account lookup returned an empty result.")
        }
        parsedAccounts.append(contentsOf: Self.parseSolanaTokenAccounts(accounts))
      } catch {
        warnings.append("\(Self.solanaProgramLabel(program)) token account scan failed; SPL balances may be incomplete.")
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
    let balances: [(token: TokenConfig, amount: Double)] = totals.compactMap { mint, raw in
      guard let token = registryByMint[mint] else { return nil }
      return (token, raw / pow(10, Double(token.decimals)))
    }
    return SolanaTokenBalanceScan(balances: balances, warnings: warnings)
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

  public static func parseCosmosLiquid(_ response: CosmosBankResponse, denom: String, decimals: Int) -> Double {
    let raw = Double(response.balances?.first(where: { $0.denom == denom })?.amount ?? "0") ?? 0
    return raw / pow(10, Double(decimals))
  }

  public static func parseCosmosDelegations(_ response: CosmosDelegationResponse, denom: String, decimals: Int) -> Double {
    let raw = response.delegationResponses?.reduce(0.0) { sum, item in
      guard item.balance?.denom == denom else { return sum }
      return sum + (Double(item.balance?.amount ?? "0") ?? 0)
    } ?? 0
    return raw / pow(10, Double(decimals))
  }

  public static func parseCosmosRewards(_ response: CosmosRewardsResponse, denom: String, decimals: Int) -> Double {
    let raw = response.total?.reduce(0.0) { sum, balance in
      guard balance.denom == denom else { return sum }
      return sum + (Double(balance.amount) ?? 0)
    } ?? 0
    return raw / pow(10, Double(decimals))
  }

  public static func parseTronTrc20Balances(_ balances: [[String: String]], tokens: [TokenConfig]) -> [(token: TokenConfig, amount: Double)] {
    tokens.compactMap { token in
      let raw = balances.reduce(0.0) { sum, entry in
        sum + (Double(entry[token.address] ?? "0") ?? 0)
      }
      let amount = raw / pow(10, Double(token.decimals))
      guard amount > 0 else { return nil }
      return (token, amount)
    }
  }

  public static func parseXrpTrustLines(_ lines: [XrpTrustLine], address: String, chain: ChainConfig) -> [TrackedAsset] {
    lines.compactMap { line in
      guard
        let amount = Double(line.balance),
        amount > 0
      else {
        return nil
      }
      let symbol = decodeXrplCurrency(line.currency)
      let issuer = line.account
      let shortIssuer = String(issuer.prefix(6)) + "..." + String(issuer.suffix(4))
      return TrackedAsset(
        id: "\(address)-\(chain.id)-\(symbol)-\(issuer)",
        address: address,
        chainId: chain.id,
        chainName: chain.name,
        family: chain.family,
        symbol: symbol,
        name: "\(symbol) issued by \(shortIssuer)",
        amount: amount,
        priceUsd: 0,
        valueUsd: 0,
        change24h: nil,
        explorerUrl: chain.explorerUrl.appending(path: address).absoluteString,
        source: .issued
      )
    }
  }

  public static func decodeXrplCurrency(_ value: String) -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count == 40, normalized.allSatisfy(\.isHexDigit) else {
      return normalized
    }
    var bytes: [UInt8] = []
    var index = normalized.startIndex
    while index < normalized.endIndex {
      let next = normalized.index(index, offsetBy: 2)
      let byteString = String(normalized[index..<next])
      if let byte = UInt8(byteString, radix: 16), byte >= 32, byte <= 126 {
        bytes.append(byte)
      }
      index = next
    }
    let decoded = String(bytes: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return decoded.isEmpty ? "\(normalized.prefix(8))..." : decoded
  }

  public static func erc20BalanceOfData(_ owner: String) -> String {
    let normalized = owner.replacingOccurrences(of: "0x", with: "").lowercased()
    return "0x70a08231\(String(repeating: "0", count: max(0, 64 - normalized.count)))\(normalized)"
  }

  public static func tokenRegistries(customTokens: [CustomTokenRecord]) -> TokenRegistries {
    var evm = ChainRegistry.commonErc20Tokens
    var spl = ChainRegistry.commonSplTokens
    var trc20 = ChainRegistry.commonTrc20Tokens

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
      } else if token.chainKind == .tron {
        appendUnique(config, to: &trc20[token.chainId, default: []])
      }
    }

    return TokenRegistries(evm: evm, spl: spl, trc20: trc20)
  }

  private static func appendUnique(_ token: TokenConfig, to tokens: inout [TokenConfig]) {
    guard !tokens.contains(where: { $0.address.lowercased() == token.address.lowercased() }) else {
      return
    }
    tokens.append(token)
  }

  private static func formattedSymbols(_ symbols: [String]) -> String {
    let unique = Array(Set(symbols)).sorted()
    guard unique.count > 5 else { return unique.joined(separator: ", ") }
    return "\(unique.prefix(5).joined(separator: ", ")) and \(unique.count - 5) more"
  }

  private static func solanaProgramLabel(_ program: String) -> String {
    switch program {
    case "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA":
      return "SPL Token"
    case "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb":
      return "Token-2022"
    default:
      return program
    }
  }

  public static func hexQuantityToDouble(_ value: String, decimals: Int) -> Double {
    let clean = value.replacingOccurrences(of: "0x", with: "")
    let padded = clean.isEmpty
      ? "00"
      : (clean.count.isMultiple(of: 2) ? clean : "0\(clean)")
    guard let data = try? Data(hex: padded) else { return 0 }
    let raw = data.reduce(0.0) { $0 * 256 + Double($1) }
    return raw / pow(10, Double(decimals))
  }

  private static func rpcError(domain: String, error: JSONRPCError, fallback: String) -> NSError {
    messageError(domain: domain, message: error.message ?? fallback, code: error.code ?? 1)
  }

  private static func messageError(domain: String, message: String, code: Int = 1) -> NSError {
    NSError(domain: "AddressAtlas.\(domain)", code: code, userInfo: [NSLocalizedDescriptionKey: message])
  }

  private static func cosmosURL(rest: URL, path: String, queryItems: [URLQueryItem]) -> URL {
    let url = rest.appending(path: path)
    guard !queryItems.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url
    }
    components.queryItems = queryItems
    return components.url ?? url
  }
}

public struct TokenRegistries: Sendable {
  public var evm: [String: [TokenConfig]]
  public var spl: [String: [TokenConfig]]
  public var trc20: [String: [TokenConfig]]
}

private struct NativeScanResult: Sendable {
  var assets: [TrackedAsset] = []
  var warnings: [String] = []
}

private struct SolanaTokenBalanceScan: Sendable {
  var balances: [(token: TokenConfig, amount: Double)] = []
  var warnings: [String] = []
}

public struct ParsedSplAccount: Equatable, Sendable {
  public var mint: String
  public var rawAmount: Double
  public var decimals: Int
}

public struct SolanaTokenAccountsResponse: Decodable, Sendable {
  public var result: Result?
  public var error: JSONRPCError?

  public struct Result: Decodable, Sendable {
    public var value: [SolanaTokenAccount]
  }
}

public struct JSONRPCError: Decodable, Sendable {
  public var code: Int?
  public var message: String?
}

private struct EvmTokenBatchResponse: Decodable, Sendable {
  var id: Int
  var result: String?
  var error: JSONRPCError?
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

public struct CosmosBankResponse: Decodable, Sendable {
  public var balances: [CosmosBalance]?
}

public struct CosmosDelegationResponse: Decodable, Sendable {
  public var delegationResponses: [CosmosDelegation]?

  enum CodingKeys: String, CodingKey {
    case delegationResponses = "delegation_responses"
  }
}

public struct CosmosRewardsResponse: Decodable, Sendable {
  public var total: [CosmosBalance]?
}

public struct CosmosDelegation: Decodable, Sendable {
  public var balance: CosmosBalance?
}

public struct CosmosBalance: Decodable, Sendable {
  public var denom: String
  public var amount: String
}

public struct TronAccountResponse: Decodable, Sendable {
  public var data: [Account]?

  public struct Account: Decodable, Sendable {
    public var balance: Double?
    public var trc20: [[String: String]]?
  }
}

public struct XrpAccountLinesResponse: Decodable, Sendable {
  public var result: Result?

  public struct Result: Decodable, Sendable {
    public var status: String?
    public var error: String?
    public var errorMessage: String?
    public var lines: [XrpTrustLine]?

    enum CodingKeys: String, CodingKey {
      case status
      case error
      case errorMessage = "error_message"
      case lines
    }
  }
}

public struct XrpTrustLine: Decodable, Sendable {
  public var account: String
  public var balance: String
  public var currency: String
}

private struct XRPRequest: Encodable {
  var method: String
  var params: [[String: XRPValue]]
}

private enum XRPValue: Encodable {
  case string(String)
  case number(Int)

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    }
  }
}

private struct JSONRPCRequest: Encodable {
  var jsonrpc = "2.0"
  var id = 1
  var method: String
  var params: [RPCValue]

  init(id: Int = 1, method: String, params: [RPCValue]) {
    self.id = id
    self.method = method
    self.params = params
  }
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
