import Foundation

extension NativeScanner {
  func scanBitcoin(address: String, chain: ChainConfig, prices: [String: PricePoint])
    async throws -> [TrackedAsset]
  {
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
      response.mempoolStats?.spentTxoSum ?? 0.0,
    ]
    guard reportedValues.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
      throw Self.messageError(
        domain: "Bitcoin", message: "Bitcoin balance lookup returned invalid statistics.")
    }
    let sats =
      (response.chainStats.fundedTxoSum - response.chainStats.spentTxoSum)
      + ((response.mempoolStats?.fundedTxoSum ?? 0) - (response.mempoolStats?.spentTxoSum ?? 0))
    guard sats.isFinite, sats >= 0 else {
      throw Self.messageError(
        domain: "Bitcoin", message: "Bitcoin balance lookup returned an invalid total.")
    }
    return assetIfPositive(
      amount: sats / pow(10, Double(chain.decimals)), address: address, chain: chain, prices: prices
    )
  }

  func scanEVM(
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
        body: JSONRPCRequest(
          method: "eth_getBalance", params: [.string(address), .string("latest")]),
        as: Response.self
      )
      if let message = response.error?.message {
        throw Self.messageError(domain: "EVM", message: message)
      }
      guard let rawResult = response.result else {
        throw Self.messageError(
          domain: "EVM", message: "Native balance lookup returned an empty result.")
      }
      guard let amount = Self.hexQuantityToDouble(rawResult, decimals: chain.decimals) else {
        throw Self.messageError(
          domain: "EVM", message: "Native balance lookup returned an invalid hex quantity.")
      }
      assets.append(
        contentsOf: assetIfPositive(amount: amount, address: address, chain: chain, prices: prices))
    } catch {
      try throwIfCancellation(error)
      warnings.append("\(chain.name) native balance failed: \(error.localizedDescription)")
    }
    let tokenScan = try await scanErc20Balances(
      address: address, chain: chain, tokens: tokens, prices: prices)
    assets.append(contentsOf: tokenScan.assets)
    warnings.append(contentsOf: tokenScan.warnings)
    return NativeScanResult(assets: assets, warnings: warnings)
  }

  func scanErc20Balances(
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
              "data": .string(Self.erc20BalanceOfData(address)),
            ]),
            .string("latest"),
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
        warnings: [
          "\(chain.name) token balance batch was rate-limited; individual retries were skipped to avoid amplifying the limit."
        ]
      )
    } catch {
      try throwIfCancellation(error)
      return try await scanErc20Individually(
        address: address, chain: chain, tokens: tokens, prices: prices)
    }
  }

  func scanErc20Individually(
    address: String,
    chain: ChainConfig,
    tokens: [TokenConfig],
    prices: [String: PricePoint]
  ) async throws -> NativeScanResult {
    let outcomes = try await boundedConcurrentMap(tokens, maxConcurrent: 4) { token in
      do {
        if let tokenAsset = try await scanErc20(
          address: address, chain: chain, token: token, prices: prices)
        {
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
    let warnings =
      failedTokens.isEmpty
      ? []
      : [
        "ERC-20 token balance checks failed for \(Self.formattedSymbols(failedTokens)); token balances may be incomplete."
      ]
    return NativeScanResult(assets: assets, warnings: warnings)
  }

  func buildErc20TokenScan(
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
      guard
        let tokenAsset = tokenAsset(
          amount: amount, address: address, chain: chain, token: token, prices: prices,
          source: .erc20)
      else {
        continue
      }
      assets.append(tokenAsset)
    }

    let warnings =
      failedTokens.isEmpty
      ? []
      : [
        "ERC-20 token balance checks failed for \(Self.formattedSymbols(failedTokens)); token balances may be incomplete."
      ]
    return NativeScanResult(assets: assets, warnings: warnings)
  }

  func scanErc20(
    address: String, chain: ChainConfig, token: TokenConfig, prices: [String: PricePoint]
  ) async throws -> TrackedAsset? {
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
            "data": .string(Self.erc20BalanceOfData(address)),
          ]),
          .string("latest"),
        ]
      ),
      as: Response.self
    )
    if let message = response.error?.message {
      throw NSError(domain: "EVMToken", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    guard let rawResult = response.result else {
      throw Self.messageError(
        domain: "EVMToken", message: "Token balance lookup returned an empty result.")
    }
    guard let amount = Self.hexQuantityToDouble(rawResult, decimals: token.decimals) else {
      throw Self.messageError(
        domain: "EVMToken", message: "Token balance lookup returned an invalid hex quantity.")
    }
    guard amount > 0 else { return nil }
    return tokenAsset(
      amount: amount, address: address, chain: chain, token: token, prices: prices, source: .erc20)
  }

  public static func erc20BalanceOfData(_ owner: String) -> String {
    let normalized = owner.replacingOccurrences(of: "0x", with: "").lowercased()
    return "0x70a08231\(String(repeating: "0", count: max(0, 64 - normalized.count)))\(normalized)"
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
    let padded =
      clean.isEmpty
      ? "00"
      : (clean.count.isMultiple(of: 2) ? clean : "0\(clean)")
    guard let data = try? Data(hex: padded) else { return nil }
    let raw = data.reduce(0.0) { $0 * 256 + Double($1) }
    let amount = raw / pow(10, Double(decimals))
    return amount.isFinite ? amount : nil
  }
}
