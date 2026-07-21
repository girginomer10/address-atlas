import Foundation

extension NativeScanner {
  func scanCosmos(address: String, chain: ChainConfig, prices: [String: PricePoint])
    async throws -> NativeScanResult
  {
    guard let rest = chain.restUrl, let denom = chain.nativeDenom else { return NativeScanResult() }
    let liquidScan: CosmosBalanceScan
    do {
      liquidScan = try await fetchCosmosBalances(rest: rest, address: address)
    } catch {
      try throwIfCancellation(error)
      do {
        let height = try await fetchCosmosSnapshotHeight(rest: rest, chain: chain)
        liquidScan = try await fetchCosmosBalances(
          rest: rest, address: address, expectedHeight: height)
      } catch {
        try throwIfCancellation(error)
        return NativeScanResult(
          warnings: [
            "A height-bound Cosmos snapshot could not be established; liquid, staked, and reward balances were skipped."
          ])
      }
    }
    guard let snapshotHeight = liquidScan.height else {
      return NativeScanResult(
        warnings: [
          "The Cosmos provider omitted its block height; liquid, staked, and reward balances were skipped."
        ])
    }

    var initialResult = NativeScanResult(warnings: liquidScan.warnings)
    let liquidResponse = CosmosBankResponse(balances: liquidScan.balances, pagination: nil)
    if let amount = Self.parseCosmosLiquid(
      liquidResponse, denom: denom, decimals: chain.decimals)
    {
      initialResult.assets = assetIfPositive(
        amount: amount, address: address, chain: chain, prices: prices)
    } else {
      initialResult.warnings.append(CosmosScanPart.liquid.failureWarning)
    }

    let parts: [CosmosScanPart] = [.delegations, .rewards]
    let results = try await boundedConcurrentMap(parts, maxConcurrent: 2) { part in
      do {
        switch part {
        case .liquid:
          return NativeScanResult()
        case .delegations:
          let scan = try await fetchCosmosDelegations(
            rest: rest, address: address, expectedHeight: snapshotHeight)
          let response = CosmosDelegationResponse(
            delegationResponses: scan.delegations, pagination: nil)
          guard
            let amount = Self.parseCosmosDelegations(
              response, denom: denom, decimals: chain.decimals)
          else {
            throw Self.messageError(
              domain: "Cosmos", message: "Delegations contained an invalid amount.")
          }
          return NativeScanResult(
            assets: assetIfPositive(
              amount: amount,
              address: address,
              chain: chain,
              prices: prices,
              name: "\(chain.name) Staked",
              source: .staked
            ), warnings: scan.warnings)
        case .rewards:
          let fetched = try await http.getResponse(
            rest.appending(path: "cosmos/distribution/v1beta1/delegators/\(address)/rewards"),
            headers: Self.cosmosHeightHeaders(snapshotHeight),
            as: CosmosRewardsResponse.self
          )
          try Self.validateCosmosHeight(fetched.response, expected: snapshotHeight)
          let parsedRewards = Self.parseCosmosRewardsResult(
            fetched.value, denom: denom, decimals: chain.decimals)
          guard
            let amount = parsedRewards.amount
          else {
            throw Self.messageError(
              domain: "Cosmos", message: "Rewards contained an invalid amount.")
          }
          return NativeScanResult(
            assets: assetIfPositive(
              amount: amount,
              address: address,
              chain: chain,
              prices: prices,
              name: "\(chain.name) Rewards",
              source: .rewards
            ), warnings: parsedRewards.warnings)
        }
      } catch {
        try throwIfCancellation(error)
        return NativeScanResult(warnings: [part.failureWarning])
      }
    }

    return NativeScanResult(
      assets: initialResult.assets + results.flatMap(\.assets),
      warnings: initialResult.warnings + results.flatMap(\.warnings)
    )
  }

