import AddressAtlasCore
import SwiftUI

/// The portfolio at a glance: total value in the theme's display face, what
/// changed since the previous comparable scan, a chart in one of 14 views,
/// and the largest coins. Every number comes from the same `AppState` and
/// `PortfolioAnalytics` derivations as the Mac app.
struct PortfolioScreen: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var reachability: NetworkReachability
  @EnvironmentObject private var navigation: IOSNavigationModel
  @EnvironmentObject private var preferences: AtlasDisplayPreferences

  var body: some View {
    let current = PortfolioCurrentHoldings(state: state)
    IOSPage(title: "Portfolio") {
      if !state.hasScanSources {
        PortfolioStartCard()
      } else if let latest = state.latestScan {
        if !reachability.isReachable {
          IOSNotice(
            systemImage: "wifi.slash",
            text: "You're offline. Connect to a network to scan.")
        }

        PortfolioHero(
          total: current.total,
          generatedAt: latest.generatedAt,
          change: current.drift.hasChanges ? nil : change(latest: latest),
          drift: current.drift,
          unpricedCount: latest.warnings.isEmpty ? current.unpricedCount : 0,
          hiddenDustCount: current.hiddenDustCount,
          hiddenDustValueUsd: current.hiddenDustValueUsd,
          sourceSummary: sourceSummary
        )

        if !latest.warnings.isEmpty {
          PortfolioWarnings(warnings: latest.warnings)
        }

        PortfolioChartSection()

        PortfolioTopHoldings(unpricedCount: current.unpricedCount)

        Link(destination: AppState.coinGeckoAttributionURL) {
          Text("Prices by CoinGecko")
            .font(AtlasTheme.font(.label, .caption2))
            .foregroundStyle(AtlasTheme.ink3)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityLabel("Prices by CoinGecko")
        .accessibilityHint("Opens the CoinGecko website.")
      } else {
        PortfolioFirstScanCard(sourceCount: sourceCount)
      }
    }
    .refreshable { await refresh() }
    .onAppear { runPendingFirstScan() }
    .onChange(of: navigation.pendingAction) { _, _ in runPendingFirstScan() }
  }

  private var sourceCount: Int {
    state.document.wallets.count + state.document.exchangeConnections.count
      + state.document.manualHoldings.filter(\.enabled).count
  }

  private var sourceSummary: String {
    var parts: [String] = []
    let wallets = state.document.wallets.count
    let exchanges = state.document.exchangeConnections.count
    let manual = state.document.manualHoldings.filter(\.enabled).count
    if wallets > 0 { parts.append(IOSNumber.count(wallets, "wallet")) }
    if exchanges > 0 { parts.append(IOSNumber.count(exchanges, "exchange")) }
    if manual > 0 { parts.append(IOSNumber.count(manual, "manual holding")) }
    return parts.joined(separator: ", ")
  }

  /// Change against the scan before the latest one, with the same validated
  /// total on both sides. When the two scans read different wallets,
  /// exchanges or holdings the difference is not a market move, so the hero
  /// says so instead of showing it.
  private func change(latest: ScanRunRecord) -> PortfolioChange? {
    let runs = state.document.scanRuns.sorted { $0.generatedAt > $1.generatedAt }
    guard runs.count > 1, runs[0].id == latest.id else { return nil }
    let previous = runs[1]
    guard state.scanRunsShareSources(previous, latest) else { return .sourcesChanged }
    guard let previousTotal = AppState.validatedPortfolioTotal(previous.holdings),
      let latestTotal = AppState.validatedPortfolioTotal(latest.holdings)
    else { return nil }
    let delta = latestTotal - previousTotal
    guard delta.isFinite else { return nil }
    return .moved(
      delta: delta, fraction: previousTotal > 0 ? delta / previousTotal : nil,
      since: previous.generatedAt)
  }

  /// `IOSPendingAction.runFirstScan`: another screen (the toast after the
  /// first source is saved, or Sources) asked Portfolio to start a scan.
  private func runPendingFirstScan() {
    guard navigation.consume(.runFirstScan) else { return }
    guard !state.scanning, PortfolioScanAdmission.canStart(state) else { return }
    state.startScanIfReachable(reachability)
  }

  /// Pull-to-refresh follows the Scan button's admission rules but never
  /// cancels: a pull while a scan runs just waits for it. The spinner stays
  /// until the scan finishes; leaving the page ends the wait, not the scan.
  private func refresh() async {
    if !state.scanning {
      guard PortfolioScanAdmission.canStart(state) else { return }
      state.startScanIfReachable(reachability)
      // The scan task flips `scanning` on its first hop.
      for _ in 0..<20 where !state.scanning {
        guard !Task.isCancelled else { return }
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
    while state.scanning, !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(250))
    }
  }
}

