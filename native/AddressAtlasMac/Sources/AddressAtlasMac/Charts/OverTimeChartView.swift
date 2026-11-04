import AddressAtlasCore
import SwiftUI

/// Placeholder while the view is built.
struct OverTimeChartView: View {
  let input: PortfolioChartInput

  init(input: PortfolioChartInput) {
    self.input = input
  }

  var body: some View {
    HistoryChartMessage(title: "Over time", detail: "Not built yet", density: input.density)
  }
}
