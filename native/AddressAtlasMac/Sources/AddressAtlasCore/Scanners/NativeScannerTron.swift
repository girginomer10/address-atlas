import Foundation

extension NativeScanner {
  func scanTron(
    address: String,
    chain: ChainConfig,
    tokens: [TokenConfig],
    prices: [String: PricePoint]
  ) async throws -> NativeScanResult {
    guard let rest = chain.restUrl else { return NativeScanResult() }
    let url = rest.appending(path: "v1/accounts/\(address)")
    let response = try await http.get(url, as: TronAccountResponse.self)
    guard response.success == true else {
      throw Self.messageError(
        domain: "TRON", message: "TRON account lookup did not report success.")
    }
    let accounts = response.data ?? []
    guard accounts.count <= 1 else {
      throw Self.messageError(
        domain: "TRON", message: "TRON account lookup returned multiple account records.")
    }
    let account = accounts.first
    if let account {
      guard let expectedAddress = AddressDetection.tronHexAddress(address),
        account.address?.lowercased() == expectedAddress
      else {
        throw Self.messageError(
          domain: "TRON", message: "TRON account lookup returned a different account.")
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
        "Native TRX balance returned an invalid amount; TRC-20 balances may still be available.")
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
        "TRC-20 token balance data was invalid for \(Self.formattedSymbols(tokenScan.invalidSymbols)); balances may be incomplete."
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
          ? "TRON repeated one identical TRC-20 contract balance record; the duplicate was skipped to avoid double-counting."
          : "TRON repeated \(identicalDuplicateCount) identical TRC-20 contract balance records; the duplicates were skipped to avoid double-counting."
      )
    }
    if !conflictingSymbols.isEmpty {
      result.warnings.append(
        "TRON returned conflicting TRC-20 balance records for \(Self.formattedSymbols(conflictingSymbols)); every conflicting version was skipped."
      )
    }
    return result
  }

}
