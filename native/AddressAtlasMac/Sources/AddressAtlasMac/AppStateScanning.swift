import AddressAtlasCore
import Foundation

@MainActor
extension AppState {
  func startScan() {
    guard acceptsNewOperations else { return }
    guard !syncing else {
      error = "Wait for the active sync operation before scanning."
      return
    }
    guard !syncPersistencePending else {
      error = "Save the pending sync state locally before scanning."
      return
    }
    guard !hasPendingAccountDeletion else {
      error = "Finish or retry the pending account deletion before scanning."
      return
    }
    guard !isPersisting else {
      error = "Wait for the current local save before scanning."
      return
    }
    guard !isValidatingExchangeCredentials else {
      error = "Wait for the exchange credential check before scanning."
      return
    }
    guard scanTask == nil, !scanning else {
      notice = "A scan is already running."
      return
    }
    scanTask = Task { [weak self] in
      guard let self else { return }
      await self.scanSavedWallets()
      self.scanTask = nil
    }
  }

  func cancelScan() {
    scanTask?.cancel()
  }

  func scanSavedWallets() async {
    guard acceptsNewOperations else { return }
    guard let vaultKey else {
      error = "Vault must be unlocked before scanning."
      return
    }
    guard !scanning else {
      notice = "A scan is already running."
      return
    }
    guard !syncing else {
      error = "Wait for the active sync operation before scanning."
      return
    }
    guard !syncPersistencePending else {
      error = "Save the pending sync state locally before scanning."
      return
    }
    guard !hasPendingAccountDeletion else {
      error = "Finish or retry the pending account deletion before scanning."
      return
    }
    guard !isPersisting else {
      error = "Wait for the current local save before scanning."
      return
    }
    guard !isValidatingExchangeCredentials else {
      error = "Wait for the exchange credential check before scanning."
      return
    }
    scanning = true
    error = ""
    defer { scanning = false }
    do {
      var endpointPolicyWarning: String?
      if legacyServerSyncEnabled,
        let serverURL = AppState.validatedSyncURL(document.syncState.serverURL) {
        let refreshed = await refreshEndpointConfig(silent: true)
        try Task.checkCancellation()
        if !refreshed {
          // A fresh process has only the bundled policy and a version/digest
          // high-water record; it cannot reconstruct a previously accepted
          // remote minimum-version rule. Only a policy accepted for this exact
          // authority in this process is safe as an outage fallback.
          guard acceptedEndpointConfigServerURL == serverURL else {
            throw UserFacingAppError(
              message:
                "The sync endpoint policy could not be verified. Scanning stayed offline so a previously accepted minimum-version rule cannot be bypassed."
            )
          }
          endpointPolicyWarning =
            "The sync endpoint policy could not be refreshed; this local snapshot used the last policy trusted for this server in the current app session."
        }
      }
      // A transport failure may fall back to an already trusted policy, but a
      // successfully accepted minimum-version policy remains a global network
      // kill switch. This distinction keeps local scans available during a sync
      // outage without letting an obsolete client bypass a deliberate safety
      // cutoff for provider and exchange traffic.
      guard isAppVersionSupported else {
        throw UserFacingAppError(
          message:
            "This app version is no longer supported. Update Address Atlas before scanning or syncing."
        )
      }
      try Task.checkCancellation()
      let input = document.wallets.map(\.address).joined(separator: "\n")
      let scanner = NativeScanner(
        http: JSONHTTPClient(http: httpClient),
        endpointConfig: endpointConfig
      )
      var scan = try await scanner.scan(addresses: input, customTokens: document.customTokens)
      try Task.checkCancellation()
      scan.holdings = AppState.applyingWalletLabels(to: scan.holdings, wallets: document.wallets)
      let exchangeClient = NativeExchangeBalanceClient(
        http: httpClient,
        endpointConfig: endpointConfig
      )
      let exchangeScan = try await NativeExchangeScanner(
        client: exchangeClient,
        priceProvider: CoinGeckoPriceClient(
          baseURL: endpointConfig.priceBaseURL,
          http: JSONHTTPClient(http: httpClient)
        ),
        krakenDeviceIdentifier: krakenDeviceIdentifier
      ).scanThrowing(
        connections: document.exchangeConnections,
        vaultKey: vaultKey
      )
      try Task.checkCancellation()
      let manualAssets = document.manualHoldings.filter(\.enabled).map { holding in
        TrackedAsset(
          id: "manual-\(holding.id.uuidString)",
          address: holding.label,
          chainId: "manual-\(holding.provider)",
          chainName: holding.customVenue ?? holding.provider,
          family: .exchange,
          symbol: holding.symbol,
          name: holding.name,
          amount: holding.amount,
          priceUsd: holding.priceUsd ?? 0,
          valueUsd: holding.valueUsd,
          pricingStatus: holding.priceUsd != nil || holding.valueUsd > 0 ? .priced : .unpriced,
          source: .exchange
        )
      }
      scan.holdings.append(contentsOf: exchangeScan.holdings)
      scan.holdings.append(contentsOf: manualAssets)
      scan.warnings.append(contentsOf: exchangeScan.warnings)
      if let endpointPolicyWarning {
        scan.warnings.append(endpointPolicyWarning)
      }
      for index in scan.holdings.indices {
        scan.holdings[index].change24h = FiniteValueMath.finiteOptional(
          scan.holdings[index].change24h)
      }
      let holdingCountBeforeValidation = scan.holdings.count
      scan.holdings = scan.holdings.filter {
        $0.amount.isFinite && $0.amount >= 0 && $0.priceUsd.isFinite && $0.priceUsd >= 0
          && $0.valueUsd.isFinite && $0.valueUsd >= 0
      }
      let invalidHoldingCount = holdingCountBeforeValidation - scan.holdings.count
      if invalidHoldingCount > 0 {
        scan.warnings.append(
          "Ignored \(invalidHoldingCount) invalid holding value\(invalidHoldingCount == 1 ? "" : "s")."
        )
      }
      guard let totalUsd = AppState.validatedPortfolioTotal(scan.holdings) else {
        throw PortfolioValueError.totalExceedsSupportedRange
      }
      scan.totalUsd = totalUsd
      scan.warnings = ScanWarningPolicy.bounded(scan.warnings)
      try Task.checkCancellation()
      if await mutateDocument({ document in
        document.exchangeConnections = exchangeScan.connections
        document.scanRuns.append(scan)
        document.scanRuns = Array(
          document.scanRuns.sorted { $0.generatedAt > $1.generatedAt }.prefix(
            Self.maximumStoredScanRuns)
        )
      }) {
        let successNotice =
          scan.warnings.isEmpty
          ? "Snapshot saved."
          : "Snapshot saved with \(scan.warnings.count) warning\(scan.warnings.count == 1 ? "" : "s")."
        notice = successNotice + pruningNoticeSuffix(lastSaveRemovedScanRunCount)
      }
    } catch is CancellationError {
      notice = "Scan cancelled."
    } catch {
      recordDiagnosticFailure(.scanFailed)
      presentUserFacingError(error)
    }
  }

