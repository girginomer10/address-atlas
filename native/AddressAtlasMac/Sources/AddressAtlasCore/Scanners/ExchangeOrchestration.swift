import Foundation

public struct ExchangeBalance: Equatable, Sendable {
  public var total: [String: Double]
  public var free: [String: Double]
  public var warnings: [String]

  public init(total: [String: Double] = [:], free: [String: Double] = [:], warnings: [String] = [])
  {
    self.total = total
    self.free = free
    self.warnings = warnings
  }
}

public struct ExchangeScanResult: Sendable {
  public var holdings: [TrackedAsset]
  public var connections: [ExchangeConnectionRecord]
  public var warnings: [String]

  public init(
    holdings: [TrackedAsset], connections: [ExchangeConnectionRecord], warnings: [String] = []
  ) {
    self.holdings = holdings
    self.connections = connections
    self.warnings = ScanWarningPolicy.bounded(warnings)
  }
}

public enum ExchangeCredentialScopeValidation: Equatable, Sendable {
  /// The provider exposed an authoritative permission API and every dangerous
  /// capability was disabled at validation time.
  case verifiedReadOnly
  /// The provider's current credential API does not expose a sufficiently
  /// authoritative scope check. Callers must state that limitation explicitly
  /// rather than presenting the key as verified read-only.
  case manualVerificationRequired(provider: ExchangeProvider, guidance: String)
}

public enum ExchangeClientError: Error, Equatable, LocalizedError, Sendable {
  case httpError(statusCode: Int, message: String)
  case invalidResponse(String)
  case paginationLimit(provider: String, pages: Int)
  case legacyKrakenCredentialRequiresMigration
  case krakenCredentialBelongsToAnotherDevice
  case duplicateKrakenCredential
  case duplicateCredential(provider: ExchangeProvider)
  case unsafeCredentialScope(provider: ExchangeProvider, permissions: [String])
  case missingReadPermission(provider: ExchangeProvider)

  public var errorDescription: String? {
    switch self {
    case .httpError(let statusCode, let message):
      return "Exchange request failed (\(statusCode)): \(message)"
    case .invalidResponse(let message):
      return "Exchange returned invalid data: \(message)"
    case .paginationLimit(let provider, let pages):
      return "\(provider) pagination exceeded the \(pages)-page safety limit."
    case .legacyKrakenCredentialRequiresMigration:
      return
        "This Kraken connection predates device-safe nonces. Remove it, then add a new read-only Kraken API key created only for this Mac. Use a different Kraken API key on every device."
    case .krakenCredentialBelongsToAnotherDevice:
      return
        "This Kraken connection belongs to another Mac. Add a separate read-only Kraken API key for this Mac; never reuse one Kraken API key across devices."
    case .duplicateKrakenCredential:
      return
        "The same Kraken API key appears in more than one saved connection. Remove every duplicate, then add exactly one read-only Kraken API key created only for this Mac. Use a different Kraken API key on every device."
    case .duplicateCredential(let provider):
      return
        "The same \(provider.label) API key appears in more than one saved connection. Remove every duplicate so this exchange account is scanned exactly once."
    case .unsafeCredentialScope(let provider, let permissions):
      let summary = permissions.sorted().joined(separator: ", ")
      return
        "\(provider.label) refused this API key because dangerous permissions are enabled (\(summary)). Create a new balance/read-only key with trading, transfers, margin, futures, options, and withdrawals disabled."
    case .missingReadPermission(let provider):
      return
        "\(provider.label) did not confirm balance/read permission for this API key. No credentials were saved."
    }
  }
}

public struct NativeExchangeScanner: Sendable {
  private let client: NativeExchangeBalanceClient
  private let credentialVault: ExchangeCredentialVault
  private let priceProvider: PriceProviding
  private let maxConcurrentConnections: Int
  private let connectionDeadline: TimeInterval
  private let workflowDeadline: TimeInterval
  private let krakenDeviceIdentifier: @Sendable () throws -> String

