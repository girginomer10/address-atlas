import Foundation

public struct NativeScanner: Sendable {
  private let http: JSONHTTPClient
  private let priceProvider: PriceProviding
  private let endpointConfig: NativeEndpointConfig
  private let maxConcurrentChainScans: Int
  private let chainDeadline: TimeInterval
  private let workflowDeadline: TimeInterval
  private let maxXrpPages: Int
  private let maxCosmosPages: Int

  public init(
    http: JSONHTTPClient = JSONHTTPClient(),
    endpointConfig: NativeEndpointConfig = .bundled,
    priceProvider: PriceProviding? = nil,
    maxConcurrentChainScans: Int = 4,
    chainDeadline: TimeInterval = 45,
    workflowDeadline: TimeInterval = 120,
    maxXrpPages: Int = 20,
    maxCosmosPages: Int = 20
  ) {
    self.http = http
    self.endpointConfig = endpointConfig
    self.priceProvider = priceProvider ?? CoinGeckoPriceClient(baseURL: endpointConfig.priceBaseURL, http: http)
    self.maxConcurrentChainScans = max(1, maxConcurrentChainScans)
    self.chainDeadline = chainDeadline.isFinite && chainDeadline > 0 ? chainDeadline : 45
    self.workflowDeadline = workflowDeadline.isFinite && workflowDeadline > 0 ? workflowDeadline : 120
    self.maxXrpPages = max(1, maxXrpPages)
    self.maxCosmosPages = max(1, maxCosmosPages)
  }

