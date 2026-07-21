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
  @Published private(set) var walletLabelDrafts: [UUID: String] = [:]
  @Published var isValidatingExchangeCredentials = false
  @Published var syncPersistencePending = false
  @Published var pendingVaultUploadHasRemoteConflict = false
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

  let crypto = VaultCrypto()
  let keyStore: any VaultKeyStore
  let appSupportDirectoryOverride: URL?
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
    },
    keyStore: any VaultKeyStore = KeychainVaultKeyStore(),
    appSupportDirectoryOverride: URL? = nil
  ) {
    self.endpointConfigClient = endpointConfigClient
    self.endpointConfigTrustStore = endpointConfigTrustStore
    self.httpClient = httpClient
    self.passkeyAuthenticator = passkeyAuthenticator ?? PasskeyWebAuthenticator()
    self.krakenDeviceIdentifier = krakenDeviceIdentifier
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
    }
  ) {
    precondition((1...VaultSyncCodec.maximumSnapshotByteCount).contains(syncSnapshotByteLimit))
    self.endpointConfigClient = endpointConfigClient
    self.endpointConfigTrustStore = endpointConfigTrustStore
    self.httpClient = httpClient
    self.passkeyAuthenticator = passkeyAuthenticator ?? PasskeyWebAuthenticator()
    self.krakenDeviceIdentifier = krakenDeviceIdentifier
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
    self.pendingVaultUpload = try? testStore.loadPendingVaultUpload()
    self.syncPersistencePending = pendingVaultUpload != nil
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
      ? holdings.filter { $0.valueUsd.isFinite && $0.valueUsd >= threshold }
      : holdings
    return Self.sortedHoldingsForDisplay(visible)
  }

  static func sortedHoldingsForDisplay(_ holdings: [TrackedAsset]) -> [TrackedAsset] {
    holdings.sorted { lhs, rhs in
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
  var latestTotalUsd: Double {
    AppState.validatedPortfolioTotal(latestScan?.holdings ?? []) ?? 0
  }

  var hiddenDustHoldingCount: Int {
    hiddenDustHoldings.count
  }

  var hiddenDustValueUsd: Double {
    let valued = hiddenDustHoldings.filter { $0.valueUsd.isFinite && $0.valueUsd >= 0 }
    return AppState.validatedPortfolioTotal(valued) ?? 0
  }

  private var hiddenDustHoldings: [TrackedAsset] {
    guard document.preferences.hideDust else { return [] }
    let threshold =
      document.preferences.dustThreshold.isFinite
      ? max(0, document.preferences.dustThreshold)
      : 0
    return (latestScan?.holdings ?? []).filter {
      !$0.valueUsd.isFinite || $0.valueUsd < threshold
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

  /// Recovery obligations are global vault state, not page-level feedback.
  /// Keep this guidance visible across navigation until the underlying durable
  /// operation is resolved, even though ordinary notices and errors are reset.
  var persistentOperationGuidance: String? {
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

  var safeUpdateDownloadURL: URL { Self.updateDownloadURL }

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
    do {
      let vaultURL = appSupportDirectory.appending(path: "vault.sqlite")
      let key = try await vaultKeyManager.loadOrCreateVaultKey(existingVaultAt: vaultURL)
      let sqlite = try EncryptedSQLiteVaultStore(path: vaultURL, vaultKey: key, crypto: crypto)
      let coordinator = VaultPersistenceCoordinator(
        store: sqlite,
        syncSnapshotByteLimit: syncSnapshotByteLimit
      )
      let loaded = try await coordinator.load()
      let pendingUpload = try await coordinator.loadPendingVaultUpload(vaultKey: key)
      let hasRollbackCheckpoint = try await coordinator.hasRollbackCheckpoint()
      let normalized = normalizedLoadedDocument(loaded.document)
      let durable =
        pendingUpload != nil || normalized == loaded.document
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
      self.hasVaultRollbackCheckpoint = hasRollbackCheckpoint
      pendingVaultUploadHasRemoteConflict = false
      syncPersistencePending = pendingUpload != nil
      notice = pendingUpload == nil ? "" : "Recovering an interrupted encrypted vault upload."
      error = ""
      if pendingUpload != nil {
        await recoverPendingVaultUpload()
      }
    } catch {
      presentUserFacingError(error)
      isUnlocked = false
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
      } else if pendingSyncPersistence == nil, pendingVaultUpload == nil {
        syncPersistencePending = false
      }
      notice = "Saved locally." + pruningNoticeSuffix(result.removedScanRunCount)
      error = ""
      persistenceSucceeded = true
      return true
    } catch {
      notice = ""
      presentUserFacingError(error)
      return false
    }
  }

  /// Persist an account-disconnected document and remove its historical
  /// rollback point as one durable operation. This prevents a crash or disk
  /// error from leaving only one side of the identity transition committed.
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
        syncPersistencePending = true
        error =
          "The vault changed while a local account transition was finishing. Reopen Address Atlas before making more changes."
        return false
      }
      document = result.document
      documentRevision &+= 1
      hasUnsyncedLocalChanges = result.hasLocalChanges
      if pendingSyncPersistence == nil, pendingVaultUpload == nil {
        syncPersistencePending = false
      }
      notice = "Saved locally."
      error = ""
      persistenceSucceeded = true
      return true
    } catch {
      notice = ""
      presentUserFacingError(error)
      return false
    }
  }

  func retryPendingSyncPersistence() async {
    guard acceptsNewOperations else { return }
    guard syncPersistencePending else { return }
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
        pendingVaultUpload == nil
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
