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
      error = "Unlock Address Atlas before revoking the sync session."
      return
    }
    guard let serverURL = AppState.validatedSyncURL(document.syncState.serverURL),
      hasUsableSyncSession()
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
      postNotice("A sync is already running.", tone: .neutral)
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
          "The server session was revoked, but this \(PlatformCopy.deviceNoun) couldn't save that change. Fix local storage, then use Retry local save: \(persistenceError)"
        return
      }
      notice = "This \(PlatformCopy.deviceNounPossessive) sync session was revoked."
      error = ""
    } catch {
      recordDiagnosticFailure(.syncAccountLifecycleFailed)
      await handleSyncError(error)
    }
  }

  /// Delete the authenticated server account while preserving the encrypted
  /// local vault. The server call commits first; afterward account/session and
  /// remote-baseline metadata are cleared and persisted locally.
  func deleteSyncAccount(expectedServerURL: URL) async {
    guard canMutateVault(allowPendingAccountDeletion: true) else { return }
    guard persistence != nil, isUnlocked else {
      error = "Unlock Address Atlas before deleting the sync account."
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
      postNotice("A sync is already running.", tone: .neutral)
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
              "Address Atlas couldn't prepare the account deletion. Nothing was deleted."
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
          "The sync account was deleted, but this \(PlatformCopy.deviceNoun) couldn't clear its local account data and backup copy. Fix local storage, then retry Delete sync account to finish: \(persistenceError)"
        return
      }
      notice =
        "Sync account deleted. Your local portfolio was kept. The deleted account's automatic backup copy was removed."
      error = ""
    } catch let failure {
      if !(failure is CancellationError),
        (failure as? PasskeyAuthenticationError) != .cancelled
      {
        recordDiagnosticFailure(.syncAccountLifecycleFailed)
      }
      presentUserFacingError(
        failure,
        cancellationNotice: "Account deletion cancelled. Nothing was deleted."
      )
      if AccountDeletionIdempotencyKey.normalized(
        document.syncState.accountDeletionIdempotencyKey
      ) != nil {
        if error.isEmpty {
          notice =
            "Account deletion isn't finished. Retry Delete sync account to continue."
        } else {
          error +=
            " Account deletion isn't finished. Retry Delete sync account to continue."
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
      SyncSessionToken.isUsable(session.sessionToken, forAccountId: connectedAccountId)
    else {
      throw UserFacingAppError(
        message: "That passkey doesn't match the connected sync account. Nothing was deleted."
      )
    }
    return session
  }

  func authenticateWithPasskey(serverURL: String, mode: PasskeyWebMode) async {
    guard acceptsNewOperations else { return }
    guard !scanning else {
      error = "Wait for the scan to finish, or cancel it, before changing sync accounts."
      return
    }
    guard let url = AppState.validatedSyncURL(serverURL) else {
      error = "The sync server address must start with https. Only localhost can use http."
      return
    }
    let connectedAccountId = document.syncState.accountId.flatMap(
      SyncAccountIdentifier.normalized
    )
    let connectedServerURL = AppState.validatedSyncURL(document.syncState.serverURL)
    if connectedAccountId != nil, mode == .register {
      error =
        "Disconnect the current sync account before creating or switching to another one."
      return
    }
    if connectedAccountId != nil, connectedServerURL != url {
      error =
        "Your portfolio is connected to a different sync server. Disconnect it before switching servers or accounts."
      return
    }
    if syncPersistencePending {
      guard let pendingUpload = pendingVaultUpload else {
        error = "Save the last sync result before changing sync accounts."
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
      error = "Finish the account deletion before changing sync accounts."
      return
    }
    guard !isPersisting else {
      error = "Wait for the current save to finish before changing sync accounts."
      return
    }
    guard !isValidatingExchangeCredentials else {
      error = "Wait for the exchange key check to finish before changing sync accounts."
      return
    }
    guard !syncing else {
      postNotice("A sync is already running.", tone: .neutral)
      return
    }
    let activity: SyncActivity = mode == .register ? .creatingPasskeyAccount : .signingIn
    guard beginSyncActivity(activity) else {
      postNotice("A sync is already running.", tone: .neutral)
      return
    }
    defer { finishSyncActivity(activity) }
    guard await flushWalletLabelDraftsBeforeRemoteOperation() else { return }
    let priorEndpointConfig = endpointConfig
    let priorEndpointConfigStatus = endpointConfigStatus
    let priorAcceptedEndpointConfigServerURL = acceptedEndpointConfigServerURL
    let priorEndpointConfigTrustDurabilityDegraded =
      endpointConfigTrustDurabilityDegraded
    var remoteAuthenticationCompleted = false
    do {
      let stagedEndpointConfig = try await compatibilityPolicyCandidate(for: url)
      let session = try await passkeyAuthenticator.authenticate(serverURL: url, mode: mode)
      remoteAuthenticationCompleted = true
      if let passkeyAuthenticationCompletedHook {
        self.passkeyAuthenticationCompletedHook = nil
        passkeyAuthenticationCompletedHook()
      }
      guard AppState.validatedSyncURL(session.serverURL) == url else {
        throw UserFacingAppError(
          message: "The passkey sign-in came from a different sync server. Nothing was changed."
        )
      }
      if let connectedAccountId {
        guard SyncAccountIdentifier.normalized(session.userId) == connectedAccountId else {
          throw UserFacingAppError(
            message:
              "That passkey belongs to a different sync account. The current account was kept. Disconnect it before switching."
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
            "The server settings were updated, but this \(PlatformCopy.deviceNoun) couldn't confirm they were saved. Passkey sign-in wasn't saved. Fix local storage, refresh the server settings, and try again."
        )
      }
      guard await save(connected, projectedSyncVersion: nil) else {
        let persistenceFailure = error
        endpointConfig = priorEndpointConfig
        endpointConfigStatus = priorEndpointConfigStatus
        acceptedEndpointConfigServerURL = priorAcceptedEndpointConfigServerURL
        setEndpointConfigTrustDurabilityDegraded(
          priorEndpointConfigTrustDurabilityDegraded
        )
        error = "\(persistenceFailure) \(Self.postPasskeyAuthenticationGuidance(for: mode))"
        return
      }
      // The policy becomes active only after the authenticated server binding
      // is durable. Cancellation, authentication failure and unsupported-build
      // rejection all restore the exact policy that preceded this attempt.
      endpointConfig = stagedEndpointConfig
      acceptedEndpointConfigServerURL = url
      setEndpointConfigTrustDurabilityDegraded(false)
      endpointConfigStatus = acceptedEndpointStatus(
        "Server settings v\(stagedEndpointConfig.configVersion)"
      )
      let removedScanRunCount = lastSaveRemovedScanRunCount
      notice =
        (mode == .register ? "Passkey account connected." : "Passkey sign-in complete.")
        + pruningNoticeSuffix(removedScanRunCount)
      error = ""
    } catch {
      if !(error is CancellationError),
        (error as? PasskeyAuthenticationError) != .cancelled
      {
        recordDiagnosticFailure(
          mode == .register ? .passkeyRegistrationFailed : .passkeyAuthenticationFailed
        )
      }
      endpointConfig = priorEndpointConfig
      endpointConfigStatus = priorEndpointConfigStatus
      acceptedEndpointConfigServerURL = priorAcceptedEndpointConfigServerURL
      setEndpointConfigTrustDurabilityDegraded(
        priorEndpointConfigTrustDurabilityDegraded
      )
      presentUserFacingError(error, cancellationNotice: "Passkey sign-in cancelled.")
      if remoteAuthenticationCompleted {
        let guidance = Self.postPasskeyAuthenticationGuidance(for: mode)
        if self.error.isEmpty {
          notice = ""
          self.error = guidance
        } else if !self.error.contains(guidance) {
          self.error += " \(guidance)"
        }
      }
    }
  }

  static func postPasskeyAuthenticationGuidance(for mode: PasskeyWebMode) -> String {
    switch mode {
    case .register:
      "The account and passkey may already exist on the server. Your previous sync connection was kept. Fix local storage, then choose Sign in before trying Create passkey account again."
    case .authenticate:
      "Your previous sync connection was kept. Fix local storage, then choose Sign in again."
    }
  }

  /// Revoke this Mac's current bearer grant when possible, then durably clear
  /// the local account binding. This explicit transition is the only path that
  /// makes account creation or a different sync authority available again.
  func disconnectSyncAccountForSwitch(expectedServerURL: URL) async {
    guard canMutateVault() else { return }
    guard persistence != nil, isUnlocked else {
      error = "Unlock Address Atlas before disconnecting the sync account."
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
      postNotice("A sync is already running.", tone: .neutral)
      return
    }
    defer { finishSyncActivity(.disconnectingAccount) }
    guard await flushWalletLabelDraftsBeforeRemoteOperation() else { return }
    do {
      if hasUsableSyncSession() {
        let client = ZeroKnowledgeSyncClient(baseURL: serverURL, http: httpClient)
        await client.setBearerToken(document.syncState.sessionToken)
        try await client.revokeCurrentSession()
      }
      var disconnected = document
      disconnected.syncState.disconnectAccount()
      guard await saveAndDiscardRollbackCheckpoint(disconnected) else {
        let persistenceError = error
        error =
          "This \(PlatformCopy.deviceNounPossessive) server session was revoked, but its sync connection and backup copy couldn't be cleared. Fix local storage, then use Disconnect locally without contacting server: \(persistenceError)"
        return
      }
      notice =
        "This \(PlatformCopy.deviceNoun) was disconnected from the sync account. The account and its encrypted copy on the server were kept. The account's automatic backup copy was removed."
      error = ""
    } catch {
      recordDiagnosticFailure(.syncAccountLifecycleFailed)
      await handleSyncError(error)
      let recovery =
        " The sync connection and backup copy were kept. If the server stays unavailable, use Disconnect locally without contacting server."
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
      error = "Unlock Address Atlas before disconnecting the sync account."
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
      postNotice("A sync is already running.", tone: .neutral)
      return
    }
    defer { finishSyncActivity(.disconnectingAccount) }
    guard await flushWalletLabelDraftsBeforeRemoteOperation() else { return }

    var disconnected = document
    disconnected.syncState.disconnectAccount()
    guard await saveAndDiscardRollbackCheckpoint(disconnected) else {
      let persistenceError = error
      error =
        "The sync connection and backup copy were kept because they couldn't be cleared: \(persistenceError)"
      return
    }
    notice =
      "This \(PlatformCopy.deviceNoun) was disconnected from the sync account without contacting the server. The account and its encrypted copy were kept, and the old server session may stay valid until it expires."
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
        "The interrupted upload belongs to a different sync server or account. Sign in to that account to finish it."
      return
    }
    guard !hasPendingAccountDeletion else {
      error = "Finish the account deletion before recovering the upload."
      return
    }
    guard !isPersisting else {
      error = "Wait for the current save to finish before recovering the upload."
      return
    }
    guard !isValidatingExchangeCredentials else {
      error = "Wait for the exchange key check to finish before recovering the upload."
      return
    }
    guard !syncing else {
      postNotice("A sync is already running.", tone: .neutral)
      return
    }

    let priorEndpointConfig = endpointConfig
    let priorEndpointConfigStatus = endpointConfigStatus
    let priorAcceptedEndpointConfigServerURL = acceptedEndpointConfigServerURL
    let priorEndpointConfigTrustDurabilityDegraded =
      endpointConfigTrustDurabilityDegraded
    guard beginSyncActivity(.signingIn) else {
      postNotice("A sync is already running.", tone: .neutral)
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
        SyncSessionToken.isUsable(session.sessionToken, forAccountId: pendingUpload.accountId)
      else {
        throw UserFacingAppError(
          message:
            "That passkey doesn't match the account of the interrupted upload. Recovery didn't start."
        )
      }
      let trustOutcome = try await endpointConfigTrustStore.validateAndRecord(
        stagedEndpointConfig,
        for: serverURL
      )
      guard trustOutcome.isDurable else {
        throw UserFacingAppError(
          message:
            "The server settings were updated, but this \(PlatformCopy.deviceNoun) couldn't confirm they were saved. Passkey sign-in wasn't saved. Fix local storage, refresh the server settings, and try again."
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
        "Server settings v\(stagedEndpointConfig.configVersion)"
      )
      error = ""
      // Hand the single operation lane from authentication to replay so the
      // UI moves progress from Sign in to Retry upload recovery.
      finishSyncActivity(.signingIn)
      await recoverPendingVaultUpload()
    } catch {
      if !(error is CancellationError),
        (error as? PasskeyAuthenticationError) != .cancelled
      {
        recordDiagnosticFailure(.passkeyAuthenticationFailed)
      }
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
          "Address Atlas couldn't verify that this version works with the sync server. Passkey sign-in didn't start."
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
