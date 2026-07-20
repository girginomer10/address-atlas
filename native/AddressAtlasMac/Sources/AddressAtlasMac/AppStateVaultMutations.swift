import AddressAtlasCore
import Foundation

extension AppState {

  @discardableResult
  func addWallet(address: String) async -> Bool {
    guard canMutateVault() else { return false }
    guard document.wallets.count < Self.maximumWallets else {
      error =
        "A vault can scan at most \(Self.maximumWallets) saved wallets. Remove one before adding another."
      return false
    }
    let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard AddressDetection.isSafePublicAddress(trimmed),
      let chain = AddressDetection.detectChains(for: trimmed).first
    else {
      error = "Enter a supported public wallet address."
      return false
    }
    guard let identity = AddressDetection.canonicalAddress(trimmed, family: chain.family) else {
      error = "Enter a supported public wallet address."
      return false
    }
    if document.wallets.contains(where: {
      $0.chainKind == chain.family
        && AddressDetection.canonicalAddress($0.address, family: $0.chainKind) == identity
    }) {
      error = "That wallet is already saved."
      return false
    }
    return await mutateDocument { document in
      document.wallets.append(
        WalletRecord(
          label: AddressDetection.defaultWalletLabel(trimmed), address: trimmed,
          chainKind: chain.family)
      )
    }
  }

  static func normalizedWalletLabel(_ label: String) -> String? {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty || trimmed.count > 80 ? nil : trimmed
  }

  @discardableResult
  func updateWalletLabel(id: UUID, label: String) async -> Bool {
    guard canMutateVault() else { return false }
    guard let index = document.wallets.firstIndex(where: { $0.id == id }) else { return false }
    guard let normalized = AppState.normalizedWalletLabel(label) else {
      error = "Wallet labels must be between 1 and 80 characters."
      return false
    }
    guard document.wallets[index].label != normalized else { return true }
    return await mutateDocument { document in
      document.wallets[index].label = normalized
      document.wallets[index].updatedAt = Date()
    }
  }

  func removeWallet(id: UUID) async {
    guard canMutateVault() else { return }
    _ = await mutateDocument { $0.wallets.removeAll { $0.id == id } }
  }

