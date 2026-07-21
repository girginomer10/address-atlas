import Foundation

public struct NativeScanner: Sendable {
  let http: JSONHTTPClient
  private let priceProvider: PriceProviding
  private let endpointConfig: NativeEndpointConfig
  private let maxConcurrentChainScans: Int
  private let chainDeadline: TimeInterval
  private let workflowDeadline: TimeInterval
  let maxXrpPages: Int
  let maxCosmosPages: Int

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
    self.priceProvider =
      priceProvider ?? CoinGeckoPriceClient(baseURL: endpointConfig.priceBaseURL, http: http)
    self.maxConcurrentChainScans = max(1, maxConcurrentChainScans)
    self.chainDeadline = chainDeadline.isFinite && chainDeadline > 0 ? chainDeadline : 45
    self.workflowDeadline =
      workflowDeadline.isFinite && workflowDeadline > 0 ? workflowDeadline : 120
    self.maxXrpPages = max(1, maxXrpPages)
    self.maxCosmosPages = max(1, maxCosmosPages)
  }

  public func scan(addresses input: String, customTokens: [CustomTokenRecord] = []) async throws
    -> ScanRunRecord
  {
    // Network identity is proved once per endpoint within this workflow, never
    // for the scanner lifetime. Re-proving on the next scan detects endpoint
    // drift and lets a transient proof outage recover without restarting.
    let scanNetworkIdentityProofs = ChainNetworkValueCache<Void>()
    let scanCosmosSnapshotAnchors = ChainNetworkValueCache<Int64>()
    let workflowStartedAt = ProcessInfo.processInfo.systemUptime
    let parsedInput = AddressDetection.parseWithMetadata(input)
    let addresses = parsedInput.addresses.filter(AddressDetection.isSafePublicAddress)
    let detectedChains = addresses.flatMap(AddressDetection.detectChains).map {
      endpointConfig.applying(to: $0)
    }
    let registries = Self.tokenRegistries(customTokens: customTokens)
    let detectedChainIds = Set(detectedChains.map(\.id))
    let tokenIds =
      registries.evm.filter { detectedChainIds.contains($0.key) }.values.flatMap { $0 }.compactMap(
        \.coinGeckoId)
      + registries.spl.filter { detectedChainIds.contains($0.key) }.values.flatMap { $0 }
      .compactMap(\.coinGeckoId)
      + registries.trc20.filter { detectedChainIds.contains($0.key) }.values.flatMap { $0 }
      .compactMap(\.coinGeckoId)
    let requestedPriceIds = Array(Set(detectedChains.map(\.coinGeckoId) + tokenIds))
    var prices: [String: PricePoint] = [:]
    var warnings = registries.warnings
    var priceRequestFailed = false
    if parsedInput.wasTruncated {
      warnings.append(
        "Only the first 24 unique input entries were scanned; additional entries were skipped.")
    }
    let remainingBeforePricing =
      workflowDeadline - (ProcessInfo.processInfo.systemUptime - workflowStartedAt)
    if remainingBeforePricing <= 0 {
      priceRequestFailed = true
      warnings.append(
        "USD pricing was skipped because the overall scan deadline was already exhausted.")
    } else {
      do {
        let fetchedPrices = try await withWorkflowTimeout(seconds: min(25, remainingBeforePricing))
        {
          try await priceProvider.prices(for: requestedPriceIds)
        }
        prices = fetchedPrices.reduce(into: [:]) { valid, entry in
          guard let point = CoinGeckoPriceClient.sanitized(entry.value) else { return }
          valid[entry.key] = point
        }
      } catch {
        try throwIfCancellation(error)
        priceRequestFailed = true
        warnings.append(
          "USD pricing is temporarily unavailable; successful balances will be shown unpriced.")
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
        jobs.append(
          ChainScanJob(
            index: jobIndex, address: address, chain: endpointConfig.applying(to: detectedChain)))
        jobIndex += 1
      }
    }
    let chainJobs = jobs

    let collector = CompletedWorkCollector<ChainScanOutcome>()
    let remainingWorkflowTime =
      workflowDeadline - (ProcessInfo.processInfo.systemUptime - workflowStartedAt)
    let outcomes: [ChainScanOutcome]
    if chainJobs.isEmpty {
      outcomes = []
    } else if remainingWorkflowTime <= 0 {
      outcomes = []
      let deadline = WorkflowTimeoutError(seconds: workflowDeadline).displaySeconds
      warnings.append(
        "The overall scan reached its \(deadline)-second deadline before chain checks began; all chain checks were skipped."
      )
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
                  registries: registries,
                  networkIdentityProofs: scanNetworkIdentityProofs,
                  cosmosSnapshotAnchors: scanCosmosSnapshotAnchors
                )
              }
              outcome = ChainScanOutcome(
                index: job.index,
                chainName: job.chain.name,
                addressHint: Self.displayAddress(job.address),
                result: scanned
              )
            } catch {
              try throwIfCancellation(error)
              outcome = ChainScanOutcome(
                index: job.index,
                chainName: job.chain.name,
                addressHint: Self.displayAddress(job.address),
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
    warnings.append(
      contentsOf: ordered.flatMap { outcome in
        outcome.result.warnings.map {
          "\(outcome.chainName) [\(outcome.addressHint)]: \($0)"
        }
      })
    let unpricedSymbols =
      assets
      .filter { $0.amount > 0 && $0.pricingStatus == .unpriced && $0.source != .issued }
      .map(\.symbol)
    if !priceRequestFailed, !unpricedSymbols.isEmpty {
      warnings.append(
        "No USD price was available for \(Self.formattedSymbols(unpricedSymbols)); balances are still included."
      )
    }

    let valuationOverflowSymbols = assets.compactMap { asset -> String? in
      guard asset.amount > 0, asset.pricingStatus == .valuationUnavailable,
        asset.priceUsd > 0,
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

  func scanNative(
    address: String,
    chain: ChainConfig,
    prices: [String: PricePoint],
    registries: TokenRegistries,
    networkIdentityProofs: ChainNetworkValueCache<Void>,
    cosmosSnapshotAnchors: ChainNetworkValueCache<Int64>
  ) async throws -> NativeScanResult {
    switch chain.family {
    case .bitcoin:
      return NativeScanResult(
        assets: try await scanBitcoin(
          address: address,
          chain: chain,
          prices: prices,
          networkIdentityProofs: networkIdentityProofs
        ))
    case .evm:
      return try await scanEVM(
        address: address,
        chain: chain,
        tokens: registries.evm[chain.id] ?? [],
        prices: prices,
        networkIdentityProofs: networkIdentityProofs
      )
    case .solana:
      return try await scanSolana(
        address: address,
        chain: chain,
        tokens: registries.spl[chain.id] ?? [],
        prices: prices,
        networkIdentityProofs: networkIdentityProofs
      )
    case .cosmos:
      return try await scanCosmos(
        address: address,
        chain: chain,
        prices: prices,
        snapshotAnchors: cosmosSnapshotAnchors
      )
    case .tron:
      return try await scanTron(
        address: address,
        chain: chain,
        tokens: registries.trc20[chain.id] ?? [],
        prices: prices,
        networkIdentityProofs: networkIdentityProofs
      )
    case .xrp:
      return try await scanXRP(
        address: address,
        chain: chain,
        prices: prices,
        networkIdentityProofs: networkIdentityProofs
      )
    case .exchange:
      return NativeScanResult()
    }
  }

}
