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

  /// One-line description shown in the iPhone "More" list and iPad sidebar.
  var summary: String {
    switch self {
    case .portfolio: "Total value, allocation, and the latest scan"
    case .wallets: "Public addresses tracked read-only"
    case .assets: "Every holding from the latest scan"
    case .tokens: "Custom token allowlist and manual holdings"
    case .snapshots: "Encrypted scan history kept on this device"
    case .exchanges: "Read-only exchange balance connections"
    case .iCloud: "Optional encrypted copy in your private iCloud"
    case .export: "Share-safer or full reports, generated locally"
    case .settings: "Preferences, recovery kit, updates, and privacy"
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
