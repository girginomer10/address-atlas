import Foundation

/// A closed vocabulary for support diagnostics. Callers cannot attach arbitrary
/// strings, errors, URLs, identifiers, or user payloads to an event.
public enum PrivacySafeDiagnosticCode: String, CaseIterable, Sendable {
  case storageUnlockFailed = "storage.unlock_failed"
  case storageSaveFailed = "storage.save_failed"
  case storageProtectedTransitionFailed = "storage.protected_transition_failed"
  case passkeyRegistrationFailed = "passkey.registration_failed"
  case passkeyAuthenticationFailed = "passkey.authentication_failed"
  case syncUploadFailed = "sync.upload_failed"
  case syncDownloadFailed = "sync.download_failed"
  case syncUploadRecoveryFailed = "sync.upload_recovery_failed"
  case syncAccountLifecycleFailed = "sync.account_lifecycle_failed"
  case scanFailed = "scan.failed"
  case recoveryRollbackFailed = "recovery.rollback_failed"
  case recoveryQuarantineFailed = "recovery.quarantine_failed"
  case recoveryKitExportFailed = "recovery.kit_export_failed"
  case recoveryKitRestoreFailed = "recovery.kit_restore_failed"
  case endpointPolicyRefreshFailed = "endpoint_policy.refresh_failed"

  public var operation: PrivacySafeDiagnosticOperation {
    switch self {
    case .storageUnlockFailed, .storageSaveFailed, .storageProtectedTransitionFailed:
      .storage
    case .passkeyRegistrationFailed, .passkeyAuthenticationFailed:
      .passkey
    case .syncUploadFailed, .syncDownloadFailed, .syncUploadRecoveryFailed,
      .syncAccountLifecycleFailed:
      .sync
    case .scanFailed:
      .scan
    case .recoveryRollbackFailed, .recoveryQuarantineFailed,
      .recoveryKitExportFailed, .recoveryKitRestoreFailed:
      .recovery
    case .endpointPolicyRefreshFailed:
      .endpointPolicy
    }
  }
}

public enum PrivacySafeDiagnosticOperation: String, CaseIterable, Sendable {
  case storage
  case passkey
  case sync
  case scan
  case recovery
  case endpointPolicy = "endpoint_policy"
}

public enum PrivacySafeCountBucket: String, Sendable {
  case none
  case one
  case few
  case several
  case many

  public init(count: Int) {
    switch count {
    case ...0: self = .none
    case 1: self = .one
    case 2...5: self = .few
    case 6...20: self = .several
    default: self = .many
    }
  }
}

public enum PrivacySafeSessionState: String, Sendable {
  case absent
  case usable
  case unusable
}

public enum PrivacySafeVaultState: String, Sendable {
  case locked
  case unlocked
  case recoveryRequired = "recovery_required"
}

/// Snapshot values are deliberately limited to coarse enums, booleans, and
/// bounded version numbers. There is no field capable of carrying user data.
public struct PrivacySafeDiagnosticSnapshot: Sendable {
  public let appMajorVersion: Int
  public let appMinorVersion: Int
  public let appPatchVersion: Int
  public let osMajorVersion: Int
  public let osMinorVersion: Int
  public let osPatchVersion: Int
  public let vaultSchemaVersion: Int
  public let endpointConfigVersion: Int
  public let vaultState: PrivacySafeVaultState
  public let syncAccountBound: Bool
  public let sessionState: PrivacySafeSessionState
  public let syncPersistencePending: Bool
  public let uploadRecoveryPending: Bool
  public let uploadRecoveryQuarantined: Bool
  public let rollbackCheckpointAvailable: Bool
  public let remoteOutcomeUncertain: Bool
  public let unsyncedLocalChanges: Bool
  public let scanInProgress: Bool
  public let syncInProgress: Bool
  public let walletCount: PrivacySafeCountBucket
  public let exchangeCount: PrivacySafeCountBucket
  public let latestHoldingCount: PrivacySafeCountBucket

