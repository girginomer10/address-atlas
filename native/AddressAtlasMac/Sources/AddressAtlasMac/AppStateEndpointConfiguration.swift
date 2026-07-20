import AddressAtlasCore
import Foundation

@MainActor
extension AppState {
  @discardableResult
  func saveSyncSettings(serverURL: String) async -> Bool {
    guard canMutateVault() else { return false }
    guard !syncPersistencePending else {
      error = "Save the pending sync state locally before changing sync servers."
      return false
    }
    guard let canonicalURL = AppState.validatedSyncURL(serverURL) else {
      error = "Sync server URL must use https (http is allowed only for localhost)."
      return false
    }
    let canonical = canonicalURL.absoluteString
    let serverChanged = document.syncState.serverURL != canonical
    guard await mutateDocument({ $0.syncState.changeServer(to: canonical) }) else { return false }
    if serverChanged {
      endpointConfig = .bundled
      endpointConfigStatus = "Bundled endpoints"
      acceptedEndpointConfigServerURL = nil
    }
    return true
  }

  @discardableResult
  func refreshEndpointConfig(silent: Bool = false) async -> Bool {
    guard let serverURL = AppState.validatedSyncURL(document.syncState.serverURL) else {
      endpointConfigRefreshGeneration &+= 1
      endpointConfigRefreshRequest?.task.cancel()
      endpointConfigRefreshRequest = nil
      endpointConfig = .bundled
      endpointConfigStatus = "Bundled endpoints"
      acceptedEndpointConfigServerURL = nil
      if !silent {
        notice = "Using bundled endpoints."
      }
      return false
    }

    if let acceptedServer = acceptedEndpointConfigServerURL,
      acceptedServer != serverURL
    {
      // This can also happen when a restored/test document changes the server
      // without going through saveSyncSettings. Never carry one authority's
      // endpoint policy into another authority's refresh.
      endpointConfig = .bundled
      endpointConfigStatus = "Bundled endpoints"
      acceptedEndpointConfigServerURL = nil
    }

    let request: EndpointConfigRefreshRequest
    if let inFlight = endpointConfigRefreshRequest, inFlight.serverURL == serverURL {
      request = inFlight
    } else {
      endpointConfigRefreshGeneration &+= 1
      endpointConfigRefreshRequest?.task.cancel()
      let generation = endpointConfigRefreshGeneration
      let client = endpointConfigClient
      request = EndpointConfigRefreshRequest(
        generation: generation,
        serverURL: serverURL,
        task: Task { try await client.fetch(from: serverURL) }
      )
      endpointConfigRefreshRequest = request
    }
    defer {
      if endpointConfigRefreshRequest?.generation == request.generation {
        endpointConfigRefreshRequest = nil
      }
    }

    do {
      let config = try await request.task.value
      guard request.generation == endpointConfigRefreshGeneration,
        AppState.validatedSyncURL(document.syncState.serverURL) == serverURL
      else { return false }
      // Verify and durably advance the per-origin high-water mark before
      // applying any remote policy. This survives relaunch and fails closed if
      // the trust record is unreadable, unwritable, stale, or equivocated.
      try await endpointConfigTrustStore.validateAndRecord(config, for: serverURL)
      endpointConfig = config
      acceptedEndpointConfigServerURL = serverURL
      if !isAppVersionSupported {
        endpointConfigStatus = "Update required"
        if !silent {
          self.error =
            "This app version is no longer supported. Update Address Atlas to keep syncing."
        }
      } else {
        endpointConfigStatus = "Remote v\(config.configVersion)"
        if !silent {
          notice = "Endpoint config refreshed."
        }
      }
      return true
    } catch {
      guard request.generation == endpointConfigRefreshGeneration,
        AppState.validatedSyncURL(document.syncState.serverURL) == serverURL
      else { return false }
      if case EndpointConfigTrustStoreError.rollback(_, let received) = error,
        acceptedEndpointConfigServerURL == serverURL
      {
        endpointConfigStatus = acceptedEndpointStatus(
          "Remote v\(endpointConfig.configVersion) (stale v\(received) rejected)"
        )
      } else if case EndpointConfigTrustStoreError.equivocation = error,
        acceptedEndpointConfigServerURL == serverURL
      {
        endpointConfigStatus = acceptedEndpointStatus(
          "Remote v\(endpointConfig.configVersion) (conflicting refresh rejected)"
        )
      } else if acceptedEndpointConfigServerURL == serverURL {
        endpointConfigStatus = acceptedEndpointStatus(
          "Remote v\(endpointConfig.configVersion) (refresh unavailable)"
        )
      } else {
        endpointConfig = .bundled
        endpointConfigStatus = "Bundled endpoints (remote unavailable)"
        acceptedEndpointConfigServerURL = nil
      }
      if !silent {
        presentUserFacingError(error)
      }
      return false
    }
  }

  /// Keep compatibility policy and credential-free scanner endpoints fresh
  /// even when the user is not actively scanning or syncing. The SwiftUI task
  /// that owns this loop is restarted whenever the configured server changes.
  func runEndpointConfigRefreshLoop() async {
    guard isUnlocked else { return }
    while !Task.isCancelled,
      isUnlocked,
      AppState.validatedSyncURL(document.syncState.serverURL) != nil
    {
      // Scan and sync flows already perform a fail-closed refresh before using
      // remote policy, so avoid starting another request while they are active.
      if !scanning, !syncing {
        _ = await refreshEndpointConfig(silent: true)
      }

      let refreshSeconds = min(
        max(endpointConfig.refreshAfterSeconds, NativeEndpointConfig.minimumRefreshAfterSeconds),
        NativeEndpointConfig.maximumRefreshAfterSeconds
      )
      do {
        try await Task.sleep(for: .seconds(refreshSeconds))
      } catch {
        return
      }
    }
  }

}
