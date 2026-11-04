import AddressAtlasCore
import SwiftUI

/// Placeholder while the view is built. Uses `input.coinKey`, `input.runs`.
struct CoinAmountHistoryView: View {
  let input: PortfolioChartInput

  init(input: PortfolioChartInput) {
    self.input = input
  }

  var body: some View {
    HistoryChartMessage(title: "Amount over time", detail: "Not built yet", density: input.density)
  }
}