  public init(
    appMajorVersion: Int,
    appMinorVersion: Int,
    appPatchVersion: Int,
    osMajorVersion: Int,
    osMinorVersion: Int,
    osPatchVersion: Int,
    vaultSchemaVersion: Int,
    endpointConfigVersion: Int,
    vaultState: PrivacySafeVaultState,
    syncAccountBound: Bool,
    sessionState: PrivacySafeSessionState,
    syncPersistencePending: Bool,
    uploadRecoveryPending: Bool,
    uploadRecoveryQuarantined: Bool,
    rollbackCheckpointAvailable: Bool,
    remoteOutcomeUncertain: Bool,
    unsyncedLocalChanges: Bool,
    scanInProgress: Bool,
    syncInProgress: Bool,
    walletCount: PrivacySafeCountBucket,
    exchangeCount: PrivacySafeCountBucket,
    latestHoldingCount: PrivacySafeCountBucket
  ) {
    self.appMajorVersion = Self.boundedVersionComponent(appMajorVersion)
    self.appMinorVersion = Self.boundedVersionComponent(appMinorVersion)
    self.appPatchVersion = Self.boundedVersionComponent(appPatchVersion)
    self.osMajorVersion = Self.boundedVersionComponent(osMajorVersion)
    self.osMinorVersion = Self.boundedVersionComponent(osMinorVersion)
    self.osPatchVersion = Self.boundedVersionComponent(osPatchVersion)
    self.vaultSchemaVersion = Self.boundedVersionComponent(vaultSchemaVersion)
    self.endpointConfigVersion = Self.boundedVersionComponent(endpointConfigVersion)
    self.vaultState = vaultState
    self.syncAccountBound = syncAccountBound
    self.sessionState = sessionState
    self.syncPersistencePending = syncPersistencePending
    self.uploadRecoveryPending = uploadRecoveryPending
    self.uploadRecoveryQuarantined = uploadRecoveryQuarantined
    self.rollbackCheckpointAvailable = rollbackCheckpointAvailable
    self.remoteOutcomeUncertain = remoteOutcomeUncertain
    self.unsyncedLocalChanges = unsyncedLocalChanges
    self.scanInProgress = scanInProgress
    self.syncInProgress = syncInProgress
    self.walletCount = walletCount
    self.exchangeCount = exchangeCount
    self.latestHoldingCount = latestHoldingCount
  }

  private static func boundedVersionComponent(_ value: Int) -> Int {
    min(max(value, 0), 999_999)
  }
}

public struct PrivacySafeDiagnosticEvent: Equatable, Sendable {
  public let code: PrivacySafeDiagnosticCode

  public var operation: PrivacySafeDiagnosticOperation { code.operation }

  public init(code: PrivacySafeDiagnosticCode) {
    self.code = code
  }
}

/// A small process-local ring buffer. It intentionally stores neither wall
/// clock time nor free-form context, and its export is deterministic text.
public struct PrivacySafeDiagnosticLog: Sendable {
  public static let formatVersion = 1
  public static let maximumEventCount = 48
  public static let maximumReportUTF8ByteCount = 8 * 1_024

  public private(set) var events: [PrivacySafeDiagnosticEvent] = []
  public private(set) var didDropEvents = false

  public init() {}

  public mutating func record(_ code: PrivacySafeDiagnosticCode) {
    if events.count == Self.maximumEventCount {
      events.removeFirst()
      didDropEvents = true
    }
    events.append(PrivacySafeDiagnosticEvent(code: code))
  }

  public func report(snapshot: PrivacySafeDiagnosticSnapshot) -> String {
    let bool: (Bool) -> String = { $0 ? "true" : "false" }
    var lines = [
      "Address Atlas privacy-safe diagnostics",
      "format_version=\(Self.formatVersion)",
      "app_version=\(snapshot.appMajorVersion).\(snapshot.appMinorVersion).\(snapshot.appPatchVersion)",
      "os_version=\(snapshot.osMajorVersion).\(snapshot.osMinorVersion).\(snapshot.osPatchVersion)",
      "vault_schema_version=\(snapshot.vaultSchemaVersion)",
      "endpoint_config_version=\(snapshot.endpointConfigVersion)",
      "vault_state=\(snapshot.vaultState.rawValue)",
      "sync_account_bound=\(bool(snapshot.syncAccountBound))",
      "session_state=\(snapshot.sessionState.rawValue)",
      "sync_persistence_pending=\(bool(snapshot.syncPersistencePending))",
      "upload_recovery_pending=\(bool(snapshot.uploadRecoveryPending))",
      "upload_recovery_quarantined=\(bool(snapshot.uploadRecoveryQuarantined))",
      "rollback_checkpoint_available=\(bool(snapshot.rollbackCheckpointAvailable))",
      "remote_outcome_uncertain=\(bool(snapshot.remoteOutcomeUncertain))",
      "unsynced_local_changes=\(bool(snapshot.unsyncedLocalChanges))",
      "scan_in_progress=\(bool(snapshot.scanInProgress))",
      "sync_in_progress=\(bool(snapshot.syncInProgress))",
      "wallet_count_bucket=\(snapshot.walletCount.rawValue)",
      "exchange_count_bucket=\(snapshot.exchangeCount.rawValue)",
      "latest_holding_count_bucket=\(snapshot.latestHoldingCount.rawValue)",
      "event_history_truncated=\(bool(didDropEvents))",
      "event_count=\(events.count)",
    ]
    lines.append(contentsOf: events.enumerated().map { index, event in
      "event.\(index + 1)=\(event.operation.rawValue):\(event.code.rawValue)"
    })
    let report = lines.joined(separator: "\n") + "\n"
    precondition(report.utf8.count <= Self.maximumReportUTF8ByteCount)
    return report
  }
}
