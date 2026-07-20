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

}