// MARK: - Current holdings

/// The latest scan as the person's saved sources see it now: holdings from a
/// wallet, exchange or manual holding that was removed (or paused) since the
/// scan are left out until the next scan, so a deleted wallet never keeps
/// counting. The stored scan itself is unchanged (History still shows it in
/// full). Dust and pricing rules match `AppState`.
@MainActor
struct PortfolioCurrentHoldings {
  var all: [TrackedAsset]
  var visible: [TrackedAsset]
  var total: Double
  var unpricedCount: Int
  var hiddenDustCount: Int
  var hiddenDustValueUsd: Double
  var drift: ScanSourceDrift

  init(state: AppState) {
    let savedKeys = state.savedScanSourceKeys
    let keep = { (asset: TrackedAsset) in AppState.holdingSourceIsSaved(asset, savedKeys: savedKeys) }
    all = (state.latestScan?.holdings ?? []).filter(keep)
    visible = state.visibleLatestHoldings.filter(keep)
    total = AppState.validatedPortfolioTotal(all) ?? 0
    unpricedCount = all.filter { $0.pricingStatus != .priced }.count
    let preferences = state.document.preferences
    if preferences.hideDust {
      let threshold = preferences.dustThreshold.isFinite ? max(0, preferences.dustThreshold) : 0
      let dust = all.filter {
        $0.pricingStatus == .priced && (!$0.valueUsd.isFinite || $0.valueUsd < threshold)
      }
      hiddenDustCount = dust.count
      hiddenDustValueUsd =
        AppState.validatedPortfolioTotal(dust.filter { $0.valueUsd.isFinite && $0.valueUsd >= 0 })
        ?? 0
    } else {
      hiddenDustCount = 0
      hiddenDustValueUsd = 0
    }
    drift = state.latestScanSourceDrift
  }
}

// MARK: - Scan control

/// Same admission rule as the macOS quick-actions panel: cancelling is
/// always allowed while a scan runs; starting waits for sync activity and
/// pending sync persistence and needs at least one source.
@MainActor
private enum PortfolioScanAdmission {
  static func canStart(_ state: AppState) -> Bool {
    !state.syncing && !state.syncPersistencePending && state.hasScanSources
  }

  static func controlDisabled(_ state: AppState) -> Bool {
    !state.scanning && !canStart(state)
  }
}

/// Scan, or Cancel while a scan runs. `prominent` stretches it for the
/// first-scan call to action.
private struct PortfolioScanButton: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var reachability: NetworkReachability
  var prominent = false

  var body: some View {
    Button {
      if state.scanning {
        state.cancelScan()
      } else {
        state.startScanIfReachable(reachability)
      }
    } label: {
      HStack(spacing: 8) {
        if state.scanning {
          ProgressView()
            .controlSize(.small)
            .tint(AtlasTheme.onAccent)
        }
        Text(state.scanning ? "Cancel" : "Scan")
      }
      .frame(maxWidth: prominent ? .infinity : nil, minHeight: prominent ? 48 : 36)
    }
    .buttonStyle(AtlasPrimaryButtonStyle())
    .fixedSize(horizontal: !prominent, vertical: false)
    .disabled(PortfolioScanAdmission.controlDisabled(state))
    .accessibilityLabel(state.scanning ? "Cancel scan" : "Scan")
    .accessibilityHint(
      state.scanning
        ? "Stops the running scan. The previous scan is kept."
        : "Reads the balances of every saved wallet and exchange and saves a scan on this device."
    )
    .accessibilityIdentifier(prominent ? "portfolio-first-scan-button" : "portfolio-scan-button")
  }
}

