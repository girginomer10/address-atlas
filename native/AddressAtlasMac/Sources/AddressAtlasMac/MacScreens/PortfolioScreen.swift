import AddressAtlasCore
import SwiftUI

/// The first screen: the total, what changed, the chosen view of the
/// portfolio, and the largest holdings.
struct PortfolioView: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var preferences: AtlasDisplayPreferences
  @EnvironmentObject private var navigation: MacNavigationModel

  var body: some View {
    let snapshot = MacPortfolioSnapshot(state: state)
    MacPage("Portfolio") {
      if !snapshot.hasScan {
        emptyState
      } else {
        MacPortfolioHero(snapshot: snapshot)
        notes(snapshot)
        viewSection(snapshot)
        holdingsSection(snapshot)
      }
    }
  }

  // MARK: Empty

  @ViewBuilder
  private var emptyState: some View {
    if state.hasScanSources {
      MacEmptyState(
        "No scan yet", copy: "Scan to see what you hold.", systemImage: "arrow.clockwise"
      ) {
        MacScanButton()
      }
    } else {
      MacEmptyState(
        "Nothing to show yet",
        copy: "Add a wallet address or an exchange to see what you hold.",
        systemImage: "wallet.pass"
      ) {
        Button {
          navigation.requestAddWallet()
        } label: {
          Label("Add wallet", systemImage: "plus")
        }
        .buttonStyle(MacPrimaryButtonStyle())
        Button {
          navigation.go(.exchanges)
        } label: {
          Label("Connect exchange", systemImage: "building.columns")
        }
        .buttonStyle(MacSecondaryButtonStyle())
      }
    }
  }

  // MARK: Notes

  @ViewBuilder
  private func notes(_ snapshot: MacPortfolioSnapshot) -> some View {
    let warnings = snapshot.latest?.warnings ?? []
    if snapshot.driftSentence != nil || !warnings.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        if let drift = snapshot.driftSentence {
          MacNote(text: drift, tone: .info, systemImage: "arrow.triangle.2.circlepath")
        }
        if !warnings.isEmpty {
          MacScanWarnings(warnings: warnings)
        }
      }
    }
  }

  // MARK: View

  private func viewSection(_ snapshot: MacPortfolioSnapshot) -> some View {
    let visualization = preferences.portfolioVisualization
    return VStack(alignment: .leading, spacing: 14) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 14) {
          MacViewSwitcher(
            selection: $preferences.portfolioVisualization,
            options: PortfolioVisualization.allCases)
          Spacer(minLength: 8)
          if visualization.usesGrouping {
            MacGroupingMenu(
              selection: Binding(
                get: { preferences.grouping }, set: { preferences.grouping = $0 }))
          }
        }
        VStack(alignment: .leading, spacing: 10) {
          MacViewSwitcher(
            selection: $preferences.portfolioVisualization,
            options: PortfolioVisualization.allCases)
          if visualization.usesGrouping {
            MacGroupingMenu(
              selection: Binding(
                get: { preferences.grouping }, set: { preferences.grouping = $0 }))
          }
        }
      }
      Surface(padding: 16) {
        PortfolioVisualizationView(
          visualization: visualization,
          input: state.chartInput(
            grouping: preferences.grouping,
            density: .full,
            onSelect: { navigation.handle($0) }
          )
        )
        .frame(maxWidth: .infinity)
        .frame(
          height: Self.chartHeight(
            for: visualization,
            rows: MacCoinRow.rows(for: snapshot.visible).count)
        )
      }
    }
  }

  /// A height each view reads well at; the page scrolls, so none has to fit the
  /// window.
  /// `rows` is the number of coins, which sets how tall the list view must be
  /// to show every one without scrolling inside the chart.
  static func chartHeight(for visualization: PortfolioVisualization, rows: Int = 8) -> CGFloat {
    switch visualization {
    case .flow: 460
    case .concentration: 300
    case .calendar: 340
    case .overTime, .whatChanged: 380
    case .list: min(max(240, CGFloat(rows) * 45 + 64), 900)
    default: 420
    }
  }

  // MARK: Holdings

  private func holdingsSection(_ snapshot: MacPortfolioSnapshot) -> some View {
    let rows = MacCoinRow.rows(for: snapshot.visible)
    return VStack(alignment: .leading, spacing: 12) {
      MacHeading("Holdings") {
        if rows.count > Self.listLimit {
          Button("All \(rows.count) assets") { navigation.openAssets() }
            .buttonStyle(MacSecondaryButtonStyle())
        }
      }
      if rows.isEmpty {
        MacEmptyState(
          "No holdings to show",
          copy: "Every balance in the last scan is hidden as a small balance.",
          systemImage: "line.3.horizontal.decrease.circle")
      } else {
        MacCoinList(rows: Array(rows.prefix(Self.listLimit))) { navigation.openCoin($0) }
      }
      if let dust = snapshot.dustSentence {
        MacNote(text: dust, tone: .info, systemImage: "line.3.horizontal.decrease.circle")
      }
    }
  }

  private static let listLimit = 8
}

// MARK: - Hero

/// The total, its change, when it was read, and the Scan button. In themes
/// whose cards are tinted (Candy) the card takes the first pastel.
struct MacPortfolioHero: View {
  @Environment(\.atlasTheme) private var tokens
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var snapshot: MacPortfolioSnapshot