  func fetchCosmosBalances(
    rest: URL,
    address: String,
    expectedHeight: Int64? = nil
  ) async throws -> CosmosBalanceScan {
    var balances: [CosmosBalance] = []
    var warnings: [String] = []
    var nextKey: String?
    var seenKeys = Set<String>()
    var snapshotHeight = expectedHeight

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
        let fetched = try await http.getResponse(
          url,
          headers: snapshotHeight.map(Self.cosmosHeightHeaders) ?? [:],
          as: CosmosBankResponse.self
        )
        let returnedHeight = try Self.optionalCosmosHeight(from: fetched.response)
        if let snapshotHeight {
          guard returnedHeight == snapshotHeight else {
            throw Self.messageError(
              domain: "Cosmos",
              message: "Cosmos liquid-balance response omitted or changed block height.")
          }
        } else {
          guard let returnedHeight else {
            throw Self.messageError(
              domain: "Cosmos", message: "Cosmos response omitted a valid block height.")
          }
          snapshotHeight = returnedHeight
        }
        balances.append(contentsOf: fetched.value.balances ?? [])
        guard let candidate = Self.normalizedCosmosNextKey(fetched.value.pagination?.nextKey) else {
          break
        }
        guard seenKeys.insert(candidate).inserted else {
          warnings.append(
            "Cosmos liquid-balance pagination returned a repeated key; later balances were skipped."
          )
          break
        }
        guard page < maxCosmosPages else {
          warnings.append(
            "Cosmos liquid-balance pagination reached the \(maxCosmosPages)-page safety limit; later balances were skipped."
          )
          break
        }
        nextKey = candidate
      } catch {
        try throwIfCancellation(error)
        guard page > 1 else { throw error }
        warnings.append(
          "Later Cosmos liquid-balance pages could not be read; balances from completed pages were kept."
        )
        break
      }
    }
    let deduplicated = Self.deduplicateCosmosBalances(balances)
    warnings.append(contentsOf: deduplicated.warnings)
    return CosmosBalanceScan(
      balances: deduplicated.balances, warnings: warnings, height: snapshotHeight)
  }

  func fetchCosmosDelegations(rest: URL, address: String, expectedHeight: Int64) async throws
    -> CosmosDelegationScan
  {
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
        let fetched = try await http.getResponse(
          url,
          headers: Self.cosmosHeightHeaders(expectedHeight),
          as: CosmosDelegationResponse.self
        )
        try Self.validateCosmosHeight(fetched.response, expected: expectedHeight)
        delegations.append(contentsOf: fetched.value.delegationResponses ?? [])
        guard
          let candidate = Self.normalizedCosmosNextKey(fetched.value.pagination?.nextKey)
        else {
          break
        }
        guard seenKeys.insert(candidate).inserted else {
          warnings.append(
            "Cosmos delegation pagination returned a repeated key; later delegations were skipped.")
          break
        }
        guard page < maxCosmosPages else {
          warnings.append(
            "Cosmos delegation pagination reached the \(maxCosmosPages)-page safety limit; later delegations were skipped."
          )
          break
        }
        nextKey = candidate
      } catch {
        try throwIfCancellation(error)
        guard page > 1 else { throw error }
        warnings.append(
          "Later Cosmos delegation pages could not be read; delegations from completed pages were kept."
        )
        break
      }
    }
    let deduplicated = Self.deduplicateCosmosDelegations(
      delegations, expectedDelegatorAddress: address)
    warnings.append(contentsOf: deduplicated.warnings)
    return CosmosDelegationScan(delegations: deduplicated.delegations, warnings: warnings)
  }

  public static func parseCosmosLiquid(_ response: CosmosBankResponse, denom: String, decimals: Int)
    -> Double?
  {
    guard (0...36).contains(decimals) else { return nil }
    guard let balance = response.balances?.first(where: { $0.denom == denom }) else { return 0 }
    return scaledNonnegativeAmount(balance.amount, decimals: decimals)
  }

  public static func parseCosmosDelegations(
    _ response: CosmosDelegationResponse, denom: String, decimals: Int
  ) -> Double? {
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

  public static func parseCosmosRewards(
    _ response: CosmosRewardsResponse, denom: String, decimals: Int
  ) -> Double? {
    let result = parseCosmosRewardsResult(response, denom: denom, decimals: decimals)
    return result.targetDenomConflicted ? nil : result.amount
  }

  static func parseCosmosRewardsResult(
    _ response: CosmosRewardsResponse, denom: String, decimals: Int
  ) -> (amount: Double?, warnings: [String], targetDenomConflicted: Bool) {
    guard (0...36).contains(decimals) else { return (nil, [], false) }
    let deduplicated = deduplicateCosmosRewards(response.total ?? [])
    if deduplicated.conflictingDenoms.contains(denom) {
      // The product scan needs a warning-only, no-holding result, represented
      // by zero here. The public parser separately exposes the ambiguity as nil
      // so callers cannot mistake quarantined provider data for a true zero.
      return (0, deduplicated.warnings, true)
    }
    guard let balance = deduplicated.balances.first(where: { $0.denom == denom }) else {
      return (0, deduplicated.warnings, false)
    }
    return (
      scaledNonnegativeAmount(balance.amount, decimals: decimals),
      deduplicated.warnings,
      false
    )
  }

  private func fetchCosmosSnapshotHeight(rest: URL, chain: ChainConfig) async throws -> Int64 {
    struct LatestBlockResponse: Decodable {
      var block: Block?

      struct Block: Decodable {
        var header: Header?
      }

      struct Header: Decodable {
        var chainID: String?
        var height: String?

        enum CodingKeys: String, CodingKey {
          case chainID = "chain_id"
          case height
        }
      }
    }

    let response = try await http.get(
      rest.appending(path: "cosmos/base/tendermint/v1beta1/blocks/latest"),
      as: LatestBlockResponse.self
    )
    guard
      let header = response.block?.header,
      let heightText = header.height,
      let height = Int64(heightText),
      height > 0,
      let expectedChainID = Self.cosmosChainID(for: chain.id),
      header.chainID == expectedChainID
    else {
      throw Self.messageError(
        domain: "Cosmos",
        message: "Cosmos latest-block lookup returned the wrong network or height.")
    }
    return height
  }

  static func scaledNonnegativeAmount(_ rawValue: String, decimals: Int) -> Double? {
    guard let raw = Double(rawValue), raw.isFinite, raw >= 0 else { return nil }
    let amount = raw / pow(10, Double(decimals))
    return amount.isFinite ? amount : nil
  }

  private static func cosmosHeightHeaders(_ height: Int64) -> [String: String] {
    ["x-cosmos-block-height": String(height)]
  }

  private static func optionalCosmosHeight(from response: HTTPURLResponse) throws -> Int64? {
    let rawHeights = [
      response.value(forHTTPHeaderField: "x-cosmos-block-height"),
      response.value(forHTTPHeaderField: "grpc-metadata-x-cosmos-block-height")
    ].compactMap { $0 }
    guard !rawHeights.isEmpty else { return nil }

    var parsedHeights = Set<Int64>()
    for rawHeader in rawHeights {
      let rawHeight = rawHeader.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let height = Int64(rawHeight), height > 0 else {
        throw Self.messageError(
          domain: "Cosmos", message: "Cosmos response returned an invalid block height.")
      }
      parsedHeights.insert(height)
    }
    guard parsedHeights.count == 1, let height = parsedHeights.first else {
      throw Self.messageError(
        domain: "Cosmos", message: "Cosmos response returned conflicting block heights.")
    }
    return height
  }

  private static func validateCosmosHeight(
    _ response: HTTPURLResponse,
    expected: Int64
  ) throws {
    guard let returned = try optionalCosmosHeight(from: response), returned == expected else {
      throw Self.messageError(
        domain: "Cosmos", message: "Cosmos response omitted or changed block height.")
    }
  }

  private static func cosmosChainID(for chainID: String) -> String? {
    switch chainID {
    case "cosmoshub": "cosmoshub-4"
    case "osmosis": "osmosis-1"
    case "celestia": "celestia"
    case "stride": "stride-1"
    default: nil
    }
  }

  private static func deduplicateCosmosBalances(
    _ balances: [CosmosBalance]
  ) -> (balances: [CosmosBalance], warnings: [String]) {
    var balancesByDenom: [String: CosmosBalance] = [:]
    var conflictingDenoms = Set<String>()
    var identicalDuplicateCount = 0
    for balance in balances {
      let denom = balance.denom
      guard !conflictingDenoms.contains(denom) else { continue }
      if let existing = balancesByDenom[denom] {
        if existing == balance {
          identicalDuplicateCount += 1
        } else {
          balancesByDenom.removeValue(forKey: denom)
          conflictingDenoms.insert(denom)
        }
      } else {
        balancesByDenom[denom] = balance
      }
    }
    var warnings: [String] = []
    if identicalDuplicateCount > 0 {
      warnings.append(
        identicalDuplicateCount == 1
          ? "Cosmos repeated one identical liquid-balance record; the duplicate was skipped."
          : "Cosmos repeated \(identicalDuplicateCount) identical liquid-balance records; the duplicates were skipped."
      )
    }
    if !conflictingDenoms.isEmpty {
      warnings.append(
        "Cosmos returned conflicting liquid-balance records for \(conflictingDenoms.count) denomination(s); every conflicting version was skipped."
      )
    }
    return (balancesByDenom.values.sorted { $0.denom < $1.denom }, warnings)
  }

  private static func deduplicateCosmosRewards(
    _ balances: [CosmosBalance]
  ) -> (balances: [CosmosBalance], conflictingDenoms: Set<String>, warnings: [String]) {
    var balancesByDenom: [String: CosmosBalance] = [:]
    var conflictingDenoms = Set<String>()
    var identicalDuplicateCount = 0
    for balance in balances {
      let denom = balance.denom
      guard !conflictingDenoms.contains(denom) else { continue }
      if let existing = balancesByDenom[denom] {
        if existing == balance {
          identicalDuplicateCount += 1
        } else {
          balancesByDenom.removeValue(forKey: denom)
          conflictingDenoms.insert(denom)
        }
      } else {
        balancesByDenom[denom] = balance
      }
    }
    var warnings: [String] = []
    if identicalDuplicateCount > 0 {
      warnings.append(
        identicalDuplicateCount == 1
          ? "Cosmos repeated one identical reward-balance record; the duplicate was skipped."
          : "Cosmos repeated \(identicalDuplicateCount) identical reward-balance records; the duplicates were skipped."
      )
    }
    if !conflictingDenoms.isEmpty {
      warnings.append(
        "Cosmos returned conflicting reward-balance records for \(conflictingDenoms.count) denomination(s); every conflicting version was skipped."
      )
    }
    return (
      balancesByDenom.values.sorted { $0.denom < $1.denom },
      conflictingDenoms,
      warnings
    )
  }

  private static func deduplicateCosmosDelegations(
    _ delegations: [CosmosDelegation],
    expectedDelegatorAddress: String
  ) -> (delegations: [CosmosDelegation], warnings: [String]) {
    var delegationsByValidator: [String: CosmosDelegation] = [:]
    var conflictingValidators = Set<String>()
    var invalidIdentityCount = 0
    var identicalDuplicateCount = 0
    let expectedDelegator = AddressDetection.canonicalAddress(
      expectedDelegatorAddress, family: .cosmos)
    for delegation in delegations {
      guard
        let expectedDelegator,
        let rawDelegator = delegation.delegation?.delegatorAddress,
        AddressDetection.canonicalAddress(rawDelegator, family: .cosmos) == expectedDelegator,
        let validator = delegation.delegation?.validatorAddress?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !validator.isEmpty,
        validator.utf8.count <= 128,
        validator == delegation.delegation?.validatorAddress
      else {
        invalidIdentityCount += 1
        continue
      }
      guard !conflictingValidators.contains(validator) else { continue }
      if let existing = delegationsByValidator[validator] {
        if existing == delegation {
          identicalDuplicateCount += 1
        } else {
          delegationsByValidator.removeValue(forKey: validator)
          conflictingValidators.insert(validator)
        }
      } else {
        delegationsByValidator[validator] = delegation
      }
    }
    var warnings: [String] = []
    if invalidIdentityCount > 0 {
      warnings.append(
        "Cosmos skipped \(invalidIdentityCount) delegation record(s) without the requested delegator and a valid validator identity."
      )
    }
    if identicalDuplicateCount > 0 {
      warnings.append(
        identicalDuplicateCount == 1
          ? "Cosmos repeated one identical delegation record; the duplicate was skipped."
          : "Cosmos repeated \(identicalDuplicateCount) identical delegation records; the duplicates were skipped."
      )
    }
    if !conflictingValidators.isEmpty {
      warnings.append(
        "Cosmos returned conflicting delegation records for \(conflictingValidators.count) validator(s); every conflicting version was skipped."
      )
    }
    return (
      delegationsByValidator.sorted { $0.key < $1.key }.map(\.value),
      warnings
    )
  }

  static func cosmosURL(rest: URL, path: String, queryItems: [URLQueryItem]) -> URL {
    let url = rest.appending(path: path)
    guard !queryItems.isEmpty,
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
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

  static func percentEncodedCosmosQueryComponent(_ value: String) -> String {
    let unreserved = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
  }

  static func normalizedCosmosNextKey(_ value: String?) -> String? {
    guard let candidate = value?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty
    else {
      return nil
    }
    return candidate
  }
}