  public init(
    client: NativeExchangeBalanceClient = NativeExchangeBalanceClient(),
    credentialVault: ExchangeCredentialVault = ExchangeCredentialVault(),
    priceProvider: PriceProviding = CoinGeckoPriceClient(),
    maxConcurrentConnections: Int = 3,
    connectionDeadline: TimeInterval = 45,
    workflowDeadline: TimeInterval = 120,
    krakenDeviceIdentifier: @escaping @Sendable () throws -> String = {
      try KrakenDeviceIdentity.currentIdentifier()
    }
  ) {
    self.client = client
    self.credentialVault = credentialVault
    self.priceProvider = priceProvider
    self.maxConcurrentConnections = max(1, maxConcurrentConnections)
    self.connectionDeadline =
      connectionDeadline.isFinite && connectionDeadline > 0 ? connectionDeadline : 45
    self.workflowDeadline =
      workflowDeadline.isFinite && workflowDeadline > 0 ? workflowDeadline : 120
    self.krakenDeviceIdentifier = krakenDeviceIdentifier
  }

  public func scanThrowing(connections: [ExchangeConnectionRecord], vaultKey: Data) async throws
    -> ExchangeScanResult
  {
    // Synced, legacy, or damaged vault state can contain duplicate records even
    // though ordinary creation prevents them. Fail every member of any duplicate
    // raw-key group before HTTP: scanning two same-device records would otherwise
    // double-count the same account. The plaintext comparison lives only for this
    // in-memory preflight; no global/raw-key fingerprint is persisted.
    let duplicateCredentialErrors = duplicateCredentialErrors(
      connections,
      vaultKey: vaultKey
    )
    let jobs = connections.enumerated().map {
      ExchangeConnectionJob(index: $0.offset, connection: $0.element)
    }
    guard !jobs.isEmpty else { return ExchangeScanResult(holdings: [], connections: []) }
    let collector = CompletedWorkCollector<IndexedExchangeConnectionOutcome>()
    let completed: [IndexedExchangeConnectionOutcome]
    var globalWarnings: [String] = []
    do {
      completed = try await withWorkflowTimeout(seconds: workflowDeadline) {
        try await boundedConcurrentMap(jobs, maxConcurrent: maxConcurrentConnections) { job in
          let outcome: ExchangeConnectionOutcome
          do {
            if let duplicateError = duplicateCredentialErrors[job.connection.id] {
              throw duplicateError
            }
            outcome = try await withWorkflowTimeout(seconds: connectionDeadline) {
              try await scanConnection(job.connection, vaultKey: vaultKey)
            }
          } catch ExchangeClientError.krakenCredentialBelongsToAnotherDevice {
            // A synced vault legitimately contains one distinct Kraken key per
            // Mac. The foreign record is not an error on this installation and
            // must remain byte-for-byte unchanged; marking it failed would make
            // every Mac rewrite every other Mac's status on each scan.
            outcome = ExchangeConnectionOutcome(
              connection: job.connection,
              warnings: [
                ProviderErrorSanitizer.sanitize(
                  "\(job.connection.label): skipped on this Mac because this Kraken connection is bound to another Mac."
                )
              ]
            )
          } catch {
            try throwIfCancellation(error)
            let safeError = ProviderErrorSanitizer.sanitize(error.localizedDescription)
            var failed = job.connection
            if failed.provider == .binance {
              // Binance permissions are mutable outside Address Atlas. Any
              // failed or unverifiable scan invalidates the prior point-in-time
              // assurance instead of leaving a stale green safety badge.
              failed.credentialScopeAssurance = nil
            }
            failed.status = .failed
            failed.lastTestedAt = Date()
            failed.lastError = safeError
            failed.updatedAt = Date()
            outcome = ExchangeConnectionOutcome(
              connection: failed,
              warnings: [ProviderErrorSanitizer.sanitize("\(job.connection.label): \(safeError)")]
            )
          }
          let indexed = IndexedExchangeConnectionOutcome(index: job.index, outcome: outcome)
          await collector.append(indexed)
          return indexed
        }
      }
    } catch is WorkflowTimeoutError {
      completed = await collector.snapshot()
      let skipped = max(0, jobs.count - completed.count)
      let deadline = WorkflowTimeoutError(seconds: workflowDeadline).displaySeconds
      globalWarnings.append(
        "The overall exchange scan reached its \(deadline)-second deadline; \(skipped) unfinished connections were skipped and completed results were kept."
      )
    } catch {
      try throwIfCancellation(error)
      throw error
    }

    let completedByIndex = Dictionary(
      uniqueKeysWithValues: completed.map { ($0.index, $0.outcome) })
    let outcomes = jobs.map { job -> ExchangeConnectionOutcome in
      if let completed = completedByIndex[job.index] { return completed }
      var unfinished = job.connection
      if unfinished.provider == .binance {
        unfinished.credentialScopeAssurance = nil
      }
      return ExchangeConnectionOutcome(
        connection: unfinished,
        warnings: ["\(job.connection.label): not scanned before the overall deadline."]
      )
    }

    return ExchangeScanResult(
      holdings: outcomes.flatMap(\.holdings),
      connections: outcomes.map(\.connection),
      warnings: ScanWarningPolicy.bounded(globalWarnings + outcomes.flatMap(\.warnings))
    )
  }

