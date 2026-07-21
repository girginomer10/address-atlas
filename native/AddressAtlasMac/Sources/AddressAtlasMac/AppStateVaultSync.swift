import AddressAtlasCore
import Foundation

@MainActor
extension AppState {
  func uploadEncryptedVault(expectedServerURL: URL) async {
    guard acceptsNewOperations else { return }
    guard !scanning else {
      error = "Cancel or finish the active scan before syncing."
      return
    }
    guard let vaultKey, let persistence else {
      error = "Vault must be unlocked before syncing."
      return
    }
    guard let serverURL = AppState.validatedSyncURL(document.syncState.serverURL),
      hasUsableSyncSession()
    else {
      error = "Sign in with passkey before syncing."
      return
    }
    guard expectedServerURL == serverURL else {
      error = "The sync server selection changed. Review the saved server before syncing."
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
    guard beginSyncActivity(.uploadingVault) else {
      notice = "A sync operation is already running."
      return
    }
    defer { finishSyncActivity(.uploadingVault) }
    guard await flushWalletLabelDraftsBeforeRemoteOperation() else { return }
    let startingRevision = documentRevision
    let baseDocument = document
    var projectedRemovedScanRunCount = 0
    do {
      guard await refreshEndpointConfig(silent: true) else {
        throw SyncClientError.requestFailed(
          503,
          "The sync server's compatibility policy could not be verified. Try again when endpoint config is available."
        )
      }
      guard !endpointConfigTrustDurabilityDegraded else {
        throw SyncClientError.requestFailed(
          503,
          "The endpoint policy is applied, but its local trust record is not crash-durable. Refresh endpoints before syncing."
        )
      }
      guard isAppVersionSupported else {
        throw SyncClientError.requestFailed(
          426, "This app version is no longer supported. Update Address Atlas to keep syncing.")
      }
      guard documentRevision == startingRevision else {
        throw PendingVaultUploadError.localDocumentChanged
      }
      let client = ZeroKnowledgeSyncClient(baseURL: serverURL, http: httpClient)
      await client.setBearerToken(baseDocument.syncState.sessionToken)
      let baseContentChecksum = try await persistence.contentChecksum(for: baseDocument)
      var uploadDocument = baseDocument
      var expectedRemoteVersion: Int?
      var expectedRemoteChecksum: String?
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
        expectedRemoteVersion = remote.version
        expectedRemoteChecksum = remote.checksum
      } else if uploadDocument.syncState.latestRemoteVersion > 0 {
        throw SyncClientError.requestFailed(
          409,
          "The remote vault is missing after a previous sync. Download or recover the remote account before uploading again."
        )
      }
      let nextVersion = try syncCodec.nextVersion(
        after: uploadDocument.syncState.latestRemoteVersion)
      let prepared = try await persistence.prepareForSyncPersistence(
        uploadDocument,
        projectedVersion: nextVersion
      )
      uploadDocument = prepared.document
      // The wire snapshot may need less history than the local vault can retain.
      // Do not make that destructive projection durable before the remote side
      // effect: a timeout or rejected upload must leave every local snapshot
      // intact. Once the server confirms the commit, this exact projection
      // becomes the authoritative local candidate below.
      projectedRemovedScanRunCount = prepared.removedScanRunCount
      let sealed = try await persistence.sealSyncSnapshot(
        document: uploadDocument,
        vaultKey: vaultKey,
        version: nextVersion,
        accountId: accountId
      )
      let snapshot = sealed.snapshot
      uploadDocument.syncState.markSynced(
        version: snapshot.version,
        snapshotChecksum: snapshot.checksum,
        contentChecksum: sealed.contentChecksum
      )
      let pendingUpload = PendingVaultUpload(
        serverOrigin: serverURL.absoluteString,
        accountId: accountId,
        expectedRemoteVersion: expectedRemoteVersion,
        expectedRemoteChecksum: expectedRemoteChecksum,
        snapshot: snapshot,
        postCommitDocument: uploadDocument,
        baseLocalContentChecksum: baseContentChecksum,
        removedScanRunCount: projectedRemovedScanRunCount
      )
      guard documentRevision == startingRevision else {
        throw PendingVaultUploadError.localDocumentChanged
      }
      // Durability precedes the remote side effect. If this write fails, no
      // PUT is attempted and the full local document remains authoritative.
      try await persistence.savePendingVaultUpload(pendingUpload, vaultKey: vaultKey)
      let durablePendingUpload = try await requiredPendingVaultUpload(
        persistence: persistence,
        vaultKey: vaultKey
      )
      pendingVaultUpload = durablePendingUpload
      pendingVaultUploadHasRemoteConflict = false
      syncPersistencePending = true
      let stagedHook = pendingUploadStagedHook
      pendingUploadStagedHook = nil
      stagedHook?()
      guard documentRevision == startingRevision else {
        try await persistence.cancelPendingVaultUploadBeforeUpload(
          durablePendingUpload,
          vaultKey: vaultKey
        )
        pendingVaultUpload = nil
        syncPersistencePending = pendingSyncPersistence != nil
        throw PendingVaultUploadError.localDocumentChanged
      }
      try await client.upload(snapshot: durablePendingUpload.snapshot)
      try await completePendingVaultUpload(
        durablePendingUpload,
        expectedDocumentRevision: startingRevision
      )
      notice =
        (hasUnsyncedLocalChanges
          ? "Encrypted vault uploaded. Newer local changes were preserved and still need upload."
          : "Encrypted vault uploaded.")
        + pruningNoticeSuffix(hasUnsyncedLocalChanges ? 0 : projectedRemovedScanRunCount)
    } catch {
      recordDiagnosticFailure(.syncUploadFailed)
      if pendingVaultUpload != nil || quarantinedPendingVaultUpload != nil {
        presentPendingVaultUploadError(error)
      } else {
        await handleSyncError(error)
      }
    }
  }

