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
      if AppState.validatedSyncURL(document.syncState.serverURL) != nil {
        let refreshed = await refreshEndpointConfig(silent: true)
        try Task.checkCancellation()
        guard refreshed else {
          throw UserFacingAppError(
            message:
              "The sync server's compatibility policy could not be verified. Scanning was not started."
          )
        }
      }
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
          source: .exchange
        )
      }
      scan.holdings.append(contentsOf: exchangeScan.holdings)
      scan.holdings.append(contentsOf: manualAssets)
      scan.warnings.append(contentsOf: exchangeScan.warnings)
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
      presentUserFacingError(error)
    }
  }

}
