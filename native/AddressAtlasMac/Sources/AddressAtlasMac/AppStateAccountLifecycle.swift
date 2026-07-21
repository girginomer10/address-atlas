import AddressAtlasCore
import Foundation

@MainActor
extension AppState {
  func createPasskeyAccount(serverURL: String) async {
    await authenticateWithPasskey(serverURL: serverURL, mode: .register)
  }

  func signInWithPasskey(serverURL: String) async {
    await authenticateWithPasskey(serverURL: serverURL, mode: .authenticate)
  }

  /// Revoke this device's server-side bearer grant, then durably remove the
  /// local copy. A completed remote revocation is never rolled back in memory
  /// merely because local persistence subsequently fails.
  func revokeCurrentSyncSession(expectedServerURL: URL) async {
    guard canMutateVault() else { return }
    guard persistence != nil, isUnlocked else {
      error = "Unlock the vault before revoking the sync session."
      return
    }
    guard let serverURL = AppState.validatedSyncURL(document.syncState.serverURL),
      !document.syncState.sessionToken.isEmpty
    else {
      error = "Sign in with passkey before revoking the sync session."
      return
    }
    guard expectedServerURL == serverURL else {
      error =
        "The sync server selection changed. Review the saved server before revoking the session."
      return
    }
    guard beginSyncActivity(.revokingSession) else {
      notice = "A sync operation is already running."
      return
    }
    defer { finishSyncActivity(.revokingSession) }
    guard await flushWalletLabelDraftsBeforeRemoteOperation() else { return }
    do {
      let client = ZeroKnowledgeSyncClient(baseURL: serverURL, http: httpClient)
      await client.setBearerToken(document.syncState.sessionToken)
      try await client.revokeCurrentSession()
      var disconnected = document
      disconnected.syncState.clearSession()
      guard await save(disconnected, projectedSyncVersion: nil) else {
        let persistenceError = error
        requirePendingSyncPersistence(disconnected, projectedSyncVersion: nil)
        error =
          "The server session was revoked, but removing its local token is pending persistence. Use Retry local save after fixing storage: \(persistenceError)"
        return
      }
      notice = "This Mac's sync session was revoked."
      error = ""
    } catch {
      await handleSyncError(error)
    }
  }

