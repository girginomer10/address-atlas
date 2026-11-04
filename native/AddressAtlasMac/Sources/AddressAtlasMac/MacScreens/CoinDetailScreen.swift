import AddressAtlasCore
import SwiftUI

/// One coin: what it is worth, what state it is in, where it is held, and how
/// it changed. Opens on top of Portfolio or Assets and goes back to it.
struct CoinDetailView: View {
  var coinKey: String

  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: MacNavigationModel
  @Environment(\.macNow) private var now

  @State private var visualization: PortfolioVisualization
  @State private var grouping: PortfolioGrouping
  /// Limits the holdings list to one slice the user picked in a chart.
  @State private var rowFilter: MacSliceFilter?

  /// Groupings that split one coin in a useful way.
  static let groupings: [PortfolioGrouping] = [.network, .source, .state]

  /// `visualization` and `grouping` start the screen's own switchers; the
  /// choice is not stored, because the Portfolio's views include ones that make
  /// no sense for a single coin.
  init(
    coinKey: String,
    visualization: PortfolioVisualization = .map,
    grouping: PortfolioGrouping = .network
  ) {
    self.coinKey = coinKey
    _visualization = State(
      initialValue: visualization.worksForSingleCoin ? visualization : .map)
    _grouping = State(
      initialValue: Self.groupings.contains(grouping) ? grouping : .network)
  }

  private var holdingsCount: Int { holdings.count }

  private var holdings: [TrackedAsset] {
    state.chartHoldings.filter { CoinIdentity.key(for: $0) == coinKey }
  }

  var body: some View {
    let holdings = holdings
    let summary = PortfolioAnalytics.coinSummary(holdings, coin: coinKey)
    MacPage(summary?.symbol ?? coinKey, trailing: { backButton }) {
      if let summary {
        content(summary: summary, holdings: holdings)
      } else {
        MacEmptyState(
          "\(coinKey) isn\u{2019}t in the last scan",
          copy: "Scan again, or check that its wallet or exchange is still saved.",
          systemImage: "magnifyingglass"
        ) {
          Button("Go back") { navigation.closeCoin() }
            .buttonStyle(MacSecondaryButtonStyle())
        }
      }
    }
    .onChange(of: coinKey) { _, _ in rowFilter = nil }
  }

  private var backButton: some View {
    Button {
      navigation.closeCoin()
    } label: {
      Label(navigation.section.title, systemImage: "chevron.left")
    }
    .buttonStyle(MacSecondaryButtonStyle())
    .keyboardShortcut(.cancelAction)
    .help("Back to \(navigation.section.title) (Esc)")
    .accessibilityLabel("Back to \(navigation.section.title)")
  }

  // MARK: Content

  @ViewBuilder
  private func content(summary: CoinSummary, holdings: [TrackedAsset]) -> some View {
    let visibleTotal = PortfolioAnalytics.totalValueUsd(state.chartHoldings)
    MacCoinHeader(
      summary: summary,
      name: MacCoinRow.rows(for: holdings).first?.name ?? summary.symbol,
      shareOfPortfolio: visibleTotal > 0 ? summary.valueUsd / visibleTotal : nil)

    let widgets = widgets(for: summary)
    widgetGrid(widgets.filter { ["state", "unlock"].contains($0.id) })

    viewSection

    widgetGrid(widgets.filter { ["change", "custody"].contains($0.id) })

    CoinWidgetCard(height: 300) { CoinAmountHistoryView(input: input(grouping)) }

    holdingsSection(holdings)
  }

  private func input(_ grouping: PortfolioGrouping) -> PortfolioChartInput {
    state.chartInput(
      grouping: grouping, coinKey: coinKey, density: .full, onSelect: { select($0) })
  }

  // MARK: Widgets

  private struct Widget: Identifiable {
    let id: String
    let height: CGFloat
    let view: AnyView
  }

  /// The coin widgets that apply: state, unbonding (only when something is
  /// unbonding), change since the previous scan, and custody. Heights follow
  /// the number of rows each draws.
  private func widgets(for summary: CoinSummary) -> [Widget] {
    let stateInput = input(.state)
    var result = [
      Widget(
        id: "state", height: 104 + 34 * CGFloat(summary.states.count),
        view: AnyView(CoinStateStripView(input: stateInput)))
    ]
    if summary.states.contains(where: { $0.state == .unbonding }) {
      result.append(
        Widget(
          id: "unlock", height: 140 + 44 * CGFloat(summary.unlocks.count),
          view: AnyView(CoinUnlockTimelineView(input: stateInput, now: now))))
    }
    result.append(
      Widget(id: "change", height: 210, view: AnyView(CoinChangeView(input: input(grouping)))))
    let custody = summary.custody
    let custodyRows = [custody.walletAmount, custody.exchangeAmount, custody.manualAmount]
      .filter { $0 > 0 }.count
    result.append(
      Widget(
        id: "custody", height: 140 + 34 * CGFloat(max(1, custodyRows)),
        view: AnyView(CoinCustodyView(input: stateInput))))
    return result
  }

  /// Cards two to a row when the window is wide enough, otherwise one to a row.
  private func widgetGrid(_ widgets: [Widget]) -> some View {
    let rows = stride(from: 0, to: widgets.count, by: 2).map {
      Array(widgets[$0..<min($0 + 2, widgets.count)])
    }
    return ViewThatFits(in: .horizontal) {
      VStack(alignment: .leading, spacing: 18) {
        ForEach(rows, id: \.first?.id) { row in
          let height = row.map(\.height).max() ?? 0
          HStack(alignment: .top, spacing: 18) {
            ForEach(row) { widget in
              CoinWidgetCard(height: height) { widget.view }
            }
          }
        }
      }
      .frame(minWidth: 900)
      VStack(alignment: .leading, spacing: 18) {
        ForEach(widgets) { widget in
          CoinWidgetCard(height: widget.height) { widget.view }
        }
      }
    }
  }

