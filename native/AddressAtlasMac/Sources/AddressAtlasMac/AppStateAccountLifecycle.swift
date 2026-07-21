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
    syncing = true
    defer { syncing = false }
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
    syncing = true
    defer { syncing = false }
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
      guard await save(disconnected, projectedSyncVersion: nil) else {
        let persistenceError = error
        requirePendingSyncPersistence(disconnected, projectedSyncVersion: nil)
        error =
          "The sync account was deleted, but clearing its local metadata is pending persistence. Use Retry local save after fixing storage: \(persistenceError)"
        return
      }
      notice = "Sync account deleted. Your encrypted local vault was kept."
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
    syncing = true
    defer { syncing = false }
    guard await flushWalletLabelDraftsBeforeRemoteOperation() else { return }
    let priorEndpointConfig = endpointConfig
    let priorEndpointConfigStatus = endpointConfigStatus
    let priorAcceptedEndpointConfigServerURL = acceptedEndpointConfigServerURL
    do {
      let stagedEndpointConfig = try await compatibilityPolicyCandidate(for: url)
      let session = try await passkeyAuthenticator.authenticate(serverURL: url, mode: mode)
      guard AppState.validatedSyncURL(session.serverURL) == url else {
        throw UserFacingAppError(
          message: "Passkey sign-in returned a different sync server. Nothing was changed."
        )
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
      try await endpointConfigTrustStore.validateAndRecord(stagedEndpointConfig, for: url)
      guard await save(connected, projectedSyncVersion: nil) else {
        endpointConfig = priorEndpointConfig
        endpointConfigStatus = priorEndpointConfigStatus
        acceptedEndpointConfigServerURL = priorAcceptedEndpointConfigServerURL
        return
      }
      // The policy becomes active only after the authenticated server binding
      // is durable. Cancellation, authentication failure and unsupported-build
      // rejection all restore the exact policy that preceded this attempt.
      endpointConfig = stagedEndpointConfig
      acceptedEndpointConfigServerURL = url
      endpointConfigStatus = "Remote v\(stagedEndpointConfig.configVersion)"
      let removedScanRunCount = lastSaveRemovedScanRunCount
      notice =
        (mode == .register ? "Passkey account connected." : "Passkey sign-in complete.")
        + pruningNoticeSuffix(removedScanRunCount)
      error = ""
    } catch {
      endpointConfig = priorEndpointConfig
      endpointConfigStatus = priorEndpointConfigStatus
      acceptedEndpointConfigServerURL = priorAcceptedEndpointConfigServerURL
      presentUserFacingError(error, cancellationNotice: "Passkey sign-in cancelled.")
    }
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
    syncing = true
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
      try await endpointConfigTrustStore.validateAndRecord(stagedEndpointConfig, for: serverURL)

      // The pending-upload trigger intentionally blocks an ordinary document
      // save. Keep only the freshly authenticated token in memory; successful
      // recovery writes it as an override while atomically finalizing the
      // exact post-commit document stored in the recovery record.
      document.syncState.sessionToken = session.sessionToken
      endpointConfig = stagedEndpointConfig
      acceptedEndpointConfigServerURL = serverURL
      endpointConfigStatus = "Remote v\(stagedEndpointConfig.configVersion)"
      error = ""
      syncing = false
      await recoverPendingVaultUpload()
    } catch {
      syncing = false
      endpointConfig = priorEndpointConfig
      endpointConfigStatus = priorEndpointConfigStatus
      acceptedEndpointConfigServerURL = priorAcceptedEndpointConfigServerURL
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
