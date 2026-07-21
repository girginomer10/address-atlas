import Foundation

extension NativeScanner {

  func assetIfPositive(
    amount: Double,
    address: String,
    chain: ChainConfig,
    prices: [String: PricePoint],
    name: String? = nil,
    source: AssetSource = .native
  ) -> [TrackedAsset] {
    guard amount.isFinite, amount > 0 else { return [] }
    let price = prices[chain.coinGeckoId] ?? PricePoint(usd: 0)
    let unitPrice = price.usd.isFinite && price.usd >= 0 ? price.usd : 0
    let valueUsd = FiniteValueMath.multiplyingNonnegative(amount, unitPrice)
    return [
      TrackedAsset(
        id: "\(address)-\(chain.id)-\(chain.symbol)-\(source.rawValue)",
        address: address,
        chainId: chain.id,
        chainName: chain.name,
        family: chain.family,
        symbol: chain.symbol,
        name: name ?? chain.name,
        amount: amount,
        priceUsd: unitPrice,
        valueUsd: valueUsd ?? 0,
        change24h: FiniteValueMath.finiteOptional(price.usd24hChange),
        explorerUrl: chain.explorerURL(for: address).absoluteString,
        source: source
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
    let rawPrice = price?.usd ?? token.priceUsd ?? 0
    let priceUsd = rawPrice.isFinite && rawPrice >= 0 ? rawPrice : 0
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
        "Only the first \(maxEnabledCustomTokens) enabled custom tokens were scanned; additional tokens were skipped."
      )
    }

    for token in enabledTokens {
      let label = customTokenLabel(token)
      let chainId = token.chainId.trimmingCharacters(in: .whitespacesAndNewlines)
      if let network = ChainRegistry.retiredChainNames[chainId] {
        warnings.append(
          "Custom token \(label) references retired \(network); the saved record was kept but not scanned."
        )
        continue
      }
      guard [.evm, .solana, .tron].contains(token.chainKind) else {
        warnings.append("Custom token \(label) uses an unsupported chain family and was skipped.")
        continue
      }
      guard let chain = ChainRegistry.allChains.first(where: { $0.id == chainId }),
        chain.family == token.chainKind
      else {
        warnings.append(
          "Custom token \(label) references an unknown or mismatched chain and was skipped.")
        continue
      }
      guard let address = AddressDetection.canonicalAddress(token.address, family: token.chainKind)
      else {
        warnings.append(
          "Custom token \(label) has an invalid contract or mint address and was skipped.")
        continue
      }
      let symbol = token.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
      let name = token.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !symbol.isEmpty, symbol.count <= 32, !name.isEmpty, name.count <= 128 else {
        warnings.append("Custom token \(label) has an invalid symbol or name and was skipped.")
        continue
      }
      guard (0...36).contains(token.decimals) else {
        warnings.append("Custom token \(label) has unsupported decimals and was skipped.")
        continue
      }
      guard token.priceUsd.map({ $0.isFinite && $0 >= 0 }) ?? true else {
        warnings.append("Custom token \(label) has an invalid USD price and was skipped.")
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
            "Custom token \(label) has an invalid CoinGecko ID; CoinGecko pricing was disabled.")
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
