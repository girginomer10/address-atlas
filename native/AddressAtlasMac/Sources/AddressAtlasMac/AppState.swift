import AddressAtlasCore
import Foundation
import SwiftUI

protocol EndpointConfigFetching: Sendable {
  func fetch(from serverURL: URL) async throws -> NativeEndpointConfig
}

extension NativeEndpointConfigClient: EndpointConfigFetching {}

/// The single owner of the sync/account operation lane. Keeping the concrete
/// activity instead of a Boolean lets the UI put progress on the control that
/// started the work while preserving strict mutual exclusion.
enum SyncActivity: String, CaseIterable, Equatable, Sendable {
  case creatingPasskeyAccount
  case signingIn
  case uploadingVault
  case downloadingVault
  case recoveringUpload
  case retryingLocalSave
  case stoppingUploadRecovery
  case revokingSession
  case deletingAccount
  case disconnectingAccount
  case restoringRollbackCheckpoint

  var progressTitle: String {
    switch self {
    case .creatingPasskeyAccount: "Creating passkey account"
    case .signingIn: "Signing in with passkey"
    case .uploadingVault: "Uploading encrypted vault"
    case .downloadingVault: "Downloading encrypted vault"
    case .recoveringUpload: "Recovering interrupted upload"
    case .retryingLocalSave: "Retrying local save"
    case .stoppingUploadRecovery: "Stopping upload recovery"
    case .revokingSession: "Revoking this Mac's session"
    case .deletingAccount: "Deleting sync account"
    case .disconnectingAccount: "Disconnecting sync account"
    case .restoringRollbackCheckpoint: "Restoring encrypted rollback point"
    }
  }

  var accessibilityLabel: String { "\(progressTitle), in progress" }
}

enum DamagedVaultRecoveryAvailability: Equatable, Sendable {
  case validatedRollbackCheckpoint
  case quarantineOnly
}

@MainActor
final class AppState: ObservableObject {
  @Published var document = VaultDocument() {
    didSet {
      documentRevision &+= 1
      if AppState.validatedSyncURL(oldValue.syncState.serverURL)
        != AppState.validatedSyncURL(document.syncState.serverURL)
      {
        // The authority changed even if this document replacement bypassed
        // saveSyncSettings (restore/tests do this). Cancel the shared request
        // before it can advance the previous origin's durable trust record.
        endpointConfigRefreshGeneration &+= 1
        endpointConfigRefreshRequest?.task.cancel()
        endpointConfigRefreshRequest = nil
        endpointConfig = .bundled
        endpointConfigStatus = "Bundled endpoints"
        acceptedEndpointConfigServerURL = nil
        endpointConfigTrustDurabilityDegraded = false
      }
      // Never risk a false-clean UI after a future call site mutates the value
      // directly. A successful actor save replaces this conservative value
      // with the checksum-backed result.
      hasUnsyncedLocalChanges = true
    }
  }
  @Published var isUnlocked = false
  @Published var isUnlocking = false
  @Published private(set) var isPersisting = false
  @Published private(set) var isTerminationInProgress = false
  @Published private(set) var isExportOperationInProgress = false
  @Published var damagedVaultRecoveryAvailability:
    DamagedVaultRecoveryAvailability?
  @Published private(set) var walletLabelDrafts: [UUID: String] = [:]
  @Published var isValidatingExchangeCredentials = false
  @Published var syncPersistencePending = false
  @Published var pendingVaultUploadHasRemoteConflict = false
  /// Damaged encrypted upload journal. The decrypted primary remains visible,
  /// while mutation stays blocked until this exact row is explicitly discarded.
  @Published var quarantinedPendingVaultUpload: QuarantinedPendingVaultUpload?
  @Published var hasVaultRollbackCheckpoint = false
  @Published var hasUnsyncedLocalChanges = true
  var lastSaveRemovedScanRunCount = 0
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
  @Published private(set) var syncActivity: SyncActivity?
  var syncing: Bool { syncActivity != nil }
  @Published var endpointConfig = NativeEndpointConfig.bundled {
    didSet {
      operatorMessage = AppState.normalizedOperatorMessage(endpointConfig.message)
    }
  }
  @Published var endpointConfigStatus = "Bundled endpoints"
  /// True only when an accepted policy's rename is visible but its containing
  /// directory durability barrier failed. Read-only scans may continue with the
  /// applied policy, while every sync/auth path remains fail-closed until a
  /// refresh retries and proves the barrier.
  @Published private(set) var endpointConfigTrustDurabilityDegraded = false
  /// Operator broadcast carried by the currently applied endpoint config.
  /// Nil whenever the server supplied no message or only whitespace.
  @Published private(set) var operatorMessage: String?

