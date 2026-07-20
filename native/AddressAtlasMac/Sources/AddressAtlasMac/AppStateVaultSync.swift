import AddressAtlasCore
import Foundation

@MainActor
extension AppState {
  func uploadEncryptedVault() async {
    guard !scanning else {
      error = "Cancel or finish the active scan before syncing."
      return
    }
    guard let vaultKey, let persistence else {
      error = "Vault must be unlocked before syncing."
      return
    }
    guard let serverURL = AppState.validatedSyncURL(document.syncState.serverURL),
      !document.syncState.sessionToken.isEmpty
    else {
      error = "Sign in with passkey before syncing."
      return
    }
    guard let accountId = document.syncState.accountId.flatMap(SyncAccountIdentifier.normalized)
    else {
      error = "Sync account identity is missing. Sign in with passkey again."
      return
    }
    guard !syncPersistencePending else {
      error = "Save the pending sync state locally before starting another sync operation."
      return
    }
    guard !hasPendingAccountDeletion else {
      error = "Finish or retry the pending account deletion before syncing."
      return
    }
    guard !isPersisting else {
      error = "Wait for the current local save before syncing."
      return
    }
    guard !isValidatingExchangeCredentials else {
      error = "Wait for the exchange credential check before syncing."
      return
    }
    guard !syncing else {
      notice = "A sync operation is already running."
      return
    }
    syncing = true
    defer { syncing = false }
    var durablyRemovedScanRunCount = 0
    do {
      guard await refreshEndpointConfig(silent: true) else {
        throw SyncClientError.requestFailed(
          503,
          "The sync server's compatibility policy could not be verified. Try again when endpoint config is available."
        )
      }
      guard isAppVersionSupported else {
        throw SyncClientError.requestFailed(
          426, "This app version is no longer supported. Update Address Atlas to keep syncing.")
      }
      let client = ZeroKnowledgeSyncClient(baseURL: serverURL, http: httpClient)
      await client.setBearerToken(document.syncState.sessionToken)
      var uploadDocument = document
      if let remote = try await client.latestVault() {
        // GET is an untrusted wire boundary. Validate every field used below
        // before comparing checksums or feeding its version into arithmetic.
        try await persistence.validateRemoteSnapshot(remote)
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
        uploadDocument.syncState.latestRemoteVersion = max(
          uploadDocument.syncState.latestRemoteVersion, remote.version)
      }
      let nextVersion = try syncCodec.nextVersion(
        after: uploadDocument.syncState.latestRemoteVersion)
      let prepared = try await persistence.prepareForSyncPersistence(
        uploadDocument,
        projectedVersion: nextVersion
      )
      uploadDocument = prepared.document
      if prepared.removedScanRunCount > 0 {
        // Make the pruned candidate durable before the remote side effect, and
        // upload that exact persisted value (including its canonical timestamp).
        let durable = try await persistence.saveExactly(uploadDocument)
        uploadDocument = durable.document
        document = durable.document
        documentRevision &+= 1
        hasUnsyncedLocalChanges = durable.hasLocalChanges
        durablyRemovedScanRunCount = prepared.removedScanRunCount
      }
      let sealed = try await persistence.sealSyncSnapshot(
        document: uploadDocument,
        vaultKey: vaultKey,
        version: nextVersion,
        accountId: accountId
      )
      let snapshot = sealed.snapshot
      try await client.upload(snapshot: snapshot)
      uploadDocument.syncState.markSynced(
        version: snapshot.version,
        snapshotChecksum: snapshot.checksum,
        contentChecksum: sealed.contentChecksum
      )
      guard await save(uploadDocument, projectedSyncVersion: snapshot.version) else {
        let persistenceError = self.error
        requirePendingSyncPersistence(
          uploadDocument,
          projectedSyncVersion: snapshot.version
        )
        self.error =
          "The remote vault was uploaded, but its sync state is pending local persistence. Keep the app open and use Retry local save after fixing storage: \(persistenceError)"
          + pruningNoticeSuffix(durablyRemovedScanRunCount)
        return
      }
      let removedScanRunCount = durablyRemovedScanRunCount + lastSaveRemovedScanRunCount
      notice = "Encrypted vault uploaded." + pruningNoticeSuffix(removedScanRunCount)
    } catch {
      await handleSyncError(error, removedScanRunCount: durablyRemovedScanRunCount)
    }
  }

