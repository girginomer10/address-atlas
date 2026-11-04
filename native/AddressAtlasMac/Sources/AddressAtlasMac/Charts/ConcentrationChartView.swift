import AddressAtlasCore
import SwiftUI

/// Placeholder while the view is built.
struct ConcentrationChartView: View {
  let input: PortfolioChartInput

  init(input: PortfolioChartInput) {
    self.input = input
  }

  var body: some View {
    HistoryChartMessage(title: "Concentration", detail: "Not built yet", density: input.density)
  }
}