  /// Process-local support history. Its event type has no free-form payload,
  /// so even an upstream error that contains secrets cannot enter diagnostics.
  var privacySafeDiagnosticLog = PrivacySafeDiagnosticLog()

  let crypto = VaultCrypto()
  let keyStore: any VaultKeyStore
  let appSupportDirectoryOverride: URL?
  let syncCodec = VaultSyncCodec()
  let syncSnapshotByteLimit: Int
  let recoveryKit = RecoveryKitCodec()
  let endpointConfigClient: any EndpointConfigFetching
  let endpointConfigTrustStore: any EndpointConfigTrustPersisting
  let krakenDeviceIdentifier: @Sendable () throws -> String
  /// Injected only to make session-expiry boundaries deterministic in tests.
  /// Production samples wall-clock time at each authorization decision.
  let sessionDateProvider: @Sendable () -> Date
  /// Test seam for the network boundary only. Nil keeps each production
  /// client's own BoundedURLSessionHTTPClient defaults.
  let httpClient: (any HTTPClient)?
  let passkeyAuthenticator: any PasskeyAuthenticating
  private lazy var vaultKeyManager = VaultKeyManager(store: keyStore, crypto: crypto)
  var vaultKey: Data?
  /// Held only after Keychain supplied the existing key and the primary row
  /// then failed a recoverable integrity read. It is never replaced with a new
  /// key during damaged-vault recovery.
  var damagedVaultRecoveryKey: Data?
  var persistence: VaultPersistenceCoordinator?
  /// Encrypted upload intent mirrored from SQLite. Its presence blocks all
  /// vault mutation until the exact remote snapshot is reconciled.
  var pendingVaultUpload: PendingVaultUpload?
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
  /// Termination waits here when an already-started local save owns the
  /// persistence actor. MainActor isolation makes registration and resumption
  /// race-free without polling or blocking the application run loop.
  var persistenceCompletionWaiters: [CheckedContinuation<Bool, Never>] = []
  /// One-shot deterministic seam for exercising termination while a local save
  /// is suspended. Production never installs this callback.
  var persistenceStartedHook: (@MainActor @Sendable () async -> Void)?
  /// Focused test seam for proving revision checks at the journal/PUT boundary.
  /// Production never installs this callback.
  var pendingUploadStagedHook: (@MainActor () -> Void)?
  /// Focused test seam for the post-CAS memory-adoption boundary.
  var pendingUploadCompletedPersistenceHook: (@MainActor () -> Void)?
  /// One-shot test seam after the browser/code exchange has completed but
  /// before endpoint trust and the local account binding are committed.
  var passkeyAuthenticationCompletedHook: (@MainActor () -> Void)?
  /// The origin that supplied the currently accepted remote configuration.
  /// Versions are monotonic only within one authority; changing servers resets
  /// this state to the bundled baseline.
  var acceptedEndpointConfigServerURL: URL?

  struct EndpointConfigRefreshRequest {
    var generation: Int
    var serverURL: URL
    var task: Task<TrustedEndpointConfig, Error>
    var waiterPool: EndpointConfigRefreshWaiterPool
    var waiterIDs: Set<UUID>
  }