  func recoverPendingVaultUpload() async {
    guard acceptsNewOperations else { return }
    guard let pendingUpload = pendingVaultUpload else { return }
    guard let persistence, let vaultKey else {
      syncPersistencePending = true
      error = "Unlock the vault before recovering the interrupted upload."
      return
    }
    guard !syncing else {
      notice = "A sync operation is already running."
      return
    }
    guard
      let serverURL = AppState.validatedSyncURL(document.syncState.serverURL),
      serverURL.absoluteString == pendingUpload.serverOrigin,
      document.syncState.accountId.flatMap(SyncAccountIdentifier.normalized)
        == pendingUpload.accountId,
      SyncSessionToken.isUsable(
        document.syncState.sessionToken,
        forAccountId: pendingUpload.accountId
      )
    else {
      syncPersistencePending = true
      error =
        "The interrupted upload is bound to a different or expired sync session. Sign in to the same account before retrying recovery."
      return
    }

    guard beginSyncActivity(.recoveringUpload) else {
      notice = "A sync operation is already running."
      return
    }
    defer { finishSyncActivity(.recoveringUpload) }
    let startingRevision = documentRevision
    do {
      // Recovery can run automatically immediately after unlock. It must pass
      // the same current compatibility and durable-trust gates as a new upload
      // before replaying any authenticated GET or PUT.
      guard await refreshEndpointConfig(silent: true) else {
        throw SyncClientError.requestFailed(
          503,
          "The sync server's compatibility policy could not be verified. Try again when endpoint config is available."
        )
      }
      guard !endpointConfigTrustDurabilityDegraded else {
        throw SyncClientError.requestFailed(
          503,
          "The endpoint policy is applied, but its local trust record is not crash-durable. Refresh endpoints before syncing."
        )
      }
      guard isAppVersionSupported else {
        throw SyncClientError.requestFailed(
          426, "This app version is no longer supported. Update Address Atlas to keep syncing.")
      }
      let durablePendingUpload = try await requiredPendingVaultUpload(
        persistence: persistence,
        vaultKey: vaultKey
      )
      guard durablePendingUpload == pendingUpload else {
        throw PendingVaultUploadError.operationMismatch
      }
      guard
        try await persistence.contentChecksum(for: document)
          == pendingUpload.baseLocalContentChecksum
      else {
        throw PendingVaultUploadError.localDocumentChanged
      }
      let client = ZeroKnowledgeSyncClient(baseURL: serverURL, http: httpClient)
      await client.setBearerToken(document.syncState.sessionToken)
      let remote = try await client.latestVault()
      if let remote {
        try await persistence.validateRemoteSnapshot(remote)
      }

      if remote.map({ Self.sameUploadedSnapshot($0, pendingUpload.snapshot) }) == true {
        // The original PUT committed and only its response was lost.
      } else if Self.remoteMatchesPendingPredecessor(remote, pendingUpload: pendingUpload) {
        // Replay the exact envelope/nonce/checksum. The server treats this
        // byte-identical request idempotently if the first response was merely
        // delayed rather than lost.
        try await client.upload(snapshot: pendingUpload.snapshot)
      } else {
        throw PendingVaultUploadError.remoteConflict
      }

      try await completePendingVaultUpload(
        pendingUpload,
        expectedDocumentRevision: startingRevision
      )
      notice =
        (hasUnsyncedLocalChanges
          ? "Interrupted upload recovered. Newer local changes were preserved and still need upload."
          : "Interrupted encrypted vault upload recovered.")
        + pruningNoticeSuffix(
          hasUnsyncedLocalChanges ? 0 : pendingUpload.removedScanRunCount
        )
      error = ""
    } catch {
      recordDiagnosticFailure(.syncUploadRecoveryFailed)
      presentPendingVaultUploadError(error)
    }
  }