  /// Delete the authenticated server account while preserving the encrypted
  /// local vault. The server call commits first; afterward account/session and
  /// remote-baseline metadata are cleared and persisted locally.
  func deleteSyncAccount(expectedServerURL: URL) async {
    guard canMutateVault(allowPendingAccountDeletion: true) else { return }
    guard persistence != nil, isUnlocked else {
      error = "Unlock the vault before deleting the sync account."
      return
    }
    guard let serverURL = AppState.validatedSyncURL(document.syncState.serverURL),
      let connectedAccountId = document.syncState.accountId.flatMap(
        SyncAccountIdentifier.normalized
      )
    else {
      error = "Connect a passkey account before deleting the sync account."
      return
    }
    guard expectedServerURL == serverURL else {
      error =
        "The sync server selection changed. Review the saved server before deleting the account."
      return
    }
    guard beginSyncActivity(.deletingAccount) else {
      notice = "A sync operation is already running."
      return
    }
    defer { finishSyncActivity(.deletingAccount) }
    guard await flushWalletLabelDraftsBeforeRemoteOperation() else { return }
    do {
      let client = ZeroKnowledgeSyncClient(baseURL: serverURL, http: httpClient)
      let existingOperationKey = AccountDeletionIdempotencyKey.normalized(
        document.syncState.accountDeletionIdempotencyKey
      )
      let operationKey: String

      if let existingOperationKey {
        operationKey = existingOperationKey
        // Resolve an uncertain previous outcome before asking for another
        // passkey ceremony. A committed deletion can replay its receipt even
        // though that account, passkey, and bearer grant no longer exist.
        await client.setBearerToken(
          document.syncState.sessionToken.isEmpty
            ? nil
            : document.syncState.sessionToken
        )
        do {
          try await client.deleteAccount(idempotencyKey: operationKey)
        } catch SyncClientError.authenticationRequired {
          let freshSession = try await freshAccountDeletionSession(
            serverURL: serverURL,
            connectedAccountId: connectedAccountId
          )
          await client.setBearerToken(freshSession.sessionToken)
          try await client.deleteAccount(idempotencyKey: operationKey)
        }
      } else {
        let freshSession = try await freshAccountDeletionSession(
          serverURL: serverURL,
          connectedAccountId: connectedAccountId
        )
        operationKey = Base64URL.encode(try crypto.generateVaultKey())
        guard AccountDeletionIdempotencyKey.normalized(operationKey) != nil else {
          throw UserFacingAppError(
            message:
              "A secure account deletion operation could not be created. Nothing was deleted."
          )
        }

        // Persist the operation identity before the first destructive request.
        // Exact persistence bypasses sync-size projection: this privacy control
        // must remain available even for a vault that cannot currently upload.
        var pendingDeletion = document
        pendingDeletion.syncState.accountDeletionIdempotencyKey = operationKey
        guard
          await save(
            pendingDeletion,
            projectedSyncVersion: nil,
            saveExactly: true
          )
        else {
          return
        }

        // The step-up token authorizes this destructive request only. Do not
        // extend or replace the ordinary persisted sync session with it.
        await client.setBearerToken(freshSession.sessionToken)
        try await client.deleteAccount(idempotencyKey: operationKey)
      }

      var disconnected = document
      disconnected.syncState.disconnectAccount()
      // Commit the disconnected primary document and removal of the old
      // account's rollback point together. If local storage rejects either
      // half, the durable idempotency key remains available to replay the
      // server receipt and retry the entire privacy cleanup.
      guard await saveAndDiscardRollbackCheckpoint(disconnected) else {
        let persistenceError = error
        error =
          "The sync account was deleted, but its local metadata and rollback point could not be cleared atomically. Fix local storage, then retry Delete sync account to replay the saved deletion receipt: \(persistenceError)"
        return
      }
      notice =
        "Sync account deleted. Your encrypted local vault was kept; the deleted account's automatic rollback point was removed."
      error = ""
    } catch let failure {
      presentUserFacingError(
        failure,
        cancellationNotice: "Account deletion cancelled. Nothing was deleted."
      )
      if AccountDeletionIdempotencyKey.normalized(
        document.syncState.accountDeletionIdempotencyKey
      ) != nil {
        if error.isEmpty {
          notice =
            "Account deletion remains safely pending. Retry Delete sync account to resume the same operation."
        } else {
          error +=
            " The deletion operation remains safely pending; retry Delete sync account to resume it."
        }
      }
    }
  }

  /// A fresh passkey session satisfies the server's five-minute recent-auth
  /// requirement. This privacy path deliberately does not consult minimum app
  /// version policy: even an unsupported build must be able to delete data.
  func freshAccountDeletionSession(
    serverURL: URL,
    connectedAccountId: String
  ) async throws -> PasskeyWebSession {
    let session = try await passkeyAuthenticator.authenticate(
      serverURL: serverURL,
      mode: .authenticate
    )
    guard
      SyncAccountIdentifier.normalized(session.userId) == connectedAccountId,
      AppState.validatedSyncURL(session.serverURL) == serverURL,
      SyncSessionToken.isValid(session.sessionToken)
    else {
      throw UserFacingAppError(
        message: "Passkey sign-in did not match the connected sync account. Nothing was deleted."
      )
    }
    return session
  }