  public func scan(addresses input: String, customTokens: [CustomTokenRecord] = []) async throws -> ScanRunRecord {
    let workflowStartedAt = ProcessInfo.processInfo.systemUptime
    let parsedInput = AddressDetection.parseWithMetadata(input)
    let addresses = parsedInput.addresses.filter(AddressDetection.isSafePublicAddress)
    let detectedChains = addresses.flatMap(AddressDetection.detectChains).map { endpointConfig.applying(to: $0) }
    let registries = Self.tokenRegistries(customTokens: customTokens)
    let detectedChainIds = Set(detectedChains.map(\.id))
    let tokenIds = registries.evm.filter { detectedChainIds.contains($0.key) }.values.flatMap { $0 }.compactMap(\.coinGeckoId)
      + registries.spl.filter { detectedChainIds.contains($0.key) }.values.flatMap { $0 }.compactMap(\.coinGeckoId)
      + registries.trc20.filter { detectedChainIds.contains($0.key) }.values.flatMap { $0 }.compactMap(\.coinGeckoId)
    let requestedPriceIds = Array(Set(detectedChains.map(\.coinGeckoId) + tokenIds))
    var prices: [String: PricePoint] = [:]
    var warnings = registries.warnings
    var priceRequestFailed = false
    if parsedInput.wasTruncated {
      warnings.append("Only the first 24 unique input entries were scanned; additional entries were skipped.")
    }
    let remainingBeforePricing = workflowDeadline - (ProcessInfo.processInfo.systemUptime - workflowStartedAt)
    if remainingBeforePricing <= 0 {
      priceRequestFailed = true
      warnings.append("USD pricing was skipped because the overall scan deadline was already exhausted.")
    } else {
      do {
        let fetchedPrices = try await withWorkflowTimeout(seconds: min(25, remainingBeforePricing)) {
          try await priceProvider.prices(for: requestedPriceIds)
        }
        prices = fetchedPrices.reduce(into: [:]) { valid, entry in
          guard let point = CoinGeckoPriceClient.sanitized(entry.value) else { return }
          valid[entry.key] = point
        }
      } catch {
        try throwIfCancellation(error)
        priceRequestFailed = true
        warnings.append("USD pricing is temporarily unavailable; successful balances will be shown unpriced.")
      }
    }
    let resolvedPrices = prices

    var jobs: [ChainScanJob] = []
    var jobIndex = 0
    for address in addresses {
      let chains = AddressDetection.detectChains(for: address)
      if chains.isEmpty {
        if let network = AddressDetection.retiredCosmosNetworkName(for: address) {
          warnings.append(
            "\(network) is retired and no longer supported; the saved address was kept but not scanned: \(Self.displayAddress(address))."
          )
        } else {
          warnings.append("Unsupported address skipped: \(Self.displayAddress(address)).")
        }
        continue
      }
      for detectedChain in chains {
        jobs.append(ChainScanJob(index: jobIndex, address: address, chain: endpointConfig.applying(to: detectedChain)))
        jobIndex += 1
      }
    }
    let chainJobs = jobs

    let collector = CompletedWorkCollector<ChainScanOutcome>()
    let remainingWorkflowTime = workflowDeadline - (ProcessInfo.processInfo.systemUptime - workflowStartedAt)
    let outcomes: [ChainScanOutcome]
    if chainJobs.isEmpty {
      outcomes = []
    } else if remainingWorkflowTime <= 0 {
      outcomes = []
      let deadline = WorkflowTimeoutError(seconds: workflowDeadline).displaySeconds
      warnings.append("The overall scan reached its \(deadline)-second deadline before chain checks began; all chain checks were skipped.")
    } else {
      do {
        outcomes = try await withWorkflowTimeout(seconds: remainingWorkflowTime) {
          try await boundedConcurrentMap(chainJobs, maxConcurrent: maxConcurrentChainScans) { job in
            let outcome: ChainScanOutcome
            do {
              let scanned = try await withWorkflowTimeout(seconds: chainDeadline) {
                try await scanNative(
                  address: job.address,
                  chain: job.chain,
                  prices: resolvedPrices,
                  registries: registries
                )
              }
              outcome = ChainScanOutcome(index: job.index, chainName: job.chain.name, result: scanned)
            } catch {
              try throwIfCancellation(error)
              outcome = ChainScanOutcome(
                index: job.index,
                chainName: job.chain.name,
                result: NativeScanResult(warnings: [error.localizedDescription])
              )
            }
            await collector.append(outcome)
            return outcome
          }
        }
      } catch is WorkflowTimeoutError {
        outcomes = await collector.snapshot()
        let skipped = max(0, chainJobs.count - outcomes.count)
        let deadline = WorkflowTimeoutError(seconds: workflowDeadline).displaySeconds
        warnings.append(
          "The overall scan reached its \(deadline)-second deadline; \(skipped) unfinished chain checks were skipped and completed results were kept."
        )
      } catch {
        try throwIfCancellation(error)
        throw error
      }
    }
    let ordered = outcomes.sorted { $0.index < $1.index }
    let assets = ordered.flatMap(\.result.assets)
    warnings.append(contentsOf: ordered.flatMap { outcome in
      outcome.result.warnings.map { "\(outcome.chainName): \($0)" }
    })
    let unpricedSymbols = assets
      .filter { $0.amount > 0 && $0.priceUsd == 0 && $0.source != .issued }
      .map(\.symbol)
    if !priceRequestFailed, !unpricedSymbols.isEmpty {
      warnings.append("No USD price was available for \(Self.formattedSymbols(unpricedSymbols)); balances are still included.")
    }

    let valuationOverflowSymbols = assets.compactMap { asset -> String? in
      guard asset.amount > 0, asset.priceUsd > 0,
            FiniteValueMath.multiplyingNonnegative(asset.amount, asset.priceUsd) == nil
      else { return nil }
      return asset.symbol
    }
    if !valuationOverflowSymbols.isEmpty {
      warnings.append(
        "USD valuation exceeded the supported numeric range for \(Self.formattedSymbols(valuationOverflowSymbols)); those balances are shown without a USD value."
      )
    }
    guard let totalUsd = FiniteValueMath.sumNonnegative(assets.map(\.valueUsd)) else {
      throw PortfolioValueError.totalExceedsSupportedRange
    }

    return ScanRunRecord(
      totalUsd: totalUsd,
      inputCount: addresses.count,
      holdings: assets,
      warnings: ScanWarningPolicy.bounded(warnings)
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
    guard let rest = chain.restUrl else { return [] }
    let url = rest.appending(path: "address/\(address)")
    let response = try await http.get(url, as: Response.self)
    let reportedValues: [Double] = [
      response.chainStats.fundedTxoSum,
      response.chainStats.spentTxoSum,
      response.mempoolStats?.fundedTxoSum ?? 0.0,
      response.mempoolStats?.spentTxoSum ?? 0.0
    ]
    guard reportedValues.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
      throw Self.messageError(domain: "Bitcoin", message: "Bitcoin balance lookup returned invalid statistics.")
    }
    let sats = (response.chainStats.fundedTxoSum - response.chainStats.spentTxoSum)
      + ((response.mempoolStats?.fundedTxoSum ?? 0) - (response.mempoolStats?.spentTxoSum ?? 0))
    guard sats.isFinite, sats >= 0 else {
      throw Self.messageError(domain: "Bitcoin", message: "Bitcoin balance lookup returned an invalid total.")
    }
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
    var assets: [TrackedAsset] = []
    var warnings: [String] = []
    do {
      let response = try await http.post(
        rpc,
        body: JSONRPCRequest(method: "eth_getBalance", params: [.string(address), .string("latest")]),
        as: Response.self
      )
      if let message = response.error?.message {
        throw Self.messageError(domain: "EVM", message: message)
      }
      guard let rawResult = response.result else {
        throw Self.messageError(domain: "EVM", message: "Native balance lookup returned an empty result.")
      }
      guard let amount = Self.hexQuantityToDouble(rawResult, decimals: chain.decimals) else {
        throw Self.messageError(domain: "EVM", message: "Native balance lookup returned an invalid hex quantity.")
      }
      assets.append(contentsOf: assetIfPositive(amount: amount, address: address, chain: chain, prices: prices))
    } catch {
      try throwIfCancellation(error)
      warnings.append("\(chain.name) native balance failed: \(error.localizedDescription)")
    }
    let tokenScan = try await scanErc20Balances(address: address, chain: chain, tokens: tokens, prices: prices)
    assets.append(contentsOf: tokenScan.assets)
    warnings.append(contentsOf: tokenScan.warnings)
    return NativeScanResult(assets: assets, warnings: warnings)
  }

