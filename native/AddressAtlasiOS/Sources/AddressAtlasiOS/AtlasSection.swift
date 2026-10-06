import SwiftUI

/// The nine product areas, mirroring the macOS sidebar. iPhone shows four of
/// them as tabs plus a "More" tab; iPad shows all of them in a sidebar.
enum AtlasSection: String, CaseIterable, Identifiable, Hashable, Sendable {
  case portfolio
  case wallets
  case assets
  case tokens
  case snapshots
  case exchanges
  case iCloud
  case export
  case settings

  var id: String { rawValue }

  var title: String {
    switch self {
    case .portfolio: "Portfolio"
    case .wallets: "Wallets"
    case .assets: "Assets"
    case .tokens: "Tokens"
    case .snapshots: "Snapshots"
    case .exchanges: "Exchanges"
    case .iCloud: "iCloud"
    case .export: "Export"
    case .settings: "Settings"
    }
  }

  var systemImage: String {
    switch self {
    case .portfolio: "chart.pie"
    case .wallets: "wallet.pass"
    case .assets: "list.bullet.rectangle"
    case .tokens: "tag"
    case .snapshots: "clock.arrow.circlepath"
    case .exchanges: "building.columns"
    case .iCloud: "arrow.triangle.2.circlepath"
    case .export: "square.and.arrow.down"
    case .settings: "gearshape"
    }
  }

  /// Short description shown under the title in the iPhone "More" list.
  var summary: String {
    switch self {
    case .portfolio: "Total value and allocation"
    case .wallets: "Watch-only addresses"
    case .assets: "Every holding from the last scan"
    case .tokens: "Custom tokens and manual balances"
    case .snapshots: "Scan history on this device"
    case .exchanges: "Read-only connections"
    case .iCloud: "Optional encrypted copy"
    case .export: "CSV and JSON reports"
    case .settings: "Preferences and recovery kit"
    }
  }

  /// Settings-style icon tile color for the "More" list and iPad sidebar.
  var iconTint: Color {
    switch self {
    case .portfolio: AtlasTheme.accent
    case .wallets: .indigo
    case .assets: .teal
    case .tokens: .orange
    case .snapshots: .purple
    case .exchanges: .green
    case .iCloud: .cyan
    case .export: .pink
    case .settings: .gray
    }
  }

  /// Sections that get their own iPhone tab.
  static let primaryTabs: [AtlasSection] = [.portfolio, .wallets, .assets, .exchanges]

  /// Sections reached through the iPhone "More" tab.
  static let moreSections: [AtlasSection] = [.tokens, .snapshots, .iCloud, .export, .settings]

  @MainActor @ViewBuilder
  var screen: some View {
    switch self {
    case .portfolio: PortfolioScreen()
    case .wallets: WalletsScreen()
    case .assets: AssetsScreen()
    case .tokens: TokensScreen()
    case .snapshots: SnapshotsScreen()
    case .exchanges: ExchangesScreen()
    case .iCloud: ICloudScreen()
    case .export: ExportScreen()
    case .settings: SettingsScreen()
    }
  }
}
