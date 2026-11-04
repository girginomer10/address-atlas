import AddressAtlasCore
import SwiftUI

/// Placeholder while the view is built.
struct AtlasMapChartView: View {
  let input: PortfolioChartInput

  init(input: PortfolioChartInput) {
    self.input = input
  }

  var body: some View {
    HistoryChartMessage(title: "Atlas map", detail: "Not built yet", density: input.density)
  }
}
