import AddressAtlasCore
import Foundation
import SwiftUI

protocol EndpointConfigFetching: Sendable {
  func fetch(from serverURL: URL) async throws -> NativeEndpointConfig
}

extension NativeEndpointConfigClient: EndpointConfigFetching {}

@MainActor
final class AppState: ObservableObject {
  @Published var document = VaultDocument() {
    didSet {
      documentRevision &+= 1
      // Never risk a false-clean UI after a future call site mutates the value
      // directly. A successful actor save replaces this conservative value
      // with the checksum-backed result.
      hasUnsyncedLocalChanges = true
    }
  }
  @Published var isUnlocked = false
  @Published var isUnlocking = false
  @Published private(set) var isPersisting = false
  @Published var isValidatingExchangeCredentials = false
  @Published var syncPersistencePending = false
  @Published var hasUnsyncedLocalChanges = true
  private(set) var lastSaveRemovedScanRunCount = 0
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
  @Published var endpointConfig = NativeEndpointConfig.bundled {
    didSet {
      operatorMessage = AppState.normalizedOperatorMessage(endpointConfig.message)
    }
  }
  @Published var endpointConfigStatus = "Bundled endpoints"
  /// Operator broadcast carried by the currently applied endpoint config.
  /// Nil whenever the server supplied no message or only whitespace.
  @Published private(set) var operatorMessage: String?

  let crypto = VaultCrypto()
  let keyStore = KeychainVaultKeyStore()
  let syncCodec = VaultSyncCodec()
  let syncSnapshotByteLimit: Int
  let recoveryKit = RecoveryKitCodec()
  let endpointConfigClient: any EndpointConfigFetching
  let endpointConfigTrustStore: any EndpointConfigTrustPersisting
  let krakenDeviceIdentifier: @Sendable () throws -> String
  /// Test seam for the network boundary only. Nil keeps each production
  /// client's own BoundedURLSessionHTTPClient defaults.
  let httpClient: (any HTTPClient)?
  let passkeyAuthenticator: any PasskeyAuthenticating
  private lazy var vaultKeyManager = VaultKeyManager(store: keyStore, crypto: crypto)
  var vaultKey: Data?
  var persistence: VaultPersistenceCoordinator?
  /// Exact local state that still has to become durable after a remote side
  /// effect has already committed. Keeping only a Boolean is unsafe: upload
  /// and download assemble their authoritative result in a local candidate,
  /// so retrying the previously published document can persist stale state.
  var pendingSyncPersistence: PendingSyncPersistence?
  /// Monotonic in-memory revision checked across every actor hop. UI mutations
  /// are disabled while persistence owns a candidate, but this is an
  /// independent fail-closed guard against future re-entrant call sites.
  var documentRevision: UInt64 = 0
  var scanTask: Task<Void, Never>?
  var endpointConfigRefreshGeneration = 0
  var endpointConfigRefreshRequest: EndpointConfigRefreshRequest?
  /// The origin that supplied the currently accepted remote configuration.
  /// Versions are monotonic only within one authority; changing servers resets
  /// this state to the bundled baseline.
  var acceptedEndpointConfigServerURL: URL?

  struct EndpointConfigRefreshRequest {
    var generation: Int
    var serverURL: URL
    var task: Task<NativeEndpointConfig, Error>
  }

  struct PendingSyncPersistence {
    var document: VaultDocument
    var projectedSyncVersion: Int?
    var saveExactly: Bool
  }

  static let maximumStoredScanRuns = 30
  static let maximumWallets = 24
  static let maximumCustomTokens = 100
  static let maximumManualHoldings = 100
  static let maximumExchangeConnections = 20
  /// The app-bundle script reads this value when generating Info.plist.
  /// SwiftPM's `swift run` executable has no Info.plist, so it also needs the
  /// compiled release version for the server compatibility check.
  static let currentAppVersion = "0.2.0"
  /// Hard-pinned, HTTPS update route. Compatibility policy is remote, but the
  /// destination that can replace executable code is not remotely mutable.
  static let updateDownloadURL = URL(
    string: "https://github.com/girginomer10/address-atlas/releases/latest"
  )!

