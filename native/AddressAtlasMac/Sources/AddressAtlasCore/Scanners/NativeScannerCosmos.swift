import Foundation

extension NativeScanner {
  func scanCosmos(address: String, chain: ChainConfig, prices: [String: PricePoint])
    async throws -> NativeScanResult
  {
    guard let rest = chain.restUrl, let denom = chain.nativeDenom else { return NativeScanResult() }
    let parts: [CosmosScanPart] = [.liquid, .delegations, .rewards]
    let results = try await boundedConcurrentMap(parts, maxConcurrent: 3) { part in
      do {
        switch part {
        case .liquid:
          let scan = try await fetchCosmosBalances(rest: rest, address: address)
          let response = CosmosBankResponse(balances: scan.balances, pagination: nil)
          guard
            let amount = Self.parseCosmosLiquid(response, denom: denom, decimals: chain.decimals)
          else {
            throw Self.messageError(
              domain: "Cosmos", message: "Liquid balance contained an invalid amount.")
          }
          return NativeScanResult(
            assets: assetIfPositive(
              amount: amount,
              address: address,
              chain: chain,
              prices: prices
            ), warnings: scan.warnings)
        case .delegations:
          let scan = try await fetchCosmosDelegations(rest: rest, address: address)
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
          let response = try await http.get(
            rest.appending(path: "cosmos/distribution/v1beta1/delegators/\(address)/rewards"),
            as: CosmosRewardsResponse.self
          )
          guard
            let amount = Self.parseCosmosRewards(response, denom: denom, decimals: chain.decimals)
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

  func fetchCosmosBalances(rest: URL, address: String) async throws -> CosmosBalanceScan {
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
        guard let candidate = Self.normalizedCosmosNextKey(response.pagination?.nextKey) else {
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
    return CosmosBalanceScan(balances: balances, warnings: warnings)
  }

  func fetchCosmosDelegations(rest: URL, address: String) async throws
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
        let response = try await http.get(url, as: CosmosDelegationResponse.self)
        delegations.append(contentsOf: response.delegationResponses ?? [])
        guard let candidate = Self.normalizedCosmosNextKey(response.pagination?.nextKey) else {
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
    return CosmosDelegationScan(delegations: delegations, warnings: warnings)
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
    guard (0...36).contains(decimals) else { return nil }
    var total = 0.0
    for balance in response.total ?? [] where balance.denom == denom {
      guard let raw = Double(balance.amount), raw.isFinite, raw >= 0 else { return nil }
      total += raw
      guard total.isFinite else { return nil }
    }
    return total / pow(10, Double(decimals))
  }

  static func scaledNonnegativeAmount(_ rawValue: String, decimals: Int) -> Double? {
    guard let raw = Double(rawValue), raw.isFinite, raw >= 0 else { return nil }
    let amount = raw / pow(10, Double(decimals))
    return amount.isFinite ? amount : nil
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
