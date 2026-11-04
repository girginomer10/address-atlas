import AddressAtlasCore
import Foundation

extension AppState {
  /// Holdings every chart and summary should show: the latest scan, with the
  /// dust preference applied and holdings from removed or paused sources left
  /// out (the "Sources changed" banner explains the gap).
  var chartHoldings: [TrackedAsset] {
    let saved = savedScanSourceKeys
    return visibleLatestHoldings.filter { Self.holdingSourceIsSaved($0, savedKeys: saved) }
  }

  /// Saved scans, oldest first, as the history views expect.
  var chartRuns: [ScanRunRecord] {
    document.scanRuns.sorted { $0.generatedAt < $1.generatedAt }
  }

  /// Builds the input for `PortfolioVisualizationView` and the coin widgets.
  /// Pass `coinKey` (`CoinIdentity.key`) on a coin detail screen to limit the
  /// holdings to that coin.
  func chartInput(
    grouping: PortfolioGrouping,
    coinKey: String? = nil,
    density: PortfolioChartDensity = .full,
    onSelect: @escaping (PortfolioChartSelection) -> Void = { _ in }
  ) -> PortfolioChartInput {
    var holdings = chartHoldings
    if let coinKey {
      holdings = holdings.filter { CoinIdentity.key(for: $0) == coinKey }
    }
    return PortfolioChartInput(
      holdings: holdings,
      runs: chartRuns,
      grouping: grouping,
      coinKey: coinKey,
      sourceContext: ScanSourceContext(document: document),
      timeZone: .current,
      density: density,
      onSelect: onSelect
    )
  }

  /// Every coin in the latest scan, largest first, for coin lists and pickers.
  var coinSummaries: [CoinSummary] {
    PortfolioAnalytics.coinSummaries(chartHoldings)
  }
}
