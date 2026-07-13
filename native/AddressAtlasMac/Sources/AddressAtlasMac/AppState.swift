import AddressAtlasCore
import Foundation
import SwiftUI

protocol EndpointConfigFetching: Sendable {
  func fetch(from serverURL: URL) async throws -> NativeEndpointConfig
}

extension NativeEndpointConfigClient: EndpointConfigFetching {}

@MainActor
final class AppState: ObservableObject {
  @Published var document = VaultDocument()
  @Published var isUnlocked = false
  @Published private(set) var isUnlocking = false
  @Published private(set) var syncPersistencePending = false
  @Published var notice = "" {
    didSet {
      if !notice.isEmpty, !error.isEmpty { error = "" }
    }
  }
  @Published var error = "" {
    didSet {
      if !error.isEmpty, !notice.isEmpty { notice = "" }
    }
  }
  @Published var scanning = false
  @Published var syncing = false
  @Published var endpointConfig = NativeEndpointConfig.bundled
  @Published var endpointConfigStatus = "Bundled endpoints"

  private let crypto = VaultCrypto()
  private let keyStore = KeychainVaultKeyStore()
  private let syncCodec = VaultSyncCodec()
  private let recoveryKit = RecoveryKitCodec()
  private let endpointConfigClient: any EndpointConfigFetching
  private let passkeyAuthenticator = PasskeyWebAuthenticator()
  private lazy var vaultKeyManager = VaultKeyManager(store: keyStore, crypto: crypto)
  private var vaultKey: Data?
  private var store: EncryptedSQLiteVaultStore?
  private var scanTask: Task<Void, Never>?
  private var endpointConfigRefreshGeneration = 0
  private var endpointConfigRefreshRequest: EndpointConfigRefreshRequest?

  private struct EndpointConfigRefreshRequest {
    var generation: Int
    var serverURL: URL
    var task: Task<NativeEndpointConfig, Error>
  }

  private static let maximumStoredScanRuns = 30
  private static let maximumWallets = 24
  private static let maximumCustomTokens = 100
  private static let maximumManualHoldings = 100
  private static let maximumExchangeConnections = 20

  init(endpointConfigClient: any EndpointConfigFetching = NativeEndpointConfigClient()) {
    self.endpointConfigClient = endpointConfigClient
  }

  var latestScan: ScanRunRecord? {
    document.scanRuns.sorted { $0.generatedAt > $1.generatedAt }.first
  }

  var visibleLatestHoldings: [TrackedAsset] {
    let holdings = latestScan?.holdings ?? []
    guard document.preferences.hideDust else { return holdings }
    let threshold = document.preferences.dustThreshold.isFinite
      ? max(0, document.preferences.dustThreshold)
      : 0
    return holdings.filter { $0.valueUsd >= threshold }
  }

  var visibleLatestTotalUsd: Double {
    visibleLatestHoldings.reduce(0) { $0 + $1.valueUsd }
  }

  var hasScanSources: Bool {
    !document.wallets.isEmpty || !document.exchangeConnections.isEmpty || document.manualHoldings.contains(where: \.enabled)
  }

  /// UI controls that change the encrypted document should remain unavailable
  /// while another operation owns the document or a completed sync still needs
  /// to be made durable locally.
  var vaultEditsDisabled: Bool {
    syncing || scanning || syncPersistencePending || isUnlocking
  }

  var hasUnsyncedLocalChanges: Bool {
    (try? syncCodec.hasLocalChanges(in: document)) ?? true
  }

