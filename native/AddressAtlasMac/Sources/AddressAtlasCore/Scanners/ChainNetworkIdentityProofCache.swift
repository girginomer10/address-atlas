import Foundation

/// Coalesces immutable network proofs and typed snapshot anchors without
/// sharing mutable balance responses. Waiters are explicit continuations so a
/// canceled workflow never remains suspended behind an unstructured network
/// task. A waiter's cancellation is isolated: sibling addresses that depend on
/// the same proof keep waiting for the shared producer.
actor ChainNetworkValueCache<Value: Sendable> {
  private struct Key: Hashable, Sendable {
    var chainID: String
    var endpoint: String
    var identity: ChainNetworkIdentity
  }

  private struct Entry {
    /// Distinguishes successive producers for the same logical key. The prior
    /// detached producer may finish after its last waiter removed the entry and
    /// a new caller installed a replacement; key equality alone cannot tell
    /// those generations apart.
    var generation = UUID()
    var task: Task<Void, Never>?
    var result: Result<Value, Error>?
    var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]
  }

  private var entries: [Key: Entry] = [:]

  func value(
    chainID: String,
    endpoint: URL,
    identity: ChainNetworkIdentity,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let key = Key(chainID: chainID, endpoint: endpoint.absoluteString, identity: identity)
    let waiterID = UUID()

    let value: Value = try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
          return
        }
        if let result = entries[key]?.result {
          continuation.resume(with: result)
          return
        }

        var entry = entries[key] ?? Entry()
        entry.waiters[waiterID] = continuation
        if entry.task == nil {
          let generation = entry.generation
          // Detached work prevents a synchronous HTTP test double (or future
          // adapter) from monopolizing this actor and delaying cancellation.
          entry.task = Task.detached { [weak self] in
            let result: Result<Value, Error>
            do {
              try Task.checkCancellation()
              result = .success(try await operation())
            } catch {
              result = .failure(error)
            }
            await self?.finish(result, for: key, generation: generation)
          }
        }
        entries[key] = entry
      }
    } onCancel: {
      Task { await self.cancel(waiterID: waiterID, for: key) }
    }
    // Cancellation registration runs asynchronously so the producer's finish
    // can win the actor race. The waiter task's cancellation bit is immediate,
    // however, and must still prevent a just-resumed success from escaping.
    try Task.checkCancellation()
    return value
  }

  private func finish(_ result: Result<Value, Error>, for key: Key, generation: UUID) {
    guard var entry = entries[key], entry.generation == generation, entry.result == nil else {
      return
    }
    let waiters = Array(entry.waiters.values)
    entry.waiters.removeAll(keepingCapacity: false)
    entry.task = nil
    entry.result = result
    entries[key] = entry
    waiters.forEach { $0.resume(with: result) }
  }

  private func cancel(waiterID: UUID, for key: Key) {
    guard var entry = entries[key], let canceledWaiter = entry.waiters.removeValue(forKey: waiterID)
    else { return }
    let failure: Result<Value, Error> = .failure(CancellationError())
    if entry.waiters.isEmpty {
      // Nobody can consume this producer now. Remove the entry before
      // cancellation so its eventual finish cannot cache CancellationError
      // (or a late success) for a future workflow.
      entries.removeValue(forKey: key)
      entry.task?.cancel()
    } else {
      entries[key] = entry
    }
    canceledWaiter.resume(with: failure)
  }
}

extension ChainNetworkValueCache where Value == Void {
  func prove(
    chainID: String,
    endpoint: URL,
    identity: ChainNetworkIdentity,
    operation: @escaping @Sendable () async throws -> Void
  ) async throws {
    _ = try await value(
      chainID: chainID,
      endpoint: endpoint,
      identity: identity,
      operation: operation
    )
  }
}