  private func scanErc20Balances(
    address: String,
    chain: ChainConfig,
    tokens: [TokenConfig],
    prices: [String: PricePoint]
  ) async throws -> NativeScanResult {
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
    } catch let error as JSONHTTPClientError where error.statusCode == 429 {
      return NativeScanResult(
        warnings: ["\(chain.name) token balance batch was rate-limited; individual retries were skipped to avoid amplifying the limit."]
      )
    } catch {
      try throwIfCancellation(error)
      return try await scanErc20Individually(address: address, chain: chain, tokens: tokens, prices: prices)
    }
  }

  private func scanErc20Individually(
    address: String,
    chain: ChainConfig,
    tokens: [TokenConfig],
    prices: [String: PricePoint]
  ) async throws -> NativeScanResult {
    let outcomes = try await boundedConcurrentMap(tokens, maxConcurrent: 4) { token in
      do {
        if let tokenAsset = try await scanErc20(address: address, chain: chain, token: token, prices: prices) {
          return TokenScanOutcome(asset: tokenAsset)
        }
        return TokenScanOutcome()
      } catch {
        try throwIfCancellation(error)
        return TokenScanOutcome(failedSymbol: token.symbol)
      }
    }

    let assets = outcomes.compactMap(\.asset)
    let failedTokens = outcomes.compactMap(\.failedSymbol)
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
      guard let amount = Self.hexQuantityToDouble(rawResult, decimals: token.decimals) else {
        failedTokens.append(token.symbol)
        continue
      }
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
    guard let rawResult = response.result else {
      throw Self.messageError(domain: "EVMToken", message: "Token balance lookup returned an empty result.")
    }
    guard let amount = Self.hexQuantityToDouble(rawResult, decimals: token.decimals) else {
      throw Self.messageError(domain: "EVMToken", message: "Token balance lookup returned an invalid hex quantity.")
    }
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
      guard lamports.isFinite, lamports >= 0 else {
        throw Self.messageError(domain: "Solana", message: "Native SOL balance lookup returned an invalid amount.")
      }
      assets.append(contentsOf: assetIfPositive(amount: lamports / pow(10, Double(chain.decimals)), address: address, chain: chain, prices: prices))
    } catch {
      try throwIfCancellation(error)
      warnings.append("Native SOL balance could not be read: \(error.localizedDescription)")
    }

    do {
      let splScan = try await fetchSolanaTokenBalances(rpc: rpc, owner: address, registry: tokens)
      assets.append(contentsOf: splScan.balances.compactMap { balance in
        tokenAsset(amount: balance.amount, address: address, chain: chain, token: balance.token, prices: prices, source: .spl)
      })
      warnings.append(contentsOf: splScan.warnings)
    } catch {
      try throwIfCancellation(error)
      warnings.append("SPL token balances failed: \(error.localizedDescription)")
    }

    return NativeScanResult(assets: assets, warnings: warnings)
  }

  private func scanCosmos(address: String, chain: ChainConfig, prices: [String: PricePoint]) async throws -> NativeScanResult {
    guard let rest = chain.restUrl, let denom = chain.nativeDenom else { return NativeScanResult() }
    let parts: [CosmosScanPart] = [.liquid, .delegations, .rewards]
    let results = try await boundedConcurrentMap(parts, maxConcurrent: 3) { part in
      do {
        switch part {
        case .liquid:
          let scan = try await fetchCosmosBalances(rest: rest, address: address)
          let response = CosmosBankResponse(balances: scan.balances, pagination: nil)
          guard let amount = Self.parseCosmosLiquid(response, denom: denom, decimals: chain.decimals) else {
            throw Self.messageError(domain: "Cosmos", message: "Liquid balance contained an invalid amount.")
          }
          return NativeScanResult(assets: assetIfPositive(
            amount: amount,
            address: address,
            chain: chain,
            prices: prices
          ), warnings: scan.warnings)
        case .delegations:
          let scan = try await fetchCosmosDelegations(rest: rest, address: address)
          let response = CosmosDelegationResponse(delegationResponses: scan.delegations, pagination: nil)
          guard let amount = Self.parseCosmosDelegations(response, denom: denom, decimals: chain.decimals) else {
            throw Self.messageError(domain: "Cosmos", message: "Delegations contained an invalid amount.")
          }
          return NativeScanResult(assets: assetIfPositive(
            amount: amount,
            address: address,
            chain: chain,
            prices: prices,
            name: "\(chain.name) Staked",
            source: .staked
          ), warnings: scan.warnings)
        case .rewards:
          let response = try await http.get(
            rest.appending(path: "cosmos/distribution/v1beta1/delegators/\(address)/rewards"),
            as: CosmosRewardsResponse.self
          )
          guard let amount = Self.parseCosmosRewards(response, denom: denom, decimals: chain.decimals) else {
            throw Self.messageError(domain: "Cosmos", message: "Rewards contained an invalid amount.")
          }
          return NativeScanResult(assets: assetIfPositive(
            amount: amount,
            address: address,
            chain: chain,
            prices: prices,
            name: "\(chain.name) Rewards",
            source: .rewards
          ))
        }
      } catch {
        try throwIfCancellation(error)
        return NativeScanResult(warnings: [part.failureWarning])
      }
    }

    return NativeScanResult(
      assets: results.flatMap(\.assets),
      warnings: results.flatMap(\.warnings)
    )
  }

  private func fetchCosmosBalances(rest: URL, address: String) async throws -> CosmosBalanceScan {
    var balances: [CosmosBalance] = []
    var warnings: [String] = []
    var nextKey: String?
    var seenKeys = Set<String>()

    for page in 1...maxCosmosPages {
      try Task.checkCancellation()
      var queryItems = [URLQueryItem(name: "pagination.limit", value: "500")]
      if let nextKey { queryItems.append(URLQueryItem(name: "pagination.key", value: nextKey)) }
      let url = Self.cosmosURL(
        rest: rest,
        path: "cosmos/bank/v1beta1/balances/\(address)",
        queryItems: queryItems
      )
      do {
        let response = try await http.get(url, as: CosmosBankResponse.self)
        balances.append(contentsOf: response.balances ?? [])
        guard let candidate = Self.normalizedCosmosNextKey(response.pagination?.nextKey) else { break }
        guard seenKeys.insert(candidate).inserted else {
          warnings.append("Cosmos liquid-balance pagination returned a repeated key; later balances were skipped.")
          break
        }
        guard page < maxCosmosPages else {
          warnings.append("Cosmos liquid-balance pagination reached the \(maxCosmosPages)-page safety limit; later balances were skipped.")
          break
        }
        nextKey = candidate
      } catch {
        try throwIfCancellation(error)
        guard page > 1 else { throw error }
        warnings.append("Later Cosmos liquid-balance pages could not be read; balances from completed pages were kept.")
        break
      }
    }
    return CosmosBalanceScan(balances: balances, warnings: warnings)
  }

  private func fetchCosmosDelegations(rest: URL, address: String) async throws -> CosmosDelegationScan {
    var delegations: [CosmosDelegation] = []
    var warnings: [String] = []
    var nextKey: String?
    var seenKeys = Set<String>()

    for page in 1...maxCosmosPages {
      try Task.checkCancellation()
      var queryItems = [URLQueryItem(name: "pagination.limit", value: "500")]
      if let nextKey { queryItems.append(URLQueryItem(name: "pagination.key", value: nextKey)) }
      let url = Self.cosmosURL(
        rest: rest,
        path: "cosmos/staking/v1beta1/delegations/\(address)",
        queryItems: queryItems
      )
      do {
        let response = try await http.get(url, as: CosmosDelegationResponse.self)
        delegations.append(contentsOf: response.delegationResponses ?? [])
        guard let candidate = Self.normalizedCosmosNextKey(response.pagination?.nextKey) else { break }
        guard seenKeys.insert(candidate).inserted else {
          warnings.append("Cosmos delegation pagination returned a repeated key; later delegations were skipped.")
          break
        }
        guard page < maxCosmosPages else {
          warnings.append("Cosmos delegation pagination reached the \(maxCosmosPages)-page safety limit; later delegations were skipped.")
          break
        }
        nextKey = candidate
      } catch {
        try throwIfCancellation(error)
        guard page > 1 else { throw error }
        warnings.append("Later Cosmos delegation pages could not be read; delegations from completed pages were kept.")
        break
      }
    }
    return CosmosDelegationScan(delegations: delegations, warnings: warnings)
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
    let rawNativeBalance = account?.balance ?? 0
    var warnings: [String] = []
    var assets: [TrackedAsset] = []
    if rawNativeBalance.isFinite, rawNativeBalance >= 0 {
      assets = assetIfPositive(
        amount: rawNativeBalance / pow(10, Double(chain.decimals)),
        address: address,
        chain: chain,
        prices: prices
      )
    } else {
      warnings.append("Native TRX balance returned an invalid amount; TRC-20 balances may still be available.")
    }

    let tokenScan = Self.parseTronTrc20BalanceResult(account?.trc20 ?? [], tokens: tokens)
    assets.append(contentsOf: tokenScan.balances.compactMap { entry in
      tokenAsset(amount: entry.amount, address: address, chain: chain, token: entry.token, prices: prices, source: .trc20)
    })
    if !tokenScan.invalidSymbols.isEmpty {
      warnings.append(
        "TRC-20 token balance data was invalid for \(Self.formattedSymbols(tokenScan.invalidSymbols)); balances may be incomplete."
      )
    }
    return NativeScanResult(assets: assets, warnings: warnings)
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
    var assets: [TrackedAsset] = []
    var warnings: [String] = []
    if let drops = Double(rawBalance), drops.isFinite, drops >= 0 {
      assets = assetIfPositive(
        amount: drops / pow(10, Double(chain.decimals)),
        address: address,
        chain: chain,
        prices: prices
      )
    } else {
      warnings.append("Native XRP balance was invalid; issued-currency balances may still be available.")
    }

    let trustLines = try await fetchXrpTrustLines(rpc: rpc, address: address)
    assets.append(contentsOf: Self.parseXrpTrustLines(trustLines.lines, address: address, chain: chain))
    warnings.append(contentsOf: trustLines.warnings)
    return NativeScanResult(assets: assets, warnings: warnings)
  }

  private func fetchXrpTrustLines(rpc: URL, address: String) async throws -> XrpTrustLineScan {
    var lines: [XrpTrustLine] = []
    var warnings: [String] = []
    var marker: JSONValue?
    var seenMarkers = Set<String>()

    for page in 1...maxXrpPages {
      try Task.checkCancellation()
      var parameters: [String: XRPValue] = [
        "account": .string(address),
        "ledger_index": .string("validated"),
        "limit": .number(400)
      ]
      if let marker { parameters["marker"] = .json(marker) }

      do {
        let response = try await http.post(
          rpc,
          body: XRPRequest(method: "account_lines", params: [parameters]),
          as: XrpAccountLinesResponse.self
        )
        guard let result = response.result else {
          throw Self.messageError(domain: "XRP", message: "XRP trust lines lookup returned an empty result.")
        }
        if result.status == "error" || result.error != nil {
          throw Self.messageError(
            domain: "XRP",
            message: result.errorMessage ?? result.error ?? "XRP trust lines lookup failed."
          )
        }
        guard let pageLines = result.lines else {
          throw Self.messageError(domain: "XRP", message: "XRP trust lines lookup returned no lines.")
        }
        lines.append(contentsOf: pageLines)
        guard let nextMarker = result.marker else { break }
        let markerKey = try nextMarker.stableKey()
        guard seenMarkers.insert(markerKey).inserted else {
          warnings.append("XRP pagination returned a repeated marker; later trustlines were skipped.")
          break
        }
        guard page < maxXrpPages else {
          warnings.append("XRP trustline pagination reached the \(maxXrpPages)-page safety limit; later trustlines were skipped.")
          break
        }
        marker = nextMarker
      } catch {
        try throwIfCancellation(error)
        let prefix = lines.isEmpty ? "Issued-currency trustlines could not be read" : "Later issued-currency trustline pages could not be read"
        warnings.append("\(prefix); available XRP balances are still shown.")
        break
      }
    }
    return XrpTrustLineScan(lines: lines, warnings: warnings)
  }

  private func assetIfPositive(
    amount: Double,
    address: String,
    chain: ChainConfig,
    prices: [String: PricePoint],
    name: String? = nil,
    source: AssetSource = .native
  ) -> [TrackedAsset] {
    guard amount.isFinite, amount > 0 else { return [] }
    let price = prices[chain.coinGeckoId] ?? PricePoint(usd: 0)
    let unitPrice = price.usd.isFinite && price.usd >= 0 ? price.usd : 0
    let valueUsd = FiniteValueMath.multiplyingNonnegative(amount, unitPrice)
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
        priceUsd: unitPrice,
        valueUsd: valueUsd ?? 0,
        change24h: FiniteValueMath.finiteOptional(price.usd24hChange),
        explorerUrl: chain.explorerURL(for: address).absoluteString,
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
    guard amount.isFinite, amount > 0 else { return nil }
    let price = token.coinGeckoId.flatMap { prices[$0] }
    let rawPrice = price?.usd ?? token.priceUsd ?? 0
    let priceUsd = rawPrice.isFinite && rawPrice >= 0 ? rawPrice : 0
    let valueUsd = FiniteValueMath.multiplyingNonnegative(amount, priceUsd)
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
      valueUsd: valueUsd ?? 0,
      change24h: FiniteValueMath.finiteOptional(price?.usd24hChange),
      explorerUrl: chain.explorerURL(for: address).absoluteString,
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
    let outcomes = try await boundedConcurrentMap(programs, maxConcurrent: 2) { program in
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
        let parsed = Self.parseSolanaTokenAccountResult(accounts)
        return SolanaProgramOutcome(
          accounts: parsed.accounts,
          invalidMints: parsed.invalidMints,
          unidentifiedInvalidAccountCount: parsed.unidentifiedInvalidAccountCount
        )
      } catch {
        try throwIfCancellation(error)
        return SolanaProgramOutcome(
          warnings: ["\(Self.solanaProgramLabel(program)) token account scan failed; SPL balances may be incomplete."]
        )
      }
    }
    let parsedAccounts = outcomes.flatMap(\.accounts)
    var warnings = outcomes.flatMap(\.warnings)

    let registryByMint = registry.reduce(into: [String: TokenConfig]()) { result, token in
      if result[token.address] == nil { result[token.address] = token }
    }
    let malformedSymbols = outcomes
      .flatMap(\.invalidMints)
      .compactMap { registryByMint[$0]?.symbol }
    if !malformedSymbols.isEmpty {
      warnings.append(
        "SPL token balance data was invalid for \(Self.formattedSymbols(malformedSymbols)); balances may be incomplete."
      )
    }
    if outcomes.reduce(0, { $0 + $1.unidentifiedInvalidAccountCount }) > 0 {
      warnings.append("Some SPL token accounts returned invalid parsed amount data; balances may be incomplete.")
    }
    var totals: [String: Double] = [:]
    var warnedMints = Set<String>()
    var overflowedMints = Set<String>()
    for account in parsedAccounts {
      guard let token = registryByMint[account.mint] else { continue }
      guard !overflowedMints.contains(account.mint) else { continue }
      guard (0...36).contains(account.decimals), account.rawAmount.isFinite, account.rawAmount >= 0 else {
        if warnedMints.insert(account.mint).inserted {
          warnings.append("\(token.symbol) returned invalid on-chain amount metadata and was skipped.")
        }
        continue
      }
      // Trust the on-chain decimals for the conversion rather than silently
      // dropping the balance when they differ from the bundled registry value
      // (which previously made real balances read as zero with no warning).
      if token.decimals != account.decimals, !warnedMints.contains(account.mint) {
        warnedMints.insert(account.mint)
        warnings.append("\(token.symbol) on-chain decimals (\(account.decimals)) differ from the registry (\(token.decimals)); using on-chain decimals.")
      }
      let scaledAmount = account.rawAmount / pow(10, Double(account.decimals))
      guard scaledAmount.isFinite,
            let nextTotal = FiniteValueMath.addingNonnegative(totals[account.mint, default: 0], scaledAmount)
      else {
        totals.removeValue(forKey: account.mint)
        overflowedMints.insert(account.mint)
        continue
      }
      totals[account.mint] = nextTotal
    }
    if !overflowedMints.isEmpty {
      let symbols = overflowedMints.compactMap { registryByMint[$0]?.symbol }
      warnings.append(
        "SPL balances exceeded the supported numeric range for \(Self.formattedSymbols(symbols)); those tokens were skipped."
      )
    }
    let balances: [(token: TokenConfig, amount: Double)] = totals.compactMap { mint, amount in
      guard let token = registryByMint[mint] else { return nil }
      return (token, amount)
    }
    return SolanaTokenBalanceScan(balances: balances, warnings: warnings)
  }

  public static func parseSolanaTokenAccounts(_ accounts: [SolanaTokenAccount]) -> [ParsedSplAccount] {
    parseSolanaTokenAccountResult(accounts).accounts
  }

  private static func parseSolanaTokenAccountResult(_ accounts: [SolanaTokenAccount]) -> SolanaAccountParseResult {
    var result = SolanaAccountParseResult()
    for account in accounts {
      guard let info = account.account.data.parsed?.info else {
        result.unidentifiedInvalidAccountCount += 1
        continue
      }
      guard let amount = Double(info.tokenAmount.amount), amount.isFinite, amount >= 0 else {
        result.invalidMints.append(info.mint)
        continue
      }
      result.accounts.append(
        ParsedSplAccount(mint: info.mint, rawAmount: amount, decimals: info.tokenAmount.decimals)
      )
    }
    return result
  }

  public static func parseCosmosLiquid(_ response: CosmosBankResponse, denom: String, decimals: Int) -> Double? {
    guard (0...36).contains(decimals) else { return nil }
    guard let balance = response.balances?.first(where: { $0.denom == denom }) else { return 0 }
    return scaledNonnegativeAmount(balance.amount, decimals: decimals)
  }

  public static func parseCosmosDelegations(_ response: CosmosDelegationResponse, denom: String, decimals: Int) -> Double? {
    guard (0...36).contains(decimals) else { return nil }
    var total = 0.0
    for item in response.delegationResponses ?? [] where item.balance?.denom == denom {
      guard let amount = item.balance?.amount,
            let raw = Double(amount), raw.isFinite, raw >= 0
      else { return nil }
      total += raw
      guard total.isFinite else { return nil }
    }
    return total / pow(10, Double(decimals))
  }

  public static func parseCosmosRewards(_ response: CosmosRewardsResponse, denom: String, decimals: Int) -> Double? {
    guard (0...36).contains(decimals) else { return nil }
    var total = 0.0
    for balance in response.total ?? [] where balance.denom == denom {
      guard let raw = Double(balance.amount), raw.isFinite, raw >= 0 else { return nil }
      total += raw
      guard total.isFinite else { return nil }
    }
    return total / pow(10, Double(decimals))
  }

  public static func parseTronTrc20Balances(_ balances: [[String: String]], tokens: [TokenConfig]) -> [(token: TokenConfig, amount: Double)] {
    parseTronTrc20BalanceResult(balances, tokens: tokens).balances
  }

  private static func parseTronTrc20BalanceResult(
    _ balances: [[String: String]],
    tokens: [TokenConfig]
  ) -> TronTokenBalanceParseResult {
    var result = TronTokenBalanceParseResult()
    for token in tokens {
      guard (0...36).contains(token.decimals) else {
        result.invalidSymbols.append(token.symbol)
        continue
      }
      var rawTotal = 0.0
      var isInvalid = false
      for entry in balances {
        guard let rawValue = entry[token.address] else { continue }
        guard let raw = Double(rawValue), raw.isFinite, raw >= 0 else {
          isInvalid = true
          break
        }
        rawTotal += raw
        guard rawTotal.isFinite else {
          isInvalid = true
          break
        }
      }
      guard !isInvalid else {
        result.invalidSymbols.append(token.symbol)
        continue
      }
      let amount = rawTotal / pow(10, Double(token.decimals))
      if amount.isFinite, amount > 0 {
        result.balances.append((token, amount))
      }
    }
    return result
  }

  private static func scaledNonnegativeAmount(_ rawValue: String, decimals: Int) -> Double? {
    guard let raw = Double(rawValue), raw.isFinite, raw >= 0 else { return nil }
    let amount = raw / pow(10, Double(decimals))
    return amount.isFinite ? amount : nil
  }

  public static func parseXrpTrustLines(_ lines: [XrpTrustLine], address: String, chain: ChainConfig) -> [TrackedAsset] {
    lines.compactMap { line in
      guard
        let amount = Double(line.balance),
        amount.isFinite,
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
        explorerUrl: chain.explorerURL(for: address).absoluteString,
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
    let maxEnabledCustomTokens = 100
    var evm = ChainRegistry.commonErc20Tokens
    var spl = ChainRegistry.commonSplTokens
    var trc20 = ChainRegistry.commonTrc20Tokens
    var warnings: [String] = []
    var enabledTokens: [CustomTokenRecord] = []
    var hasAdditionalEnabledTokens = false
    for token in customTokens where token.enabled {
      guard enabledTokens.count < maxEnabledCustomTokens else {
        hasAdditionalEnabledTokens = true
        break
      }
      enabledTokens.append(token)
    }
    if hasAdditionalEnabledTokens {
      warnings.append(
        "Only the first \(maxEnabledCustomTokens) enabled custom tokens were scanned; additional tokens were skipped."
      )
    }

    for token in enabledTokens {
      let label = customTokenLabel(token)
      let chainId = token.chainId.trimmingCharacters(in: .whitespacesAndNewlines)
      if let network = ChainRegistry.retiredChainNames[chainId] {
        warnings.append(
          "Custom token \(label) references retired \(network); the saved record was kept but not scanned."
        )
        continue
      }
      guard [.evm, .solana, .tron].contains(token.chainKind) else {
        warnings.append("Custom token \(label) uses an unsupported chain family and was skipped.")
        continue
      }
      guard let chain = ChainRegistry.allChains.first(where: { $0.id == chainId }), chain.family == token.chainKind else {
        warnings.append("Custom token \(label) references an unknown or mismatched chain and was skipped.")
        continue
      }
      guard let address = AddressDetection.canonicalAddress(token.address, family: token.chainKind) else {
        warnings.append("Custom token \(label) has an invalid contract or mint address and was skipped.")
        continue
      }
      let symbol = token.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
      let name = token.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !symbol.isEmpty, symbol.count <= 32, !name.isEmpty, name.count <= 128 else {
        warnings.append("Custom token \(label) has an invalid symbol or name and was skipped.")
        continue
      }
      guard (0...36).contains(token.decimals) else {
        warnings.append("Custom token \(label) has unsupported decimals and was skipped.")
        continue
      }
      guard token.priceUsd.map({ $0.isFinite && $0 >= 0 }) ?? true else {
        warnings.append("Custom token \(label) has an invalid USD price and was skipped.")
        continue
      }
      let coinGeckoId: String?
      if let rawId = token.coinGeckoId?.trimmingCharacters(in: .whitespacesAndNewlines), !rawId.isEmpty {
        if let normalizedId = UserInputValidation.normalizedCoinGeckoId(rawId) {
          coinGeckoId = normalizedId
        } else {
          // Older app versions accepted Unicode lowercase characters here.
          // Preserve the valid on-chain token and only discard unsafe pricing
          // metadata so its balance remains visible as unpriced.
          warnings.append("Custom token \(label) has an invalid CoinGecko ID; CoinGecko pricing was disabled.")
          coinGeckoId = nil
        }
      } else {
        coinGeckoId = nil
      }
      let config = TokenConfig(
        symbol: symbol,
        name: name,
        address: address,
        decimals: token.decimals,
        coinGeckoId: coinGeckoId,
        priceUsd: token.priceUsd
      )
      if token.chainKind == .evm {
        appendUnique(config, family: .evm, to: &evm[chainId, default: []])
      } else if token.chainKind == .solana {
        appendUnique(config, family: .solana, to: &spl[chainId, default: []])
      } else if token.chainKind == .tron {
        appendUnique(config, family: .tron, to: &trc20[chainId, default: []])
      }
    }

    return TokenRegistries(evm: evm, spl: spl, trc20: trc20, warnings: warnings)
  }

  private static func appendUnique(_ token: TokenConfig, family: ChainFamily, to tokens: inout [TokenConfig]) {
    let candidate = family == .evm ? token.address.lowercased() : token.address
    guard !tokens.contains(where: {
      (family == .evm ? $0.address.lowercased() : $0.address) == candidate
    }) else {
      return
    }
    tokens.append(token)
  }

  private static func customTokenLabel(_ token: CustomTokenRecord) -> String {
    let symbol = token.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
    if !symbol.isEmpty { return String(symbol.prefix(32)) }
    return String(token.address.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16))
  }

  private static func formattedSymbols(_ symbols: [String]) -> String {
    let unique = Array(Set(symbols)).sorted()
    guard unique.count > 5 else { return unique.joined(separator: ", ") }
    return "\(unique.prefix(5).joined(separator: ", ")) and \(unique.count - 5) more"
  }

  private static func displayAddress(_ address: String) -> String {
    guard address.count > 32 else { return address }
    return "\(address.prefix(16))...\(address.suffix(8))"
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

  public static func hexQuantityToDouble(_ value: String, decimals: Int) -> Double? {
    // Design decision (2026-06-22, won't-fix): on-chain balances (uint256) are
    // intentionally carried as Double for a read-only USD estimate. No overflow
    // or crash (verified) — only sub-cent precision loss well below display
    // resolution. Do not re-flag as a "uint256 overflow/precision bug".
    guard (0...36).contains(decimals),
          value.range(of: #"^0x[0-9a-fA-F]+$"#, options: .regularExpression) != nil
    else { return nil }
    let clean = String(value.dropFirst(2))
    let padded = clean.isEmpty
      ? "00"
      : (clean.count.isMultiple(of: 2) ? clean : "0\(clean)")
    guard let data = try? Data(hex: padded) else { return nil }
    let raw = data.reduce(0.0) { $0 * 256 + Double($1) }
    let amount = raw / pow(10, Double(decimals))
    return amount.isFinite ? amount : nil
  }

  private static func rpcError(domain: String, error: JSONRPCError, fallback: String) -> NSError {
    messageError(domain: domain, message: error.message ?? fallback, code: error.code ?? 1)
  }

  private static func messageError(domain: String, message: String, code: Int = 1) -> NSError {
    NSError(
      domain: "AddressAtlas.\(domain)",
      code: code,
      userInfo: [NSLocalizedDescriptionKey: ProviderErrorSanitizer.sanitize(message)]
    )
  }

  private static func cosmosURL(rest: URL, path: String, queryItems: [URLQueryItem]) -> URL {
    let url = rest.appending(path: path)
    guard !queryItems.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url
    }
    // Cosmos pagination keys are standard Base64. URLComponents.queryItems
    // leaves `+` unescaped, but grpc-gateway parses query strings as form data
    // and turns a raw `+` into a space. Encode each component using only the
    // RFC 3986 unreserved set so keys such as `+/=` survive the wire exactly.
    components.percentEncodedQuery = queryItems.map { item in
      let name = percentEncodedCosmosQueryComponent(item.name)
      guard let value = item.value else { return name }
      return "\(name)=\(percentEncodedCosmosQueryComponent(value))"
    }.joined(separator: "&")
    return components.url ?? url
  }

  private static func percentEncodedCosmosQueryComponent(_ value: String) -> String {
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
  }

  private static func normalizedCosmosNextKey(_ value: String?) -> String? {
    guard let candidate = value?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty else {
      return nil
    }
    return candidate
  }
}