// MARK: - Empty and first-run states

/// No sources yet: the two ways to start, one tap each.
private struct PortfolioStartCard: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: IOSNavigationModel

  var body: some View {
    IOSCard {
      IOSEmptyState(
        systemImage: "chart.pie",
        title: "Nothing to show yet",
        copy: "Add a wallet address or an exchange to see what you hold.",
        actionTitle: "Add wallet",
        secondaryTitle: "Connect exchange",
        action: { open(.addWallet) },
        secondaryAction: { open(.connectExchange) }
      )
    }
    .accessibilityIdentifier("portfolio-empty")
  }

  private func open(_ action: IOSPendingAction) {
    state.clearTransientMessagesForNavigation()
    navigation.open(action.section, then: action)
  }
}

/// Sources saved but no scan yet.
private struct PortfolioFirstScanCard: View {
  @EnvironmentObject private var state: AppState
  var sourceCount: Int

  var body: some View {
    IOSCard {
      VStack(spacing: 16) {
        IOSEmptyState(
          systemImage: "arrow.clockwise",
          title: state.scanning ? "Scanning" : "Ready to scan",
          copy: state.scanning
            ? "Your holdings appear here when the scan finishes."
            : "Scan to read the balances of your \(IOSNumber.count(sourceCount, "source")).",
          showsProgress: state.scanning
        )
        PortfolioScanButton(prominent: true)
      }
    }
  }
}

// MARK: - Hero

private enum PortfolioChange {
  /// Same sources as the previous scan: a market move.
  case moved(delta: Double, fraction: Double?, since: Date)
  /// The previous scan read different wallets, exchanges or holdings.
  case sourcesChanged
}

private struct PortfolioHero: View {
  @Environment(\.atlasTheme) private var tokens
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ScaledMetric(relativeTo: .largeTitle) private var totalSize: CGFloat = 46
  var total: Double
  var generatedAt: Date
  var change: PortfolioChange?
  var drift: ScanSourceDrift
  var unpricedCount: Int
  var hiddenDustCount: Int
  var hiddenDustValueUsd: Double
  var sourceSummary: String