  private func duplicateCredentialErrors(
    _ connections: [ExchangeConnectionRecord],
    vaultKey: Data
  ) -> [UUID: ExchangeClientError] {
    struct CredentialIdentity: Hashable {
      var provider: ExchangeProvider
      var apiKey: String
    }

    var connectionsByCredential: [CredentialIdentity: [UUID]] = [:]
    for connection in connections {
      guard
        let credentials = try? credentialVault.open(
          connection.encryptedCredentials,
          vaultKey: vaultKey
        )
      else { continue }
      let normalizedAPIKey = credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalizedAPIKey.isEmpty else { continue }
      connectionsByCredential[
        CredentialIdentity(provider: connection.provider, apiKey: normalizedAPIKey),
        default: []
      ].append(connection.id)
    }

    return connectionsByCredential.reduce(into: [UUID: ExchangeClientError]()) {
      duplicates, entry in
      let (identity, connectionIDs) = entry
      guard connectionIDs.count > 1 else { return }
      let error: ExchangeClientError =
        identity.provider == .kraken
        ? .duplicateKrakenCredential
        : .duplicateCredential(provider: identity.provider)
      for connectionID in connectionIDs {
        duplicates[connectionID] = error
      }
    }
  }

  private func scanConnection(
    _ original: ExchangeConnectionRecord,
    vaultKey: Data
  ) async throws -> ExchangeConnectionOutcome {
    var connection = original
    if connection.provider == .kraken {
      guard
        let boundIdentifier = connection.krakenDeviceIdentifier.flatMap(
          KrakenDeviceIdentity.normalizedIdentifier
        )
      else {
        throw ExchangeClientError.legacyKrakenCredentialRequiresMigration
      }
      guard
        let localIdentifier = KrakenDeviceIdentity.normalizedIdentifier(
          try krakenDeviceIdentifier()
        )
      else {
        throw KrakenNonceError.localStateUnavailable
      }
      guard boundIdentifier == localIdentifier else {
        throw ExchangeClientError.krakenCredentialBelongsToAnotherDevice
      }
    }
    let credentials = try credentialVault.open(connection.encryptedCredentials, vaultKey: vaultKey)
    if connection.provider == .binance {
      // Binance exposes the only authoritative scope endpoint in the supported
      // provider set. Re-check it immediately before every balance request so
      // remotely expanded permissions and legacy nil-assurance records fail
      // closed before account data is requested.
      let validation = try await client.validateCredentialScope(
        provider: .binance,
        credentials: credentials
      )
      guard validation == .verifiedReadOnly else {
        throw ExchangeClientError.missingReadPermission(provider: .binance)
      }
      connection.credentialScopeAssurance = .verifiedReadOnly
    }
    let balance = try await client.fetchBalance(
      provider: connection.provider,
      credentials: credentials,
      krakenDeviceIdentifier: connection.krakenDeviceIdentifier
    )
    let normalized = try await ExchangeBalanceNormalizer.normalizeWithWarnings(
      balance: balance,
      id: connection.id,
      provider: connection.provider,
      label: connection.label,
      priceProvider: priceProvider
    )
    connection.status = .ok
    connection.lastSyncAt = Date()
    connection.lastTestedAt = Date()
    connection.lastError = nil
    connection.updatedAt = Date()
    return ExchangeConnectionOutcome(
      connection: connection,
      holdings: normalized.holdings,
      warnings: normalized.warnings.map {
        ProviderErrorSanitizer.sanitize("\(connection.label): \($0)")
      }
    )
  }
}

private struct ExchangeConnectionOutcome: Sendable {
  var connection: ExchangeConnectionRecord
  var holdings: [TrackedAsset] = []
  var warnings: [String] = []
}

private struct ExchangeConnectionJob: Sendable {
  var index: Int
  var connection: ExchangeConnectionRecord
}

private struct IndexedExchangeConnectionOutcome: Sendable {
  var index: Int
  var outcome: ExchangeConnectionOutcome
}
