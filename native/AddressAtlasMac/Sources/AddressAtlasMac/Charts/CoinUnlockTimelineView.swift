import AddressAtlasCore
import SwiftUI

/// Placeholder while the view is built.
///
/// `now` is "today" on the timeline; the screen passes the current date, tests
/// pass a fixed one.
struct CoinUnlockTimelineView: View {
  let input: PortfolioChartInput
  let now: Date

  init(input: PortfolioChartInput, now: Date = Date()) {
    self.input = input
    self.now = now
  }

  /// For callers that already hold the coin's summary and need no history.
  init(
    summary: CoinSummary,
    now: Date = Date(),
    timeZone: TimeZone = .current,
    density: PortfolioChartDensity = .full,
    onSelect: @escaping (PortfolioChartSelection) -> Void = { _ in }
  ) {
    self.input = PortfolioChartInput(
      holdings: [], coinKey: summary.id, timeZone: timeZone, density: density, onSelect: onSelect)
    self.now = now
  }

  var body: some View {
    HistoryChartMessage(title: "Unlock timeline", detail: "Not built yet", density: input.density)
  }
}