  private func completePendingVaultUpload(
    _ pendingUpload: PendingVaultUpload,
    expectedDocumentRevision: UInt64
  ) async throws {
    guard let persistence, let vaultKey, expectedDocumentRevision == documentRevision else {
      throw PendingVaultUploadError.localDocumentChanged
    }
    let durable = try await persistence.completePendingVaultUpload(
      pendingUpload,
      currentDocument: document,
      vaultKey: vaultKey,
      localSessionToken: document.syncState.sessionToken
    )
    let completionHook = pendingUploadCompletedPersistenceHook
    pendingUploadCompletedPersistenceHook = nil
    completionHook?()
    if expectedDocumentRevision != documentRevision {
      // The remote commit and atomic SQLite completion are already durable.
      // Preserve any re-entrant user-content edit as a new dirty local version
      // instead of either overwriting it or pretending the deleted journal can
      // still be replayed.
      var merged = document
      merged.syncState = durable.document.syncState
      pendingVaultUpload = nil
      pendingVaultUploadHasRemoteConflict = false
      do {
        let mergedDurable = try await persistence.saveExactly(merged)
        document = mergedDurable.document
        documentRevision &+= 1
        hasUnsyncedLocalChanges = mergedDurable.hasLocalChanges
        lastSaveRemovedScanRunCount = 0
        syncPersistencePending = pendingSyncPersistence != nil
        return
      } catch {
        requirePendingSyncPersistence(
          merged,
          projectedSyncVersion: durable.document.syncState.latestRemoteVersion,
          saveExactly: true
        )
        throw error
      }
    }
    document = durable.document
    documentRevision &+= 1
    hasUnsyncedLocalChanges = durable.hasLocalChanges
    lastSaveRemovedScanRunCount = durable.removedScanRunCount
    pendingVaultUpload = nil
    pendingVaultUploadHasRemoteConflict = false
    syncPersistencePending = pendingSyncPersistence != nil
  }

  private static func sameUploadedSnapshot(
    _ remote: RemoteVaultSnapshot,
    _ pending: RemoteVaultSnapshot
  ) -> Bool {
    remote.version == pending.version
      && remote.byteSize == pending.byteSize
      && remote.checksum == pending.checksum
      && remote.envelope == pending.envelope
  }

  private static func remoteMatchesPendingPredecessor(
    _ remote: RemoteVaultSnapshot?,
    pendingUpload: PendingVaultUpload
  ) -> Bool {
    switch (
      remote,
      pendingUpload.expectedRemoteVersion,
      pendingUpload.expectedRemoteChecksum
    ) {
    case (nil, nil, nil):
      return true
    case (let remote?, let version?, let checksum?):
      return remote.version == version && remote.checksum == checksum
    default:
      return false
    }
  }

  private func presentPendingVaultUploadError(_ failure: Error) {
    syncPersistencePending = true
    if quarantinedPendingVaultUpload != nil {
      pendingVaultUpload = nil
      pendingVaultUploadHasRemoteConflict = false
      error =
        "The encrypted upload recovery record is damaged and has been quarantined. Your full local vault remains available read-only. Open Sync to explicitly discard only that recovery record."
      return
    }
    if let uploadError = failure as? PendingVaultUploadError,
      uploadError == .remoteConflict
    {
      pendingVaultUploadHasRemoteConflict = true
    }
    let detail = UserFacingErrorMapper.message(for: failure) ?? "Upload recovery was interrupted."
    error =
      "The encrypted vault upload remains safely pending. Retry recovery before editing the vault: \(detail)"
  }