  // MARK: - Source drift since a snapshot

  /// Stable identity of the source a holding was read from: the wallet's
  /// network family plus canonical address, the exchange connection ID, or
  /// the manual holding ID. Nil for records that cannot be attributed.
  nonisolated static func scanSourceKey(for asset: TrackedAsset) -> String? {
    if asset.id.hasPrefix("manual-") {
      return "manual:" + asset.id.dropFirst("manual-".count).lowercased()
    }
    if let exchangeId = asset.exchangeId {
      return "exchange:" + exchangeId.uuidString.lowercased()
    }
    guard asset.family != .exchange,
      let canonical = AddressDetection.canonicalAddress(asset.address, family: asset.family)
    else { return nil }
    return "wallet:\(asset.family.rawValue):\(canonical)"
  }

  nonisolated static func scanSourceKey(for wallet: WalletRecord) -> String? {
    AddressDetection.canonicalAddress(wallet.address, family: wallet.chainKind).map {
      "wallet:\(wallet.chainKind.rawValue):\($0)"
    }
  }

  /// Keys of every source the next scan would read: saved wallets, exchange
  /// connections, and enabled manual holdings.
  var savedScanSourceKeys: Set<String> {
    var keys = Set(document.wallets.compactMap { Self.scanSourceKey(for: $0) })
    for connection in document.exchangeConnections {
      keys.insert("exchange:" + connection.id.uuidString.lowercased())
    }
    for holding in document.manualHoldings where holding.enabled {
      keys.insert("manual:" + holding.id.uuidString.lowercased())
    }
    return keys
  }