  func authenticateWithPasskey(serverURL: String, mode: PasskeyWebMode) async {
    guard acceptsNewOperations else { return }
    guard !scanning else {
      error = "Cancel or finish the active scan before changing sync accounts."
      return
    }
    guard let url = AppState.validatedSyncURL(serverURL) else {
      error = "Sync server URL must use https (http is allowed only for localhost)."
      return
    }
    let connectedAccountId = document.syncState.accountId.flatMap(
      SyncAccountIdentifier.normalized
    )
    let connectedServerURL = AppState.validatedSyncURL(document.syncState.serverURL)
    if connectedAccountId != nil, mode == .register {
      error =
        "Disconnect the current sync account explicitly before creating or switching to another account."
      return
    }
    if connectedAccountId != nil, connectedServerURL != url {
      error =
        "This vault is connected to a different sync server. Disconnect it explicitly before switching servers or accounts."
      return
    }
    if syncPersistencePending {
      guard let pendingUpload = pendingVaultUpload else {
        error = "Save the pending sync state locally before changing sync accounts."
        return
      }
      await authenticateForPendingVaultUploadRecovery(
        serverURL: url,
        mode: mode,
        pendingUpload: pendingUpload
      )
      return
    }
    guard !hasPendingAccountDeletion else {
      error = "Finish or retry the pending account deletion before changing sync accounts."
      return
    }
    guard !isPersisting else {
      error = "Wait for the current local save before changing sync accounts."
      return
    }
    guard !isValidatingExchangeCredentials else {
      error = "Wait for the exchange credential check before changing sync accounts."
      return
    }
    guard !syncing else {
      notice = "A sync operation is already running."
      return
    }
    let activity: SyncActivity = mode == .register ? .creatingPasskeyAccount : .signingIn
    guard beginSyncActivity(activity) else {
      notice = "A sync operation is already running."
      return
    }
    defer { finishSyncActivity(activity) }
    guard await flushWalletLabelDraftsBeforeRemoteOperation() else { return }
    let priorEndpointConfig = endpointConfig
    let priorEndpointConfigStatus = endpointConfigStatus
    let priorAcceptedEndpointConfigServerURL = acceptedEndpointConfigServerURL
    let priorEndpointConfigTrustDurabilityDegraded =
      endpointConfigTrustDurabilityDegraded
    do {
      let stagedEndpointConfig = try await compatibilityPolicyCandidate(for: url)
      let session = try await passkeyAuthenticator.authenticate(serverURL: url, mode: mode)
      guard AppState.validatedSyncURL(session.serverURL) == url else {
        throw UserFacingAppError(
          message: "Passkey sign-in returned a different sync server. Nothing was changed."
        )
      }
      if let connectedAccountId {
        guard SyncAccountIdentifier.normalized(session.userId) == connectedAccountId else {
          throw UserFacingAppError(
            message:
              "That passkey belongs to a different sync account. The current account was kept; disconnect it explicitly before switching."
          )
        }
      }
      var connected = document
      guard
        connected.syncState.connect(
          accountId: session.userId,
          serverURL: session.serverURL,
          sessionToken: session.sessionToken
        )
      else {
        throw URLError(.badServerResponse)
      }
      // The passkey ceremony authenticates this authority. Revalidate under
      // the durable store's lock in case another process advanced trust while
      // the sheet was open, then commit before saving the server binding.
      let trustOutcome = try await endpointConfigTrustStore.validateAndRecord(
        stagedEndpointConfig,
        for: url
      )
      guard trustOutcome.isDurable else {
        throw UserFacingAppError(
          message:
            "The endpoint policy became visible, but its crash-durability check failed. Passkey sign-in was not saved; refresh endpoints and try again after local storage recovers."
        )
      }
      guard await save(connected, projectedSyncVersion: nil) else {
        endpointConfig = priorEndpointConfig
        endpointConfigStatus = priorEndpointConfigStatus
        acceptedEndpointConfigServerURL = priorAcceptedEndpointConfigServerURL
        setEndpointConfigTrustDurabilityDegraded(
          priorEndpointConfigTrustDurabilityDegraded
        )
        return
      }
      // The policy becomes active only after the authenticated server binding
      // is durable. Cancellation, authentication failure and unsupported-build
      // rejection all restore the exact policy that preceded this attempt.
      endpointConfig = stagedEndpointConfig
      acceptedEndpointConfigServerURL = url
      setEndpointConfigTrustDurabilityDegraded(false)
      endpointConfigStatus = acceptedEndpointStatus(
        "Remote v\(stagedEndpointConfig.configVersion)"
      )
      let removedScanRunCount = lastSaveRemovedScanRunCount
      notice =
        (mode == .register ? "Passkey account connected." : "Passkey sign-in complete.")
        + pruningNoticeSuffix(removedScanRunCount)
      error = ""
    } catch {
      endpointConfig = priorEndpointConfig
      endpointConfigStatus = priorEndpointConfigStatus
      acceptedEndpointConfigServerURL = priorAcceptedEndpointConfigServerURL
      setEndpointConfigTrustDurabilityDegraded(
        priorEndpointConfigTrustDurabilityDegraded
      )
      presentUserFacingError(error, cancellationNotice: "Passkey sign-in cancelled.")
    }
  }