  var body: some View {
    let hero = IOSHeroStyle.current(tokens)
    IOSCard(padding: 18, fill: hero.fill, ink: hero.ink) {
      VStack(alignment: .leading, spacing: 12) {
        header(hero)
        VStack(alignment: .leading, spacing: 8) {
          Text(money(total))
            .font(AtlasTheme.font(.number, size: totalSize, relativeTo: .largeTitle, weight: .heavy))
            .tracking(AtlasTheme.tracking(.display, size: totalSize))
            .foregroundStyle(hero.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .contentTransition(reduceMotion ? .identity : .numericText(value: total))
            .animation(
              AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
              value: total
            )
            .accessibilityLabel("Total value \(money(total))")
            .accessibilityIdentifier("portfolio-total-value")
          if let change {
            PortfolioChangeLine(change: change, hero: hero)
          }
          if drift.hasChanges {
            Text(driftText)
              .font(AtlasTheme.font(.body, .subheadline))
              .foregroundStyle(hero.secondaryInk)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("portfolio-sources-changed")
          }
        }
        VStack(alignment: .leading, spacing: 3) {
          TimelineView(.periodic(from: .now, by: 30)) { context in
            Text("Last scan \(IOSNumber.relative(generatedAt, now: context.date))")
          }
          if !sourceSummary.isEmpty { Text(sourceSummary) }
          if unpricedCount > 0 {
            Text(
              "\(IOSNumber.count(unpricedCount, "holding")) \(unpricedCount == 1 ? "has" : "have") no price and \(unpricedCount == 1 ? "is" : "are") left out of the total."
            )
          }
          if hiddenDustCount > 0 {
            Text(
              "\(IOSNumber.count(hiddenDustCount, "small balance")) (\(money(hiddenDustValueUsd))) hidden but still counted."
            )
          }
        }
        .font(AtlasTheme.font(.body, .footnote))
        .foregroundStyle(hero.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private func header(_ hero: IOSHeroStyle) -> some View {
    let label = Text("Total value")
      .font(AtlasTheme.font(.label, .subheadline, weight: .semibold))
      .foregroundStyle(hero.secondaryInk)
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 10) {
        label
        PortfolioScanButton()
      }
    } else {
      HStack(alignment: .center) {
        label
        Spacer(minLength: 8)
        PortfolioScanButton()
      }
    }
  }

  private var driftText: String {
    var parts: [String] = []
    if drift.added > 0 { parts.append("\(drift.added) added") }
    if drift.removed > 0 { parts.append("\(drift.removed) removed") }
    if drift.edited > 0 { parts.append("\(drift.edited) edited") }
    return "Sources changed since the last scan (\(parts.joined(separator: ", "))). Scan to update."
  }
}

private struct PortfolioChangeLine: View {
  @Environment(\.atlasTheme) private var tokens
  var change: PortfolioChange
  var hero: IOSHeroStyle

  private var delta: Double {
    if case .moved(let delta, _, _) = change { return delta }
    return 0
  }

  private var direction: Int {
    guard case .moved = change else { return 0 }
    if delta > 0.005 { return 1 }
    if delta < -0.005 { return -1 }
    return 0
  }

  private var color: Color {
    switch direction {
    case 1: AtlasTheme.gain
    case -1: AtlasTheme.loss
    default: hero.isTinted ? tokens.palette.ink.color : AtlasTheme.ink3
    }
  }

  private var amountText: String {
    let sign = direction > 0 ? "+" : (direction < 0 ? "−" : "")
    return sign + money(abs(delta))
  }

  /// Shown only from 0.1% up, where it says more than the amount.
  private var percentText: String? {
    guard case .moved(_, let fraction?, _) = change, fraction.isFinite, abs(fraction) >= 0.001,
      direction != 0
    else { return nil }
    return AtlasPercent.signedChange(fraction)
  }

  private var sinceText: String {
    if case .moved(_, _, let since) = change { return "since \(IOSNumber.since(since))" }
    return ""
  }

  var body: some View {
    Group {
      switch change {
      case .sourcesChanged:
        Text("Sources changed since the last scan, so no change is shown.")
          .font(AtlasTheme.font(.body, .subheadline))
          .foregroundStyle(hero.secondaryInk)
      case .moved:
        if direction == 0 {
          Text("No change \(sinceText)")
            .font(AtlasTheme.font(.body, .subheadline))
            .foregroundStyle(hero.secondaryInk)
        } else {
          HStack(spacing: 8) {
            Text(percentText.map { "\(amountText) · \($0)" } ?? amountText)
              .font(AtlasTheme.font(.number, .subheadline, weight: .bold))
              .foregroundStyle(color)
              .padding(.horizontal, hero.isTinted ? 10 : 0)
              .padding(.vertical, hero.isTinted ? 4 : 0)
              .background {
                if hero.isTinted {
                  RoundedRectangle(cornerRadius: AtlasRadius.small, style: .continuous)
                    .fill(tokens.palette.surface.color)
                    .overlay {
                      RoundedRectangle(cornerRadius: AtlasRadius.small, style: .continuous)
                        .stroke(tokens.palette.outline.color, lineWidth: 1.5)
                    }
                }
              }
            Text(sinceText)
              .font(AtlasTheme.font(.body, .subheadline))
              .foregroundStyle(hero.secondaryInk)
          }
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityText)
    .accessibilityIdentifier("portfolio-change")
  }

  private var accessibilityText: String {
    if case .sourcesChanged = change {
      return "Sources changed since the last scan, so no change is shown"
    }
    guard direction != 0 else { return "No change \(sinceText)" }
    let percent = percentText.map { ", \($0.dropFirst())" } ?? ""
    return "\(direction > 0 ? "Up" : "Down") \(money(abs(delta)))\(percent) \(sinceText)"
  }
}

// MARK: - Warnings

/// What the last scan could not read, stated next to the total it affects.
private struct PortfolioWarnings: View {
  var warnings: [String]

  var body: some View {
    VStack(spacing: 8) {
      ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
        IOSNotice(systemImage: "exclamationmark.triangle.fill", text: warning)
          .accessibilityLabel("Warning: \(warning)")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("portfolio-warnings")
  }
}

// MARK: - Chart

/// The view switcher, the grouping control and the chart.
private struct PortfolioChartSection: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: IOSNavigationModel
  @EnvironmentObject private var preferences: AtlasDisplayPreferences

  var body: some View {
    let visualization = preferences.portfolioVisualization
    VStack(alignment: .leading, spacing: 10) {
      PortfolioViewSwitcher(selection: $preferences.portfolioVisualization)
      if visualization.usesGrouping {
        PortfolioGroupMenu(grouping: groupingBinding)
      }
      IOSChartCard(
        visualization: visualization,
        input: state.iosChartInput(
          grouping: preferences.grouping,
          density: IOSChartCard.density(for: visualization),
          onSelect: { selection in
            state.handleChartSelection(selection, navigation: navigation)
          })
      )
      .id(visualization)
    }
  }

  private var groupingBinding: Binding<PortfolioGrouping> {
    Binding(get: { preferences.grouping }, set: { preferences.grouping = $0 })
  }
}

/// All 14 views in one row that scrolls sideways; the choice is remembered.
private struct PortfolioViewSwitcher: View {
  @Binding var selection: PortfolioVisualization

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(PortfolioVisualization.allCases) { item in
            IOSChip(item.title, isSelected: item == selection) { selection = item }
              .id(item)
              .accessibilityIdentifier("portfolio-view-\(item.rawValue)")
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
      }
      // Reaches the screen edge so chips scroll under the gutters.
      .padding(.horizontal, -16)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Chart view")
      .onAppear { proxy.scrollTo(selection, anchor: .center) }
    }
  }
}

private struct PortfolioGroupMenu: View {
  @Binding var grouping: PortfolioGrouping

  var body: some View {
    HStack {
      Menu {
        Picker("Group by", selection: $grouping) {
          ForEach(PortfolioGrouping.allCases, id: \.self) { item in
            Text(item.displayName).tag(item)
          }
        }
      } label: {
        HStack(spacing: 6) {
          Text("Group by")
            .foregroundStyle(AtlasTheme.ink3)
          Text(grouping.displayName)
            .foregroundStyle(AtlasTheme.ink)
            .fontWeight(.semibold)
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AtlasTheme.ink3)
            .accessibilityHidden(true)
        }
        .font(AtlasTheme.font(.body, .subheadline))
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .accessibilityLabel("Group by")
      .accessibilityValue(grouping.displayName)
      .accessibilityIdentifier("portfolio-group-menu")
      Spacer(minLength: 0)
    }
  }
}

// MARK: - Top holdings

private struct PortfolioTopHoldings: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: IOSNavigationModel
  static let limit = 6
  var unpricedCount: Int

  var body: some View {
    let summaries = state.coinSummaries
    let total = summaries.reduce(0) { $0 + $1.valueUsd }
    VStack(alignment: .leading, spacing: 10) {
      IOSSectionTitle("Top holdings") {
        Button {
          state.clearTransientMessagesForNavigation()
          navigation.openAssets(filter: nil)
        } label: {
          Text("All assets")
            .font(AtlasTheme.font(.body, .subheadline, weight: .semibold))
            .foregroundStyle(AtlasTheme.accent)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Assets.")
        .accessibilityIdentifier("portfolio-all-assets")
      }
      if summaries.isEmpty {
        Text("None of the latest holdings has a USD price.")
          .font(AtlasTheme.font(.body, .callout))
          .foregroundStyle(AtlasTheme.ink2)
      } else {
        IOSCoinList(summaries: Array(summaries.prefix(Self.limit)), total: total)
      }
    }
  }
}