  /// True when the holding's wallet, exchange connection, or manual holding
  /// is still saved (and enabled). Unattributable holdings count as saved.
  nonisolated static func holdingSourceIsSaved(
    _ asset: TrackedAsset, savedKeys: Set<String>
  ) -> Bool {
    guard let key = scanSourceKey(for: asset) else { return true }
    return savedKeys.contains(key)
  }

  /// How the saved sources differ from the ones the latest snapshot read.
  /// Presentation-only: the stored snapshot is never rewritten.
  var latestScanSourceDrift: ScanSourceDrift {
    guard let latest = latestScan else { return ScanSourceDrift() }
    let since = latest.generatedAt
    let saved = savedScanSourceKeys
    let scannedKeys = Set(latest.holdings.compactMap { Self.scanSourceKey(for: $0) })
    var drift = ScanSourceDrift()

    let addedWallets = document.wallets.filter { $0.createdAt > since }.count
    let removedWalletKeys =
      scannedKeys.filter { $0.hasPrefix("wallet:") && !saved.contains($0) }.count
    // A wallet without any balance leaves no holding behind; the scanned
    // address count still shows that one was removed.
    let walletsAtScan = document.wallets.count - addedWallets
    drift.added += addedWallets
    drift.removed += max(removedWalletKeys, latest.inputCount - walletsAtScan, 0)

    drift.added += document.exchangeConnections.filter { $0.createdAt > since }.count
    drift.removed +=
      scannedKeys.filter { $0.hasPrefix("exchange:") && !saved.contains($0) }.count

    for holding in document.manualHoldings where holding.enabled {
      let key = "manual:" + holding.id.uuidString.lowercased()
      if !scannedKeys.contains(key) {
        drift.added += 1
      } else if holding.updatedAt > since {
        drift.edited += 1
      }
    }
    drift.removed +=
      scannedKeys.filter { $0.hasPrefix("manual:") && !saved.contains($0) }.count
    return drift
  }

  /// Whether two snapshots read the same sources, so the difference between
  /// their totals is a market move rather than an added or removed wallet,
  /// exchange, or manual holding. `older` must precede `newer`.
  func scanRunsShareSources(_ older: ScanRunRecord, _ newer: ScanRunRecord) -> Bool {
    guard older.inputCount == newer.inputCount else { return false }
    let olderKeys = Set(older.holdings.compactMap { Self.scanSourceKey(for: $0) })
    let newerKeys = Set(newer.holdings.compactMap { Self.scanSourceKey(for: $0) })
    guard olderKeys.filter({ $0.hasPrefix("manual:") })
      == newerKeys.filter({ $0.hasPrefix("manual:") })
    else { return false }

    let saved = savedScanSourceKeys
    var createdAt: [String: Date] = [:]
    for wallet in document.wallets {
      if let key = Self.scanSourceKey(for: wallet) { createdAt[key] = wallet.createdAt }
    }
    for connection in document.exchangeConnections {
      createdAt["exchange:" + connection.id.uuidString.lowercased()] = connection.createdAt
    }
    // A source only the newer snapshot has was either funded since (same
    // sources) or added between the two scans.
    for key in newerKeys.subtracting(olderKeys) {
      if let created = createdAt[key], created > older.generatedAt { return false }
    }
    // A source only the older snapshot has was either emptied (same sources)
    // or removed; a removed one is no longer saved.
    for key in olderKeys.subtracting(newerKeys) where !saved.contains(key) {
      return false
    }
    return true
  }
}

/// How the saved sources differ from the ones a snapshot read.
struct ScanSourceDrift: Equatable, Sendable {
  var added = 0
  var removed = 0
  var edited = 0

  var hasChanges: Bool { added > 0 || removed > 0 || edited > 0 }
}
