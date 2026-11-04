import Foundation

extension NativeScanner {
  func scanTron(
    address: String,
    chain: ChainConfig,
    tokens: [TokenConfig],
    prices: [String: PricePoint],
    networkIdentityProofs: ChainNetworkValueCache<Void>? = nil
  ) async throws -> NativeScanResult {
    guard let rest = chain.restUrl else { return NativeScanResult() }
    struct BlockNumberRequest: Encodable { var num: Int }
    struct GenesisBlockResponse: Decodable { var blockID: String? }
    guard case .tronGenesisBlockID(let expectedGenesisBlockID) = chain.networkIdentity else {
      throw Self.messageError(domain: "TRON", message: "Couldn't confirm the TRON network, so balances are missing from this scan. Check the server settings in Settings.")
    }
    let proofCache = networkIdentityProofs ?? ChainNetworkValueCache<Void>()
    try await proofCache.prove(
      chainID: chain.id,
      endpoint: rest,
      identity: chain.networkIdentity
    ) {
      let genesis = try await http.post(
        rest.appending(path: "wallet/getblockbynum"),
        body: BlockNumberRequest(num: 0),
        as: GenesisBlockResponse.self
      )
      guard genesis.blockID == expectedGenesisBlockID else {
        throw Self.messageError(
          domain: "TRON", message: "The server isn't on the TRON network, so balances are missing from this scan. Check the server settings in Settings.")
      }
    }
    let url = rest.appending(path: "v1/accounts/\(address)")
    let response = try await http.get(url, as: TronAccountResponse.self)
    guard response.success == true else {
      throw Self.messageError(
        domain: "TRON", message: "The server didn't confirm the TRON account lookup, so balances are missing from this scan. Scan again later.")
    }
    let accounts = response.data ?? []
    guard accounts.count <= 1 else {
      throw Self.messageError(
        domain: "TRON", message: "The server sent several records for one TRON account, so balances are missing from this scan. Scan again later.")
    }
    let account = accounts.first
    if let account {
      guard let expectedAddress = AddressDetection.tronHexAddress(address),
        account.address?.lowercased() == expectedAddress
      else {
        throw Self.messageError(
          domain: "TRON", message: "The server's reply was for a different TRON account, so balances are missing from this scan. Scan again later.")
      }
    }
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
      warnings.append(
        "The server sent a TRX balance Address Atlas couldn't read, so it's missing from this scan. TRC-20 token balances may still be included.")
    }

    let tokenScan = Self.parseTronTrc20BalanceResult(account?.trc20 ?? [], tokens: tokens)
    assets.append(
      contentsOf: tokenScan.balances.compactMap { entry in
        tokenAsset(
          amount: entry.amount, address: address, chain: chain, token: entry.token, prices: prices,
          source: .trc20)
      })
    if !tokenScan.invalidSymbols.isEmpty {
      warnings.append(
        "Address Atlas couldn't read the TRC-20 balance data for \(Self.formattedSymbols(tokenScan.invalidSymbols)), so those balances may be missing from this scan."
      )
    }
    warnings.append(contentsOf: tokenScan.warnings)
    return NativeScanResult(assets: assets, warnings: warnings)
  }

  public static func parseTronTrc20Balances(_ balances: [[String: String]], tokens: [TokenConfig])
    -> [(token: TokenConfig, amount: Double)]
  {
    parseTronTrc20BalanceResult(balances, tokens: tokens).balances
  }

  static func parseTronTrc20BalanceResult(
    _ balances: [[String: String]],
    tokens: [TokenConfig]
  ) -> TronTokenBalanceParseResult {
    var result = TronTokenBalanceParseResult()
    var identicalDuplicateCount = 0
    var conflictingSymbols: [String] = []
    for token in tokens {
      guard (0...36).contains(token.decimals) else {
        result.invalidSymbols.append(token.symbol)
        continue
      }
      let rawValues = balances.compactMap { $0[token.address] }
      guard let firstRawValue = rawValues.first else { continue }
      let parsedValues = rawValues.compactMap { rawValue -> Double? in
        guard let raw = Double(rawValue), raw.isFinite, raw >= 0 else { return nil }
        return raw
      }
      guard parsedValues.count == rawValues.count, let rawAmount = parsedValues.first else {
        result.invalidSymbols.append(token.symbol)
        continue
      }
      guard rawValues.dropFirst().allSatisfy({ $0 == firstRawValue }) else {
        conflictingSymbols.append(token.symbol)
        continue
      }
      identicalDuplicateCount += rawValues.count - 1
      let amount = rawAmount / pow(10, Double(token.decimals))
      if amount.isFinite, amount > 0 {
        result.balances.append((token, amount))
      }
    }
    if identicalDuplicateCount > 0 {
      result.warnings.append(
        identicalDuplicateCount == 1
          ? "The server listed the same TRC-20 balance twice. It was counted once."
          : "The server listed \(identicalDuplicateCount) TRC-20 balances more than once. Each was counted once."
      )
    }
    if !conflictingSymbols.isEmpty {
      result.warnings.append(
        "The server sent conflicting TRC-20 balances for \(Self.formattedSymbols(conflictingSymbols)), so those balances are left out of this scan. Scan again later."
      )
    }
    return result
  }

}