  init(
    endpointConfigClient: any EndpointConfigFetching = NativeEndpointConfigClient(),
    endpointConfigTrustStore: any EndpointConfigTrustPersisting =
      EphemeralEndpointConfigTrustStore(),
    httpClient: (any HTTPClient)? = nil,
    passkeyAuthenticator: (any PasskeyAuthenticating)? = nil,
    krakenDeviceIdentifier: @escaping @Sendable () throws -> String = {
      try KrakenDeviceIdentity.currentIdentifier()
    }
  ) {
    self.endpointConfigClient = endpointConfigClient
    self.endpointConfigTrustStore = endpointConfigTrustStore
    self.httpClient = httpClient
    self.passkeyAuthenticator = passkeyAuthenticator ?? PasskeyWebAuthenticator()
    self.krakenDeviceIdentifier = krakenDeviceIdentifier
    syncSnapshotByteLimit = VaultSyncCodec.maximumSnapshotByteCount
  }

  /// Installs an already-loaded store for persistence behavior tests without
  /// involving Keychain or the user's Application Support directory.
  init(
    testStore: EncryptedSQLiteVaultStore,
    document: VaultDocument,
    testVaultKey: Data? = nil,
    syncSnapshotByteLimit: Int = VaultSyncCodec.maximumSnapshotByteCount,
    endpointConfigClient: any EndpointConfigFetching = NativeEndpointConfigClient(),
    endpointConfigTrustStore: any EndpointConfigTrustPersisting =
      EphemeralEndpointConfigTrustStore(),
    httpClient: (any HTTPClient)? = nil,
    passkeyAuthenticator: (any PasskeyAuthenticating)? = nil,
    krakenDeviceIdentifier: @escaping @Sendable () throws -> String = {
      try KrakenDeviceIdentity.currentIdentifier()
    }
  ) {
    precondition((1...VaultSyncCodec.maximumSnapshotByteCount).contains(syncSnapshotByteLimit))
    self.endpointConfigClient = endpointConfigClient
    self.endpointConfigTrustStore = endpointConfigTrustStore
    self.httpClient = httpClient
    self.passkeyAuthenticator = passkeyAuthenticator ?? PasskeyWebAuthenticator()
    self.krakenDeviceIdentifier = krakenDeviceIdentifier
    self.syncSnapshotByteLimit = syncSnapshotByteLimit
    self.persistence = VaultPersistenceCoordinator(
      store: testStore,
      syncSnapshotByteLimit: syncSnapshotByteLimit
    )
    self.vaultKey = testVaultKey
    self.document = document
    self.hasUnsyncedLocalChanges = (try? VaultSyncCodec().hasLocalChanges(in: document)) ?? true
    self.isUnlocked = true
  }

  var latestScan: ScanRunRecord? {
    document.scanRuns.sorted { $0.generatedAt > $1.generatedAt }.first
  }

  var visibleLatestHoldings: [TrackedAsset] {
    let holdings = latestScan?.holdings ?? []
    guard document.preferences.hideDust else { return holdings }
    let threshold =
      document.preferences.dustThreshold.isFinite
      ? max(0, document.preferences.dustThreshold)
      : 0
    return holdings.filter { $0.valueUsd >= threshold }
  }

  var visibleLatestTotalUsd: Double {
    AppState.validatedPortfolioTotal(visibleLatestHoldings) ?? 0
  }

  var hasScanSources: Bool {
    !document.wallets.isEmpty || !document.exchangeConnections.isEmpty
      || document.manualHoldings.contains(where: \.enabled)
  }

  /// UI controls that change the encrypted document should remain unavailable
  /// while another operation owns the document or a completed sync still needs
  /// to be made durable locally.
  var vaultEditsDisabled: Bool {
    syncing || scanning || isPersisting || isValidatingExchangeCredentials
      || syncPersistencePending || isUnlocking || hasPendingAccountDeletion
  }

  var hasPendingAccountDeletion: Bool {
    AccountDeletionIdempotencyKey.normalized(
      document.syncState.accountDeletionIdempotencyKey
    ) != nil
  }

