import AddressAtlasCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  enum Section: String, CaseIterable, Identifiable {
    case portfolio = "Portfolio"
    case wallets = "Wallets"
    case assets = "Assets"
    case tokens = "Tokens"
    case snapshots = "Snapshots"
    case exchanges = "Exchanges"
    case sync = "Sync"
    case export = "Export"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
      switch self {
      case .portfolio: "chart.pie"
      case .wallets: "wallet.pass"
      case .assets: "list.bullet.rectangle"
      case .tokens: "tag"
      case .snapshots: "clock.arrow.circlepath"
      case .exchanges: "building.columns"
      case .sync: "arrow.triangle.2.circlepath"
      case .export: "square.and.arrow.down"
      case .settings: "gearshape"
      }
    }

  }

  @State private var selected: Section

  init(initialSection: Section = .portfolio) {
    _selected = State(initialValue: initialSection)
  }

  var body: some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        Sidebar(
          selection: $selected,
          onNavigate: {
            state.clearTransientMessagesForNavigation()
          })
        Rectangle().fill(AtlasTheme.ruleSoft).frame(width: 1)
        Group {
          switch selected {
          case .portfolio: PortfolioView()
          case .wallets: WalletsView()
          case .assets: AssetsView()
          case .tokens: TokenAllowlistView()
          case .snapshots: SnapshotsView()
          case .exchanges: ExchangesView()
          case .sync: SyncView(initialServerURL: state.document.syncState.serverURL)
          case .export: ExportView()
          case .settings: SettingsView()
          }
        }
        .id(selected)
        .transition(
          reduceMotion
            ? .opacity
            : .opacity.combined(with: .move(edge: .trailing))
        )
        .animation(
          AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
          value: selected
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
}

struct Sidebar: View {
  @Binding var selection: MainView.Section
  var onNavigate: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      BrandLockup()
        .padding(.horizontal, 4)
        .padding(.bottom, 4)

      ScrollView {
        VStack(spacing: 4) {
          ForEach(MainView.Section.allCases) { item in
            Button {
              guard selection != item else { return }
              // Clear the source page's transient status before SwiftUI installs
              // the destination. An `onChange` on the parent runs after the
              // selection mutation and can erase a message emitted by the new
              // destination during that same update cycle.
              onNavigate()
              selection = item
            } label: {
              HStack(spacing: 11) {
                Image(systemName: item.systemImage)
                  .font(.callout.weight(selection == item ? .semibold : .regular))
                  .frame(width: 20)
                Text(item.rawValue)
                  .frame(maxWidth: .infinity, alignment: .leading)
                if selection == item {
                  Circle()
                    .fill(AtlasTheme.paper.opacity(0.88))
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                }
              }
              .padding(.horizontal, 11)
              .padding(.vertical, 9)
              .frame(minHeight: 38)
              .contentShape(RoundedRectangle(cornerRadius: AtlasRadius.control))
            }
            .buttonStyle(SidebarButtonStyle(active: selection == item))
            .accessibilityAddTraits(selection == item ? .isSelected : [])
            .accessibilityValue(selection == item ? "Selected" : "")
          }
        }
      }
      .scrollIndicators(.hidden)

      PrivacyCard()
    }
    .padding(18)
    .frame(width: 238)
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .background(AtlasTheme.surface)
  }
}