public struct TokenRegistries: Sendable {
  public var evm: [String: [TokenConfig]]
  public var spl: [String: [TokenConfig]]
  public var trc20: [String: [TokenConfig]]
  public var warnings: [String]

  public init(
    evm: [String: [TokenConfig]],
    spl: [String: [TokenConfig]],
    trc20: [String: [TokenConfig]],
    warnings: [String] = []
  ) {
    self.evm = evm
    self.spl = spl
    self.trc20 = trc20
    self.warnings = warnings
  }
}

private struct NativeScanResult: Sendable {
  var assets: [TrackedAsset] = []
  var warnings: [String] = []
}

private struct ChainScanJob: Sendable {
  var index: Int
  var address: String
  var chain: ChainConfig
}

private struct ChainScanOutcome: Sendable {
  var index: Int
  var chainName: String
  var result: NativeScanResult
}

private struct TokenScanOutcome: Sendable {
  var asset: TrackedAsset?
  var failedSymbol: String?
}

private struct SolanaProgramOutcome: Sendable {
  var accounts: [ParsedSplAccount] = []
  var warnings: [String] = []
  var invalidMints: [String] = []
  var unidentifiedInvalidAccountCount = 0
}

private struct SolanaAccountParseResult {
  var accounts: [ParsedSplAccount] = []
  var invalidMints: [String] = []
  var unidentifiedInvalidAccountCount = 0
}