  var accountDeletionControlDisabled: Bool {
    syncing || scanning || isPersisting || isValidatingExchangeCredentials
      || syncPersistencePending || isUnlocking || document.syncState.accountId == nil
  }

  var appSupportDirectory: URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
    return root.appending(path: "AddressAtlas")
  }

  static func productionEndpointConfigTrustStore() -> any EndpointConfigTrustPersisting {
    EndpointConfigTrustStore(
      fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "AddressAtlas/endpoint-config-trust.json")
    )
  }

  /// Page-level notices and errors should not follow the user into an unrelated
  /// section after navigation.
  func clearTransientMessagesForNavigation() {
    notice = ""
    error = ""
  }

  func presentUserFacingError(
    _ failure: Error,
    cancellationNotice: String = "Operation cancelled."
  ) {
    if let message = UserFacingErrorMapper.message(for: failure) {
      error = message
    } else {
      error = ""
      notice = cancellationNotice
    }
  }

  var appVersion: String {
    AppState.resolvedAppVersion(
      Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    )
  }

  var safeUpdateDownloadURL: URL { Self.updateDownloadURL }

  /// False when the server's `minSupportedAppVersion` is newer than this build.
  /// A present but malformed policy or app version fails closed.
  var isAppVersionSupported: Bool {
    AppState.supportsAppVersion(appVersion, minimum: endpointConfig.minSupportedAppVersion)
  }
  func acceptedEndpointStatus(_ detail: String) -> String {
    isAppVersionSupported ? detail : "Update required (\(detail))"
  }

  func unlock() async {
    guard !isUnlocked, !isUnlocking else { return }
    isUnlocking = true
    defer { isUnlocking = false }
    do {
      let vaultURL = appSupportDirectory.appending(path: "vault.sqlite")
      let key = try await vaultKeyManager.loadOrCreateVaultKey(existingVaultAt: vaultURL)
      let sqlite = try EncryptedSQLiteVaultStore(path: vaultURL, vaultKey: key, crypto: crypto)
      let coordinator = VaultPersistenceCoordinator(
        store: sqlite,
        syncSnapshotByteLimit: syncSnapshotByteLimit
      )
      let loaded = try await coordinator.load()
      let normalized = normalizedLoadedDocument(loaded.document)
      let durable =
        normalized == loaded.document
        ? loaded
        : try await coordinator.saveExactly(normalized)
      document = durable.document
      hasUnsyncedLocalChanges = durable.hasLocalChanges
      vaultKey = key
      persistence = coordinator
      documentRevision &+= 1
      isUnlocked = true
      pendingSyncPersistence = nil
      syncPersistencePending = false
      notice = ""
      error = ""
    } catch {
      presentUserFacingError(error)
      isUnlocked = false
    }
  }

  @discardableResult
  func save() async -> Bool {
    await save(document, projectedSyncVersion: nil)
  }

  @discardableResult
  func save(
    _ candidate: VaultDocument,
    projectedSyncVersion: Int?,
    saveExactly: Bool = false,
    resolvesPendingSyncPersistence: Bool = false
  ) async -> Bool {
    lastSaveRemovedScanRunCount = 0
    guard let persistence else {
      notice = ""
      error = "Unlock the vault before saving."
      return false
    }
    guard !isPersisting else {
      error = "Wait for the current local save to finish."
      return false
    }
    let startingRevision = documentRevision
    isPersisting = true
    defer { isPersisting = false }
    do {
      let result: VaultPersistenceResult
      if saveExactly {
        result = try await persistence.saveExactly(candidate)
      } else {
        result = try await persistence.save(
          candidate,
          projectedSyncVersion: projectedSyncVersion
        )
      }
      guard startingRevision == documentRevision else {
        syncPersistencePending = true
        error =
          "The vault changed while a local save was finishing. Reopen Address Atlas before making more changes."
        return false
      }
      document = result.document
      documentRevision &+= 1
      hasUnsyncedLocalChanges = result.hasLocalChanges
      lastSaveRemovedScanRunCount = result.removedScanRunCount
      if resolvesPendingSyncPersistence {
        pendingSyncPersistence = nil
        syncPersistencePending = false
      } else if pendingSyncPersistence == nil {
        syncPersistencePending = false
      }
      notice = "Saved locally." + pruningNoticeSuffix(result.removedScanRunCount)
      error = ""
      return true
    } catch {
      notice = ""
      presentUserFacingError(error)
      return false
    }
  }

  func retryPendingSyncPersistence() async {
    guard syncPersistencePending else { return }
    guard let pendingSyncPersistence else {
      error =
        "The pending local sync state cannot be retried safely. Reopen Address Atlas before making more changes."
      return
    }
    if await save(
      pendingSyncPersistence.document,
      projectedSyncVersion: pendingSyncPersistence.projectedSyncVersion,
      saveExactly: pendingSyncPersistence.saveExactly,
      resolvesPendingSyncPersistence: true
    ) {
      notice = "Sync state saved locally." + pruningNoticeSuffix(lastSaveRemovedScanRunCount)
    }
  }

  /// Publish and retain the exact post-remote candidate while blocking every
  /// other vault mutation until that candidate is durable.
  func requirePendingSyncPersistence(
    _ candidate: VaultDocument,
    projectedSyncVersion: Int?,
    saveExactly: Bool = false
  ) {
    document = candidate
    pendingSyncPersistence = PendingSyncPersistence(
      document: candidate,
      projectedSyncVersion: projectedSyncVersion,
      saveExactly: saveExactly
    )
    syncPersistencePending = true
  }

  func pruningNoticeSuffix(_ removedScanRunCount: Int) -> String {
    guard removedScanRunCount > 0 else { return "" }
    return
      " Removed \(removedScanRunCount) oldest scan snapshot\(removedScanRunCount == 1 ? "" : "s") to stay within the sync size limit."
  }

  func normalizedLoadedDocument(_ input: VaultDocument) -> VaultDocument {
    var output = input
    output.schemaVersion = VaultDocument.currentSchemaVersion
    output.preferences.currency = "USD"
    output.customTokens = AppState.repairLegacyCoinGeckoIDs(in: output.customTokens)
    output.scanRuns = Array(
      output.scanRuns.sorted { $0.generatedAt > $1.generatedAt }.prefix(Self.maximumStoredScanRuns))
    if let canonicalServer = AppState.validatedSyncURL(output.syncState.serverURL) {
      // Equivalent origin spellings must not clear a valid session/baseline.
      output.syncState.serverURL = canonicalServer.absoluteString
    } else if !output.syncState.serverURL.isEmpty {
      // Invalid persisted endpoints must not retain bearer credentials.
      output.syncState.changeServer(to: "")
    }
    return output
  }

  static func repairLegacyCoinGeckoIDs(in tokens: [CustomTokenRecord]) -> [CustomTokenRecord] {
    tokens.map { token in
      var repaired = token
      guard let rawId = token.coinGeckoId else { return repaired }
      repaired.coinGeckoId = UserInputValidation.normalizedCoinGeckoId(rawId)
      return repaired
    }
  }

  @discardableResult
  func mutateDocument(_ mutation: (inout VaultDocument) -> Void) async -> Bool {
    var candidate = document
    mutation(&candidate)
    return await save(candidate, projectedSyncVersion: nil)
  }

  func canMutateVault(allowPendingAccountDeletion: Bool = false) -> Bool {
    guard !syncing else {
      error = "Wait for the active sync operation before editing the vault."
      return false
    }
    guard !isValidatingExchangeCredentials else {
      error = "Wait for the exchange credential check before editing the vault."
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
    guard allowPendingAccountDeletion || !hasPendingAccountDeletion else {
      error = "Finish or retry the pending account deletion before editing the vault."
      return false
    }
    guard !isPersisting else {
      error = "Wait for the current local save before editing the vault."
      return false
    }
    guard !isUnlocking else {
      error = "Wait for vault recovery to finish before editing the vault."
      return false
    }
    return true
  }

}
