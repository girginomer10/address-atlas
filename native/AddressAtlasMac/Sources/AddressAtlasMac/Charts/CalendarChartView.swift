import AddressAtlasCore
import SwiftUI

/// Placeholder while the view is built.
struct CalendarChartView: View {
  let input: PortfolioChartInput

  init(input: PortfolioChartInput) {
    self.input = input
  }

  var body: some View {
    HistoryChartMessage(title: "Calendar", detail: "Not built yet", density: input.density)
  }
}
