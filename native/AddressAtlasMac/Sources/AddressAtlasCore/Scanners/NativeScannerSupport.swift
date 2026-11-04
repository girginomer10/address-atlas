import Foundation

extension NativeScanner {

  func assetIfPositive(
    amount: Double,
    address: String,
    chain: ChainConfig,
    prices: [String: PricePoint],
    name: String? = nil,
    source: AssetSource = .native,
    idSuffix: String? = nil,
    unlocksAt: Date? = nil
  ) -> [TrackedAsset] {
    guard amount.isFinite, amount > 0 else { return [] }
    let price = prices[chain.coinGeckoId]
    let hasKnownPrice = price.map { $0.usd.isFinite && $0.usd >= 0 } == true
    let unitPrice = hasKnownPrice ? price?.usd ?? 0 : 0
    let valueUsd = FiniteValueMath.multiplyingNonnegative(amount, unitPrice)
    return [
      TrackedAsset(
        id: "\(address)-\(chain.id)-\(chain.symbol)-\(source.rawValue)"
          + (idSuffix.map { "-\($0)" } ?? ""),
        address: address,
        chainId: chain.id,
        chainName: chain.name,
        family: chain.family,
        symbol: chain.symbol,
        name: name ?? chain.name,
        amount: amount,
        priceUsd: unitPrice,
        valueUsd: valueUsd ?? 0,
        pricingStatus: hasKnownPrice
          ? (valueUsd == nil ? .valuationUnavailable : .priced)
          : .unpriced,
        change24h: FiniteValueMath.finiteOptional(price?.usd24hChange),
        explorerUrl: chain.explorerURL(for: address).absoluteString,
        source: source,
        unlocksAt: unlocksAt
      )
    ]
  }

  func tokenAsset(
    amount: Double,
    address: String,
    chain: ChainConfig,
    token: TokenConfig,
    prices: [String: PricePoint],
    source: AssetSource
  ) -> TrackedAsset? {
    guard amount.isFinite, amount > 0 else { return nil }
    let price = token.coinGeckoId.flatMap { prices[$0] }
    let candidatePrice = price?.usd ?? token.priceUsd
    let hasKnownPrice = candidatePrice.map { $0.isFinite && $0 >= 0 } == true
    let priceUsd = hasKnownPrice ? candidatePrice ?? 0 : 0
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
      pricingStatus: hasKnownPrice
        ? (valueUsd == nil ? .valuationUnavailable : .priced)
        : .unpriced,
      change24h: FiniteValueMath.finiteOptional(price?.usd24hChange),
      explorerUrl: chain.explorerURL(for: address).absoluteString,
      source: source
    )
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
        "Only the first \(maxEnabledCustomTokens) enabled custom tokens were scanned. The rest are missing from this scan. Turn off tokens you don't need."
      )
    }

    for token in enabledTokens {
      let label = customTokenLabel(token)
      let chainId = token.chainId.trimmingCharacters(in: .whitespacesAndNewlines)
      if let network = ChainRegistry.retiredChainNames[chainId] {
        warnings.append(
          "Custom token \(label) is on \(network), which has shut down. It's still saved but isn't scanned."
        )
        continue
      }
      guard [.evm, .solana, .tron].contains(token.chainKind) else {
        warnings.append("Custom token \(label) is on a type of network Address Atlas doesn't support, so it's left out of this scan.")
        continue
      }
      guard let chain = ChainRegistry.allChains.first(where: { $0.id == chainId }),
        chain.family == token.chainKind
      else {
        warnings.append(
          "Custom token \(label) has an unknown or mismatched network, so it's left out of this scan. Edit the token to fix it.")
        continue
      }
      guard let address = AddressDetection.canonicalAddress(token.address, family: token.chainKind)
      else {
        warnings.append(
          "Custom token \(label) has an invalid contract or mint address, so it's left out of this scan. Check the address.")
        continue
      }
      let symbol = token.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
      let name = token.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !symbol.isEmpty,
        VaultTextLimits.contains(
          symbol,
          maximumCharacters: VaultTextLimits.tokenSymbolCharacters,
          maximumUTF8Bytes: VaultTextLimits.tokenSymbolUTF8Bytes
        ),
        !name.isEmpty,
        VaultTextLimits.contains(
          name,
          maximumCharacters: VaultTextLimits.tokenNameCharacters,
          maximumUTF8Bytes: VaultTextLimits.tokenNameUTF8Bytes
        )
      else {
        warnings.append("Custom token \(label) has an invalid symbol or name, so it's left out of this scan. Edit the token to fix it.")
        continue
      }
      guard (0...36).contains(token.decimals) else {
        warnings.append("Custom token \(label) has unsupported decimals, so it's left out of this scan. Check the decimals.")
        continue
      }
      guard token.priceUsd.map({ $0.isFinite && $0 >= 0 }) ?? true else {
        warnings.append("Custom token \(label) has an invalid USD price, so it's left out of this scan. Check the price.")
        continue
      }
      let coinGeckoId: String?
      if let rawId = token.coinGeckoId?.trimmingCharacters(in: .whitespacesAndNewlines),
        !rawId.isEmpty
      {
        if let normalizedId = UserInputValidation.normalizedCoinGeckoId(rawId) {
          coinGeckoId = normalizedId
        } else {
          // Older app versions accepted Unicode lowercase characters here.
          // Preserve the valid on-chain token and only discard unsafe pricing
          // metadata so its balance remains visible as unpriced.
          warnings.append(
            "Custom token \(label) has an invalid CoinGecko ID, so CoinGecko pricing is turned off for it. Check the ID.")
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

  static func appendUnique(
    _ token: TokenConfig, family: ChainFamily, to tokens: inout [TokenConfig]
  ) {
    let candidate = family == .evm ? token.address.lowercased() : token.address
    guard
      !tokens.contains(where: {
        (family == .evm ? $0.address.lowercased() : $0.address) == candidate
      })
    else {
      return
    }
    tokens.append(token)
  }

  static func customTokenLabel(_ token: CustomTokenRecord) -> String {
    let symbol = token.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
    if !symbol.isEmpty { return String(symbol.prefix(32)) }
    return String(token.address.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16))
  }

  static func formattedSymbols(_ symbols: [String]) -> String {
    let unique = Array(Set(symbols)).sorted()
    guard unique.count > 5 else { return unique.joined(separator: ", ") }
    return "\(unique.prefix(5).joined(separator: ", ")) and \(unique.count - 5) more"
  }

  static func displayAddress(_ address: String) -> String {
    guard address.count > 12 else { return "saved wallet" }
    return "\(address.prefix(6))...\(address.suffix(4))"
  }

  static func rpcError(domain: String, error: JSONRPCError, fallback: String) -> NSError {
    messageError(domain: domain, message: error.message ?? fallback, code: error.code ?? 1)
  }

  static func messageError(domain: String, message: String, code: Int = 1) -> NSError {
    NSError(
      domain: "AddressAtlas.\(domain)",
      code: code,
      userInfo: [NSLocalizedDescriptionKey: ProviderErrorSanitizer.sanitize(message)]
    )
  }

}
