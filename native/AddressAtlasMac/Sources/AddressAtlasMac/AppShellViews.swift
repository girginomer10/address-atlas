import AddressAtlasCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The unlocked window: a sidebar of seven sections and the selected screen.
/// Which section is open (and whether a coin's detail is open on top of it)
/// lives in `MacNavigationModel`, so menu commands can drive it too.
struct MainView: View {
  enum Section: String, CaseIterable, Identifiable {
    case portfolio = "Portfolio"
    case assets = "Assets"
    case history = "History"
    case wallets = "Wallets"
    case exchanges = "Exchanges"
    case export = "Export"
    case settings = "Settings"

    var id: String { rawValue }

    var title: String { rawValue }

    var systemImage: String {
      switch self {
      case .portfolio: "chart.pie"
      case .assets: "list.bullet.rectangle"
      case .history: "clock.arrow.circlepath"
      case .wallets: "wallet.pass"
      case .exchanges: "building.columns"
      case .export: "square.and.arrow.up"
      case .settings: "gearshape"
      }
    }

    /// 1 to 7: the digit of the ⌘ shortcut that opens the section.
    var shortcutDigit: Int {
      (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }
  }

  @StateObject private var ownNavigation: MacNavigationModel
  private let providedNavigation: MacNavigationModel?

  /// `navigation` is shared with the menu commands in the app; tests and
  /// previews omit it and get a model of their own.
  init(initialSection: Section = .portfolio, navigation: MacNavigationModel? = nil) {
    providedNavigation = navigation
    _ownNavigation = StateObject(wrappedValue: MacNavigationModel(section: initialSection))
  }

  var body: some View {
    MainShell(navigation: providedNavigation ?? ownNavigation)
  }
}

private struct MainShell: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var preferences: AtlasDisplayPreferences
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject var navigation: MacNavigationModel

  var body: some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        Sidebar(
          navigation: navigation,
          onNavigate: {
            state.clearTransientMessagesForNavigation()
          })
        Rectangle().fill(AtlasTheme.outline).frame(width: max(1, AtlasTheme.shape.cardBorderWidth))
        screen
          .environmentObject(navigation)
          .transition(
            reduceMotion
              ? .opacity
              : .opacity.combined(with: .move(edge: .trailing))
          )
          .animation(
            AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
            value: navigation.section
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(
        width: geometry.size.width,
        height: geometry.size.height,
        alignment: .topLeading
      )
    }
    .frame(minWidth: 900, minHeight: 600)
    .clipped()
    .background(AtlasTheme.canvas)
  }

  @ViewBuilder
  private var screen: some View {
    if let coinKey = navigation.coinKey {
      CoinDetailView(
        coinKey: coinKey, visualization: preferences.portfolioVisualization,
        grouping: preferences.grouping
      )
      .id("coin-\(coinKey)")
    } else {
      Group {
        switch navigation.section {
        case .portfolio: PortfolioView()
        case .assets: AssetsView()
        case .history: HistoryView()
        case .wallets: WalletsView()
        case .exchanges: ExchangesView()
        case .export: ExportView()
        case .settings: SettingsView()
        }
      }
      .id(navigation.section)
    }
  }
}

// MARK: - Sidebar

struct Sidebar: View {
  @EnvironmentObject private var state: AppState
  @ObservedObject var navigation: MacNavigationModel
  var onNavigate: () -> Void

  static let width: CGFloat = 208

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      MacBrand()
        .padding(.horizontal, 6)
        .padding(.top, 6)

      VStack(spacing: 4) {
        ForEach(MainView.Section.allCases) { item in
          let selected = navigation.section == item
          Button {
            guard !(selected && navigation.coinKey == nil) else { return }
            // Clear the source page's transient status before SwiftUI installs
            // the destination. An `onChange` on the parent runs after the
            // selection mutation and can erase a message emitted by the new
            // destination during that same update cycle.
            onNavigate()
            navigation.go(item)
          } label: {
            HStack(spacing: 11) {
              Image(systemName: item.systemImage)
                .font(.callout.weight(selected ? .semibold : .regular))
                .frame(width: 20)
              Text(item.title)
                .frame(maxWidth: .infinity, alignment: .leading)
              Text("\u{2318}\(item.shortcutDigit)")
                .font(AtlasTheme.font(.label, .caption))
                .opacity(0.7)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(minHeight: 38)
            .contentShape(RoundedRectangle(cornerRadius: AtlasRadius.control))
          }
          .buttonStyle(SidebarButtonStyle(active: selected))
          .accessibilityLabel(item.title)
          .accessibilityHint("Command \(item.shortcutDigit)")
          .accessibilityAddTraits(selected ? .isSelected : [])
          .accessibilityValue(selected ? "Selected" : "")
        }
      }

      Spacer(minLength: 0)

      if state.scanning {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Scanning\u{2026}")
            .font(AtlasTheme.font(.body, .callout))
            .foregroundStyle(AtlasTheme.ink2)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
      }
    }
    .padding(18)
    .frame(width: Self.width)
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .background(AtlasTheme.surface)
  }
}

/// The app's name with its mark.
struct MacBrand: View {
  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "map.fill")
        .font(.callout.weight(.semibold))
        .foregroundStyle(AtlasTheme.onAccent)
        .frame(width: 32, height: 32)
        .atlasChrome(
          fill: AtlasTheme.accent,
          border: AtlasTheme.outline,
          level: .control,
          radius: AtlasTheme.shape.pillControls ? 12 : AtlasRadius.control,
          borderWidth: AtlasTheme.shape.hasBoldBorders ? AtlasTheme.shape.controlBorderWidth : 0
        )
        .accessibilityHidden(true)
      Text("Address Atlas")
        .font(AtlasTheme.font(.display, .headline, weight: .bold))
        .foregroundStyle(AtlasTheme.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .accessibilityElement(children: .combine)
  }
}