  @discardableResult
  func addCustomToken(
    chainKind: ChainFamily,
    chainId: String,
    address: String,
    symbol: String,
    name: String,
    decimals: String,
    coinGeckoId: String,
    priceUsd: String
  ) async -> Bool {
    guard canMutateVault() else { return false }
    guard document.customTokens.count < Self.maximumCustomTokens else {
      error = "A vault can contain at most \(Self.maximumCustomTokens) custom tokens."
      return false
    }
    let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedAddress = chainKind == .evm ? trimmedAddress.lowercased() : trimmedAddress
    let normalizedSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let parsedDecimals = Int(decimals.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    let priceInput = priceUsd.trimmingCharacters(in: .whitespacesAndNewlines)
    let parsedPrice =
      priceInput.isEmpty ? nil : UserInputValidation.nonnegativeFiniteNumber(priceInput)
    let trimmedCoinGeckoId = coinGeckoId.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedCoinGeckoId =
      trimmedCoinGeckoId.isEmpty
      ? nil
      : UserInputValidation.normalizedCoinGeckoId(trimmedCoinGeckoId)
    guard chainKind == .evm || chainKind == .solana,
      !normalizedAddress.isEmpty,
      !normalizedSymbol.isEmpty, normalizedSymbol.count <= 32,
      !normalizedName.isEmpty, normalizedName.count <= 128,
      parsedDecimals >= 0,
      parsedDecimals <= 36
    else {
      error = "Token needs address, symbol, name, and decimals between 0 and 36."
      return false
    }
    guard trimmedCoinGeckoId.isEmpty || normalizedCoinGeckoId != nil else {
      error = "CoinGecko ID may contain lowercase letters, numbers, and hyphens only."
      return false
    }
    // Preserve mixed-case EVM input until after EIP-55 validation; lowercasing
    // first would erase an invalid checksum and turn it into an accepted address.
    guard AddressDetection.isValidCustomTokenAddress(trimmedAddress, family: chainKind) else {
      error =
        chainKind == .evm
        ? "Enter a valid 0x token contract address." : "Enter a valid Solana mint address."
      return false
    }
    guard chainKind != .evm || ChainRegistry.evmChains.contains(where: { $0.id == chainId }) else {
      error = "Choose a supported EVM chain."
      return false
    }
    guard priceInput.isEmpty || parsedPrice != nil else {
      error = "USD price must be a finite, non-negative number."
      return false
    }
    if document.customTokens.contains(where: {
      $0.chainKind == chainKind
        && $0.chainId == chainId
        && (chainKind == .evm
          ? $0.address.lowercased() == normalizedAddress.lowercased()
          : $0.address == normalizedAddress)
    }) {
      error = "That token is already in the allowlist."
      return false
    }
    return await mutateDocument { document in
      document.customTokens.append(
        CustomTokenRecord(
          chainKind: chainKind,
          chainId: chainId,
          address: normalizedAddress,
          symbol: normalizedSymbol,
          name: normalizedName,
          decimals: parsedDecimals,
          coinGeckoId: normalizedCoinGeckoId,
          priceUsd: parsedPrice
        )
      )
    }
  }

  func toggleCustomToken(id: UUID) async {
    guard canMutateVault() else { return }
    guard let index = document.customTokens.firstIndex(where: { $0.id == id }) else { return }
    _ = await mutateDocument { document in
      document.customTokens[index].enabled.toggle()
      document.customTokens[index].updatedAt = Date()
    }
  }

  func removeCustomToken(id: UUID) async {
    guard canMutateVault() else { return }
    _ = await mutateDocument { $0.customTokens.removeAll { $0.id == id } }
  }

  @discardableResult
  func addManualHolding(symbol: String, amount: String, valueUsd: String) async -> Bool {
    guard canMutateVault() else { return false }
    guard document.manualHoldings.count < Self.maximumManualHoldings else {
      error = "A vault can contain at most \(Self.maximumManualHoldings) manual holdings."
      return false
    }
    guard let parsedAmount = UserInputValidation.nonnegativeFiniteNumber(amount),
      let parsedValue = UserInputValidation.nonnegativeFiniteNumber(valueUsd),
      !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      error = "Manual holding needs a symbol plus finite, non-negative amount and value."
      return false
    }
    guard
      let derivedPrice = AppState.derivedManualPrice(amount: parsedAmount, valueUsd: parsedValue)
    else {
      error =
        parsedAmount > 0
        ? "Manual holding amount and value produce an unsupported price."
        : "Manual holding amount must be greater than zero."
      return false
    }
    let normalized = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard normalized.count <= 32,
      normalized.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" })
    else {
      error =
        "Manual holding symbols may use up to 32 letters, numbers, dots, dashes, or underscores."
      return false
    }
    return await mutateDocument { document in
      document.manualHoldings.append(
        ManualHoldingRecord(
          label: "Manual",
          provider: "custom",
          customVenue: "Manual",
          symbol: normalized,
          name: normalized,
          amount: parsedAmount,
          priceUsd: derivedPrice,
          valueUsd: parsedValue
        )
      )
    }
  }

  func toggleManualHolding(id: UUID) async {
    guard canMutateVault() else { return }
    guard let index = document.manualHoldings.firstIndex(where: { $0.id == id }) else { return }
    _ = await mutateDocument { document in
      document.manualHoldings[index].enabled.toggle()
      document.manualHoldings[index].updatedAt = Date()
    }
  }

  func removeManualHolding(id: UUID) async {
    guard canMutateVault() else { return }
    _ = await mutateDocument { $0.manualHoldings.removeAll { $0.id == id } }
  }

  func removeScanRun(id: UUID) async {
    guard canMutateVault() else { return }
    _ = await mutateDocument { $0.scanRuns.removeAll { $0.id == id } }
  }

  func setAutoRefresh(_ enabled: Bool) async {
    guard canMutateVault() else { return }
    _ = await mutateDocument { $0.preferences.autoRefresh = enabled }
  }

  func setHideDust(_ enabled: Bool) async {
    guard canMutateVault() else { return }
    _ = await mutateDocument { $0.preferences.hideDust = enabled }
  }

  func setDustThreshold(_ value: Double) async {
    guard canMutateVault() else { return }
    guard value.isFinite, value >= 0 else {
      error = "Dust threshold must be a finite, non-negative USD value."
      return
    }
    _ = await mutateDocument { $0.preferences.dustThreshold = value }
  }
}