  private func requiredPendingVaultUpload(
    persistence: VaultPersistenceCoordinator,
    vaultKey: Data
  ) async throws -> PendingVaultUpload {
    switch try await persistence.inspectPendingVaultUpload(vaultKey: vaultKey) {
    case .none:
      throw PendingVaultUploadError.operationMissing
    case .pending(let upload, _):
      return upload
    case .quarantined(let identity):
      pendingVaultUpload = nil
      quarantinedPendingVaultUpload = identity
      pendingVaultUploadHasRemoteConflict = false
      syncPersistencePending = true
      throw PendingVaultUploadError.quarantinedOperation
    }
  }

  func abandonPendingVaultUpload(expectedServerURL: URL) async {
    guard acceptsNewOperations else { return }
    guard let pendingUpload = pendingVaultUpload, let persistence, let vaultKey else {
      error = "No interrupted encrypted vault upload is available to stop."
      return
    }
    guard
      let serverURL = AppState.validatedSyncURL(document.syncState.serverURL),
      serverURL == expectedServerURL,
      serverURL.absoluteString == pendingUpload.serverOrigin
    else {
      error = "The saved sync server changed. Upload recovery was not modified."
      return
    }
    guard !syncing, !isPersisting, !scanning else {
      error = "Wait for the active vault operation before stopping upload recovery."
      return
    }
    guard beginSyncActivity(.stoppingUploadRecovery) else {
      error = "Wait for the active vault operation before stopping upload recovery."
      return
    }
    defer { finishSyncActivity(.stoppingUploadRecovery) }
    do {
      let durable = try await persistence.abandonPendingVaultUpload(
        pendingUpload,
        currentDocument: document,
        vaultKey: vaultKey
      )
      document = durable.document
      documentRevision &+= 1
      hasUnsyncedLocalChanges = durable.hasLocalChanges
      pendingVaultUpload = nil
      pendingVaultUploadHasRemoteConflict = false
      syncPersistencePending = pendingSyncPersistence != nil
      notice =
        "Upload recovery stopped. The full local vault was kept. Portfolio exports omit credentials but include identifying addresses, labels, balances, and history; they are not backups. A destructive remote download will first create an automatic encrypted rollback point."
      error = ""
    } catch {
      recordDiagnosticFailure(.syncUploadRecoveryFailed)
      presentPendingVaultUploadError(error)
    }
  }

  /// Delete only an exact opaque corrupt journal after explicit confirmation.
  /// The primary document is preserved transactionally and marked remote-dirty
  /// because the interrupted PUT's server outcome can no longer be determined.
  func discardQuarantinedPendingVaultUpload() async {
    guard acceptsNewOperations else { return }
    guard let quarantined = quarantinedPendingVaultUpload, let persistence else {
      error = "No quarantined encrypted upload recovery record is available to discard."
      return
    }
    guard !syncing, !isPersisting, !scanning, !isValidatingExchangeCredentials else {
      error = "Wait for the active vault operation before discarding the recovery record."
      return
    }
    guard beginSyncActivity(.stoppingUploadRecovery) else {
      error = "Wait for the active vault operation before discarding the recovery record."
      return
    }
    defer { finishSyncActivity(.stoppingUploadRecovery) }
    do {
      let durable = try await persistence.discardQuarantinedPendingVaultUpload(quarantined)
      document = durable.document
      documentRevision &+= 1
      hasUnsyncedLocalChanges = durable.hasLocalChanges
      quarantinedPendingVaultUpload = nil
      pendingVaultUploadHasRemoteConflict = false
      syncPersistencePending = pendingSyncPersistence != nil || pendingVaultUpload != nil
      notice =
        "The damaged upload recovery record was discarded. The full local vault was kept and marked as needing reconciliation because the remote outcome is unknown."
      error = ""
    } catch {
      recordDiagnosticFailure(.syncUploadRecoveryFailed)
      syncPersistencePending = true
      let detail =
        UserFacingErrorMapper.message(for: error)
        ?? "The encrypted recovery row changed or could not be removed safely."
      self.error = "The quarantined recovery record was not changed: \(detail)"
    }
  }

