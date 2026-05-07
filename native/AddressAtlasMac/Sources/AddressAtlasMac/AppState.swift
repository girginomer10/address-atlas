import AddressAtlasCore
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
  @Published var document = VaultDocument()
  @Published var isUnlocked = false
  @Published var notice = ""
  @Published var error = ""
  @Published var scanning = false

  private let crypto = VaultCrypto()
  private let keyStore = KeychainVaultKeyStore()
  private var vaultKey: Data?
  private var store: EncryptedSQLiteVaultStore?

  var latestScan: ScanRunRecord? {
    document.scanRuns.sorted { $0.generatedAt > $1.generatedAt }.first
  }

  var appSupportDirectory: URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return root.appending(path: "AddressAtlas")
  }

  func unlock() async {
    do {
      let manager = VaultKeyManager(store: keyStore, crypto: crypto)
      let key = try await manager.loadOrCreateVaultKey()
      let sqlite = try EncryptedSQLiteVaultStore(path: appSupportDirectory.appending(path: "vault.sqlite"), vaultKey: key, crypto: crypto)
      document = try sqlite.load()
      vaultKey = key
      store = sqlite
      isUnlocked = true
      notice = "Vault unlocked from macOS Keychain."
      error = ""
    } catch {
      self.error = error.localizedDescription
      isUnlocked = false
    }
  }

  func save() {
    guard let store else { return }
    do {
      try store.save(document)
      notice = "Saved locally."
    } catch {
      self.error = error.localizedDescription
    }
  }

  func addWallet(address: String) {
    let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard AddressDetection.isSafePublicAddress(trimmed), let chain = AddressDetection.detectChains(for: trimmed).first else {
      error = "Enter a supported public wallet address."
      return
    }
    if document.wallets.contains(where: { $0.address.lowercased() == trimmed.lowercased() }) {
      error = "That wallet is already saved."
      return
    }
    document.wallets.append(WalletRecord(label: AddressDetection.defaultWalletLabel(trimmed), address: trimmed, chainKind: chain.family))
    save()
  }

  func addManualHolding(symbol: String, amount: String, valueUsd: String) {
    let parsedAmount = Double(amount) ?? 0
    let parsedValue = Double(valueUsd) ?? 0
    guard !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, parsedAmount >= 0, parsedValue >= 0 else {
      error = "Manual holding needs a symbol, amount, and value."
      return
    }
    let normalized = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    document.manualHoldings.append(
      ManualHoldingRecord(
        label: "Manual",
        provider: "custom",
        customVenue: "Manual",
        symbol: normalized,
        name: normalized,
        amount: parsedAmount,
        priceUsd: parsedAmount > 0 ? parsedValue / parsedAmount : nil,
        valueUsd: parsedValue
      )
    )
    save()
  }

  func saveExchangeConnection(provider: ExchangeProvider, label: String, credentials: ExchangeCredentials) {
    guard let vaultKey else {
      error = "Vault must be unlocked before saving exchange credentials."
      return
    }
    let connectionId = UUID()
    do {
      let encrypted = try ExchangeCredentialVault(crypto: crypto).seal(
        credentials,
        vaultKey: vaultKey,
        connectionId: connectionId
      )
      document.exchangeConnections.append(
        ExchangeConnectionRecord(
          id: connectionId,
          provider: provider,
          label: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? provider.label : label,
          encryptedCredentials: encrypted
        )
      )
      save()
    } catch {
      self.error = error.localizedDescription
    }
  }

  func scanSavedWallets() async {
    scanning = true
    error = ""
    defer { scanning = false }
    do {
      let input = document.wallets.map(\.address).joined(separator: "\n")
      let scanner = NativeScanner()
      var scan = try await scanner.scan(addresses: input, customTokens: document.customTokens)
      let manualAssets = document.manualHoldings.filter(\.enabled).map { holding in
        TrackedAsset(
          id: "manual-\(holding.id.uuidString)",
          address: holding.label,
          chainId: "manual-\(holding.provider)",
          chainName: holding.customVenue ?? holding.provider,
          family: .exchange,
          symbol: holding.symbol,
          name: holding.name,
          amount: holding.amount,
          priceUsd: holding.priceUsd ?? 0,
          valueUsd: holding.valueUsd,
          source: .exchange
        )
      }
      scan.holdings.append(contentsOf: manualAssets)
      scan.totalUsd = scan.holdings.reduce(0) { $0 + $1.valueUsd }
      document.scanRuns.append(scan)
      save()
      notice = "Snapshot saved."
    } catch {
      self.error = error.localizedDescription
    }
  }
}
