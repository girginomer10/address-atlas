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
  @Published var syncing = false

  private let crypto = VaultCrypto()
  private let keyStore = KeychainVaultKeyStore()
  private let syncCodec = VaultSyncCodec()
  private let passkeyAuthenticator = PasskeyWebAuthenticator()
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

  func updateWalletLabel(id: UUID, label: String) {
    guard let index = document.wallets.firstIndex(where: { $0.id == id }) else { return }
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    document.wallets[index].label = trimmed
    document.wallets[index].updatedAt = Date()
    save()
  }

  func removeWallet(id: UUID) {
    document.wallets.removeAll { $0.id == id }
    save()
  }

  func addCustomToken(
    chainKind: ChainFamily,
    chainId: String,
    address: String,
    symbol: String,
    name: String,
    decimals: String,
    coinGeckoId: String,
    priceUsd: String
  ) {
    let normalizedAddress = chainKind == .evm ? address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : address.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let parsedDecimals = Int(decimals.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    let parsedPrice = Double(priceUsd.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !normalizedAddress.isEmpty, !normalizedSymbol.isEmpty, !normalizedName.isEmpty, parsedDecimals >= 0, parsedDecimals <= 36 else {
      error = "Token needs address, symbol, name, and decimals between 0 and 36."
      return
    }
    if document.customTokens.contains(where: { $0.chainKind == chainKind && $0.chainId == chainId && $0.address.lowercased() == normalizedAddress.lowercased() }) {
      error = "That token is already in the allowlist."
      return
    }
    document.customTokens.append(
      CustomTokenRecord(
        chainKind: chainKind,
        chainId: chainId,
        address: normalizedAddress,
        symbol: normalizedSymbol,
        name: normalizedName,
        decimals: parsedDecimals,
        coinGeckoId: coinGeckoId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : coinGeckoId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        priceUsd: parsedPrice
      )
    )
    save()
  }

  func toggleCustomToken(id: UUID) {
    guard let index = document.customTokens.firstIndex(where: { $0.id == id }) else { return }
    document.customTokens[index].enabled.toggle()
    document.customTokens[index].updatedAt = Date()
    save()
  }

  func removeCustomToken(id: UUID) {
    document.customTokens.removeAll { $0.id == id }
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

  func toggleManualHolding(id: UUID) {
    guard let index = document.manualHoldings.firstIndex(where: { $0.id == id }) else { return }
    document.manualHoldings[index].enabled.toggle()
    document.manualHoldings[index].updatedAt = Date()
    save()
  }

  func removeManualHolding(id: UUID) {
    document.manualHoldings.removeAll { $0.id == id }
    save()
  }

  func removeScanRun(id: UUID) {
    document.scanRuns.removeAll { $0.id == id }
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

  func removeExchangeConnection(id: UUID) {
    document.exchangeConnections.removeAll { $0.id == id }
    save()
  }

  func saveSyncSettings(serverURL: String, sessionToken: String) {
    document.syncState.serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    document.syncState.sessionToken = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
    save()
  }

  func createPasskeyAccount(serverURL: String) async {
    await authenticateWithPasskey(serverURL: serverURL, mode: .register)
  }

  func signInWithPasskey(serverURL: String) async {
    await authenticateWithPasskey(serverURL: serverURL, mode: .authenticate)
  }

  private func authenticateWithPasskey(serverURL: String, mode: PasskeyWebMode) async {
    guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      error = "Sync server URL is required."
      return
    }
    syncing = true
    defer { syncing = false }
    do {
      let session = try await passkeyAuthenticator.authenticate(serverURL: url, mode: mode)
      document.syncState.accountId = session.userId
      document.syncState.serverURL = session.serverURL
      document.syncState.sessionToken = session.sessionToken
      save()
      notice = mode == .register ? "Passkey account connected." : "Passkey sign-in complete."
      error = ""
    } catch {
      self.error = error.localizedDescription
    }
  }

  func uploadEncryptedVault() async {
    guard let vaultKey else {
      error = "Vault must be unlocked before syncing."
      return
    }
    guard let serverURL = URL(string: document.syncState.serverURL), !document.syncState.sessionToken.isEmpty else {
      error = "Sync server URL and session token are required."
      return
    }
    syncing = true
    defer { syncing = false }
    do {
      let nextVersion = max(1, document.syncState.latestRemoteVersion + 1)
      let snapshot = try syncCodec.seal(document: document, vaultKey: vaultKey, version: nextVersion)
      let client = ZeroKnowledgeSyncClient(baseURL: serverURL)
      await client.setBearerToken(document.syncState.sessionToken)
      try await client.upload(snapshot: snapshot)
      document.syncState.latestRemoteVersion = snapshot.version
      document.syncState.lastSyncedAt = Date()
      document.syncState.lastChecksum = snapshot.checksum
      save()
      notice = "Encrypted vault uploaded."
    } catch {
      self.error = error.localizedDescription
    }
  }

  func downloadEncryptedVault() async {
    guard let vaultKey else {
      error = "Vault must be unlocked before syncing."
      return
    }
    guard let serverURL = URL(string: document.syncState.serverURL), !document.syncState.sessionToken.isEmpty else {
      error = "Sync server URL and session token are required."
      return
    }
    syncing = true
    defer { syncing = false }
    do {
      let client = ZeroKnowledgeSyncClient(baseURL: serverURL)
      await client.setBearerToken(document.syncState.sessionToken)
      guard let snapshot = try await client.latestVault() else {
        notice = "No remote vault snapshot yet."
        return
      }
      var opened = try syncCodec.open(snapshot: snapshot, vaultKey: vaultKey)
      opened.syncState.serverURL = document.syncState.serverURL
      opened.syncState.sessionToken = document.syncState.sessionToken
      opened.syncState.latestRemoteVersion = snapshot.version
      opened.syncState.lastSyncedAt = Date()
      opened.syncState.lastChecksum = snapshot.checksum
      document = opened
      save()
      notice = "Encrypted vault downloaded."
    } catch {
      self.error = error.localizedDescription
    }
  }

  func scanSavedWallets() async {
    guard let vaultKey else {
      error = "Vault must be unlocked before scanning."
      return
    }
    scanning = true
    error = ""
    defer { scanning = false }
    do {
      let input = document.wallets.map(\.address).joined(separator: "\n")
      let scanner = NativeScanner()
      var scan = try await scanner.scan(addresses: input, customTokens: document.customTokens)
      let exchangeScan = await NativeExchangeScanner().scan(
        connections: document.exchangeConnections,
        vaultKey: vaultKey
      )
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
      document.exchangeConnections = exchangeScan.connections
      scan.holdings.append(contentsOf: exchangeScan.holdings)
      scan.holdings.append(contentsOf: manualAssets)
      scan.warnings.append(contentsOf: exchangeScan.warnings)
      scan.totalUsd = scan.holdings.reduce(0) { $0 + $1.valueUsd }
      document.scanRuns.append(scan)
      save()
      notice = exchangeScan.warnings.isEmpty ? "Snapshot saved." : "Snapshot saved with exchange warnings."
    } catch {
      self.error = error.localizedDescription
    }
  }
}