  // MARK: Main view

  private var viewSection: some View {
    let options = PortfolioVisualization.allCases.filter(\.worksForSingleCoin)
    return VStack(alignment: .leading, spacing: 14) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 14) {
          MacViewSwitcher(selection: $visualization, options: options)
          Spacer(minLength: 8)
          if visualization.usesGrouping {
            MacGroupingMenu(selection: $grouping, options: Self.groupings)
          }
        }
        VStack(alignment: .leading, spacing: 10) {
          MacViewSwitcher(selection: $visualization, options: options)
          if visualization.usesGrouping {
            MacGroupingMenu(selection: $grouping, options: Self.groupings)
          }
        }
      }
      Surface(padding: 16) {
        PortfolioVisualizationView(visualization: visualization, input: input(grouping))
          .frame(maxWidth: .infinity)
          .frame(
            height: visualization == .list
              ? PortfolioView.chartHeight(for: .list, rows: holdingsCount)
              : PortfolioView.chartHeight(for: visualization) - 100)
      }
    }
  }

  // MARK: Holdings

  private func holdingsSection(_ holdings: [TrackedAsset]) -> some View {
    let shown = holdings.filter { rowFilter?.matches($0) ?? true }
      .sorted { lhs, rhs in
        let left = AppState.isPricedForDisplay(lhs) ? lhs.valueUsd : -1
        let right = AppState.isPricedForDisplay(rhs) ? rhs.valueUsd : -1
        return left == right ? lhs.id < rhs.id : left > right
      }
    return VStack(alignment: .leading, spacing: 12) {
      MacHeading("Where it is") {
        if let rowFilter {
          MacFilterChip(
            title: "\(rowFilter.grouping.displayName): \(rowFilter.label(in: holdings))"
          ) { self.rowFilter = nil }
        }
      }
      MacHoldingsTable(holdings: shown, showsSymbol: false)
    }
  }

  private func select(_ selection: PortfolioChartSelection) {
    switch selection {
    case .coin:
      break
    case .slice(let grouping, let key):
      let next = MacSliceFilter(grouping: grouping, key: key)
      rowFilter = rowFilter == next ? nil : next
    case .run(let id):
      navigation.openSnapshot(id)
    }
  }
}

/// A card around one coin widget, at the height its rows need.
struct CoinWidgetCard<Widget: View>: View {
  var height: CGFloat
  var widget: Widget

  init(height: CGFloat, @ViewBuilder _ widget: () -> Widget) {
    self.height = height
    self.widget = widget()
  }

  var body: some View {
    Surface(padding: 16) {
      widget
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }
  }
}

// MARK: - Header

/// The coin's mark and name, its value, and the figures behind it.
struct MacCoinHeader: View {
  @Environment(\.atlasTheme) private var tokens
  var summary: CoinSummary
  var name: String
  var shareOfPortfolio: Double?

  var body: some View {
    Surface(padding: 22) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 22) {
          title
          Spacer(minLength: 12)
          stats
        }
        .frame(minWidth: 520)
        VStack(alignment: .leading, spacing: 16) {
          title
          stats
        }
      }
    }
    .accessibilityElement(children: .contain)
  }

  private var title: some View {
    HStack(alignment: .center, spacing: 16) {
      CoinMark(symbol: summary.symbol, size: 52)
      VStack(alignment: .leading, spacing: 4) {
        if summary.pricedAmount > 0 {
          Text(verbatim: money(summary.valueUsd))
            .font(tokens.chartKitDisplayFont(40, relativeTo: .largeTitle))
            .tracking(tokens.typography.display.tracking * 40)
            .foregroundStyle(tokens.color(.ink))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        } else {
          Text("No price")
            .font(tokens.font(.display, size: 32, relativeTo: .title, weight: .bold))
            .foregroundStyle(tokens.color(.ink))
        }
        Text(
          verbatim: name == summary.symbol ? summary.symbol : "\(summary.symbol) \u{00B7} \(name)"
        )
        .font(tokens.font(.body, .callout))
        .foregroundStyle(tokens.color(.ink3))
        .lineLimit(1)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var stats: some View {
    HStack(alignment: .top, spacing: 28) {
      MacStat(
        label: "Amount", value: MacFormat.amount(summary.totalAmount), detail: summary.symbol)
      if let price = summary.priceUsd {
        MacStat(label: "Price", value: money(price))
      }
      if let share = shareOfPortfolio {
        MacStat(label: "Of portfolio", value: MacFormat.percent(share))
      }
    }
  }
}

// MARK: - Filter chip

/// A removable "Network: Base" tag above a list.
struct MacFilterChip: View {
  var title: String
  var onClear: () -> Void

  var body: some View {
    Button(action: onClear) {
      HStack(spacing: 6) {
        Text(title).lineLimit(1)
        Image(systemName: "xmark").font(.caption2.weight(.bold))
      }
    }
    .buttonStyle(MacChipButtonStyle(selected: true))
    .help("Show everything")
    .accessibilityLabel("\(title). Clear filter")
  }
}

// MARK: - Clock

private struct MacNowKey: EnvironmentKey {
  static var defaultValue: Date { Date() }
}

extension EnvironmentValues {
  /// "Now" for the unlock timeline. Screens read the clock here so a render
  /// test can fix it.
  var macNow: Date {
    get { self[MacNowKey.self] }
    set { self[MacNowKey.self] = newValue }
  }
}