  struct PendingSyncPersistence {
    var document: VaultDocument
    var projectedSyncVersion: Int?
    var saveExactly: Bool
  }

  static let maximumStoredScanRuns = VaultDocumentLimits.maximumStoredScanRuns
  static let maximumWallets = VaultDocumentLimits.maximumWallets
  static let maximumCustomTokens = VaultDocumentLimits.maximumCustomTokens
  static let maximumManualHoldings = VaultDocumentLimits.maximumManualHoldings
  static let maximumExchangeConnections = VaultDocumentLimits.maximumExchangeConnections
  /// The app-bundle script reads this value when generating Info.plist.
  /// SwiftPM's `swift run` executable has no Info.plist, so it also needs the
  /// compiled release version for the server compatibility check.
  static let currentAppVersion = "0.2.0"
  /// Hard-pinned, HTTPS direct-distribution update route. Mac App Store builds
  /// override this with their immutable apps.apple.com product URL in Info.plist.
  static let directUpdateDownloadURL = URL(
    string: "https://github.com/girginomer10/address-atlas/releases/latest"
  )!
  /// A malformed App Store product URL must never make a sandboxed build send
  /// users to the separately distributed GitHub binary. The generic storefront
  /// is a safe fail-closed destination until the numeric product ID is set.
  static let macAppStoreFallbackURL = URL(string: "https://apps.apple.com")!
  static let privacyPolicyURL = URL(
    string: "https://github.com/girginomer10/address-atlas/blob/main/PRIVACY.md"
  )!
  static let supportURL = URL(
    string: "https://github.com/girginomer10/address-atlas/blob/main/SUPPORT.md"
  )!
  static let termsOfUseURL = URL(
    string: "https://github.com/girginomer10/address-atlas/blob/main/TERMS.md"
  )!
  static let coinGeckoAttributionURL = URL(
    string: "https://www.coingecko.com/en/api"
  )!

