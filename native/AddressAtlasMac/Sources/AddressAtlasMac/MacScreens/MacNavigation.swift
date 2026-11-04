import AddressAtlasCore
import SwiftUI

/// Where the Mac window is, shared by the sidebar, the screens, and the menu
/// commands (⌘1 to ⌘7, ⌘N, ⌘F, ⌘R).
///
/// A coin detail screen is not a section: it opens on top of whichever section
/// it came from (Portfolio, Assets), keeps that section selected in the
/// sidebar, and goes back to it. Charts and rows ask for navigation through
/// the `open...` methods so every route clears what it replaces.
@MainActor
final class MacNavigationModel: ObservableObject {
  /// Something a screen should do once it is on screen, for a command that
  /// switched to it.
  enum PendingAction: Equatable {
    case focusAssetSearch
    case focusWalletAddress
  }

  @Published private(set) var section: MainView.Section
  /// `CoinIdentity.key` of the open coin detail, if any.
  @Published private(set) var coinKey: String?
  /// The coin list in Assets is limited to one slice of the portfolio.
  @Published var assetsFilter: MacSliceFilter?
  /// The snapshot History shows in full.
  @Published var selectedRunID: UUID?
  @Published var walletsPane: MacWalletsPane = .wallets
  @Published private(set) var pendingAction: PendingAction?

  init(section: MainView.Section = .portfolio) {
    self.section = section
  }

  /// Moves to a section from the sidebar or a menu command.
  func go(_ next: MainView.Section) {
    coinKey = nil
    section = next
  }

  func openCoin(_ key: String) {
    coinKey = key
  }

  func closeCoin() {
    coinKey = nil
  }

  func openAssets(filter: MacSliceFilter? = nil) {
    coinKey = nil
    assetsFilter = filter
    section = .assets
  }

  func openSnapshot(_ id: UUID) {
    coinKey = nil
    selectedRunID = id
    section = .history
  }

  func openWallets(pane: MacWalletsPane = .wallets) {
    coinKey = nil
    walletsPane = pane
    section = .wallets
  }

  /// ⌘N: Wallets, with the address field focused.
  func requestAddWallet() {
    openWallets(pane: .wallets)
    pendingAction = .focusWalletAddress
  }

  /// ⌘F: Assets, with the search field focused.
  func requestFind() {
    openAssets(filter: assetsFilter)
    pendingAction = .focusAssetSearch
  }

  /// Returns true, once, when `action` is waiting for the calling screen.
  @discardableResult
  func consume(_ action: PendingAction) -> Bool {
    guard pendingAction == action else { return false }
    pendingAction = nil
    return true
  }
}

enum MacWalletsPane: String, CaseIterable, Identifiable {
  case wallets = "Wallets"
  case tokens = "Tokens"

  var id: String { rawValue }
}

/// One slice of the portfolio the Assets list is limited to, picked in a chart.
struct MacSliceFilter: Equatable, Hashable {
  var grouping: PortfolioGrouping
  var key: String

  /// The key `PortfolioAnalytics.breakdown` gives the slice this holding is in.
  /// Core builds these keys in a function that is not public, so the rules are
  /// repeated here; the render tests check them against `breakdown`.
  static func key(of asset: TrackedAsset, in grouping: PortfolioGrouping) -> String {
    switch grouping {
    case .asset: CoinIdentity.key(for: asset)
    case .network:
      HoldingCustody(asset) == .manual ? "\(asset.chainId)|\(asset.chainName)" : asset.chainId
    case .source: PortfolioAnalytics.sourceKey(for: asset) ?? "asset:\(asset.id)"
    case .state: HoldingState(asset).rawValue
    case .kind: HoldingKind(asset).rawValue
    }
  }

  func matches(_ asset: TrackedAsset) -> Bool {
    Self.key(of: asset, in: grouping) == key
  }

  /// The slice's name ("Base", "Staked", "Main"), taken from the breakdown of
  /// `holdings`; a name built from the first matching holding when the slice
  /// has no priced holding.
  func label(in holdings: [TrackedAsset]) -> String {
    PortfolioAnalytics.breakdown(holdings, by: grouping).slices.first { $0.key == key }?.label
      ?? Self.fallbackLabel(of: holdings.first(where: matches), grouping: grouping) ?? key
  }

  private static func fallbackLabel(of asset: TrackedAsset?, grouping: PortfolioGrouping)
    -> String?
  {
    guard let asset else { return nil }
    switch grouping {
    case .asset: return CoinIdentity.displaySymbol(for: asset)
    case .network: return asset.exchangeProvider?.label ?? asset.chainName
    case .source: return asset.walletLabel
    case .state: return HoldingState(asset).displayName
    case .kind: return HoldingKind(asset).displayName
    }
  }
}

/// The Scan button, ⌘R and the empty states all start (or stop) a scan the
/// same way.
@MainActor
enum MacScanAction {
  static func isAvailable(_ state: AppState) -> Bool {
    state.scanning || !(state.syncing || state.syncPersistencePending || !state.hasScanSources)
  }

  static func perform(_ state: AppState) {
    if state.scanning {
      state.cancelScan()
    } else {
      state.startScan()
    }
  }
}
