import AddressAtlasCore
import SwiftUI

/// Renders whichever of the 14 portfolio views the user picked. Screens use
/// this instead of switching over `PortfolioVisualization` themselves.
struct PortfolioVisualizationView: View {
  let visualization: PortfolioVisualization
  let input: PortfolioChartInput

  var body: some View {
    switch visualization {
    case .map: MapChartView(input: input)
    case .ring: RingChartView(input: input)
    case .strip: StripChartView(input: input)
    case .grid: GridChartView(input: input)
    case .bubbles: BubblesChartView(input: input)
    case .ringsInRings: RingsInRingsChartView(input: input)
    case .flow: FlowChartView(input: input)
    case .list: ListChartView(input: input)
    case .overTime: OverTimeChartView(input: input)
    case .whatChanged: WhatChangedChartView(input: input)
    case .atlasMap: AtlasMapChartView(input: input)
    case .slope: SlopeChartView(input: input)
    case .concentration: ConcentrationChartView(input: input)
    case .calendar: CalendarChartView(input: input)
    }
  }
}

extension PortfolioVisualization {
  /// Views that read saved scan history rather than only the latest holdings.
  var usesHistory: Bool {
    switch self {
    case .overTime, .whatChanged, .slope, .calendar: true
    default: false
    }
  }

  /// Views whose layout changes with the "group by" choice. The others ignore
  /// it, so screens can hide the grouping control for them.
  var usesGrouping: Bool {
    switch self {
    case .whatChanged, .slope, .concentration, .calendar: false
    default: true
    }
  }

  /// Views that make sense on a single coin's detail screen.
  var worksForSingleCoin: Bool {
    switch self {
    case .whatChanged, .slope, .concentration, .calendar: false
    default: true
    }
  }
}

extension AtlasDisplayPreferences {
  /// Typed view of the stored grouping string.
  var grouping: PortfolioGrouping {
    get { PortfolioGrouping(rawValue: portfolioGrouping) ?? .asset }
    set { portfolioGrouping = newValue.rawValue }
  }
}