  private var tinted: Bool { tokens.shape.cardFill == .pastel }
  private var ink: Color { tinted ? tokens.color(.onPastel) : tokens.color(.ink) }
  private var quietInk: Color { tinted ? tokens.color(.onPastel).opacity(0.78) : tokens.color(.ink3) }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 24) {
        figures
        Spacer(minLength: 12)
        scanColumn(alignment: .trailing)
      }
      .frame(minWidth: 520)
      VStack(alignment: .leading, spacing: 16) {
        figures
        scanColumn(alignment: .leading)
      }
    }
    .padding(22)
    .frame(maxWidth: .infinity, alignment: .leading)
    .atlasChrome(
      fill: tinted ? tokens.chart.pastel(at: 0).color : tokens.color(.surface),
      border: tokens.color(.outline),
      showsShadow: true
    )
    .accessibilityElement(children: .contain)
  }

  private var figures: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Total value")
        .font(tokens.font(.label, .callout, weight: .semibold))
        .foregroundStyle(quietInk)
      Text(verbatim: money(snapshot.total))
        .font(tokens.chartKitDisplayFont(54, relativeTo: .largeTitle))
        .tracking(tokens.typography.display.tracking * 54)
        .foregroundStyle(ink)
        .lineLimit(1)
        .minimumScaleFactor(0.55)
        .contentTransition(.numericText(value: snapshot.total))
        .animation(
          AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
          value: snapshot.total
        )
        .accessibilityLabel("Total value, \(money(snapshot.total))")
      changeLine
      if let unpriced = snapshot.unpricedSentence {
        Text(unpriced)
          .font(tokens.font(.body, .callout))
          .foregroundStyle(ink)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel(unpriced)
      }
    }
  }

  @ViewBuilder
  private var changeLine: some View {
    switch snapshot.change {
    case .none:
      EmptyView()
    case .sourcesChanged:
      pill(
        icon: "arrow.triangle.2.circlepath",
        iconColor: tokens.color(.accent),
        fill: tokens.color(.accentSoft),
        text: "Sources changed since the last scan")
    case .moved(let delta, let fraction, let since):
      let up = delta >= 0
      let detail = fraction.map { " \u{00B7} \(MacFormat.percent($0))" } ?? ""
      pill(
        icon: delta == 0 ? "equal" : (up ? "arrow.up.right" : "arrow.down.right"),
        iconColor: delta == 0 ? tokens.color(.ink3) : tokens.color(up ? .gain : .loss),
        fill: delta == 0
          ? tokens.color(.surfaceMuted) : tokens.color(up ? .gainSoft : .lossSoft),
        text: delta == 0
          ? "No change since \(MacFormat.shortDay(since))"
          : "\(MacFormat.signedMoney(delta))\(detail) since \(MacFormat.shortDay(since))")
    }
  }

  private func pill(icon: String, iconColor: Color, fill: Color, text: String) -> some View {
    HStack(spacing: 7) {
      Image(systemName: icon)
        .font(.caption.weight(.bold))
        .foregroundStyle(iconColor)
        .accessibilityHidden(true)
      Text(verbatim: text)
        .font(tokens.chartKitNumberFont(13, weight: .semibold))
        .foregroundStyle(tokens.color(.ink))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 6)
    .macChrome(
      fill: fill,
      border: tokens.shape.hasBoldBorders ? tokens.color(.outline) : iconColor.opacity(0.3),
      isPill: tokens.shape.pillControls,
      radius: tokens.shape.radiusSmall,
      borderWidth: tokens.shape.hasBoldBorders ? min(tokens.shape.controlBorderWidth, 2) : 1,
      showsShadow: false
    )
    .accessibilityElement(children: .combine)
  }

  private func scanColumn(alignment: HorizontalAlignment) -> some View {
    VStack(alignment: alignment, spacing: 10) {
      MacScanButton()
      VStack(alignment: alignment, spacing: 3) {
        if let latest = snapshot.latest {
          Text("Last scan \(AtlasFormatting.dateTime(latest.generatedAt))")
            .font(tokens.font(.body, .callout, weight: .medium))
            .foregroundStyle(ink)
        }
        if !snapshot.sourcesText.isEmpty {
          Text(snapshot.sourcesText)
            .font(tokens.font(.label, .caption))
            .foregroundStyle(quietInk)
        }
      }
      .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
      .accessibilityElement(children: .combine)
    }
  }
}

// MARK: - Scan warnings

/// Warnings the scan reported, one plain sentence each, next to the data they
/// affect.
struct MacScanWarnings: View {
  var warnings: [String]

  var body: some View {
    Surface(style: .warning) {
      VStack(alignment: .leading, spacing: 8) {
        Text(warnings.count == 1 ? "1 warning from the last scan" : "\(warnings.count) warnings from the last scan")
          .font(AtlasTheme.font(.body, .callout, weight: .semibold))
          .foregroundStyle(AtlasTheme.ink)
          .accessibilityAddTraits(.isHeader)
        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
          MacNote(text: warning, tone: .warning)
        }
      }
    }
    .accessibilityElement(children: .contain)
  }
}

// MARK: - Selection routing

extension MacNavigationModel {
  /// What a click inside a chart opens: a coin opens its detail, a slice limits
  /// Assets, a scan opens History.
  func handle(_ selection: PortfolioChartSelection) {
    switch selection {
    case .coin(let key):
      openCoin(key)
    case .slice(let grouping, let key):
      openAssets(filter: MacSliceFilter(grouping: grouping, key: key))
    case .run(let id):
      openSnapshot(id)
    }
  }
}