  /// Revoke this Mac's current bearer grant when possible, then durably clear
  /// the local account binding. This explicit transition is the only path that
  /// makes account creation or a different sync authority available again.
  func disconnectSyncAccountForSwitch(expectedServerURL: URL) async {
    guard canMutateVault() else { return }
    guard persistence != nil, isUnlocked else {
      error = "Unlock the vault before disconnecting the sync account."
      return
    }
    guard let serverURL = AppState.validatedSyncURL(document.syncState.serverURL),
      document.syncState.accountId.flatMap(SyncAccountIdentifier.normalized) != nil
    else {
      error = "No sync account is connected."
      return
    }
    guard serverURL == expectedServerURL else {
      error = "The saved sync server changed. Review it before disconnecting the account."
      return
    }
    guard beginSyncActivity(.disconnectingAccount) else {
      notice = "A sync operation is already running."
      return
    }
    defer { finishSyncActivity(.disconnectingAccount) }
    guard await flushWalletLabelDraftsBeforeRemoteOperation() else { return }
    do {
      if !document.syncState.sessionToken.isEmpty {
        let client = ZeroKnowledgeSyncClient(baseURL: serverURL, http: httpClient)
        await client.setBearerToken(document.syncState.sessionToken)
        try await client.revokeCurrentSession()
      }
      var disconnected = document
      disconnected.syncState.disconnectAccount()
      guard await saveAndDiscardRollbackCheckpoint(disconnected) else {
        let persistenceError = error
        error =
          "This Mac's server session was revoked, but its local account binding and rollback point could not be cleared atomically. Fix local storage, then use Disconnect locally without contacting server: \(persistenceError)"
        return
      }
      notice =
        "This Mac disconnected from the sync account. The remote account and encrypted remote vault were kept; the previous account's automatic rollback point was removed."
      error = ""
    } catch {
      await handleSyncError(error)
      let recovery =
        " The local account binding and encrypted rollback point were kept. If the server remains unavailable, use Disconnect locally without contacting server."
      if self.error.isEmpty {
        notice += recovery
      } else {
        self.error += recovery
      }
    }
  }

  /// Explicit offline escape hatch for switching authorities when the saved
  /// server cannot revoke this Mac's bearer grant. The confirmation belongs in
  /// the UI because a server-side session may remain valid until it expires.
  func disconnectSyncAccountLocallyForSwitch(expectedServerURL: URL) async {
    guard canMutateVault() else { return }
    guard persistence != nil, isUnlocked else {
      error = "Unlock the vault before disconnecting the sync account."
      return
    }
    guard let serverURL = AppState.validatedSyncURL(document.syncState.serverURL),
      document.syncState.accountId.flatMap(SyncAccountIdentifier.normalized) != nil
    else {
      error = "No sync account is connected."
      return
    }
    guard serverURL == expectedServerURL else {
      error = "The saved sync server changed. Review it before disconnecting the account."
      return
    }
    guard beginSyncActivity(.disconnectingAccount) else {
      notice = "A sync operation is already running."
      return
    }
    defer { finishSyncActivity(.disconnectingAccount) }
    guard await flushWalletLabelDraftsBeforeRemoteOperation() else { return }

    var disconnected = document
    disconnected.syncState.disconnectAccount()
    guard await saveAndDiscardRollbackCheckpoint(disconnected) else {
      let persistenceError = error
      error =
        "The local account binding and rollback point were kept because they could not be cleared atomically: \(persistenceError)"
      return
    }
    notice =
      "This Mac disconnected locally from the sync account. No server request was made; the remote account and vault were kept, and the old server session may remain valid until it expires."
    error = ""
  }

