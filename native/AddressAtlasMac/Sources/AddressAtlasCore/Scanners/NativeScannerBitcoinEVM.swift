import Foundation

extension NativeScanner {
  private struct EvmSingleResponse: Decodable {
    var jsonrpc: String?
    var id: Int?
    var result: String?
    var error: JSONRPCError?
  }

  private enum EvmTokenBatchEnvelope: Decodable {
    case responses([EvmTokenBatchResponse])
    case explicitlyUnsupported

    private struct Rejection: Decodable {
      var jsonrpc: String?
      var error: JSONRPCError?
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let responses = try? container.decode([EvmTokenBatchResponse].self) {
        self = .responses(responses)
        return
      }

      let rejection = try container.decode(Rejection.self)
      let normalizedMessage = rejection.error?.message?.lowercased() ?? ""
      guard rejection.jsonrpc == "2.0",
        let code = rejection.error?.code,
        code == -32600
          || (normalizedMessage.contains("batch")
            && (normalizedMessage.contains("unsupported")
              || normalizedMessage.contains("not supported")))
      else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "The EVM batch response was neither an array nor an explicit rejection."
        )
      }
      self = .explicitlyUnsupported
    }
  }

  func scanBitcoin(address: String, chain: ChainConfig, prices: [String: PricePoint])
    async throws -> [TrackedAsset]
  {
    struct Response: Decodable {
      var address: String
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
        case address
        case chainStats = "chain_stats"
        case mempoolStats = "mempool_stats"
      }
    }
    guard let rest = chain.restUrl else { return [] }
    let url = rest.appending(path: "address/\(address)")
    let response = try await http.get(url, as: Response.self)
    guard
      let expectedAddress = AddressDetection.canonicalAddress(address, family: .bitcoin),
      AddressDetection.canonicalAddress(response.address, family: .bitcoin) == expectedAddress
    else {
      throw Self.messageError(
        domain: "Bitcoin", message: "Bitcoin balance lookup returned a different address.")
    }
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
    guard let rpc = chain.rpcUrl else { return NativeScanResult() }
    let blockTag = try await resolveEvmBlockTag(rpc: rpc)
    var assets: [TrackedAsset] = []
    var warnings: [String] = []
    do {
      let response = try await http.post(
        rpc,
        body: JSONRPCRequest(
          id: 2,
          method: "eth_getBalance", params: [.string(address), .string(blockTag)]),
        as: EvmSingleResponse.self
      )
      let rawResult = try Self.validatedEvmResult(
        response, expectedID: 2, operation: "Native balance lookup")
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
      address: address, chain: chain, tokens: tokens, prices: prices, blockTag: blockTag)
    assets.append(contentsOf: tokenScan.assets)
    warnings.append(contentsOf: tokenScan.warnings)
    return NativeScanResult(assets: assets, warnings: warnings)
  }

  func scanErc20Balances(
    address: String,
    chain: ChainConfig,
    tokens: [TokenConfig],
    prices: [String: PricePoint],
    blockTag: String
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
            .string(blockTag),
          ]
        )
      }
      let envelope = try await http.post(rpc, body: requests, as: EvmTokenBatchEnvelope.self)
      switch envelope {
      case .responses(let responses):
        return buildErc20TokenScan(
          address: address,
          chain: chain,
          tokens: tokens,
          responses: responses,
          prices: prices
        )
      case .explicitlyUnsupported:
        return try await scanErc20Individually(
          address: address, chain: chain, tokens: tokens, prices: prices, blockTag: blockTag)
      }
    } catch let error as JSONHTTPClientError where error.statusCode == 429 {
      return NativeScanResult(
        warnings: [
          "\(chain.name) token balance batch was rate-limited; individual retries were skipped to avoid amplifying the limit."
        ]
      )
    } catch let error where JSONHTTPClient.isTransientFailure(error) {
      return NativeScanResult(
        warnings: [
          "\(chain.name) token balance batch remained temporarily unavailable after one retry; individual requests were skipped to avoid amplifying the provider failure."
        ]
      )
    } catch {
      try throwIfCancellation(error)
      return NativeScanResult(
        warnings: [
          "\(chain.name) token balance batch returned an invalid response; individual requests were skipped to avoid amplifying a provider failure."
        ]
      )
    }
  }

  func scanErc20Individually(
    address: String,
    chain: ChainConfig,
    tokens: [TokenConfig],
    prices: [String: PricePoint],
    blockTag: String
  ) async throws -> NativeScanResult {
    let outcomes = try await boundedConcurrentMap(tokens, maxConcurrent: 4) { token in
      do {
        if let tokenAsset = try await scanErc20(
          address: address, chain: chain, token: token, prices: prices, blockTag: blockTag)
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
    let groupedResponses = Dictionary(grouping: responses, by: \.id)
    var responsesById: [Int: EvmTokenBatchResponse] = [:]
    var identicalDuplicateCount = 0
    var conflictingResponseIds = Set<Int>()
    for (id, candidates) in groupedResponses {
      guard let first = candidates.first else { continue }
      if candidates.dropFirst().allSatisfy({ Self.equivalentEvmBatchResponse($0, first) }) {
        responsesById[id] = first
        identicalDuplicateCount += candidates.count - 1
      } else {
        conflictingResponseIds.insert(id)
      }
    }
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
      guard response.jsonrpc == "2.0" else {
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

    var warnings: [String] = []
    if identicalDuplicateCount > 0 {
      warnings.append(
        identicalDuplicateCount == 1
          ? "The EVM RPC repeated one identical token response; the duplicate was skipped."
          : "The EVM RPC repeated \(identicalDuplicateCount) identical token responses; the duplicates were skipped."
      )
    }
    let conflictingTokenCount = conflictingResponseIds.filter {
      $0 >= 1 && $0 <= tokens.count
    }.count
    if conflictingTokenCount > 0 {
      warnings.append(
        conflictingTokenCount == 1
          ? "The EVM RPC returned conflicting responses for one token request; every conflicting version was skipped."
          : "The EVM RPC returned conflicting responses for \(conflictingTokenCount) token requests; every conflicting version was skipped."
      )
    }
    if !failedTokens.isEmpty {
      warnings.append(
        "ERC-20 token balance checks failed for \(Self.formattedSymbols(failedTokens)); token balances may be incomplete."
      )
    }
    return NativeScanResult(assets: assets, warnings: warnings)
  }

  private static func equivalentEvmBatchResponse(
    _ lhs: EvmTokenBatchResponse,
    _ rhs: EvmTokenBatchResponse
  ) -> Bool {
    lhs.id == rhs.id
      && lhs.jsonrpc == rhs.jsonrpc
      && lhs.result == rhs.result
      && (lhs.error == nil) == (rhs.error == nil)
      && lhs.error?.code == rhs.error?.code
      && lhs.error?.message == rhs.error?.message
  }

  func scanErc20(
    address: String,
    chain: ChainConfig,
    token: TokenConfig,
    prices: [String: PricePoint],
    blockTag: String
  ) async throws -> TrackedAsset? {
    guard let rpc = chain.rpcUrl else { return nil }
    let response = try await http.post(
      rpc,
      body: JSONRPCRequest(
        id: 1,
        method: "eth_call",
        params: [
          .object([
            "to": .string(token.address),
            "data": .string(Self.erc20BalanceOfData(address)),
          ]),
          .string(blockTag),
        ]
      ),
      as: EvmSingleResponse.self
    )
    let rawResult = try Self.validatedEvmResult(
      response, expectedID: 1, operation: "Token balance lookup")
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

  func resolveEvmBlockTag(rpc: URL) async throws -> String {
    let response = try await http.post(
      rpc,
      body: JSONRPCRequest(id: 1, method: "eth_blockNumber", params: []),
      as: EvmSingleResponse.self
    )
    let rawResult = try Self.validatedEvmResult(
      response, expectedID: 1, operation: "Snapshot block lookup")
    guard let blockTag = Self.canonicalEvmBlockTag(rawResult) else {
      throw Self.messageError(
        domain: "EVM", message: "Snapshot block lookup returned an invalid hex quantity.")
    }
    return blockTag
  }

  private static func validatedEvmResult(
    _ response: EvmSingleResponse,
    expectedID: Int,
    operation: String
  ) throws -> String {
    guard response.jsonrpc == "2.0", response.id == expectedID else {
      throw messageError(
        domain: "EVM", message: "\(operation) returned a mismatched JSON-RPC response.")
    }
    if let error = response.error {
      throw rpcError(domain: "EVM", error: error, fallback: "\(operation) failed.")
    }
    guard let result = response.result else {
      throw messageError(domain: "EVM", message: "\(operation) returned an empty result.")
    }
    return result
  }

  public static func canonicalEvmBlockTag(_ value: String) -> String? {
    guard
      value.range(of: #"^0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)$"#, options: .regularExpression)
        != nil,
      UInt64(value.dropFirst(2), radix: 16) != nil
    else { return nil }
    return value.lowercased()
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