  init(
    endpointConfigClient: any EndpointConfigFetching = NativeEndpointConfigClient(),
    endpointConfigTrustStore: any EndpointConfigTrustPersisting =
      EphemeralEndpointConfigTrustStore(),
    httpClient: (any HTTPClient)? = nil,
    passkeyAuthenticator: (any PasskeyAuthenticating)? = nil,
    krakenDeviceIdentifier: @escaping @Sendable () throws -> String = {
      try KrakenDeviceIdentity.currentIdentifier()
    },
    sessionDateProvider: @escaping @Sendable () -> Date = { Date() },
    keyStore: any VaultKeyStore = KeychainVaultKeyStore(),
    appSupportDirectoryOverride: URL? = nil
  ) {
    self.endpointConfigClient = endpointConfigClient
    self.endpointConfigTrustStore = endpointConfigTrustStore
    self.httpClient = httpClient
    self.passkeyAuthenticator = passkeyAuthenticator ?? PasskeyWebAuthenticator()
    self.krakenDeviceIdentifier = krakenDeviceIdentifier
    self.sessionDateProvider = sessionDateProvider
    self.keyStore = keyStore
    self.appSupportDirectoryOverride = appSupportDirectoryOverride
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
    },
    sessionDateProvider: @escaping @Sendable () -> Date = { Date() }
  ) {
    precondition((1...VaultSyncCodec.maximumSnapshotByteCount).contains(syncSnapshotByteLimit))
    self.endpointConfigClient = endpointConfigClient
    self.endpointConfigTrustStore = endpointConfigTrustStore
    self.httpClient = httpClient
    self.passkeyAuthenticator = passkeyAuthenticator ?? PasskeyWebAuthenticator()
    self.krakenDeviceIdentifier = krakenDeviceIdentifier
    self.sessionDateProvider = sessionDateProvider
    self.keyStore = KeychainVaultKeyStore()
    self.appSupportDirectoryOverride = nil
    self.syncSnapshotByteLimit = syncSnapshotByteLimit
    self.persistence = VaultPersistenceCoordinator(
      store: testStore,
      syncSnapshotByteLimit: syncSnapshotByteLimit
    )
    self.vaultKey = testVaultKey
    self.document = document
    self.hasUnsyncedLocalChanges = (try? VaultSyncCodec().hasLocalChanges(in: document)) ?? true
    self.isUnlocked = true
    if let inspection = try? testStore.inspectPendingVaultUpload() {
      switch inspection {
      case .none:
        break
      case .pending(let upload, _):
        self.pendingVaultUpload = upload
      case .quarantined(let identity):
        self.quarantinedPendingVaultUpload = identity
      }
    }
    self.syncPersistencePending =
      pendingVaultUpload != nil || quarantinedPendingVaultUpload != nil
    self.hasVaultRollbackCheckpoint = (try? testStore.containsRollbackCheckpoint()) ?? false
  }

  var latestScan: ScanRunRecord? {
    document.scanRuns.sorted { $0.generatedAt > $1.generatedAt }.first
  }

  var visibleLatestHoldings: [TrackedAsset] {
    let holdings = latestScan?.holdings ?? []
    let threshold =
      document.preferences.dustThreshold.isFinite
      ? max(0, document.preferences.dustThreshold)
      : 0
    let visible =
      document.preferences.hideDust
      ? holdings.filter {
        $0.pricingStatus != .priced
          || ($0.valueUsd.isFinite && $0.valueUsd >= threshold)
      }
      : holdings
    return Self.sortedHoldingsForDisplay(visible)
  }

  static func sortedHoldingsForDisplay(_ holdings: [TrackedAsset]) -> [TrackedAsset] {
    holdings.sorted { lhs, rhs in
      if (lhs.pricingStatus == .priced) != (rhs.pricingStatus == .priced) {
        return lhs.pricingStatus == .priced
      }
      let lhsValue = lhs.valueUsd.isFinite && lhs.valueUsd >= 0 ? lhs.valueUsd : 0
      let rhsValue = rhs.valueUsd.isFinite && rhs.valueUsd >= 0 ? rhs.valueUsd : 0
      if lhsValue != rhsValue { return lhsValue > rhsValue }
      if lhs.symbol != rhs.symbol { return lhs.symbol < rhs.symbol }
      if lhs.chainId != rhs.chainId { return lhs.chainId < rhs.chainId }
      if lhs.address != rhs.address { return lhs.address < rhs.address }
      if lhs.source.rawValue != rhs.source.rawValue {
        return lhs.source.rawValue < rhs.source.rawValue
      }
      return lhs.id < rhs.id
    }
  }

  /// The headline always represents the complete validated snapshot. Dust is
  /// a row-visibility preference and must never silently rewrite portfolio
  /// value.
  var latestKnownValueUsd: Double {
    AppState.validatedPortfolioTotal(latestScan?.holdings ?? []) ?? 0
  }

  /// Compatibility name for call sites that only need the numeric subtotal.
  /// Presentation must qualify it whenever `unpricedHoldingCount` is nonzero.
  var latestTotalUsd: Double { latestKnownValueUsd }

  var unpricedHoldingCount: Int {
    (latestScan?.holdings ?? []).filter { $0.pricingStatus != .priced }.count
  }

  var hasPartialValuation: Bool { unpricedHoldingCount > 0 }

  var hiddenDustHoldingCount: Int {
    hiddenDustHoldings.count
  }

  var hiddenDustValueUsd: Double {
    let valued = hiddenDustHoldings.filter {
      $0.pricingStatus == .priced && $0.valueUsd.isFinite && $0.valueUsd >= 0
    }
    return AppState.validatedPortfolioTotal(valued) ?? 0
  }

  private var hiddenDustHoldings: [TrackedAsset] {
    guard document.preferences.hideDust else { return [] }
    let threshold =
      document.preferences.dustThreshold.isFinite
      ? max(0, document.preferences.dustThreshold)
      : 0
    return (latestScan?.holdings ?? []).filter {
      $0.pricingStatus == .priced && (!$0.valueUsd.isFinite || $0.valueUsd < threshold)
    }
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
      || isTerminationInProgress
  }

  /// AppKit freezes admission synchronously before the asynchronous quit flush.
  /// Every queued/background operation that can start network or persistence
  /// work must consult this before claiming its own activity flag.
  var acceptsNewOperations: Bool {
    !isTerminationInProgress
  }

  var hasPendingAccountDeletion: Bool {
    AccountDeletionIdempotencyKey.normalized(
      document.syncState.accountDeletionIdempotencyKey
    ) != nil
  }

  func hasUsableSyncSession(at date: Date? = nil) -> Bool {
    guard let accountId = document.syncState.accountId else { return false }
    return SyncSessionToken.isUsable(
      document.syncState.sessionToken,
      forAccountId: accountId,
      at: date ?? sessionDateProvider()
    )
  }

  func syncSessionStatus(at date: Date? = nil) -> String {
    guard !document.syncState.sessionToken.isEmpty else { return "sign in required" }
    return hasUsableSyncSession(at: date) ? "active" : "expired—sign in required"
  }

  /// Recovery obligations are global vault state, not page-level feedback.
  /// Keep this guidance visible across navigation until the underlying durable
  /// operation is resolved, even though ordinary notices and errors are reset.
  var persistentOperationGuidance: String? {
    if quarantinedPendingVaultUpload != nil {
      return
        "The encrypted upload recovery record is quarantined. Your local vault is available read-only; open Sync to explicitly discard only the damaged recovery record."
    }
    if pendingVaultUploadHasRemoteConflict {
      return
        "Encrypted upload recovery has a remote conflict. Open Sync to review it before changing the vault."
    }
    if pendingVaultUpload != nil {
      return
        "An encrypted vault upload still needs recovery. Open Sync and retry upload recovery before changing the vault."
    }
    if syncPersistencePending {
      return
        "A completed sync still needs a local save. Open Sync and retry the local save before changing the vault."
    }
    if hasPendingAccountDeletion {
      return
        "Sync account deletion is still pending. Open Sync and retry the saved deletion operation."
    }
    if document.syncState.remoteOutcomeUncertain {
      return
        "The last encrypted upload may or may not have reached the server. Open Sync to reconcile the unknown remote outcome before trusting remote status or replacing this local vault."
    }
    if document.syncState.pendingExchangeCredentialCleanup {
      return
        "Exchange credentials were removed locally, but the last confirmed remote snapshot may still contain them. Open Sync and upload the replacement encrypted vault to complete remote cleanup."
    }
    return nil
  }

  var accountDeletionControlDisabled: Bool {
    syncing || scanning || isPersisting || isValidatingExchangeCredentials
      || syncPersistencePending || isUnlocking || document.syncState.accountId == nil
  }

  var appSupportDirectory: URL {
    if let appSupportDirectoryOverride { return appSupportDirectoryOverride }
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

  var usesMacAppStoreUpdates: Bool {
    Bundle.main.infoDictionary?["AddressAtlasDistributionChannel"] as? String == "app-store"
  }

  var safeUpdateDownloadURL: URL {
    Self.resolvedUpdateDownloadURL(
      distributionChannel: Bundle.main.infoDictionary?["AddressAtlasDistributionChannel"]
        as? String,
      rawURL: Bundle.main.infoDictionary?["AddressAtlasUpdateURL"] as? String
    )
  }

  static func resolvedUpdateDownloadURL(
    distributionChannel: String?,
    rawURL: String?
  ) -> URL {
    guard distributionChannel == "app-store" else {
      return directUpdateDownloadURL
    }
    guard
      let rawURL,
      let url = URL(string: rawURL),
      url.scheme == "https",
      url.host == "apps.apple.com"
    else {
      return macAppStoreFallbackURL
    }
    return url
  }

  var updateActionTitle: String {
    usesMacAppStoreUpdates
      ? "Open Address Atlas in the Mac App Store"
      : "Download the latest signed Address Atlas release"
  }

  var updateActionHint: String {
    usesMacAppStoreUpdates
      ? "Opens the hard-pinned Address Atlas product page in the Mac App Store"
      : "Opens the hard-pinned Address Atlas releases page in your browser"
  }

  /// False when the server's `minSupportedAppVersion` is newer than this build.
  /// A present but malformed policy or app version fails closed.
  var isAppVersionSupported: Bool {
    AppState.supportsAppVersion(appVersion, minimum: endpointConfig.minSupportedAppVersion)
  }
  func acceptedEndpointStatus(_ detail: String) -> String {
    let durableDetail =
      endpointConfigTrustDurabilityDegraded
      ? "\(detail); trust durability retry required"
      : detail
    return isAppVersionSupported ? durableDetail : "Update required (\(durableDetail))"
  }

  func setEndpointConfigTrustDurabilityDegraded(_ isDegraded: Bool) {
    endpointConfigTrustDurabilityDegraded = isDegraded
  }

  func unlock() async {
    guard beginUnlockOperationIfAllowed() else { return }
    defer { isUnlocking = false }
    damagedVaultRecoveryAvailability = nil
    damagedVaultRecoveryKey = nil
    var candidateRecoveryKey: Data?
    var candidateRecoveryCoordinator: VaultPersistenceCoordinator?
    do {
      let vaultURL = appSupportDirectory.appending(path: "vault.sqlite")
      let key = try await vaultKeyManager.loadOrCreateVaultKey(existingVaultAt: vaultURL)
      candidateRecoveryKey = key
      let sqlite = try EncryptedSQLiteVaultStore(path: vaultURL, vaultKey: key, crypto: crypto)
      let coordinator = VaultPersistenceCoordinator(
        store: sqlite,
        syncSnapshotByteLimit: syncSnapshotByteLimit
      )
      candidateRecoveryCoordinator = coordinator
      let loaded = try await coordinator.load()
      let pendingInspection = try await coordinator.inspectPendingVaultUpload(vaultKey: key)
      let pendingUpload: PendingVaultUpload?
      let quarantinedUpload: QuarantinedPendingVaultUpload?
      switch pendingInspection {
      case .none:
        pendingUpload = nil
        quarantinedUpload = nil
      case .pending(let upload, _):
        pendingUpload = upload
        quarantinedUpload = nil
      case .quarantined(let identity):
        pendingUpload = nil
        quarantinedUpload = identity
      }
      let hasRollbackCheckpoint = try await coordinator.hasRollbackCheckpoint()
      let normalized = normalizedLoadedDocument(loaded.document)
      let durable =
        pendingUpload != nil || quarantinedUpload != nil || normalized == loaded.document
        ? loaded
        : try await coordinator.saveExactly(normalized)
      document = durable.document
      hasUnsyncedLocalChanges = durable.hasLocalChanges
      vaultKey = key
      persistence = coordinator
      documentRevision &+= 1
      isUnlocked = true
      pendingSyncPersistence = nil
      pendingVaultUpload = pendingUpload
      quarantinedPendingVaultUpload = quarantinedUpload
      self.hasVaultRollbackCheckpoint = hasRollbackCheckpoint
      pendingVaultUploadHasRemoteConflict = false
      syncPersistencePending = pendingUpload != nil || quarantinedUpload != nil
      if quarantinedUpload != nil {
        notice = ""
        error =
          "The encrypted upload recovery record is damaged and has been quarantined. Your full local vault is available read-only. Open Sync to explicitly discard only that recovery record."
      } else {
        notice = pendingUpload == nil ? "" : "Recovering an interrupted encrypted vault upload."
        error = ""
      }
      if pendingUpload != nil {
        await recoverPendingVaultUpload()
      }
    } catch {
      recordDiagnosticFailure(.storageUnlockFailed)
      if let key = candidateRecoveryKey,
        let coordinator = candidateRecoveryCoordinator,
        Self.isRecoverableDamagedPrimaryRead(error)
      {
        let hasValidatedRollback =
          (try? await coordinator.canRecoverDamagedPrimaryFromRollbackCheckpoint()) == true
        damagedVaultRecoveryKey = key
        damagedVaultRecoveryAvailability =
          hasValidatedRollback ? .validatedRollbackCheckpoint : .quarantineOnly
        notice = ""
        self.error =
          hasValidatedRollback
          ? "The primary encrypted vault is damaged, but its automatic encrypted rollback point was independently validated. Restore that rollback point first, or explicitly quarantine the damaged database and start with a clean local vault. Nothing has been reset."
          : "The primary encrypted vault is damaged and no valid automatic rollback point is available. You can explicitly preserve the database and its SQLite sidecars in a private quarantine, then start with a clean local vault and sign in to download the remote copy. Nothing has been reset."
        isUnlocked = false
        return
      }
      presentUserFacingError(error)
      isUnlocked = false
    }
  }

  private static func isRecoverableDamagedPrimaryRead(_ error: Error) -> Bool {
    if error is DecodingError || error is VaultCryptoError
      || error is VaultDocumentSemanticError
    {
      return true
    }
    guard let storeError = error as? EncryptedSQLiteVaultStoreError else {
      return false
    }
    switch storeError {
    case .prepareFailed, .stepFailed, .invalidRow:
      return true
    case .openFailed, .bindFailed, .filePermissionsFailed, .durabilityUnavailable,
      .missingDocument, .staleDocument, .pendingUploadExists, .pendingUploadMissing,
      .pendingUploadMismatch, .primaryDocumentIsReadable:
      return false
    }
  }

  /// Claims the unlock lifecycle on the main actor. Keeping termination
  /// admission in the same synchronous transition as `isUnlocking` prevents a
  /// queued launch task from starting vault recovery after AppKit has frozen
  /// new work for termination.
  @discardableResult
  func beginUnlockOperationIfAllowed() -> Bool {
    guard acceptsNewOperations, !isUnlocked, !isUnlocking else { return false }
    isUnlocking = true
    return true
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
    resolvesPendingSyncPersistence: Bool = false,
    allowDuringTermination: Bool = false
  ) async -> Bool {
    lastSaveRemovedScanRunCount = 0
    guard !isTerminationInProgress || allowDuringTermination else {
      notice = ""
      error = "Address Atlas is finishing a local save before quitting."
      return false
    }
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
    var persistenceSucceeded = false
    defer { finishPersistenceOperation(succeeded: persistenceSucceeded) }
    if let persistenceStartedHook {
      self.persistenceStartedHook = nil
      await persistenceStartedHook()
    }
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
        recordDiagnosticFailure(.storageSaveFailed)
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
      } else if pendingSyncPersistence == nil, pendingVaultUpload == nil,
        quarantinedPendingVaultUpload == nil
      {
        syncPersistencePending = false
      }
      notice = "Saved locally." + pruningNoticeSuffix(result.removedScanRunCount)
      error = ""
      persistenceSucceeded = true
      return true
    } catch {
      recordDiagnosticFailure(.storageSaveFailed)
      notice = ""
      presentUserFacingError(error)
      return false
    }
  }

  /// Persist a privacy- or identity-sensitive document transition and remove
  /// its historical rollback point as one durable operation. This prevents a
  /// crash or disk error from committing only one side of the transition.
  @discardableResult
  func saveAndDiscardRollbackCheckpoint(_ candidate: VaultDocument) async -> Bool {
    lastSaveRemovedScanRunCount = 0
    guard !isTerminationInProgress else {
      notice = ""
      error = "Address Atlas is finishing a local save before quitting."
      return false
    }
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
    var persistenceSucceeded = false
    defer { finishPersistenceOperation(succeeded: persistenceSucceeded) }
    if let persistenceStartedHook {
      self.persistenceStartedHook = nil
      await persistenceStartedHook()
    }
    do {
      let result = try await persistence.saveAndDiscardRollbackCheckpoint(candidate)
      hasVaultRollbackCheckpoint = false
      guard startingRevision == documentRevision else {
        recordDiagnosticFailure(.storageProtectedTransitionFailed)
        syncPersistencePending = true
        error =
          "The vault changed while a protected local transition was finishing. Reopen Address Atlas before making more changes."
        return false
      }
      document = result.document
      documentRevision &+= 1
      hasUnsyncedLocalChanges = result.hasLocalChanges
      if pendingSyncPersistence == nil, pendingVaultUpload == nil,
        quarantinedPendingVaultUpload == nil
      {
        syncPersistencePending = false
      }
      notice = "Saved locally."
      error = ""
      persistenceSucceeded = true
      return true
    } catch {
      recordDiagnosticFailure(.storageProtectedTransitionFailed)
      notice = ""
      presentUserFacingError(error)
      return false
    }
  }

  func retryPendingSyncPersistence() async {
    guard acceptsNewOperations else { return }
    guard syncPersistencePending else { return }
    if quarantinedPendingVaultUpload != nil {
      error =
        "The damaged encrypted upload recovery record cannot be replayed. Review it in Sync and explicitly discard only that record to keep the full local vault."
      return
    }
    if pendingVaultUpload != nil {
      await recoverPendingVaultUpload()
      return
    }
    guard let pendingSyncPersistence else {
      error =
        "The pending local sync state cannot be retried safely. Reopen Address Atlas before making more changes."
      return
    }
    guard beginSyncActivity(.retryingLocalSave) else {
      notice = "A sync operation is already running."
      return
    }
    defer { finishSyncActivity(.retryingLocalSave) }
    if await save(
      pendingSyncPersistence.document,
      projectedSyncVersion: pendingSyncPersistence.projectedSyncVersion,
      saveExactly: pendingSyncPersistence.saveExactly,
      resolvesPendingSyncPersistence: true
    ) {
      notice = "Sync state saved locally." + pruningNoticeSuffix(lastSaveRemovedScanRunCount)
    }
  }

  @discardableResult
  func beginSyncActivity(_ activity: SyncActivity) -> Bool {
    guard acceptsNewOperations, syncActivity == nil else { return false }
    syncActivity = activity
    return true
  }

  func finishSyncActivity(_ activity: SyncActivity) {
    guard syncActivity == activity else { return }
    syncActivity = nil
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
    for index in output.scanRuns.indices {
      output.scanRuns[index].warnings = ScanWarningPolicy.bounded(output.scanRuns[index].warnings)
    }
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
    guard !isTerminationInProgress else {
      error = "Address Atlas is saving changes before quitting."
      return false
    }
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
      error =
        quarantinedPendingVaultUpload != nil
        ? "Discard the quarantined upload recovery record explicitly before editing the read-only vault."
        : pendingVaultUpload == nil
          ? "Save the pending sync state locally before editing the vault."
          : "Recover the interrupted encrypted vault upload before editing the vault."
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

  func setTerminationInProgress(_ inProgress: Bool) {
    isTerminationInProgress = inProgress
  }

  @discardableResult
  func beginExportOperation() -> Bool {
    guard !isTerminationInProgress else {
      error = "Address Atlas is preparing to quit."
      return false
    }
    guard !isExportOperationInProgress else { return false }
    isExportOperationInProgress = true
    return true
  }

  func finishExportOperation() {
    isExportOperationInProgress = false
  }

  func storeWalletLabelDraft(_ draft: String?, for id: UUID) {
    walletLabelDrafts[id] = draft
  }

  func clearWalletLabelDrafts() {
    walletLabelDrafts.removeAll()
  }

  func finishPersistenceOperation(succeeded: Bool) {
    isPersisting = false
    let waiters = persistenceCompletionWaiters
    persistenceCompletionWaiters.removeAll()
    for waiter in waiters {
      waiter.resume(returning: succeeded)
    }
  }

}