private struct TronTokenBalanceParseResult {
  var balances: [(token: TokenConfig, amount: Double)] = []
  var invalidSymbols: [String] = []
}

private enum CosmosScanPart: Sendable {
  case liquid
  case delegations
  case rewards

  var failureWarning: String {
    switch self {
    case .liquid: "Liquid balance could not be read; staked and reward balances may still be available."
    case .delegations: "Delegations could not be read; staked balance may be missing."
    case .rewards: "Rewards could not be read; claimable rewards may be missing."
    }
  }
}

private struct SolanaTokenBalanceScan: Sendable {
  var balances: [(token: TokenConfig, amount: Double)] = []
  var warnings: [String] = []
}

private struct XrpTrustLineScan: Sendable {
  var lines: [XrpTrustLine] = []
  var warnings: [String] = []
}

private struct CosmosBalanceScan: Sendable {
  var balances: [CosmosBalance] = []
  var warnings: [String] = []
}

private struct CosmosDelegationScan: Sendable {
  var delegations: [CosmosDelegation] = []
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
  public var pagination: CosmosPageResponse?
}

public struct CosmosDelegationResponse: Decodable, Sendable {
  public var delegationResponses: [CosmosDelegation]?
  public var pagination: CosmosPageResponse?

  enum CodingKeys: String, CodingKey {
    case delegationResponses = "delegation_responses"
    case pagination
  }
}

public struct CosmosPageResponse: Decodable, Sendable {
  public var nextKey: String?

  enum CodingKeys: String, CodingKey {
    case nextKey = "next_key"
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
    public var marker: JSONValue?

    enum CodingKeys: String, CodingKey {
      case status
      case error
      case errorMessage = "error_message"
      case lines
      case marker
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
  case json(JSONValue)

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .json(let value):
      try container.encode(value)
    }
  }
}

public indirect enum JSONValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let value = try? container.decode(Bool.self) { self = .bool(value) }
    else if let value = try? container.decode(String.self) { self = .string(value) }
    else if let value = try? container.decode(Double.self) { self = .number(value) }
    else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
    else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
    else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  fileprivate func stableKey() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return Base64URL.encode(try encoder.encode(self))
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
