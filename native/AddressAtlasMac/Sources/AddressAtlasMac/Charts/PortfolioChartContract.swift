import AddressAtlasCore
import Foundation
import SwiftUI

/// Shared contract for every portfolio and coin visualization.
///
/// Each of the 14 `PortfolioVisualization` views is a SwiftUI `View` with an
/// `init(input: PortfolioChartInput)` initializer. Views read colours, fonts and
/// shapes from `@Environment(\.atlasTheme)` and never from hard-coded values, so
/// every view works in every theme. Views compile on macOS and iOS.
///
/// The caller (Portfolio screen, coin detail screen) is responsible for
/// filtering holdings (dust, paused or removed sources) before building the
/// input. Views do analytics through `PortfolioAnalytics` in AddressAtlasCore.
struct PortfolioChartInput {
  /// Holdings of the latest scan (or of one coin, on the coin detail screen),
  /// already filtered by the caller. Unpriced holdings may be present; views
  /// exclude them from value math and may mention them.
  var holdings: [TrackedAsset]
  /// Saved scan runs, oldest first. History views (over time, what changed,
  /// slope, calendar) use them; other views ignore them.
  var runs: [ScanRunRecord]
  /// Primary grouping chosen by the user.
  var grouping: PortfolioGrouping
  /// When set, the input describes a single coin (`CoinIdentity.key`). Views
  /// should then label slices by the grouping (network, source, state) rather
  /// than by coin.
  var coinKey: String?
  /// Optional context used by `PortfolioAnalytics.runsShareSources` and
  /// `attribution(from:to:context:)` to decide whether two runs are comparable.
  var sourceContext: ScanSourceContext?
  /// Time zone for calendar bucketing.
  var timeZone: TimeZone
  /// `.full` fills a page; `.compact` fits a card or a list header
  /// (roughly 320 x 200 points) and drops secondary labels.
  var density: PortfolioChartDensity
  /// Called when the user picks a slice, block, node or row.
  var onSelect: (PortfolioChartSelection) -> Void

  init(
    holdings: [TrackedAsset],
    runs: [ScanRunRecord] = [],
    grouping: PortfolioGrouping = .asset,
    coinKey: String? = nil,
    sourceContext: ScanSourceContext? = nil,
    timeZone: TimeZone = .current,
    density: PortfolioChartDensity = .full,
    onSelect: @escaping (PortfolioChartSelection) -> Void = { _ in }
  ) {
    self.holdings = holdings
    self.runs = runs
    self.grouping = grouping
    self.coinKey = coinKey
    self.sourceContext = sourceContext
    self.timeZone = timeZone
    self.density = density
    self.onSelect = onSelect
  }
}

enum PortfolioChartDensity: Sendable {
  case full
  case compact
}

/// What the user picked inside a chart. The screen decides what to do with it
/// (usually: open the coin detail screen, or filter the Assets list).
enum PortfolioChartSelection: Hashable, Sendable {
  /// A coin, by `CoinIdentity.key`.
  case coin(String)
  /// A slice of a grouping other than asset (network name, source key,
  /// `HoldingState` raw value, `HoldingKind` raw value).
  case slice(grouping: PortfolioGrouping, key: String)
  /// A specific saved scan run (history views).
  case run(UUID)
}