  func downloadEncryptedVault(discardingLocalChanges: Bool = false) async {
    guard !scanning else {
      error = "Cancel or finish the active scan before syncing."
      return
    }
    guard let vaultKey, let persistence else {
      error = "Vault must be unlocked before syncing."
      return
    }
    guard let serverURL = AppState.validatedSyncURL(document.syncState.serverURL),
      !document.syncState.sessionToken.isEmpty
    else {
      error = "Sign in with passkey before syncing."
      return
    }
    guard let accountId = document.syncState.accountId.flatMap(SyncAccountIdentifier.normalized)
    else {
      error = "Sync account identity is missing. Sign in with passkey again."
      return
    }
    guard !syncPersistencePending else {
      error = "Save the pending sync state locally before starting another sync operation."
      return
    }
    guard !hasPendingAccountDeletion else {
      error = "Finish or retry the pending account deletion before syncing."
      return
    }
    guard !isPersisting else {
      error = "Wait for the current local save before syncing."
      return
    }
    guard !isValidatingExchangeCredentials else {
      error = "Wait for the exchange credential check before syncing."
      return
    }
    guard !syncing else {
      notice = "A sync operation is already running."
      return
    }
    syncing = true
    defer { syncing = false }
    var removedScanRunCount = 0
    do {
      guard await refreshEndpointConfig(silent: true) else {
        throw SyncClientError.requestFailed(
          503,
          "The sync server's compatibility policy could not be verified. Try again when endpoint config is available."
        )
      }
      guard isAppVersionSupported else {
        throw SyncClientError.requestFailed(
          426, "This app version is no longer supported. Update Address Atlas to keep syncing.")
      }
      let startingRevision = documentRevision
      if hasUnsyncedLocalChanges, !discardingLocalChanges {
        error =
          "Local changes have not been uploaded. Upload them first, or explicitly discard them before downloading."
        return
      }
      let client = ZeroKnowledgeSyncClient(baseURL: serverURL, http: httpClient)
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
        snapshot.checksum != lastChecksum
      {
        error = "Remote vault changed without advancing its version. Download aborted."
        return
      }
      guard documentRevision == startingRevision else {
        error = "Local vault changed while downloading. Nothing was replaced; try again."
        return
      }
      let result = try await persistence.openSyncSnapshot(
        snapshot,
        vaultKey: vaultKey,
        expectedAccountId: accountId
      )
      var opened = normalizedLoadedDocument(result.document)
      opened.syncState.connect(
        accountId: accountId,
        serverURL: document.syncState.serverURL,
        sessionToken: document.syncState.sessionToken
      )
      opened = try await persistence.markingSynced(opened, snapshot: snapshot)
      var persistenceProjectionVersion = snapshot.version

      if result.requiresV2Upgrade {
        do {
          let upgradeVersion = try syncCodec.nextVersion(after: snapshot.version)
          let prepared = try await persistence.prepareForSyncPersistence(
            opened,
            projectedVersion: upgradeVersion
          )
          opened = prepared.document
          removedScanRunCount += prepared.removedScanRunCount
          let upgraded = try await persistence.sealSyncSnapshot(
            document: opened,
            vaultKey: vaultKey,
            version: upgradeVersion,
            accountId: accountId
          ).snapshot
          try await client.upload(snapshot: upgraded)
          opened = try await persistence.markingSynced(opened, snapshot: upgraded)
          persistenceProjectionVersion = upgraded.version
        } catch {
          guard await save(opened, projectedSyncVersion: persistenceProjectionVersion) else {
            requirePendingSyncPersistence(
              opened,
              projectedSyncVersion: persistenceProjectionVersion
            )
            throw SyncClientError.requestFailed(
              500,
              "The legacy vault downloaded, but its local persistence is pending before the v2 upgrade can be retried."
            )
          }
          removedScanRunCount += lastSaveRemovedScanRunCount
          throw error
        }
      }
      guard await save(opened, projectedSyncVersion: persistenceProjectionVersion) else {
        let persistenceError = self.error
        requirePendingSyncPersistence(
          opened,
          projectedSyncVersion: persistenceProjectionVersion
        )
        self.error =
          "The remote vault was opened, but its local persistence is pending. Keep the app open and use Retry local save after fixing storage: \(persistenceError)"
          + pruningNoticeSuffix(removedScanRunCount)
        return
      }
      removedScanRunCount += lastSaveRemovedScanRunCount
      let successNotice =
        result.requiresV2Upgrade
        ? "Encrypted vault downloaded and upgraded to protected sync format v2."
        : "Encrypted vault downloaded."
      notice = successNotice + pruningNoticeSuffix(removedScanRunCount)
    } catch {
      await handleSyncError(error, removedScanRunCount: removedScanRunCount)
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
      let recoveryKit = self.recoveryKit
      let crypto = self.crypto
      let keyStore = self.keyStore
      let vaultURL = appSupportDirectory.appending(path: "vault.sqlite")
      let recovered = try await Task.detached {
        try VaultRecoveryService(codec: recoveryKit, crypto: crypto).restore(
          from: url,
          recoveryCode: recoveryCode,
          vaultURL: vaultURL,
          keyStore: keyStore
        )
      }.value
      let coordinator = VaultPersistenceCoordinator(
        store: recovered.store,
        syncSnapshotByteLimit: syncSnapshotByteLimit
      )
      let normalized = normalizedLoadedDocument(recovered.document)
      let durable =
        normalized == recovered.document
        ? VaultPersistenceResult(
          document: recovered.document,
          removedScanRunCount: 0,
          hasLocalChanges: try await coordinator.hasLocalChanges(in: recovered.document)
        )
        : try await coordinator.saveExactly(normalized)
      document = durable.document
      hasUnsyncedLocalChanges = durable.hasLocalChanges
      vaultKey = recovered.vaultKey
      persistence = coordinator
      documentRevision &+= 1
      isUnlocked = true
      pendingSyncPersistence = nil
      syncPersistencePending = false
      notice = "Recovery kit restored."
      error = ""
    } catch {
      presentUserFacingError(error)
    }
  }

