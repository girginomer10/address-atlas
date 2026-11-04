import AddressAtlasCore
import SwiftUI

/// Placeholder while the view is built.
///
/// Coin widgets take `input.coinKey` (a `CoinIdentity.key`) and, when it is
/// nil, the largest coin in `input.holdings`.
struct CoinStateStripView: View {
  let input: PortfolioChartInput

  init(input: PortfolioChartInput) {
    self.input = input
  }

  /// For callers that already hold the coin's summary and need no history.
  init(
    summary: CoinSummary,
    density: PortfolioChartDensity = .full,
    onSelect: @escaping (PortfolioChartSelection) -> Void = { _ in }
  ) {
    self.input = PortfolioChartInput(
      holdings: [], coinKey: summary.id, density: density, onSelect: onSelect)
  }

  var body: some View {
    HistoryChartMessage(title: "Coin states", detail: "Not built yet", density: input.density)
  }
}
