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
  func revokeCurrentSyncSession() async {
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
    syncing = true
    defer { syncing = false }
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
  func deleteSyncAccount() async {
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
    syncing = true
    defer { syncing = false }
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
    guard !scanning else {
      error = "Cancel or finish the active scan before changing sync accounts."
      return
    }
    guard let url = AppState.validatedSyncURL(serverURL) else {
      error = "Sync server URL must use https (http is allowed only for localhost)."
      return
    }
    guard !syncPersistencePending else {
      error = "Save the pending sync state locally before changing sync accounts."
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
    do {
      try await verifyCompatibilityPolicy(for: url)
      let session = try await passkeyAuthenticator.authenticate(serverURL: url, mode: mode)
      let previousServerURL = document.syncState.serverURL
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
      guard await save(connected, projectedSyncVersion: nil) else {
        return
      }
      if previousServerURL != document.syncState.serverURL,
        acceptedEndpointConfigServerURL
          != AppState.validatedSyncURL(document.syncState.serverURL)
      {
        endpointConfig = .bundled
        endpointConfigStatus = "Bundled endpoints"
        acceptedEndpointConfigServerURL = nil
      }
      let removedScanRunCount = lastSaveRemovedScanRunCount
      notice =
        (mode == .register ? "Passkey account connected." : "Passkey sign-in complete.")
        + pruningNoticeSuffix(removedScanRunCount)
      error = ""
    } catch {
      presentUserFacingError(error, cancellationNotice: "Passkey sign-in cancelled.")
    }
  }

  func verifyCompatibilityPolicy(for serverURL: URL) async throws {
    if AppState.validatedSyncURL(document.syncState.serverURL) == serverURL {
      guard await refreshEndpointConfig(silent: true) else {
        throw UserFacingAppError(
          message:
            "The sync server's compatibility policy could not be verified. Passkey sign-in was not started."
        )
      }
    } else {
      endpointConfigRefreshGeneration &+= 1
      endpointConfigRefreshRequest?.task.cancel()
      endpointConfigRefreshRequest = nil
      let config = try await endpointConfigClient.fetch(from: serverURL)
      try await endpointConfigTrustStore.validateAndRecord(config, for: serverURL)
      endpointConfig = config
      acceptedEndpointConfigServerURL = serverURL
      endpointConfigStatus = acceptedEndpointStatus("Remote v\(config.configVersion)")
    }
    guard isAppVersionSupported else {
      endpointConfigStatus = "Update required"
      throw UserFacingAppError(
        message:
          "This app version is no longer supported. Update Address Atlas before signing in or creating an account."
      )
    }
  }

}