  func handleSyncError(_ error: Error, removedScanRunCount: Int = 0) async {
    if case SyncClientError.authenticationRequired = error {
      document.syncState.sessionToken = ""
      do {
        guard let persistence else {
          requirePendingSyncPersistence(
            document,
            projectedSyncVersion: nil,
            saveExactly: true
          )
          self.error =
            "Sync session expired, but the cleared session is pending local persistence. Unlock the vault and retry the local save."
            + pruningNoticeSuffix(removedScanRunCount)
          return
        }
        // The session token is excluded from remote snapshots, so clearing it
        // must remain locally persistable even if the existing synced payload
        // is currently above the wire limit.
        let durable = try await persistence.saveExactly(document)
        document = durable.document
        documentRevision &+= 1
        hasUnsyncedLocalChanges = durable.hasLocalChanges
      } catch {
        requirePendingSyncPersistence(
          document,
          projectedSyncVersion: nil,
          saveExactly: true
        )
        let detail =
          UserFacingErrorMapper.message(for: error)
          ?? "The local save was cancelled."
        self.error =
          "Sync session expired, but the cleared session is pending local persistence. Use Retry local save after fixing storage: \(detail)"
          + pruningNoticeSuffix(removedScanRunCount)
        return
      }
      self.error =
        "Sync session expired. Sign in with passkey again."
        + pruningNoticeSuffix(removedScanRunCount)
      return
    }
    self.error =
      (UserFacingErrorMapper.message(for: error) ?? "Operation cancelled.")
      + pruningNoticeSuffix(removedScanRunCount)
  }

}
