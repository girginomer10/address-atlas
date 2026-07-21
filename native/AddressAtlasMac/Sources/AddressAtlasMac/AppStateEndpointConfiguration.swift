import AddressAtlasCore
import Foundation

/// Gives each caller an independently cancellable wait on one shared fetch.
/// Cancelling a waiter resumes only that waiter; AppState's lease registry
/// decides when the underlying fetch has no owners left and may be cancelled.
actor EndpointConfigRefreshWaiterPool {
  nonisolated let task: Task<NativeEndpointConfig, Error>

  private var result: Result<NativeEndpointConfig, Error>?
  private var waiters: [UUID: CheckedContinuation<NativeEndpointConfig, Error>] = [:]
  private var isObservingTask = false

  init(task: Task<NativeEndpointConfig, Error>) {
    self.task = task
  }

  func value(for waiterID: UUID) async throws -> NativeEndpointConfig {
    try Task.checkCancellation()
    observeTaskIfNeeded()
    if let result {
      return try result.get()
    }

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if let result {
          continuation.resume(with: result)
        } else {
          precondition(waiters[waiterID] == nil, "Endpoint refresh waiter registered twice")
          waiters[waiterID] = continuation
        }
      }
    } onCancel: {
      Task { await self.cancel(waiterID: waiterID) }
    }
  }

  private func observeTaskIfNeeded() {
    guard !isObservingTask else { return }
    isObservingTask = true
    let task = task
    Task {
      let result = await task.result
      complete(with: result)
    }
  }

  private func cancel(waiterID: UUID) {
    waiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
  }

  private func complete(with result: Result<NativeEndpointConfig, Error>) {
    self.result = result
    let continuations = waiters.values
    waiters.removeAll()
    for continuation in continuations {
      continuation.resume(with: result)
    }
  }
}

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
    guard acceptsNewOperations else { return false }
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

    let waiterID = UUID()
    let request: EndpointConfigRefreshRequest
    if var inFlight = endpointConfigRefreshRequest, inFlight.serverURL == serverURL {
      inFlight.waiterIDs.insert(waiterID)
      endpointConfigRefreshRequest = inFlight
      request = inFlight
    } else {
      endpointConfigRefreshGeneration &+= 1
      endpointConfigRefreshRequest?.task.cancel()
      let generation = endpointConfigRefreshGeneration
      let client = endpointConfigClient
      let trustStore = endpointConfigTrustStore
      let task = Task { @MainActor [weak self] in
        let config = try await client.fetch(from: serverURL)
        try Task.checkCancellation()
        guard let self,
          generation == endpointConfigRefreshGeneration,
          AppState.validatedSyncURL(document.syncState.serverURL) == serverURL
        else {
          throw CancellationError()
        }
        // Trust advancement belongs to the shared request, not to an
        // individual waiter. Generation/server invalidation cancels this task;
        // the store independently checks cancellation at its write boundary.
        try await trustStore.validateAndRecord(config, for: serverURL)
        try Task.checkCancellation()
        guard generation == endpointConfigRefreshGeneration,
          AppState.validatedSyncURL(document.syncState.serverURL) == serverURL
        else {
          throw CancellationError()
        }
        return config
      }
      request = EndpointConfigRefreshRequest(
        generation: generation,
        serverURL: serverURL,
        task: task,
        waiterPool: EndpointConfigRefreshWaiterPool(task: task),
        waiterIDs: [waiterID]
      )
      endpointConfigRefreshRequest = request
    }
    defer {
      releaseEndpointConfigRefreshWaiter(generation: request.generation, waiterID: waiterID)
    }

    do {
      let config = try await request.waiterPool.value(for: waiterID)
      try Task.checkCancellation()
      guard request.generation == endpointConfigRefreshGeneration,
        AppState.validatedSyncURL(document.syncState.serverURL) == serverURL
      else { return false }
      // The shared request has already verified and durably advanced this
      // origin's high-water mark. Recheck caller ownership immediately before
      // publishing because this waiter may have been cancelled after commit.
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
    } catch is CancellationError {
      // Cancellation is an ownership signal, not an endpoint failure. Leave
      // the last accepted policy/status untouched and let the parent flow
      // present its operation-specific cancellation message.
      return false
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

  private func releaseEndpointConfigRefreshWaiter(generation: Int, waiterID: UUID) {
    guard var request = endpointConfigRefreshRequest,
      request.generation == generation,
      request.waiterIDs.remove(waiterID) != nil
    else { return }

    guard !request.waiterIDs.isEmpty else {
      // A completed task ignores cancellation. An unfinished task is stopped
      // as soon as its final owner leaves, so no detached network work leaks.
      request.task.cancel()
      endpointConfigRefreshRequest = nil
      return
    }
    endpointConfigRefreshRequest = request
  }

  /// Keep compatibility policy and credential-free scanner endpoints fresh
  /// even when the user is not actively scanning or syncing. The SwiftUI task
  /// that owns this loop is restarted whenever the configured server changes.
  func runEndpointConfigRefreshLoop() async {
    guard isUnlocked, acceptsNewOperations else { return }
    while !Task.isCancelled,
      isUnlocked,
      acceptsNewOperations,
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