  private func authenticateForPendingVaultUploadRecovery(
    serverURL: URL,
    mode: PasskeyWebMode,
    pendingUpload: PendingVaultUpload
  ) async {
    guard acceptsNewOperations else { return }
    guard mode == .authenticate else {
      error = "Sign in to the existing sync account to recover the interrupted upload."
      return
    }
    guard
      serverURL.absoluteString == pendingUpload.serverOrigin,
      AppState.validatedSyncURL(document.syncState.serverURL) == serverURL,
      document.syncState.accountId.flatMap(SyncAccountIdentifier.normalized)
        == pendingUpload.accountId
    else {
      error =
        "The interrupted upload is bound to a different sync server or account. Sign in to that exact account to recover it."
      return
    }
    guard !hasPendingAccountDeletion else {
      error = "Finish or retry the pending account deletion before recovering the upload."
      return
    }
    guard !isPersisting else {
      error = "Wait for the current local save before recovering the upload."
      return
    }
    guard !isValidatingExchangeCredentials else {
      error = "Wait for the exchange credential check before recovering the upload."
      return
    }
    guard !syncing else {
      notice = "A sync operation is already running."
      return
    }

    let priorEndpointConfig = endpointConfig
    let priorEndpointConfigStatus = endpointConfigStatus
    let priorAcceptedEndpointConfigServerURL = acceptedEndpointConfigServerURL
    let priorEndpointConfigTrustDurabilityDegraded =
      endpointConfigTrustDurabilityDegraded
    guard beginSyncActivity(.signingIn) else {
      notice = "A sync operation is already running."
      return
    }
    defer { finishSyncActivity(.signingIn) }
    do {
      let stagedEndpointConfig = try await compatibilityPolicyCandidate(for: serverURL)
      let session = try await passkeyAuthenticator.authenticate(
        serverURL: serverURL,
        mode: .authenticate
      )
      guard
        SyncAccountIdentifier.normalized(session.userId) == pendingUpload.accountId,
        AppState.validatedSyncURL(session.serverURL) == serverURL,
        SyncSessionToken.isValid(session.sessionToken)
      else {
        throw UserFacingAppError(
          message:
            "Passkey sign-in did not match the account bound to the interrupted upload. Recovery was not started."
        )
      }
      let trustOutcome = try await endpointConfigTrustStore.validateAndRecord(
        stagedEndpointConfig,
        for: serverURL
      )
      guard trustOutcome.isDurable else {
        throw UserFacingAppError(
          message:
            "The endpoint policy became visible, but its crash-durability check failed. Passkey sign-in was not saved; refresh endpoints and try again after local storage recovers."
        )
      }

      // The pending-upload trigger intentionally blocks an ordinary document
      // save. Keep only the freshly authenticated token in memory; successful
      // recovery writes it as an override while atomically finalizing the
      // exact post-commit document stored in the recovery record.
      document.syncState.sessionToken = session.sessionToken
      endpointConfig = stagedEndpointConfig
      acceptedEndpointConfigServerURL = serverURL
      setEndpointConfigTrustDurabilityDegraded(false)
      endpointConfigStatus = acceptedEndpointStatus(
        "Remote v\(stagedEndpointConfig.configVersion)"
      )
      error = ""
      // Hand the single operation lane from authentication to replay so the
      // UI moves progress from Sign in to Retry upload recovery.
      finishSyncActivity(.signingIn)
      await recoverPendingVaultUpload()
    } catch {
      endpointConfig = priorEndpointConfig
      endpointConfigStatus = priorEndpointConfigStatus
      acceptedEndpointConfigServerURL = priorAcceptedEndpointConfigServerURL
      setEndpointConfigTrustDurabilityDegraded(
        priorEndpointConfigTrustDurabilityDegraded
      )
      presentUserFacingError(error, cancellationNotice: "Passkey sign-in cancelled.")
    }
  }

  func compatibilityPolicyCandidate(for serverURL: URL) async throws -> NativeEndpointConfig {
    // An earlier background refresh must not race the staged candidate back
    // into the published policy while the passkey sheet is open.
    endpointConfigRefreshGeneration &+= 1
    endpointConfigRefreshRequest?.task.cancel()
    endpointConfigRefreshRequest = nil
    let config: NativeEndpointConfig
    do {
      config = try await endpointConfigClient.fetch(from: serverURL)
      try await endpointConfigTrustStore.validate(config, for: serverURL)
    } catch {
      throw UserFacingAppError(
        message:
          "The sync server's compatibility policy could not be verified. Passkey sign-in was not started."
      )
    }
    guard AppState.supportsAppVersion(appVersion, minimum: config.minSupportedAppVersion) else {
      throw UserFacingAppError(
        message:
          "This app version is no longer supported. Update Address Atlas before signing in or creating an account."
      )
    }
    return config
  }

}
