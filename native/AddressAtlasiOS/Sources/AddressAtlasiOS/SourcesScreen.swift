import AddressAtlasCore
import SwiftUI

/// What is read to build the portfolio: wallets, exchanges, manual holdings
/// and custom tokens. One tab with a switcher; each list keeps its own add
/// sheet, which the "+" menu (and other screens, through
/// `IOSNavigationModel.pendingAction`) opens.
enum SourcesSegment: String, CaseIterable, Identifiable, Hashable, Sendable {
  case wallets
  case exchanges
  case holdings
  case tokens

  var id: String { rawValue }

  var title: String {
    switch self {
    case .wallets: "Wallets"
    case .exchanges: "Exchanges"
    case .holdings: "Holdings"
    case .tokens: "Tokens"
    }
  }

  var addAction: IOSPendingAction {
    switch self {
    case .wallets: .addWallet
    case .exchanges: .connectExchange
    case .holdings: .addManualHolding
    case .tokens: .addCustomToken
    }
  }

  var addTitle: String {
    switch self {
    case .wallets: "Add wallet"
    case .exchanges: "Connect exchange"
    case .holdings: "Add holding"
    case .tokens: "Add token"
    }
  }

  static func segment(for action: IOSPendingAction) -> SourcesSegment? {
    switch action {
    case .addWallet: .wallets
    case .connectExchange: .exchanges
    case .addManualHolding: .holdings
    case .addCustomToken: .tokens
    case .runFirstScan: nil
    }
  }
}

struct SourcesScreen: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: IOSNavigationModel
  @State private var segment: SourcesSegment = SourcesScreen.initialSegment

  private static var initialSegment: SourcesSegment {
    #if DEBUG
      if let segment = DemoFixture.sourcesSegment { return segment }
    #endif
    return .wallets
  }

  var body: some View {
    VStack(spacing: 0) {
      switcher
      Group {
        switch segment {
        case .wallets: WalletsScreen()
        case .exchanges: ExchangesScreen()
        case .holdings: TokensScreen(list: .holdings)
        case .tokens: TokensScreen(list: .customTokens)
        }
      }
      .environment(\.iosPageIsEmbedded, true)
      .id(segment)
    }
    .background(AtlasCanvasBackground().ignoresSafeArea())
    .iosTitle("Sources")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          ForEach(SourcesSegment.allCases) { segment in
            Button {
              navigation.open(.sources, then: segment.addAction)
            } label: {
              Text(segment.addTitle)
            }
          }
        } label: {
          Image(systemName: "plus")
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(state.vaultEditsDisabled)
        .accessibilityLabel("Add source")
        .accessibilityIdentifier("sources-add-menu")
      }
    }
    .onAppear(perform: followPendingAction)
    .onChange(of: navigation.pendingAction) { _, _ in followPendingAction() }
  }

  /// A request from another screen shows the list that owns its sheet; that
  /// list then consumes the request and presents the sheet.
  private func followPendingAction() {
    guard let action = navigation.pendingAction,
      let target = SourcesSegment.segment(for: action), target != segment
    else { return }
    segment = target
  }

  private var switcher: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(SourcesSegment.allCases) { item in
          IOSChip(item.title, isSelected: item == segment) { segment = item }
            .accessibilityIdentifier("sources-segment-\(item.rawValue)")
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 4)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Sources")
  }
}