  var appSupportDirectory: URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return root.appending(path: "AddressAtlas")
  }

  var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
  }

  /// False when the server's `minSupportedAppVersion` is newer than this build.
  /// If the bundle version can't be read (e.g. SPM unit tests) we do not block.
  var isAppVersionSupported: Bool {
    guard let minimum = endpointConfig.minSupportedAppVersion, !minimum.isEmpty else { return true }
    let current = appVersion
    guard !current.isEmpty else { return true }
    return AppState.compareVersions(current, minimum) >= 0
  }

  /// Accepts the sync server URL only if it is https (http allowed for loopback
  /// dev hosts). Prevents the bearer token / config / vault traffic from ever
  /// traversing plaintext.
  static func validatedSyncURL(_ raw: String) -> URL? {
    SyncServerURL.validatedOrigin(raw)
  }

  /// Numeric dotted-version comparison: -1 if lhs < rhs, 0 if equal, 1 if greater.
  static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
    let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
    let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
    for index in 0..<max(a.count, b.count) {
      let x = index < a.count ? a[index] : 0
      let y = index < b.count ? b[index] : 0
      if x != y { return x < y ? -1 : 1 }
    }
    return 0
  }

  static func isPricedForDisplay(_ asset: TrackedAsset) -> Bool {
    asset.priceUsd > 0 || asset.valueUsd > 0
  }

  static func derivedManualPrice(amount: Double, valueUsd: Double) -> Double? {
    guard amount.isFinite, amount > 0, valueUsd.isFinite, valueUsd >= 0 else { return nil }
    let price = valueUsd / amount
    return price.isFinite ? price : nil
  }

  static func applyingWalletLabels(
    to holdings: [TrackedAsset],
    wallets: [WalletRecord]
  ) -> [TrackedAsset] {
    var labelsByAddress: [String: String] = [:]
    for wallet in wallets {
      guard let canonical = AddressDetection.canonicalAddress(wallet.address, family: wallet.chainKind) else { continue }
      labelsByAddress["\(wallet.chainKind.rawValue):\(canonical)"] = wallet.label
    }

    var attributed = holdings
    for index in attributed.indices {
      let asset = attributed[index]
      guard let canonical = AddressDetection.canonicalAddress(asset.address, family: asset.family) else { continue }
      if let label = labelsByAddress["\(asset.family.rawValue):\(canonical)"] {
        attributed[index].walletLabel = label
      }
    }
    return attributed
  }

  static func hasDuplicateExchangeAPIKey(
    provider: ExchangeProvider,
    apiKey: String,
    connections: [ExchangeConnectionRecord],
    vaultKey: Data,
    crypto: VaultCrypto = VaultCrypto()
  ) throws -> Bool {
    let candidate = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let credentialVault = ExchangeCredentialVault(crypto: crypto)
    for connection in connections where connection.provider == provider {
      let existing = try credentialVault.open(connection.encryptedCredentials, vaultKey: vaultKey)
      if existing.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) == candidate {
        return true
      }
    }
    return false
  }

  func unlock() async {
    guard !isUnlocked, !isUnlocking else { return }
    isUnlocking = true
    defer { isUnlocking = false }
    do {
      let vaultURL = appSupportDirectory.appending(path: "vault.sqlite")
      let key = try await vaultKeyManager.loadOrCreateVaultKey(existingVaultAt: vaultURL)
      let sqlite = try EncryptedSQLiteVaultStore(path: vaultURL, vaultKey: key, crypto: crypto)
      let loaded = try sqlite.load()
      document = normalizedLoadedDocument(loaded)
      if document != loaded {
        try sqlite.save(document)
      }
      vaultKey = key
      store = sqlite
      isUnlocked = true
      notice = ""
      error = ""
    } catch {
      self.error = error.localizedDescription
      isUnlocked = false
    }
  }

  @discardableResult
  func save() -> Bool {
    guard let store else {
      notice = ""
      error = "Unlock the vault before saving."
      return false
    }
    do {
      try store.save(document)
      syncPersistencePending = false
      notice = "Saved locally."
      error = ""
      return true
    } catch {
      notice = ""
      self.error = error.localizedDescription
      return false
    }
  }

  func retryPendingSyncPersistence() {
    guard syncPersistencePending else { return }
    if save() {
      notice = "Sync state saved locally."
    }
  }

  @discardableResult
  func addWallet(address: String) -> Bool {
    guard canMutateVault() else { return false }
    guard document.wallets.count < Self.maximumWallets else {
      error = "A vault can scan at most \(Self.maximumWallets) saved wallets. Remove one before adding another."
      return false
    }
    let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard AddressDetection.isSafePublicAddress(trimmed), let chain = AddressDetection.detectChains(for: trimmed).first else {
      error = "Enter a supported public wallet address."
      return false
    }
    guard let identity = AddressDetection.canonicalAddress(trimmed, family: chain.family) else {
      error = "Enter a supported public wallet address."
      return false
    }
    if document.wallets.contains(where: {
      $0.chainKind == chain.family && AddressDetection.canonicalAddress($0.address, family: $0.chainKind) == identity
    }) {
      error = "That wallet is already saved."
      return false
    }
    return mutateDocument { document in
      document.wallets.append(
        WalletRecord(label: AddressDetection.defaultWalletLabel(trimmed), address: trimmed, chainKind: chain.family)
      )
    }
  }

  func updateWalletLabel(id: UUID, label: String) {
    guard canMutateVault() else { return }
    guard let index = document.wallets.firstIndex(where: { $0.id == id }) else { return }
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 80 else {
      error = "Wallet labels must be between 1 and 80 characters."
      return
    }
    _ = mutateDocument { document in
      document.wallets[index].label = trimmed
      document.wallets[index].updatedAt = Date()
    }
  }

  func removeWallet(id: UUID) {
    guard canMutateVault() else { return }
    _ = mutateDocument { $0.wallets.removeAll { $0.id == id } }
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
  ) -> Bool {
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
    let parsedPrice = priceInput.isEmpty ? nil : UserInputValidation.nonnegativeFiniteNumber(priceInput)
    let normalizedCoinGeckoId = coinGeckoId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
    guard normalizedCoinGeckoId.isEmpty || (
      normalizedCoinGeckoId.count <= 128
        && normalizedCoinGeckoId.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
    ) else {
      error = "CoinGecko ID may contain lowercase letters, numbers, and hyphens only."
      return false
    }
    // Preserve mixed-case EVM input until after EIP-55 validation; lowercasing
    // first would erase an invalid checksum and turn it into an accepted address.
    guard AddressDetection.isValidCustomTokenAddress(trimmedAddress, family: chainKind) else {
      error = chainKind == .evm ? "Enter a valid 0x token contract address." : "Enter a valid Solana mint address."
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
        && (chainKind == .evm ? $0.address.lowercased() == normalizedAddress.lowercased() : $0.address == normalizedAddress)
    }) {
      error = "That token is already in the allowlist."
      return false
    }
    return mutateDocument { document in
      document.customTokens.append(
        CustomTokenRecord(
          chainKind: chainKind,
          chainId: chainId,
          address: normalizedAddress,
          symbol: normalizedSymbol,
          name: normalizedName,
          decimals: parsedDecimals,
          coinGeckoId: normalizedCoinGeckoId.isEmpty ? nil : normalizedCoinGeckoId,
          priceUsd: parsedPrice
        )
      )
    }
  }

  func toggleCustomToken(id: UUID) {
    guard canMutateVault() else { return }
    guard let index = document.customTokens.firstIndex(where: { $0.id == id }) else { return }
    _ = mutateDocument { document in
      document.customTokens[index].enabled.toggle()
      document.customTokens[index].updatedAt = Date()
    }
  }

  func removeCustomToken(id: UUID) {
    guard canMutateVault() else { return }
    _ = mutateDocument { $0.customTokens.removeAll { $0.id == id } }
  }

  @discardableResult
  func addManualHolding(symbol: String, amount: String, valueUsd: String) -> Bool {
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
    guard let derivedPrice = AppState.derivedManualPrice(amount: parsedAmount, valueUsd: parsedValue) else {
      error = parsedAmount > 0
        ? "Manual holding amount and value produce an unsupported price."
        : "Manual holding amount must be greater than zero."
      return false
    }
    let normalized = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard normalized.count <= 32,
          normalized.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" })
    else {
      error = "Manual holding symbols may use up to 32 letters, numbers, dots, dashes, or underscores."
      return false
    }
    return mutateDocument { document in
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

  func toggleManualHolding(id: UUID) {
    guard canMutateVault() else { return }
    guard let index = document.manualHoldings.firstIndex(where: { $0.id == id }) else { return }
    _ = mutateDocument { document in
      document.manualHoldings[index].enabled.toggle()
      document.manualHoldings[index].updatedAt = Date()
    }
  }

  func removeManualHolding(id: UUID) {
    guard canMutateVault() else { return }
    _ = mutateDocument { $0.manualHoldings.removeAll { $0.id == id } }
  }

  func removeScanRun(id: UUID) {
    guard canMutateVault() else { return }
    _ = mutateDocument { $0.scanRuns.removeAll { $0.id == id } }
  }

  func setAutoRefresh(_ enabled: Bool) {
    guard canMutateVault() else { return }
    _ = mutateDocument { $0.preferences.autoRefresh = enabled }
  }

  func setHideDust(_ enabled: Bool) {
    guard canMutateVault() else { return }
    _ = mutateDocument { $0.preferences.hideDust = enabled }
  }

  func setDustThreshold(_ value: Double) {
    guard canMutateVault() else { return }
    guard value.isFinite, value >= 0 else {
      error = "Dust threshold must be a finite, non-negative USD value."
      return
    }
    _ = mutateDocument { $0.preferences.dustThreshold = value }
  }

  @discardableResult
  func saveExchangeConnection(provider: ExchangeProvider, label: String, credentials: ExchangeCredentials) -> Bool {
    guard canMutateVault() else { return false }
    guard document.exchangeConnections.count < Self.maximumExchangeConnections else {
      error = "A vault can contain at most \(Self.maximumExchangeConnections) exchange connections."
      return false
    }
    guard let vaultKey else {
      error = "Vault must be unlocked before saving exchange credentials."
      return false
    }
    let normalizedCredentials = ExchangeCredentials(
      apiKey: credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
      secret: credentials.secret.trimmingCharacters(in: .whitespacesAndNewlines),
      passphrase: credentials.passphrase?.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    guard !normalizedCredentials.apiKey.isEmpty,
          !normalizedCredentials.secret.isEmpty,
          normalizedCredentials.apiKey.utf8.count <= 4_096,
          normalizedCredentials.secret.utf8.count <= 32_768
    else {
      error = "API key and secret are required and must be within supported size limits."
      return false
    }
    let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalizedLabel.count <= 80 else {
      error = "Exchange labels must be 80 characters or fewer."
      return false
    }
    let connectionId = UUID()
    do {
      let credentialVault = ExchangeCredentialVault(crypto: crypto)
      if try AppState.hasDuplicateExchangeAPIKey(
        provider: provider,
        apiKey: normalizedCredentials.apiKey,
        connections: document.exchangeConnections,
        vaultKey: vaultKey,
        crypto: crypto
      ) {
        error = "That \(provider.label) API key is already saved."
        return false
      }
      let encrypted = try credentialVault.seal(
        normalizedCredentials,
        vaultKey: vaultKey,
        connectionId: connectionId
      )
      return mutateDocument { document in
        document.exchangeConnections.append(
          ExchangeConnectionRecord(
            id: connectionId,
            provider: provider,
            label: normalizedLabel.isEmpty ? provider.label : normalizedLabel,
            encryptedCredentials: encrypted
          )
        )
      }
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  func removeExchangeConnection(id: UUID) {
    guard canMutateVault() else { return }
    _ = mutateDocument { $0.exchangeConnections.removeAll { $0.id == id } }
  }

  @discardableResult
  func saveSyncSettings(serverURL: String) -> Bool {
    guard canMutateVault() else { return false }
    guard !syncPersistencePending else {
      error = "Save the pending sync state locally before changing sync servers."
      return false
    }
    guard let canonicalURL = AppState.validatedSyncURL(serverURL) else {
      error = "Sync server URL must use https (http is allowed only for localhost)."
      return false
    }
    let canonical = canonicalURL.absoluteString
    let serverChanged = document.syncState.serverURL != canonical
    guard mutateDocument({ $0.syncState.changeServer(to: canonical) }) else { return false }
    if serverChanged {
      endpointConfig = .bundled
      endpointConfigStatus = "Bundled endpoints"
    }
    return true
  }

  @discardableResult
  func refreshEndpointConfig(silent: Bool = false) async -> Bool {
    guard let serverURL = AppState.validatedSyncURL(document.syncState.serverURL) else {
      endpointConfigRefreshGeneration &+= 1
      endpointConfigRefreshRequest?.task.cancel()
      endpointConfigRefreshRequest = nil
      endpointConfig = .bundled
      endpointConfigStatus = "Bundled endpoints"
      if !silent {
        notice = "Using bundled endpoints."
      }
      return false
    }

    let request: EndpointConfigRefreshRequest
    if let inFlight = endpointConfigRefreshRequest, inFlight.serverURL == serverURL {
      request = inFlight
    } else {
      endpointConfigRefreshGeneration &+= 1
      endpointConfigRefreshRequest?.task.cancel()
      let generation = endpointConfigRefreshGeneration
      let client = endpointConfigClient
      request = EndpointConfigRefreshRequest(
        generation: generation,
        serverURL: serverURL,
        task: Task { try await client.fetch(from: serverURL) }
      )
      endpointConfigRefreshRequest = request
    }
    defer {
      if endpointConfigRefreshRequest?.generation == request.generation {
        endpointConfigRefreshRequest = nil
      }
    }

    do {
      let config = try await request.task.value
      guard request.generation == endpointConfigRefreshGeneration,
            AppState.validatedSyncURL(document.syncState.serverURL) == serverURL
      else { return false }
      endpointConfig = config
      if !isAppVersionSupported {
        endpointConfigStatus = "Update required"
        if !silent {
          self.error = "This app version is no longer supported. Update Address Atlas to keep syncing."
        }
      } else {
        endpointConfigStatus = "Remote v\(config.configVersion)"
        if !silent {
          notice = "Endpoint config refreshed."
        }
      }
      return true
    } catch {
      guard request.generation == endpointConfigRefreshGeneration,
            AppState.validatedSyncURL(document.syncState.serverURL) == serverURL
      else { return false }
      endpointConfig = .bundled
      endpointConfigStatus = "Bundled endpoints (remote unavailable)"
      if !silent {
        self.error = error.localizedDescription
      }
      return false
    }
  }

  /// Keep compatibility policy and credential-free scanner endpoints fresh
  /// even when the user is not actively scanning or syncing. The SwiftUI task
  /// that owns this loop is restarted whenever the configured server changes.
  func runEndpointConfigRefreshLoop() async {
    guard isUnlocked else { return }
    while !Task.isCancelled,
          isUnlocked,
          AppState.validatedSyncURL(document.syncState.serverURL) != nil {
      // Scan and sync flows already perform a fail-closed refresh before using
      // remote policy, so avoid starting another request while they are active.
      if !scanning, !syncing {
        _ = await refreshEndpointConfig(silent: true)
      }

      let refreshSeconds = min(
        max(endpointConfig.refreshAfterSeconds, NativeEndpointConfig.minimumRefreshAfterSeconds),
        NativeEndpointConfig.maximumRefreshAfterSeconds
      )
      do {
        try await Task.sleep(for: .seconds(refreshSeconds))
      } catch {
        return
      }
    }
  }

  func createPasskeyAccount(serverURL: String) async {
    await authenticateWithPasskey(serverURL: serverURL, mode: .register)
  }

  func signInWithPasskey(serverURL: String) async {
    await authenticateWithPasskey(serverURL: serverURL, mode: .authenticate)
  }

  private func authenticateWithPasskey(serverURL: String, mode: PasskeyWebMode) async {
    guard !scanning else {
      error = "Cancel or finish the active scan before changing sync accounts."
      return
    }
    guard let url = AppState.validatedSyncURL(serverURL) else {
      error = "Sync server URL must use https (http is allowed only for localhost)."
      return
    }
    guard !syncPersistencePending else {
      error = "Save the pending sync state locally before changing sync accounts."
      return
    }
    guard !syncing else {
      notice = "A sync operation is already running."
      return
    }
    syncing = true
    defer { syncing = false }
    do {
      let session = try await passkeyAuthenticator.authenticate(serverURL: url, mode: mode)
      let previousDocument = document
      document.syncState.connect(
        accountId: session.userId,
        serverURL: session.serverURL,
        sessionToken: session.sessionToken
      )
      guard save() else {
        document = previousDocument
        return
      }
      await refreshEndpointConfig(silent: true)
      notice = mode == .register ? "Passkey account connected." : "Passkey sign-in complete."
      error = ""
    } catch {
      self.error = error.localizedDescription
    }
  }

  func uploadEncryptedVault() async {
    guard !scanning else {
      error = "Cancel or finish the active scan before syncing."
      return
    }
    guard let vaultKey else {
      error = "Vault must be unlocked before syncing."
      return
    }
    guard let serverURL = AppState.validatedSyncURL(document.syncState.serverURL), !document.syncState.sessionToken.isEmpty else {
      error = "Sign in with passkey before syncing."
      return
    }
    guard let accountId = document.syncState.accountId, !accountId.isEmpty else {
      error = "Sync account identity is missing. Sign in with passkey again."
      return
    }
    guard !syncPersistencePending else {
      error = "Save the pending sync state locally before starting another sync operation."
      return
    }
    guard !syncing else {
      notice = "A sync operation is already running."
      return
    }
    syncing = true
    defer { syncing = false }
    do {
      guard await refreshEndpointConfig(silent: true) else {
        throw SyncClientError.requestFailed(503, "The sync server's compatibility policy could not be verified. Try again when endpoint config is available.")
      }
      guard isAppVersionSupported else {
        throw SyncClientError.requestFailed(426, "This app version is no longer supported. Update Address Atlas to keep syncing.")
      }
      let client = ZeroKnowledgeSyncClient(baseURL: serverURL)
      await client.setBearerToken(document.syncState.sessionToken)
      var uploadDocument = document
      if let remote = try await client.latestVault() {
        guard
          let lastChecksum = uploadDocument.syncState.lastChecksum,
          !lastChecksum.isEmpty,
          remote.checksum == lastChecksum
        else {
          throw SyncClientError.requestFailed(
            409,
            "Remote vault snapshot is newer. Download before uploading again."
          )
        }
        uploadDocument.syncState.latestRemoteVersion = max(uploadDocument.syncState.latestRemoteVersion, remote.version)
      }
      let nextVersion = max(1, uploadDocument.syncState.latestRemoteVersion + 1)
      let sealedContentChecksum = try syncCodec.contentChecksum(for: uploadDocument)
      let snapshot = try syncCodec.seal(
        document: uploadDocument,
        vaultKey: vaultKey,
        version: nextVersion,
        accountId: accountId
      )
      try await client.upload(snapshot: snapshot)
      uploadDocument.syncState.markSynced(
        version: snapshot.version,
        snapshotChecksum: snapshot.checksum,
        contentChecksum: sealedContentChecksum
      )
      document = uploadDocument
      guard save() else {
        let persistenceError = self.error
        syncPersistencePending = true
        self.error = "The remote vault was uploaded, but its sync state is pending local persistence. Keep the app open and use Retry local save after fixing storage: \(persistenceError)"
        return
      }
      notice = "Encrypted vault uploaded."
    } catch {
      handleSyncError(error)
    }
  }

  func downloadEncryptedVault(discardingLocalChanges: Bool = false) async {
    guard !scanning else {
      error = "Cancel or finish the active scan before syncing."
      return
    }
    guard let vaultKey else {
      error = "Vault must be unlocked before syncing."
      return
    }
    guard let serverURL = AppState.validatedSyncURL(document.syncState.serverURL), !document.syncState.sessionToken.isEmpty else {
      error = "Sign in with passkey before syncing."
      return
    }
    guard let accountId = document.syncState.accountId, !accountId.isEmpty else {
      error = "Sync account identity is missing. Sign in with passkey again."
      return
    }
    guard !syncPersistencePending else {
      error = "Save the pending sync state locally before starting another sync operation."
      return
    }
    guard !syncing else {
      notice = "A sync operation is already running."
      return
    }
    syncing = true
    defer { syncing = false }
    do {
      guard await refreshEndpointConfig(silent: true) else {
        throw SyncClientError.requestFailed(503, "The sync server's compatibility policy could not be verified. Try again when endpoint config is available.")
      }
      guard isAppVersionSupported else {
        throw SyncClientError.requestFailed(426, "This app version is no longer supported. Update Address Atlas to keep syncing.")
      }
      let startingContentChecksum = try syncCodec.contentChecksum(for: document)
      if try syncCodec.hasLocalChanges(in: document), !discardingLocalChanges {
        error = "Local changes have not been uploaded. Upload them first, or explicitly discard them before downloading."
        return
      }
      let client = ZeroKnowledgeSyncClient(baseURL: serverURL)
      await client.setBearerToken(document.syncState.sessionToken)
      guard let snapshot = try await client.latestVault() else {
        notice = "No remote vault snapshot yet."
        return
      }
      // Refuse a server snapshot older than the last version we synced: the
      // content is end-to-end encrypted (the server can't forge it), but it
      // could replay a stale-but-authentic snapshot to roll back local data.
      guard snapshot.version >= document.syncState.latestRemoteVersion else {
        error = "Remote vault is older than your last sync (possible rollback). Download aborted."
        return
      }
      if snapshot.version == document.syncState.latestRemoteVersion,
         let lastChecksum = document.syncState.lastChecksum,
         snapshot.checksum != lastChecksum {
        error = "Remote vault changed without advancing its version. Download aborted."
        return
      }
      guard try syncCodec.contentChecksum(for: document) == startingContentChecksum else {
        error = "Local vault changed while downloading. Nothing was replaced; try again."
        return
      }
      let result = try syncCodec.open(
        snapshot: snapshot,
        vaultKey: vaultKey,
        expectedAccountId: accountId
      )
      var opened = normalizedLoadedDocument(result.document)
      opened.syncState.connect(
        accountId: accountId,
        serverURL: document.syncState.serverURL,
        sessionToken: document.syncState.sessionToken
      )
      try syncCodec.markSynced(document: &opened, snapshot: snapshot)

      if result.requiresV2Upgrade {
        do {
          let upgraded = try syncCodec.seal(
            document: opened,
            vaultKey: vaultKey,
            version: snapshot.version + 1,
            accountId: accountId
          )
          try await client.upload(snapshot: upgraded)
          try syncCodec.markSynced(document: &opened, snapshot: upgraded)
        } catch {
          document = opened
          guard save() else {
            syncPersistencePending = true
            throw SyncClientError.requestFailed(
              500,
              "The legacy vault downloaded, but its local persistence is pending before the v2 upgrade can be retried."
            )
          }
          throw error
        }
      }
      document = opened
      guard save() else {
        let persistenceError = self.error
        syncPersistencePending = true
        self.error = "The remote vault was opened, but its local persistence is pending. Keep the app open and use Retry local save after fixing storage: \(persistenceError)"
        return
      }
      notice = result.requiresV2Upgrade
        ? "Encrypted vault downloaded and upgraded to protected sync format v2."
        : "Encrypted vault downloaded."
    } catch {
      handleSyncError(error)
    }
  }

  func exportRecoveryKit(to url: URL) throws -> String {
    guard let vaultKey else {
      throw RecoveryKitError.invalidVaultKey
    }
    let output = try recoveryKit.create(vaultKey: vaultKey)
    let data = try JSONEncoder.addressAtlas.encode(output.document)
    try data.write(to: url, options: [.atomic])
    notice = "Recovery kit saved. Store the code separately."
    error = ""
    return output.recoveryCode
  }

  func restoreRecoveryKit(from url: URL, recoveryCode: String) async {
    if isUnlocked, !canMutateVault() { return }
    guard !isUnlocking else {
      notice = "A vault unlock or recovery is already running."
      return
    }
    isUnlocking = true
    defer { isUnlocking = false }
    do {
      let recovered = try VaultRecoveryService(codec: recoveryKit, crypto: crypto).restore(
        from: url,
        recoveryCode: recoveryCode,
        vaultURL: appSupportDirectory.appending(path: "vault.sqlite"),
        keyStore: keyStore
      )
      document = normalizedLoadedDocument(recovered.document)
      if document != recovered.document {
        try recovered.store.save(document)
      }
      vaultKey = recovered.vaultKey
      store = recovered.store
      isUnlocked = true
      syncPersistencePending = false
      notice = "Recovery kit restored."
      error = ""
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func handleSyncError(_ error: Error) {
    if case SyncClientError.authenticationRequired = error {
      document.syncState.sessionToken = ""
      do {
        guard let store else {
          syncPersistencePending = true
          self.error = "Sync session expired, but the cleared session is pending local persistence. Unlock the vault and retry the local save."
          return
        }
        try store.save(document)
      } catch {
        syncPersistencePending = true
        self.error = "Sync session expired, but the cleared session is pending local persistence. Use Retry local save after fixing storage: \(error.localizedDescription)"
        return
      }
      self.error = "Sync session expired. Sign in with passkey again."
      return
    }
    self.error = error.localizedDescription
  }

  func startScan() {
    guard !syncing else {
      error = "Wait for the active sync operation before scanning."
      return
    }
    guard !syncPersistencePending else {
      error = "Save the pending sync state locally before scanning."
      return
    }
    guard scanTask == nil, !scanning else {
      notice = "A scan is already running."
      return
    }
    scanTask = Task { [weak self] in
      guard let self else { return }
      await self.scanSavedWallets()
      self.scanTask = nil
    }
  }

  func cancelScan() {
    scanTask?.cancel()
  }

  func scanSavedWallets() async {
    guard let vaultKey else {
      error = "Vault must be unlocked before scanning."
      return
    }
    guard !scanning else {
      notice = "A scan is already running."
      return
    }
    guard !syncing else {
      error = "Wait for the active sync operation before scanning."
      return
    }
    guard !syncPersistencePending else {
      error = "Save the pending sync state locally before scanning."
      return
    }
    scanning = true
    error = ""
    defer { scanning = false }
    do {
      await refreshEndpointConfig(silent: true)
      try Task.checkCancellation()
      let input = document.wallets.map(\.address).joined(separator: "\n")
      let scanner = NativeScanner(endpointConfig: endpointConfig)
      var scan = try await scanner.scan(addresses: input, customTokens: document.customTokens)
      try Task.checkCancellation()
      scan.holdings = AppState.applyingWalletLabels(to: scan.holdings, wallets: document.wallets)
      let exchangeClient = NativeExchangeBalanceClient(endpointConfig: endpointConfig)
      let exchangeScan = try await NativeExchangeScanner(
        client: exchangeClient,
        priceProvider: CoinGeckoPriceClient(baseURL: endpointConfig.priceBaseURL)
      ).scanThrowing(
        connections: document.exchangeConnections,
        vaultKey: vaultKey
      )
      try Task.checkCancellation()
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
      scan.holdings.append(contentsOf: exchangeScan.holdings)
      scan.holdings.append(contentsOf: manualAssets)
      scan.warnings.append(contentsOf: exchangeScan.warnings)
      let holdingCountBeforeValidation = scan.holdings.count
      scan.holdings = scan.holdings.filter {
        $0.amount.isFinite && $0.amount >= 0 && $0.priceUsd.isFinite && $0.priceUsd >= 0 && $0.valueUsd.isFinite && $0.valueUsd >= 0
      }
      let invalidHoldingCount = holdingCountBeforeValidation - scan.holdings.count
      if invalidHoldingCount > 0 {
        scan.warnings.append("Ignored \(invalidHoldingCount) invalid holding value\(invalidHoldingCount == 1 ? "" : "s").")
      }
      scan.totalUsd = scan.holdings.reduce(0) { $0 + $1.valueUsd }
      try Task.checkCancellation()
      if mutateDocument({ document in
        document.exchangeConnections = exchangeScan.connections
        document.scanRuns.append(scan)
        document.scanRuns = Array(
          document.scanRuns.sorted { $0.generatedAt > $1.generatedAt }.prefix(Self.maximumStoredScanRuns)
        )
      }) {
        notice = scan.warnings.isEmpty
          ? "Snapshot saved."
          : "Snapshot saved with \(scan.warnings.count) warning\(scan.warnings.count == 1 ? "" : "s")."
      }
    } catch is CancellationError {
      notice = "Scan cancelled."
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func normalizedLoadedDocument(_ input: VaultDocument) -> VaultDocument {
    var output = input
    output.schemaVersion = VaultDocument.currentSchemaVersion
    output.preferences.currency = "USD"
    output.scanRuns = Array(output.scanRuns.sorted { $0.generatedAt > $1.generatedAt }.prefix(Self.maximumStoredScanRuns))
    if let canonicalServer = AppState.validatedSyncURL(output.syncState.serverURL) {
      // Equivalent origin spellings must not clear a valid session/baseline.
      output.syncState.serverURL = canonicalServer.absoluteString
    } else if !output.syncState.serverURL.isEmpty {
      // Invalid persisted endpoints must not retain bearer credentials.
      output.syncState.changeServer(to: "")
    }
    return output
  }

  @discardableResult
  private func mutateDocument(_ mutation: (inout VaultDocument) -> Void) -> Bool {
    let previous = document
    mutation(&document)
    guard save() else {
      document = previous
      return false
    }
    return true
  }

  private func canMutateVault() -> Bool {
    guard !syncing else {
      error = "Wait for the active sync operation before editing the vault."
      return false
    }
    guard !scanning else {
      error = "Cancel or finish the active scan before editing the vault."
      return false
    }
    guard !syncPersistencePending else {
      error = "Save the pending sync state locally before editing the vault."
      return false
    }
    guard !isUnlocking else {
      error = "Wait for vault recovery to finish before editing the vault."
      return false
    }
    return true
  }

}
