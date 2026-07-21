import AddressAtlasCore
import Foundation

@MainActor
extension AppState {
  func recordDiagnosticFailure(_ code: PrivacySafeDiagnosticCode) {
    privacySafeDiagnosticLog.record(code)
  }

  func privacySafeDiagnosticsReport() -> String {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    let appVersionComponents = AppState.currentAppVersion.split(separator: ".")
    let appMajorVersion = appVersionComponents.first.flatMap { Int($0) } ?? 0
    let appMinorVersion = appVersionComponents.dropFirst().first.flatMap { Int($0) } ?? 0
    let appPatchVersion = appVersionComponents.dropFirst(2).first.flatMap { Int($0) } ?? 0
    let sessionState: PrivacySafeSessionState
    if document.syncState.sessionToken.isEmpty {
      sessionState = .absent
    } else if hasUsableSyncSession() {
      sessionState = .usable
    } else {
      sessionState = .unusable
    }

    let vaultState: PrivacySafeVaultState
    if damagedVaultRecoveryAvailability != nil {
      vaultState = .recoveryRequired
    } else {
      vaultState = isUnlocked ? .unlocked : .locked
    }

    let snapshot = PrivacySafeDiagnosticSnapshot(
      appMajorVersion: appMajorVersion,
      appMinorVersion: appMinorVersion,
      appPatchVersion: appPatchVersion,
      osMajorVersion: os.majorVersion,
      osMinorVersion: os.minorVersion,
      osPatchVersion: os.patchVersion,
      vaultSchemaVersion: document.schemaVersion,
      endpointConfigVersion: endpointConfig.configVersion,
      vaultState: vaultState,
      syncAccountBound:
        document.syncState.accountId.flatMap(SyncAccountIdentifier.normalized) != nil,
      sessionState: sessionState,
      syncPersistencePending: syncPersistencePending,
      uploadRecoveryPending: pendingVaultUpload != nil,
      uploadRecoveryQuarantined: quarantinedPendingVaultUpload != nil,
      rollbackCheckpointAvailable: hasVaultRollbackCheckpoint,
      remoteOutcomeUncertain: document.syncState.remoteOutcomeUncertain,
      unsyncedLocalChanges: hasUnsyncedLocalChanges,
      scanInProgress: scanning,
      syncInProgress: syncing,
      walletCount: PrivacySafeCountBucket(count: document.wallets.count),
      exchangeCount: PrivacySafeCountBucket(count: document.exchangeConnections.count),
      latestHoldingCount: PrivacySafeCountBucket(count: latestScan?.holdings.count ?? 0)
    )
    return privacySafeDiagnosticLog.report(snapshot: snapshot)
  }
}
