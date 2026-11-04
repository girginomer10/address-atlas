import AddressAtlasCore
import SwiftUI

/// Placeholder while the view is built.
struct WhatChangedChartView: View {
  let input: PortfolioChartInput

  init(input: PortfolioChartInput) {
    self.input = input
  }

  var body: some View {
    HistoryChartMessage(title: "What changed", detail: "Not built yet", density: input.density)
  }
}