  func downloadEncryptedVault(
    discardingLocalChanges: Bool = false,
    expectedServerURL: URL
  ) async {
    guard acceptsNewOperations else { return }
    guard !scanning else {
      error = "Cancel or finish the active scan before syncing."
      return
    }
    guard let vaultKey, let persistence else {
      error = "Vault must be unlocked before syncing."
      return
    }
    guard let serverURL = AppState.validatedSyncURL(document.syncState.serverURL),
      hasUsableSyncSession()
    else {
      error = "Sign in with passkey before syncing."
      return
    }
    guard expectedServerURL == serverURL else {
      error = "The sync server selection changed. Review the saved server before syncing."
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
    let discardedWalletLabelDrafts = discardingLocalChanges ? walletLabelDrafts : [:]
    var discardAcceptedByRemoteStateMachine = false
    guard beginSyncActivity(.downloadingVault) else {
      notice = "A sync operation is already running."
      return
    }
    defer {
      if discardingLocalChanges, !discardAcceptedByRemoteStateMachine {
        for (id, draft) in discardedWalletLabelDrafts where walletLabelDrafts[id] == nil {
          storeWalletLabelDraft(draft, for: id)
        }
      }
      finishSyncActivity(.downloadingVault)
    }
    if discardingLocalChanges {
      // Stage drafts out of the active UI state while the remote candidate is
      // evaluated. The defer restores them on an early failure; once remote
      // adoption is durable or pending, they stay discarded and cannot be
      // reapplied by a later quit.
      clearWalletLabelDrafts()
    } else {
      guard await flushWalletLabelDraftsBeforeRemoteOperation() else { return }
    }
    let startingRevision = documentRevision
    let baseDocument = document
    let baseHasUnsyncedLocalChanges = hasUnsyncedLocalChanges
    var removedScanRunCount = 0
    do {
      guard await refreshEndpointConfig(silent: true) else {
        throw SyncClientError.requestFailed(
          503,
          "The sync server's compatibility policy could not be verified. Try again when endpoint config is available."
        )
      }
      guard !endpointConfigTrustDurabilityDegraded else {
        throw SyncClientError.requestFailed(
          503,
          "The endpoint policy is applied, but its local trust record is not crash-durable. Refresh endpoints before syncing."
        )
      }
      guard isAppVersionSupported else {
        throw SyncClientError.requestFailed(
          426, "This app version is no longer supported. Update Address Atlas to keep syncing.")
      }
      guard documentRevision == startingRevision else {
        throw PendingVaultUploadError.localDocumentChanged
      }
      let baseContentChecksum = try await persistence.contentChecksum(for: baseDocument)
      if baseDocument.syncState.remoteOutcomeUncertain, !discardingLocalChanges {
        error =
          "The last upload outcome is unknown. Confirm the dedicated reconcile download in Sync before replacing local content."
        return
      }
      if baseHasUnsyncedLocalChanges, !discardingLocalChanges {
        error =
          "Local changes are not confirmed on the server. Upload them first, or explicitly discard them before downloading."
        return
      }
      let client = ZeroKnowledgeSyncClient(baseURL: serverURL, http: httpClient)
      await client.setBearerToken(baseDocument.syncState.sessionToken)
      guard let snapshot = try await client.latestVault() else {
        notice = "No remote vault snapshot yet."
        return
      }
      // Refuse a server snapshot older than the last version we synced: the
      // content is end-to-end encrypted (the server can't forge it), but it
      // could replay a stale-but-authentic snapshot to roll back local data.
      guard snapshot.version >= baseDocument.syncState.latestRemoteVersion else {
        error = "Remote vault is older than your last sync (possible rollback). Download aborted."
        return
      }
      if snapshot.version == baseDocument.syncState.latestRemoteVersion,
        let lastChecksum = baseDocument.syncState.lastChecksum,
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
      guard
        opened.syncState.connect(
          accountId: accountId,
          serverURL: baseDocument.syncState.serverURL,
          sessionToken: baseDocument.syncState.sessionToken,
          at: sessionDateProvider()
        )
      else {
        // The GET was authorized when it began, but a short-lived bearer may
        // expire while a large snapshot downloads and decrypts. Never publish
        // a remote document with an empty local authority binding; fail closed
        // before creating the rollback point or replacing local content.
        throw SyncClientError.authenticationRequired(
          "The sync session expired while downloading the encrypted vault."
        )
      }
      opened = try await persistence.markingSynced(opened, snapshot: snapshot)

      // The authenticated remote candidate is safe to decode, but replacing
      // local state is still destructive. Persist and cryptographically
      // reopen a full-fidelity local rollback point before either the direct
      // save or legacy-upgrade state machine can adopt the remote document.
      _ = try await persistence.saveRollbackCheckpoint(baseDocument)
      hasVaultRollbackCheckpoint = true
      guard documentRevision == startingRevision else {
        throw PendingVaultUploadError.localDocumentChanged
      }

      if result.requiresV2Upgrade {
        let downloadedLegacy = opened
        do {
          let upgradeVersion = try syncCodec.nextVersion(after: snapshot.version)
          let prepared = try await persistence.prepareForSyncPersistence(
            opened,
            projectedVersion: upgradeVersion
          )
          opened = prepared.document
          removedScanRunCount += prepared.removedScanRunCount
          let sealedUpgrade = try await persistence.sealSyncSnapshot(
            document: opened,
            vaultKey: vaultKey,
            version: upgradeVersion,
            accountId: accountId
          )
          opened.syncState.markSynced(
            version: sealedUpgrade.snapshot.version,
            snapshotChecksum: sealedUpgrade.snapshot.checksum,
            contentChecksum: sealedUpgrade.contentChecksum
          )
          let pendingUpload = PendingVaultUpload(
            serverOrigin: serverURL.absoluteString,
            accountId: accountId,
            expectedRemoteVersion: snapshot.version,
            expectedRemoteChecksum: snapshot.checksum,
            snapshot: sealedUpgrade.snapshot,
            postCommitDocument: opened,
            baseLocalContentChecksum: baseContentChecksum,
            removedScanRunCount: removedScanRunCount
          )
          guard documentRevision == startingRevision else {
            throw PendingVaultUploadError.localDocumentChanged
          }
          try await persistence.savePendingVaultUpload(pendingUpload, vaultKey: vaultKey)
          // From this point the explicit discard is represented by a durable,
          // replayable remote-adoption operation. Do not resurrect UI drafts
          // even if the network response is lost.
          discardAcceptedByRemoteStateMachine = true
          let durablePendingUpload = try await requiredPendingVaultUpload(
            persistence: persistence,
            vaultKey: vaultKey
          )
          pendingVaultUpload = durablePendingUpload
          pendingVaultUploadHasRemoteConflict = false
          syncPersistencePending = true
          let stagedHook = pendingUploadStagedHook
          pendingUploadStagedHook = nil
          stagedHook?()
          guard documentRevision == startingRevision else {
            try await persistence.cancelPendingVaultUploadBeforeUpload(
              durablePendingUpload,
              vaultKey: vaultKey
            )
            pendingVaultUpload = nil
            pendingVaultUploadHasRemoteConflict = false
            syncPersistencePending = pendingSyncPersistence != nil
            discardAcceptedByRemoteStateMachine = false
            throw PendingVaultUploadError.localDocumentChanged
          }
          try await client.upload(snapshot: durablePendingUpload.snapshot)
          try await completePendingVaultUpload(
            durablePendingUpload,
            expectedDocumentRevision: startingRevision
          )
          notice =
            (hasUnsyncedLocalChanges
              ? "Encrypted vault upgraded to sync format v2. Newer local changes were preserved and still need upload."
              : "Encrypted vault downloaded and upgraded to protected sync format v2.")
            + pruningNoticeSuffix(hasUnsyncedLocalChanges ? 0 : removedScanRunCount)
          error = ""
          return
        } catch {
          if error as? PendingVaultUploadError == .localDocumentChanged {
            throw error
          }
          if pendingVaultUpload != nil || quarantinedPendingVaultUpload != nil { throw error }
          guard
            await save(
              downloadedLegacy,
              projectedSyncVersion: snapshot.version,
              saveExactly: true
            )
          else {
            requirePendingSyncPersistence(
              downloadedLegacy,
              projectedSyncVersion: snapshot.version,
              saveExactly: true
            )
            discardAcceptedByRemoteStateMachine = true
            throw SyncClientError.requestFailed(
              500,
              "The legacy vault downloaded, but its local persistence is pending before the v2 upgrade can be retried."
            )
          }
          discardAcceptedByRemoteStateMachine = true
          removedScanRunCount += lastSaveRemovedScanRunCount
          throw error
        }
      }
      guard
        await save(
          opened,
          projectedSyncVersion: snapshot.version,
          saveExactly: true
        )
      else {
        let persistenceError = self.error
        requirePendingSyncPersistence(
          opened,
          projectedSyncVersion: snapshot.version,
          saveExactly: true
        )
        discardAcceptedByRemoteStateMachine = true
        self.error =
          "The remote vault was opened, but its local persistence is pending. Keep the app open and use Retry local save after fixing storage: \(persistenceError)"
          + pruningNoticeSuffix(removedScanRunCount)
        return
      }
      discardAcceptedByRemoteStateMachine = true
      removedScanRunCount += lastSaveRemovedScanRunCount
      notice = "Encrypted vault downloaded." + pruningNoticeSuffix(removedScanRunCount)
    } catch {
      recordDiagnosticFailure(.syncDownloadFailed)
      if pendingVaultUpload != nil || quarantinedPendingVaultUpload != nil {
        presentPendingVaultUploadError(error)
      } else {
        await handleSyncError(error, removedScanRunCount: removedScanRunCount)
      }
    }
  }

  func restoreVaultRollbackCheckpoint() async {
    guard acceptsNewOperations else { return }
    guard hasVaultRollbackCheckpoint, let persistence else {
      error = "No local rollback checkpoint is available."
      return
    }
    guard !syncPersistencePending, pendingSyncPersistence == nil, pendingVaultUpload == nil else {
      error = "Finish the pending sync recovery before restoring the previous local vault."
      return
    }
    guard !syncing, !scanning, !isPersisting, !isValidatingExchangeCredentials else {
      error = "Wait for the active vault operation before restoring the previous local vault."
      return
    }
    guard beginSyncActivity(.restoringRollbackCheckpoint) else {
      error = "Wait for the active vault operation before restoring the previous local vault."
      return
    }
    defer { finishSyncActivity(.restoringRollbackCheckpoint) }
    guard await flushWalletLabelDraftsBeforeRemoteOperation() else { return }
    do {
      let restored = try await persistence.restoreRollbackCheckpoint()
      document = normalizedLoadedDocument(restored.document)
      documentRevision &+= 1
      hasUnsyncedLocalChanges = restored.hasLocalChanges
      hasVaultRollbackCheckpoint = false
      pendingSyncPersistence = nil
      pendingVaultUpload = nil
      quarantinedPendingVaultUpload = nil
      pendingVaultUploadHasRemoteConflict = false
      syncPersistencePending = false
      notice =
        "The previous encrypted local vault content was restored. The current sync account and remote baseline were kept; review the changes before uploading."
      error = ""
    } catch {
      recordDiagnosticFailure(.recoveryRollbackFailed)
      presentUserFacingError(error)
    }
  }

  func recoverDamagedVaultFromRollbackCheckpoint() async {
    guard acceptsNewOperations else { return }
    guard damagedVaultRecoveryAvailability == .validatedRollbackCheckpoint,
      let key = damagedVaultRecoveryKey
    else {
      error = "No validated rollback point is available for the damaged vault."
      return
    }
    guard !isUnlocking else { return }
    isUnlocking = true
    defer { isUnlocking = false }
    do {
      guard try keyStore.loadVaultKey() == key else {
        throw UserFacingAppError(
          message:
            "The Keychain vault key changed during recovery. Nothing was replaced; restart Address Atlas before trying again."
        )
      }
      let sqlite = try EncryptedSQLiteVaultStore(
        path: appSupportDirectory.appending(path: "vault.sqlite"),
        vaultKey: key,
        crypto: crypto
      )
      let coordinator = VaultPersistenceCoordinator(
        store: sqlite,
        syncSnapshotByteLimit: syncSnapshotByteLimit
      )
      let restored = try await coordinator.recoverDamagedPrimaryFromRollbackCheckpoint()
      guard try keyStore.loadVaultKey() == key else {
        throw UserFacingAppError(
          message:
            "The rollback was restored on disk, but the Keychain vault key changed unexpectedly. Restart Address Atlas before continuing."
        )
      }
      document = normalizedLoadedDocument(restored.document)
      documentRevision &+= 1
      hasUnsyncedLocalChanges = restored.hasLocalChanges
      vaultKey = key
      persistence = coordinator
      pendingSyncPersistence = nil
      pendingVaultUpload = nil
      quarantinedPendingVaultUpload = nil
      pendingVaultUploadHasRemoteConflict = false
      syncPersistencePending = false
      hasVaultRollbackCheckpoint = false
      damagedVaultRecoveryAvailability = nil
      damagedVaultRecoveryKey = nil
      isUnlocked = true
      notice =
        "The validated automatic rollback point replaced the damaged primary vault atomically. Review the restored data and reconcile Sync before uploading."
      error = ""
    } catch {
      recordDiagnosticFailure(.recoveryRollbackFailed)
      presentUserFacingError(error)
      isUnlocked = false
    }
  }

  /// This path is intentionally user-driven and destructive only after a
  /// durable byte-for-byte quarantine exists. It never rotates the vault key
  /// and never claims that remote data was downloaded automatically.
  func quarantineDamagedVaultAndStartClean() async {
    guard acceptsNewOperations else { return }
    guard damagedVaultRecoveryAvailability != nil, let key = damagedVaultRecoveryKey else {
      error = "No damaged local vault is awaiting quarantine."
      return
    }
    guard !isUnlocking else { return }
    isUnlocking = true
    defer { isUnlocking = false }
    do {
      guard try keyStore.loadVaultKey() == key else {
        throw UserFacingAppError(
          message:
            "The Keychain vault key changed during recovery. The damaged vault was not replaced. Restart Address Atlas before trying again."
        )
      }
      let vaultURL = appSupportDirectory.appending(path: "vault.sqlite")
      let recovered = try await Task.detached {
        try DamagedVaultRecoveryService().quarantineAndCreateCleanVault(
          at: vaultURL,
          vaultKey: key
        )
      }.value

      let keyAfterRecovery = try keyStore.loadVaultKey()
      if keyAfterRecovery == nil {
        try keyStore.saveVaultKey(key)
      }
      guard try keyStore.loadVaultKey() == key else {
        throw UserFacingAppError(
          message:
            "The damaged vault is preserved in quarantine, but the same vault key could not be retained in Keychain. Restore the key before continuing."
        )
      }
      let coordinator = VaultPersistenceCoordinator(
        store: recovered.store,
        syncSnapshotByteLimit: syncSnapshotByteLimit
      )
      document = recovered.document
      documentRevision &+= 1
      hasUnsyncedLocalChanges = true
      vaultKey = key
      persistence = coordinator
      pendingSyncPersistence = nil
      pendingVaultUpload = nil
      quarantinedPendingVaultUpload = nil
      pendingVaultUploadHasRemoteConflict = false
      syncPersistencePending = false
      hasVaultRollbackCheckpoint = false
      damagedVaultRecoveryAvailability = nil
      damagedVaultRecoveryKey = nil
      isUnlocked = true
      notice =
        "The damaged database and its SQLite sidecars were preserved in the private \(recovered.quarantineDirectory.lastPathComponent) folder. A clean local vault now uses the same vault key; no remote data was downloaded. Open Sync, sign in, and download the remote vault."
      error = ""
    } catch {
      recordDiagnosticFailure(.recoveryQuarantineFailed)
      presentUserFacingError(error)
      isUnlocked = false
    }
  }

  func exportRecoveryKit(to url: URL) throws -> String {
    do {
      guard let vaultKey else {
        throw RecoveryKitError.invalidVaultKey
      }
      let recoveryCode = try recoveryKit.export(vaultKey: vaultKey, to: url)
      notice = "Recovery kit saved. Store the code separately."
      error = ""
      return recoveryCode
    } catch {
      recordDiagnosticFailure(.recoveryKitExportFailed)
      throw error
    }
  }

  func restoreRecoveryKit(from url: URL, recoveryCode: String) async {
    guard acceptsNewOperations else { return }
    if isUnlocked, quarantinedPendingVaultUpload == nil, !canMutateVault() { return }
    if isUnlocked, quarantinedPendingVaultUpload != nil,
      syncing || scanning || isPersisting || isValidatingExchangeCredentials
    {
      error = "Wait for the active vault operation before restoring the recovery kit."
      return
    }
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
      let pendingInspection = try await coordinator.inspectPendingVaultUpload(
        vaultKey: recovered.vaultKey)
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
      let normalized = normalizedLoadedDocument(recovered.document)
      let durable =
        pendingUpload != nil || quarantinedUpload != nil || normalized == recovered.document
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
      damagedVaultRecoveryAvailability = nil
      damagedVaultRecoveryKey = nil
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
          "Recovery kit restored. The full local vault is available read-only, and the damaged upload recovery record remains quarantined until you explicitly discard it in Sync."
      } else {
        notice =
          pendingUpload == nil
          ? "Recovery kit restored."
          : "Recovery kit restored. Recovering an interrupted encrypted vault upload."
        error = ""
      }
      if pendingUpload != nil {
        await recoverPendingVaultUpload()
      }
    } catch {
      recordDiagnosticFailure(.recoveryKitRestoreFailed)
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
        recordDiagnosticFailure(.storageSaveFailed)
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
