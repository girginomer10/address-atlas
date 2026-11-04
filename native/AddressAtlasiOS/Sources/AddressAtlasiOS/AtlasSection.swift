import SwiftUI

/// The five places the app is organised into. iPhone shows them as tabs; iPad
/// shows them in a sidebar. Everything else (a coin, a snapshot, iCloud,
/// Export) is pushed from one of them.
enum AtlasSection: String, CaseIterable, Identifiable, Hashable, Sendable {
  case portfolio
  case assets
  case sources
  case history
  case settings

  var id: String { rawValue }

  var title: String {
    switch self {
    case .portfolio: "Portfolio"
    case .assets: "Assets"
    case .sources: "Sources"
    case .history: "History"
    case .settings: "Settings"
    }
  }

  var systemImage: String {
    switch self {
    case .portfolio: "chart.pie"
    case .assets: "list.bullet.rectangle"
    case .sources: "wallet.pass"
    case .history: "clock.arrow.circlepath"
    case .settings: "gearshape"
    }
  }

  @MainActor @ViewBuilder
  var screen: some View {
    switch self {
    case .portfolio: PortfolioScreen()
    case .assets: AssetsScreen()
    case .sources: SourcesScreen()
    case .history: HistoryScreen()
    case .settings: SettingsScreen()
    }
  }
}
