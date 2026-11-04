import Foundation

extension NativeScanner {
  func scanCosmos(
    address: String,
    chain: ChainConfig,
    prices: [String: PricePoint],
    snapshotAnchors: ChainNetworkValueCache<Int64>? = nil
  )
    async throws -> NativeScanResult
  {
    guard let rest = chain.restUrl, let denom = chain.nativeDenom else { return NativeScanResult() }
    guard case .cosmosChainID = chain.networkIdentity else {
      throw Self.messageError(domain: "Cosmos", message: "Cosmos network identity is missing.")
    }
    let liquidScan: CosmosBalanceScan
    do {
      // Establish both immutable chain identity and the one snapshot height
      // before accepting any balance. Every successful path is therefore
      // network-bound; there is no optimistic unbound fast path.
      let anchorCache = snapshotAnchors ?? ChainNetworkValueCache<Int64>()
      let height = try await anchorCache.value(
        chainID: chain.id,
        endpoint: rest,
        identity: chain.networkIdentity
      ) {
        try await fetchCosmosSnapshotHeight(rest: rest, chain: chain)
      }
      liquidScan = try await fetchCosmosBalances(
        rest: rest, address: address, expectedHeight: height)
    } catch {
      try throwIfCancellation(error)
      return NativeScanResult(
        warnings: [
          "Couldn't get a consistent snapshot from the network; available, staked, unbonding, and reward balances were skipped."
        ])
    }
    guard let snapshotHeight = liquidScan.height else {
      return NativeScanResult(
        warnings: [
          "The network provider didn't report a block height; available, staked, unbonding, and reward balances were skipped."
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

    let parts: [CosmosScanPart] = [.delegations, .rewards, .unbonding]
    let results = try await boundedConcurrentMap(parts, maxConcurrent: 2) { part in
      do {
        switch part {
        case .liquid:
          return NativeScanResult()
        case .unbonding:
          let scan = try await fetchCosmosUnbondingDelegations(
            rest: rest, address: address, expectedHeight: snapshotHeight)
          let response = CosmosUnbondingResponse(
            unbondingResponses: scan.unbondingDelegations, pagination: nil)
          guard let parsed = Self.parseCosmosUnbonding(response, decimals: chain.decimals)
          else {
            throw Self.messageError(
              domain: "Cosmos", message: "Unbonding delegations contained an invalid amount.")
          }
          // One holding per distinct completion time, so every holding's
          // `unlocksAt` is exact for its whole amount.
          let assets = parsed.buckets.flatMap { bucket in
            assetIfPositive(
              amount: bucket.amount,
              address: address,
              chain: chain,
              prices: prices,
              name: "\(chain.name) Unbonding",
              source: .unbonding,
              idSuffix: bucket.unlocksAt.map { String(Int64($0.timeIntervalSince1970)) }
                ?? "undated",
              unlocksAt: bucket.unlocksAt
            )
          }
          return NativeScanResult(assets: assets, warnings: scan.warnings + parsed.warnings)
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

  /// Same shape and safety rules as `fetchCosmosDelegations`: every page is
  /// pinned to the scan's snapshot height, pagination keys are bounded and
  /// never repeat, and a failure after the first page keeps the pages already
  /// read and says so.
  func fetchCosmosUnbondingDelegations(rest: URL, address: String, expectedHeight: Int64)
    async throws -> CosmosUnbondingScan
  {
    var unbonding: [CosmosUnbondingDelegation] = []
    var warnings: [String] = []
    var nextKey: String?
    var seenKeys = Set<String>()

    for page in 1...maxCosmosPages {
      try Task.checkCancellation()
      var queryItems = [URLQueryItem(name: "pagination.limit", value: "500")]
      if let nextKey { queryItems.append(URLQueryItem(name: "pagination.key", value: nextKey)) }
      let url = Self.cosmosURL(
        rest: rest,
        path: "cosmos/staking/v1beta1/delegators/\(address)/unbonding_delegations",
        queryItems: queryItems
      )
      do {
        let fetched = try await http.getResponse(
          url,
          headers: Self.cosmosHeightHeaders(expectedHeight),
          as: CosmosUnbondingResponse.self
        )
        try Self.validateCosmosHeight(fetched.response, expected: expectedHeight)
        unbonding.append(contentsOf: fetched.value.unbondingResponses ?? [])
        guard
          let candidate = Self.normalizedCosmosNextKey(fetched.value.pagination?.nextKey)
        else {
          break
        }
        guard seenKeys.insert(candidate).inserted else {
          warnings.append(
            "Cosmos unbonding pagination returned a repeated key; later unbonding entries were skipped."
          )
          break
        }
        guard page < maxCosmosPages else {
          warnings.append(
            "Cosmos unbonding pagination reached the \(maxCosmosPages)-page safety limit; later unbonding entries were skipped."
          )
          break
        }
        nextKey = candidate
      } catch {
        try throwIfCancellation(error)
        guard page > 1 else { throw error }
        warnings.append(
          "Later Cosmos unbonding pages could not be read; entries from completed pages were kept."
        )
        break
      }
    }
    let deduplicated = Self.deduplicateCosmosUnbondingDelegations(
      unbonding, expectedDelegatorAddress: address)
    warnings.append(contentsOf: deduplicated.warnings)
    return CosmosUnbondingScan(unbondingDelegations: deduplicated.delegations, warnings: warnings)
  }

  /// Most distinct completion times that become separate holdings. A real
  /// delegator has a handful (every unbond in one transaction shares a time);
  /// the bound only keeps a hostile or broken provider from creating thousands
  /// of holdings and pushing the scan past the vault's per-scan limit.
  public static let maximumCosmosUnbondingHoldings = 20

  /// Sums unbonding entries per completion time (whole seconds, UTC).
  ///
  /// - Returns nil when any entry has no usable `balance`, mirroring
  ///   `parseCosmosDelegations`: an amount that cannot be trusted fails the
  ///   whole part (a visible warning), never a partial total.
  /// - An entry whose completion time is missing or not a real RFC 3339 UTC
  ///   time still counts; it lands in one undated bucket and a warning says so.
  /// - Buckets come back soonest first, undated last. Beyond
  ///   `maximumCosmosUnbondingHoldings` the latest buckets fold into one that
  ///   shows the earliest of their times, with a warning.
  public static func parseCosmosUnbonding(
    _ response: CosmosUnbondingResponse, decimals: Int
  ) -> CosmosUnbondingParse? {
    guard (0...36).contains(decimals) else { return nil }
    var rawByCompletion: [Int64?: Double] = [:]
    var undatedEntryCount = 0
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    var parsedTimes: [String: Int64?] = [:]

    for delegation in response.unbondingResponses ?? [] {
      for entry in delegation.entries ?? [] {
        guard let balance = entry.balance, let raw = cosmosRawAmount(balance) else { return nil }
        guard raw > 0 else { continue }
        let completion: Int64?
        if let text = entry.completionTime {
          if let cached = parsedTimes[text] {
            completion = cached
          } else {
            let parsed = cosmosCompletionTime(text, formatter: formatter)
              .map { Int64($0.timeIntervalSince1970) }
            parsedTimes.updateValue(parsed, forKey: text)
            completion = parsed
          }
        } else {
          completion = nil
        }
        if completion == nil { undatedEntryCount += 1 }
        let total = (rawByCompletion[completion] ?? 0) + raw
        guard total.isFinite else { return nil }
        rawByCompletion[completion] = total
      }
    }

    var warnings: [String] = []
    if undatedEntryCount > 0 {
      warnings.append(
        undatedEntryCount == 1
          ? "Cosmos reported one unbonding entry without a usable completion time; it is counted without an unlock date."
          : "Cosmos reported \(undatedEntryCount) unbonding entries without a usable completion time; they are counted without an unlock date."
      )
    }

    let scale = pow(10, Double(decimals))
    var buckets: [CosmosUnbondingBucket] = []
    for key in rawByCompletion.keys.sorted(by: { lhs, rhs in
      switch (lhs, rhs) {
      case (let left?, let right?): return left < right
      case (_?, nil): return true
      default: return false
      }
    }) {
      let amount = (rawByCompletion[key] ?? 0) / scale
      guard amount.isFinite else { return nil }
      buckets.append(
        CosmosUnbondingBucket(
          unlocksAt: key.map { Date(timeIntervalSince1970: TimeInterval($0)) },
          amount: amount
        ))
    }

    if buckets.count > maximumCosmosUnbondingHoldings {
      let kept = Array(buckets.prefix(maximumCosmosUnbondingHoldings - 1))
      let folded = buckets.dropFirst(maximumCosmosUnbondingHoldings - 1)
      var combined = 0.0
      for bucket in folded {
        combined += bucket.amount
      }
      guard combined.isFinite else { return nil }
      buckets = kept + [
        CosmosUnbondingBucket(
          unlocksAt: folded.compactMap(\.unlocksAt).min(),
          amount: combined
        )
      ]
      warnings.append(
        "Cosmos reported unbonding entries with more than \(maximumCosmosUnbondingHoldings) distinct completion times; the latest ones were combined and show the earliest of their times."
      )
    }
    return CosmosUnbondingParse(buckets: buckets, warnings: warnings)
  }

  /// Plain decimal digits only (the SDK's integer string). Unlike `Double(_:)`
  /// alone this refuses exponent, hexadecimal, signed, and spaced spellings.
  static func cosmosRawAmount(_ value: String) -> Double? {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= 40,
      bytes.allSatisfy({ $0 >= 48 && $0 <= 57 }),
      let raw = Double(value), raw.isFinite
    else { return nil }
    return raw
  }

  /// Strict `YYYY-MM-DDTHH:MM:SS[.fraction]Z` (what the Cosmos SDK emits).
  /// Returns whole seconds (the fraction is dropped, like every persisted
  /// date) or nil for anything else, including impossible calendar values
  /// that Foundation would silently normalize (February 30, hour 24), leap
  /// seconds, and dates outside 1970...9999.
  static func cosmosCompletionTime(_ value: String, formatter: ISO8601DateFormatter) -> Date? {
    let bytes = Array(value.utf8)
    guard bytes.count >= 20, bytes.count <= 40, bytes.last == UInt8(ascii: "Z") else { return nil }
    func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }
    let separators: [Int: UInt8] = [
      4: UInt8(ascii: "-"), 7: UInt8(ascii: "-"), 10: UInt8(ascii: "T"),
      13: UInt8(ascii: ":"), 16: UInt8(ascii: ":"),
    ]
    for index in 0..<19 {
      if let separator = separators[index] {
        guard bytes[index] == separator else { return nil }
      } else {
        guard isDigit(bytes[index]) else { return nil }
      }
    }
    if bytes.count > 20 {
      guard bytes[19] == UInt8(ascii: "."), bytes.count >= 22,
        bytes[20..<(bytes.count - 1)].allSatisfy(isDigit)
      else { return nil }
    } else {
      guard bytes[19] == UInt8(ascii: "Z") else { return nil }
    }
    let wholeSeconds = String(decoding: bytes[0..<19], as: UTF8.self) + "Z"
    guard let date = formatter.date(from: wholeSeconds),
      formatter.string(from: date) == wholeSeconds,
      (0...VaultDocumentSemanticValidator.latestRepresentableUnlockTimestamp).contains(
        date.timeIntervalSince1970)
    else { return nil }
    return date
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
      case .cosmosChainID(let expectedChainID) = chain.networkIdentity,
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

  private static func deduplicateCosmosUnbondingDelegations(
    _ delegations: [CosmosUnbondingDelegation],
    expectedDelegatorAddress: String
  ) -> (delegations: [CosmosUnbondingDelegation], warnings: [String]) {
    var delegationsByValidator: [String: CosmosUnbondingDelegation] = [:]
    var conflictingValidators = Set<String>()
    var invalidIdentityCount = 0
    var identicalDuplicateCount = 0
    let expectedDelegator = AddressDetection.canonicalAddress(
      expectedDelegatorAddress, family: .cosmos)
    for delegation in delegations {
      guard
        let expectedDelegator,
        let rawDelegator = delegation.delegatorAddress,
        AddressDetection.canonicalAddress(rawDelegator, family: .cosmos) == expectedDelegator,
        let validator = delegation.validatorAddress?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !validator.isEmpty,
        validator.utf8.count <= 128,
        validator == delegation.validatorAddress
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
        "Cosmos skipped \(invalidIdentityCount) unbonding record(s) without the requested delegator and a valid validator identity."
      )
    }
    if identicalDuplicateCount > 0 {
      warnings.append(
        identicalDuplicateCount == 1
          ? "Cosmos repeated one identical unbonding record; the duplicate was skipped."
          : "Cosmos repeated \(identicalDuplicateCount) identical unbonding records; the duplicates were skipped."
      )
    }
    if !conflictingValidators.isEmpty {
      warnings.append(
        "Cosmos returned conflicting unbonding records for \(conflictingValidators.count) validator(s); every conflicting version was skipped."
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
