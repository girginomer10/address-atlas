import AddressAtlasCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
  @EnvironmentObject private var state: AppState

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

    var ordinal: String {
      let index = Self.allCases.firstIndex(of: self) ?? 0
      return String(format: "%02d", index + 1)
    }
  }

  @State private var selected: Section = .portfolio

  var body: some View {
    HStack(spacing: 0) {
      Sidebar(
        selection: $selected,
        onNavigate: {
          state.clearTransientMessagesForNavigation()
        })
      Rectangle().fill(AtlasTheme.rule).frame(width: 1)
      Group {
        switch selected {
        case .portfolio: PortfolioView()
        case .wallets: WalletsView()
        case .assets: AssetsView()
        case .tokens: TokenAllowlistView()
        case .snapshots: SnapshotsView()
        case .exchanges: ExchangesView()
        case .sync: SyncView()
        case .export: ExportView()
        case .settings: SettingsView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 900, minHeight: 600)
    .background(AtlasTheme.paper)
  }
}

struct Sidebar: View {
  @Binding var selection: MainView.Section
  var onNavigate: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      BrandLockup()
        .padding(.bottom, 20)
        .overlay(alignment: .bottom) {
          Rectangle().fill(AtlasTheme.rule).frame(height: 1)
        }

      ScrollView {
        VStack(spacing: 2) {
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
              HStack(spacing: 12) {
                Image(systemName: item.systemImage)
                  .frame(width: 18)
                Text(item.rawValue)
                  .frame(maxWidth: .infinity, alignment: .leading)
                Text(item.ordinal)
                  .font(.system(.caption, design: .serif))
                  .italic()
                  .opacity(0.72)
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .frame(minHeight: 42)
              .contentShape(Rectangle())
            }
            .buttonStyle(SidebarButtonStyle(active: selection == item))
            .accessibilityAddTraits(selection == item ? .isSelected : [])
            .accessibilityValue(selection == item ? "Selected" : "")
          }
        }
      }
      .scrollIndicators(.visible)

      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Circle().stroke(AtlasTheme.gain, lineWidth: 1).frame(width: 8, height: 8)
          Text("LOCAL VAULT")
        }
        Text("Encrypted locally")
        Text("RPC/API from Mac")
        Text("Server cannot decrypt")
      }
      .font(.caption2.monospaced())
      .textCase(.uppercase)
      .foregroundStyle(AtlasTheme.ink3)
      .padding(.top, 18)
      .overlay(alignment: .top) {
        Rectangle().fill(AtlasTheme.rule).frame(height: 1)
      }
    }
    .padding(22)
    .frame(width: 228)
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .background(AtlasTheme.paper)
  }
}
