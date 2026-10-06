import AddressAtlasCore
import SwiftUI

/// Portfolio overview for compact widths. Every number comes from the same
/// `AppState` derivations the macOS `PortfolioView` uses (validated snapshot
/// total, dust visibility, unpriced counts, scan warnings); only the layout is
/// rebuilt for a phone: a hero value card with the change since the previous
/// snapshot, a compact source summary, collapsible partial-scan warnings, and
/// the allocation of the latest snapshot. Scanning lives in the navigation
/// bar and in pull-to-refresh.
struct PortfolioScreen: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var reachability: NetworkReachability
  @EnvironmentObject private var navigation: IOSNavigationModel

  var body: some View {
    let current = PortfolioCurrentHoldings(state: state)
    IOSPage(title: "Portfolio") {
      if !state.hasScanSources {
        PortfolioStartCard()
      } else if !reachability.isReachable {
        PortfolioOfflineBanner()
      }

      if let latest = state.latestScan, state.hasScanSources {
        if current.drift.hasChanges {
          PortfolioSourcesChangedBanner(drift: current.drift)
        }

        PortfolioHero(
          total: current.total,
          generatedAt: latest.generatedAt,
          // The banner already says the sources changed since this scan.
          change: current.drift.hasChanges ? nil : change(latest: latest),
          unpricedCount: current.unpricedCount,
          hiddenDustCount: current.hiddenDustCount,
          hiddenDustValueUsd: current.hiddenDustValueUsd,
          stats: stats(visibleCount: current.visible.count)
        )

        if !latest.warnings.isEmpty {
          PortfolioWarnings(warnings: latest.warnings)
        }

        PortfolioAllocationSection(
          allocation: PortfolioAllocation.make(
            visibleHoldings: current.visible,
            hiddenDustCount: current.hiddenDustCount,
            total: current.total
          ),
          unpricedCount: current.unpricedCount,
          openAssets: { symbol in openAssets(symbol: symbol) }
        )

        Link(destination: AppState.coinGeckoAttributionURL) {
          Text("Prices by CoinGecko")
            .font(.caption2)
            .foregroundStyle(AtlasTheme.ink3)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityLabel("Data provided by CoinGecko")
        .accessibilityHint("Opens the CoinGecko website.")
      } else if state.hasScanSources {
        PortfolioFirstScanCard(sourceCount: sourceCount)
      }
    }
    .toolbar {
      // With no sources the empty state carries the actions; a disabled
      // scan button would only add noise.
      if state.hasScanSources || state.scanning {
        ToolbarItem(placement: .topBarTrailing) {
          PortfolioScanToolbarButton()
        }
      }
    }
    .refreshable {
      await refresh()
    }
    .onAppear { runPendingFirstScan() }
    .onChange(of: navigation.pendingAction) { _, _ in runPendingFirstScan() }
  }

  private var sourceCount: Int {
    state.document.wallets.count + state.document.exchangeConnections.count
      + state.document.manualHoldings.filter(\.enabled).count
  }

  private func stats(visibleCount: Int) -> [PortfolioStat] {
    var stats = [
      PortfolioStat(
        id: "wallets", systemImage: "wallet.pass",
        count: state.document.wallets.count, singular: "wallet", plural: "wallets"),
      PortfolioStat(
        id: "exchanges", systemImage: "building.columns",
        count: state.document.exchangeConnections.count, singular: "exchange",
        plural: "exchanges"),
      PortfolioStat(
        id: "assets", systemImage: "circle.grid.2x2",
        count: visibleCount, singular: "asset", plural: "assets"),
    ]
    // Zero-count sources are noise on the hero; assets always show.
    stats.removeAll { $0.count == 0 && $0.id != "assets" }
    return stats
  }

  /// Change against the snapshot before the latest one, using the same
  /// validated-total derivation for both sides. When the two scans read
  /// different wallets, exchanges, or manual holdings the difference is not
  /// a market move, so the hero says the sources changed instead.
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
    return .moved(delta: delta, fraction: previousTotal > 0 ? delta / previousTotal : nil)
  }

  /// Nil opens every asset; a symbol opens Assets filtered to it.
  private func openAssets(symbol: String?) {
    state.clearTransientMessagesForNavigation()
    navigation.openAssets(symbol: symbol)
  }

  /// `IOSPendingAction.runFirstScan`: another screen (the toast after the
  /// first source is saved, or Wallets) asked Portfolio to start a scan.
  private func runPendingFirstScan() {
    guard navigation.consume(.runFirstScan) else { return }
    guard !state.scanning, PortfolioScanAdmission.canStart(state) else { return }
    state.startScanIfReachable(reachability)
  }

  /// Pull-to-refresh follows the toolbar button's admission rules but never
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

/// The latest snapshot as the person's saved sources see it now: holdings
/// from a wallet, exchange, or manual holding that was removed (or paused)
/// since the scan are left out until the next scan, so a deleted wallet
/// never keeps counting. The stored snapshot itself is unchanged (Snapshots
/// still shows it in full). Dust and pricing rules match `AppState`.
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

/// Sources were added, removed, or edited after the latest scan.
private struct PortfolioSourcesChangedBanner: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var drift: ScanSourceDrift

  private var detail: String {
    var parts: [String] = []
    if drift.added > 0 { parts.append("\(drift.added) new") }
    if drift.removed > 0 { parts.append("\(drift.removed) removed") }
    if drift.edited > 0 { parts.append("\(drift.edited) edited") }
    return parts.joined(separator: ", ")
  }

  private var copy: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Sources changed")
        .font(.callout.weight(.semibold))
        .foregroundStyle(AtlasTheme.ink)
      Text("\(detail) since the last scan")
        .font(.footnote)
        .foregroundStyle(AtlasTheme.ink3)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }

  var body: some View {
    let layout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
      : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
    layout {
      if !dynamicTypeSize.isAccessibilitySize {
        Image(systemName: "arrow.triangle.2.circlepath")
          .font(.body.weight(.semibold))
          .foregroundStyle(AtlasTheme.accent)
          .frame(width: 32, height: 32)
          .background(AtlasTheme.accent.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
          .accessibilityHidden(true)
      }
      copy
      if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 4) }
      PortfolioCompactScanButton()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous)
        .fill(AtlasTheme.accent.opacity(0.07))
    )
    .overlay {
      RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous)
        .stroke(AtlasTheme.accent.opacity(0.2), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("portfolio-sources-changed")
  }
}

/// A small capsule scan button for inline banners.
private struct PortfolioCompactScanButton: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var reachability: NetworkReachability

  var body: some View {
    Button {
      if state.scanning {
        state.cancelScan()
      } else {
        state.startScanIfReachable(reachability)
      }
    } label: {
      HStack(spacing: 6) {
        if state.scanning {
          ProgressView()
            .controlSize(.mini)
            .tint(AtlasTheme.paper)
        }
        Text(state.scanning ? "Scanning" : "Scan")
      }
      .font(.callout.weight(.semibold))
      .foregroundStyle(AtlasTheme.paper)
      .padding(.horizontal, 16)
      .frame(minHeight: 34)
      .background(Capsule().fill(AtlasTheme.accent))
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .fixedSize()
    .disabled(PortfolioScanAdmission.controlDisabled(state))
    .opacity(PortfolioScanAdmission.controlDisabled(state) ? 0.5 : 1)
    .accessibilityLabel(state.scanning ? "Cancel scan" : "Scan now")
    .accessibilityIdentifier("portfolio-sources-changed-scan")
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

private struct PortfolioScanToolbarButton: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var reachability: NetworkReachability

  var body: some View {
    Button {
      if state.scanning {
        state.cancelScan()
      } else {
        state.startScanIfReachable(reachability)
      }
    } label: {
      if state.scanning {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.small)
          Text("Cancel")
        }
      } else {
        Label("Scan now", systemImage: "arrow.clockwise")
      }
    }
    .disabled(PortfolioScanAdmission.controlDisabled(state))
    .accessibilityLabel(state.scanning ? "Cancel scan" : "Scan now")
    .accessibilityHint(
      state.scanning
        ? "Stops the running scan. The previous snapshot is kept."
        : "Reads balances for every saved wallet and exchange and saves a new snapshot on this device."
    )
    .accessibilityIdentifier("portfolio-scan-button")
  }
}

/// The same action as a full-width button, for the first-scan call to action.
private struct PortfolioScanButton: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var reachability: NetworkReachability
  var title: String

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
            .tint(AtlasTheme.paper)
          Text("Scanning… Tap to cancel")
        } else {
          Label(title, systemImage: "arrow.clockwise")
        }
      }
      .frame(maxWidth: .infinity, minHeight: 48)
    }
    .buttonStyle(AtlasPrimaryButtonStyle())
    .disabled(PortfolioScanAdmission.controlDisabled(state))
    .accessibilityLabel(state.scanning ? "Cancel scan" : title)
    .accessibilityIdentifier("portfolio-first-scan-button")
  }
}

// MARK: - Empty and first-run states

/// No sources yet: the two ways to start, one tap each.
private struct PortfolioStartCard: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: IOSNavigationModel

  var body: some View {
    VStack(spacing: 20) {
      PortfolioBadgeIcon(systemImage: "sparkles")

      VStack(spacing: 6) {
        Text("Add your first source")
          .font(.title2.weight(.bold))
          .multilineTextAlignment(.center)
          .accessibilityAddTraits(.isHeader)
        Text("Track a wallet by its public address, or connect an exchange read-only.")
          .font(.callout)
          .foregroundStyle(AtlasTheme.ink2)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(spacing: 10) {
        Button {
          open(.wallets, then: .addWallet)
        } label: {
          Label {
            Text("Add a wallet")
          } icon: {
            Image(systemName: "wallet.pass.fill").accessibilityHidden(true)
          }
          .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(AtlasPrimaryButtonStyle())
        .accessibilityLabel("Add a wallet")
        .accessibilityIdentifier("portfolio-empty-add-wallet")

        Button {
          open(.exchanges, then: .connectExchange)
        } label: {
          Label {
            Text("Connect an exchange")
          } icon: {
            Image(systemName: "building.columns.fill").accessibilityHidden(true)
          }
          .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        .accessibilityLabel("Connect an exchange")
        .accessibilityIdentifier("portfolio-empty-connect-exchange")
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 28)
    .frame(maxWidth: .infinity)
    .background(
      RoundedRectangle(cornerRadius: AtlasRadius.large, style: .continuous)
        .fill(
          LinearGradient(
            colors: [AtlasTheme.accent.opacity(0.10), AtlasTheme.surface],
            startPoint: .top,
            endPoint: .bottom
          )
        )
    )
    .overlay {
      RoundedRectangle(cornerRadius: AtlasRadius.large, style: .continuous)
        .stroke(AtlasTheme.ruleSoft, lineWidth: 1)
    }
  }

  private func open(_ section: AtlasSection, then action: IOSPendingAction) {
    state.clearTransientMessagesForNavigation()
    navigation.open(section, then: action)
  }
}

/// Sources saved but no snapshot yet.
private struct PortfolioFirstScanCard: View {
  var sourceCount: Int

  var body: some View {
    VStack(spacing: 18) {
      PortfolioBadgeIcon(systemImage: "arrow.clockwise")
      VStack(spacing: 6) {
        Text("Run your first scan")
          .font(.title2.weight(.bold))
          .multilineTextAlignment(.center)
          .accessibilityAddTraits(.isHeader)
        Text(
          "Reads the balances of your \(sourceCount) source\(sourceCount == 1 ? "" : "s") and saves a private snapshot."
        )
        .font(.callout)
        .foregroundStyle(AtlasTheme.ink2)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      }
      PortfolioScanButton(title: "Scan now")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 28)
    .frame(maxWidth: .infinity)
    .background(
      RoundedRectangle(cornerRadius: AtlasRadius.large, style: .continuous)
        .fill(AtlasTheme.surface)
    )
    .overlay {
      RoundedRectangle(cornerRadius: AtlasRadius.large, style: .continuous)
        .stroke(AtlasTheme.ruleSoft, lineWidth: 1)
    }
  }
}

private struct PortfolioBadgeIcon: View {
  var systemImage: String

  var body: some View {
    Image(systemName: systemImage)
      .font(.title2.weight(.semibold))
      .foregroundStyle(AtlasTheme.paper)
      .frame(width: 56, height: 56)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(
            LinearGradient(
              colors: [AtlasTheme.accent, AtlasTheme.accent.opacity(0.75)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
      )
      .shadow(color: AtlasTheme.accent.opacity(0.25), radius: 10, y: 4)
      .accessibilityHidden(true)
  }
}

private struct PortfolioOfflineBanner: View {
  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "wifi.slash")
        .foregroundStyle(AtlasTheme.warning)
        .accessibilityHidden(true)
      Text("Offline. Scans resume when you reconnect.")
        .font(.callout)
        .foregroundStyle(AtlasTheme.ink2)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(AtlasTheme.warning.opacity(0.09))
    .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Hero

private enum PortfolioChange {
  /// Same sources as the previous scan: a market move.
  case moved(delta: Double, fraction: Double?)
  /// The previous scan read different wallets, exchanges, or holdings.
  case sourcesChanged
}

private struct PortfolioStat: Identifiable {
  var id: String
  var systemImage: String
  var count: Int
  var singular: String
  var plural: String

  var text: String { "\(count) \(count == 1 ? singular : plural)" }
}

private struct PortfolioHero: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ScaledMetric(relativeTo: .largeTitle) private var totalSize: CGFloat = 44
  var total: Double
  var generatedAt: Date
  var change: PortfolioChange?
  var unpricedCount: Int
  var hiddenDustCount: Int
  var hiddenDustValueUsd: Double
  var stats: [PortfolioStat]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Text(unpricedCount > 0 ? "Priced subtotal" : "Total value")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(AtlasTheme.ink3)
          if unpricedCount > 0 {
            Badge("Partial", color: AtlasTheme.warning)
          }
        }
        Text(money(total))
          .font(.system(size: totalSize, weight: .bold, design: .rounded))
          .monospacedDigit()
          .tracking(-1)
          .lineLimit(1)
          .minimumScaleFactor(0.5)
          .contentTransition(reduceMotion ? .identity : .numericText(value: total))
          .animation(
            AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
            value: total
          )
          .accessibilityIdentifier("portfolio-total-value")
        if let change {
          PortfolioChangeLine(change: change)
        }
        TimelineView(.periodic(from: .now, by: 30)) { context in
          Text("Updated \(Self.relative(generatedAt, now: context.date))")
            .font(.footnote)
            .foregroundStyle(AtlasTheme.ink3)
        }
      }

      if unpricedCount > 0 || hiddenDustCount > 0 {
        VStack(alignment: .leading, spacing: 3) {
          if unpricedCount > 0 {
            Text("\(unpricedCount) without a USD price, not in the subtotal")
          }
          if hiddenDustCount > 0 {
            Text("\(hiddenDustCount) small balances hidden (\(money(hiddenDustValueUsd))), still counted")
          }
        }
        .font(.caption)
        .foregroundStyle(AtlasTheme.ink3)
        .fixedSize(horizontal: false, vertical: true)
      }

      Divider().overlay(AtlasTheme.ruleSoft)

      PortfolioStatsRow(stats: stats)
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: AtlasRadius.large, style: .continuous)
        .fill(AtlasTheme.surface)
    )
    .overlay {
      RoundedRectangle(cornerRadius: AtlasRadius.large, style: .continuous)
        .stroke(AtlasTheme.ruleSoft, lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
    .accessibilityElement(children: .combine)
  }

  static func relative(_ date: Date, now: Date) -> String {
    if now.timeIntervalSince(date) < 60 { return "just now" }
    return date.formatted(
      Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide)
        .locale(AtlasFormatting.locale)
    )
  }
}

private struct PortfolioChangeLine: View {
  var change: PortfolioChange

  private var delta: Double {
    if case .moved(let delta, _) = change { return delta }
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
    default: AtlasTheme.ink3
    }
  }

  private var symbol: String {
    if case .sourcesChanged = change { return "arrow.triangle.branch" }
    switch direction {
    case 1: return "arrow.up.right"
    case -1: return "arrow.down.right"
    default: return "equal"
    }
  }

  private var amountText: String {
    let sign = direction > 0 ? "+" : (direction < 0 ? "−" : "")
    return sign + money(abs(delta))
  }

  /// Shown only from 0.1% up, where it says more than the amount.
  private var percentText: String? {
    guard case .moved(_, let fraction?) = change, fraction.isFinite, abs(fraction) >= 0.001,
      direction != 0
    else { return nil }
    return AtlasPercent.signedChange(fraction)
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: symbol)
        .font(.footnote.weight(.bold))
        .foregroundStyle(color)
        .accessibilityHidden(true)
      text
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityText)
    .accessibilityIdentifier("portfolio-change")
  }

  private var text: Text {
    if case .sourcesChanged = change {
      return Text("Sources changed since the previous scan")
        .font(.subheadline)
        .foregroundStyle(AtlasTheme.ink3)
    }
    if direction == 0 {
      return Text("No change since last scan")
        .font(.subheadline)
        .foregroundStyle(AtlasTheme.ink3)
    }
    let amount = Text(percentText.map { "\(amountText) (\($0))" } ?? amountText)
      .font(.subheadline.weight(.semibold).monospacedDigit())
      .foregroundStyle(color)
    let caption = Text("since last scan")
      .font(.subheadline)
      .foregroundStyle(AtlasTheme.ink3)
    return Text("\(amount) \(caption)")
  }

  private var accessibilityText: String {
    if case .sourcesChanged = change {
      return "Sources changed since the previous scan, so no change is shown"
    }
    guard direction != 0 else { return "No change since the previous scan" }
    let percent = percentText.map { ", \($0.dropFirst())" } ?? ""
    return "\(direction > 0 ? "Up" : "Down") \(money(abs(delta)))\(percent) since the previous scan"
  }
}

private struct PortfolioStatsRow: View {
  var stats: [PortfolioStat]

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 18) {
        ForEach(stats) { stat in item(stat) }
        Spacer(minLength: 0)
      }
      VStack(alignment: .leading, spacing: 8) {
        ForEach(stats) { stat in item(stat) }
      }
    }
  }

  private func item(_ stat: PortfolioStat) -> some View {
    HStack(spacing: 6) {
      Image(systemName: stat.systemImage)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(AtlasTheme.ink3)
        .accessibilityHidden(true)
      Text(stat.text)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(AtlasTheme.ink2)
        .fixedSize()
    }
    // The text alone is the element, so the symbol's name never surfaces.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(stat.text)
    .accessibilityIdentifier("portfolio-metric-\(stat.id)")
  }
}

// MARK: - Warnings

private struct PortfolioWarnings: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var isExpanded = false
  var warnings: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 10) {
          if !dynamicTypeSize.isAccessibilitySize {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(AtlasTheme.warning)
              .accessibilityHidden(true)
          }
          VStack(alignment: .leading, spacing: 1) {
            Text("Last scan was incomplete")
              .font(.callout.weight(.semibold))
              .foregroundStyle(AtlasTheme.ink)
            Text("\(warnings.count) issue\(warnings.count == 1 ? "" : "s"). Some balances may be missing.")
              .font(.footnote)
              .foregroundStyle(AtlasTheme.ink3)
          }
          .multilineTextAlignment(.leading)
          Spacer(minLength: 8)
          Image(systemName: "chevron.down")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AtlasTheme.ink3)
            .rotationEffect(.degrees(isExpanded ? 180 : 0))
            .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
      .accessibilityHint(isExpanded ? "Hides the warnings." : "Shows the warnings.")
      .accessibilityIdentifier("portfolio-warnings-toggle")

      if isExpanded {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
            HStack(alignment: .top, spacing: 9) {
              Circle()
                .fill(AtlasTheme.warning)
                .frame(width: 5, height: 5)
                .padding(.top, 7)
                .accessibilityHidden(true)
              Text(warning)
                .font(.callout)
                .foregroundStyle(AtlasTheme.ink2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
        .transition(.opacity)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
    .background(AtlasTheme.warning.opacity(0.09))
    .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous)
        .stroke(AtlasTheme.warning.opacity(0.25), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Partial scan warnings")
  }
}

// MARK: - Allocation

private struct PortfolioAllocationEntry: Identifiable {
  enum Subject {
    /// Every visible priced holding of one symbol, across networks and
    /// sources.
    case group(symbol: String, holdings: [TrackedAsset])
    case other(count: Int, hiddenDustCount: Int)
  }

  var id: String
  var subject: Subject
  var valueUsd: Double
  var fraction: Double
}

/// Top priced assets by validated USD value (one row per symbol, merged
/// across networks) plus an "Other" bucket that absorbs the remaining priced
/// value, including rows hidden as dust, so the bars always sum to the same
/// headline value the hero shows.
private struct PortfolioAllocation {
  static let rowLimit = 6

  var entries: [PortfolioAllocationEntry]

  @MainActor
  static func make(
    visibleHoldings: [TrackedAsset],
    hiddenDustCount: Int,
    total: Double
  ) -> PortfolioAllocation {
    let denominator = total.isFinite && total > 0 ? total : 0
    let priced = visibleHoldings.filter { AppState.isPricedForDisplay($0) }

    var order: [String] = []
    var bySymbol: [String: [TrackedAsset]] = [:]
    for asset in priced {
      let key = asset.symbol.uppercased()
      if bySymbol[key] == nil { order.append(key) }
      bySymbol[key, default: []].append(asset)
    }
    let groups =
      order
      .compactMap { key -> (key: String, holdings: [TrackedAsset], value: Double)? in
        guard let holdings = bySymbol[key] else { return nil }
        return (key, holdings, AppState.validatedPortfolioTotal(holdings) ?? 0)
      }
      .sorted { lhs, rhs in
        lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
      }

    let top = Array(groups.prefix(rowLimit))
    var entries = top.map { group in
      PortfolioAllocationEntry(
        id: "symbol-\(group.key)",
        subject: .group(symbol: group.holdings[0].symbol, holdings: group.holdings),
        valueUsd: group.value,
        fraction: fraction(group.value, of: denominator)
      )
    }
    let topHoldings = top.flatMap(\.holdings)
    let otherCount = priced.count - topHoldings.count + hiddenDustCount
    if otherCount > 0 {
      let topValue = AppState.validatedPortfolioTotal(topHoldings) ?? 0
      let otherValue = max(0, total - topValue)
      entries.append(
        PortfolioAllocationEntry(
          id: "portfolio-allocation-other",
          subject: .other(count: otherCount, hiddenDustCount: hiddenDustCount),
          valueUsd: otherValue,
          fraction: fraction(otherValue, of: denominator)
        ))
    }
    return PortfolioAllocation(entries: entries)
  }

  private static func fraction(_ value: Double, of denominator: Double) -> Double {
    guard denominator > 0, value.isFinite, value > 0 else { return 0 }
    return min(1, value / denominator)
  }
}

private struct PortfolioAllocationSection: View {
  var allocation: PortfolioAllocation
  var unpricedCount: Int
  /// Nil opens every asset; a symbol opens Assets filtered to it.
  var openAssets: (String?) -> Void
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var headerTitle: some View {
    Text("Allocation")
      .font(.title3.weight(.semibold))
      .foregroundStyle(AtlasTheme.ink)
  }

  private var headerLink: some View {
    HStack(spacing: 4) {
      Text("All assets")
      Image(systemName: "chevron.right")
        .font(.footnote.weight(.semibold))
    }
    .font(.subheadline.weight(.medium))
    .foregroundStyle(AtlasTheme.accent)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button {
        openAssets(nil)
      } label: {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .firstTextBaseline) {
            headerTitle
            Spacer(minLength: 8)
            headerLink
          }
          VStack(alignment: .leading, spacing: 4) {
            headerTitle
            headerLink
          }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Allocation, all assets")
      .accessibilityAddTraits(.isHeader)
      .accessibilityHint("Opens Assets.")
      .accessibilityIdentifier("portfolio-allocation-header")

      if allocation.entries.isEmpty {
        EmptyState(
          title: "Nothing priced yet",
          systemImage: "chart.pie",
          copy: "None of the latest holdings has a USD price."
        )
      } else {
        VStack(spacing: 0) {
          ForEach(allocation.entries) { entry in
            PortfolioAllocationRow(entry: entry, openAssets: openAssets)
            if entry.id != allocation.entries.last?.id {
              Divider()
                .overlay(AtlasTheme.ruleSoft)
                .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 16 : 66)
            }
          }
          if unpricedCount > 0 {
            Divider().overlay(AtlasTheme.ruleSoft)
            Text("\(unpricedCount) without a USD price, not shown")
              .font(.caption)
              .foregroundStyle(AtlasTheme.ink3)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 16)
              .padding(.vertical, 12)
          }
        }
        .background(
          RoundedRectangle(cornerRadius: AtlasRadius.large, style: .continuous)
            .fill(AtlasTheme.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.large, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: AtlasRadius.large, style: .continuous)
            .stroke(AtlasTheme.ruleSoft, lineWidth: 1)
        }
      }
    }
  }
}

private struct PortfolioAllocationRow: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var entry: PortfolioAllocationEntry
  var openAssets: (String?) -> Void

  private var isOther: Bool {
    if case .other = entry.subject { return true }
    return false
  }

  private var title: String {
    switch entry.subject {
    case .group(let symbol, _): symbol
    case .other: "Other"
    }
  }

  private var subtitle: String {
    switch entry.subject {
    case .group(_, let holdings):
      let networks = Set(holdings.map(\.atlasIOSVenue))
      if networks.count > 1 { return "On \(networks.count) networks" }
      let chain = holdings[0].atlasIOSVenue
      if holdings.count > 1 { return "\(chain) · \(holdings.count) sources" }
      let source = holdings[0].walletLabel.flatMap { $0.isEmpty ? nil : $0 }
      guard let source, source != chain else { return chain }
      return "\(chain) · \(source)"
    case .other(let count, let hiddenDustCount):
      return hiddenDustCount > 0
        ? "\(count) more, \(hiddenDustCount) small"
        : "\(count) more holding\(count == 1 ? "" : "s")"
    }
  }

  private var percentText: String { AtlasPercent.text(entry.fraction) }

  private var barColor: Color {
    switch entry.subject {
    case .group(let symbol, _):
      Color(
        hue: TokenMonogram.hue(for: symbol), saturation: 0.62,
        brightness: colorScheme == .dark ? 0.9 : 0.7)
    case .other:
      AtlasTheme.ink3
    }
  }

  private var accessibilityLabel: String {
    switch entry.subject {
    case .group(_, let holdings) where holdings.count == 1:
      "\(AtlasIOSAccessibility.holding(holdings[0])), \(percentText) of portfolio value"
    case .group(let symbol, _):
      "\(symbol), \(subtitle), value \(money(entry.valueUsd)), \(percentText) of portfolio value"
    case .other:
      "Other, \(subtitle), value \(money(entry.valueUsd)), \(percentText) of portfolio value"
    }
  }

  private var symbolFilter: String? {
    if case .group(let symbol, _) = entry.subject { return symbol }
    return nil
  }

  var body: some View {
    Button {
      openAssets(symbolFilter)
    } label: {
      content(showsChevron: true)
    }
    .buttonStyle(PortfolioRowButtonStyle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint(symbolFilter.map { "Shows every \($0) holding in Assets." } ?? "Opens Assets.")
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("portfolio-allocation-row-\(entry.id)")
  }

  @ViewBuilder
  private func content(showsChevron: Bool) -> some View {
    if dynamicTypeSize.isAccessibilitySize {
      accessibilitySizeContent
    } else {
      regularContent(showsChevron: showsChevron)
    }
  }

  /// One fact per line so nothing truncates at accessibility text sizes.
  private var accessibilitySizeContent: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.body.weight(.semibold))
        .foregroundStyle(AtlasTheme.ink)
      Text(money(entry.valueUsd))
        .font(.body.monospacedDigit())
        .foregroundStyle(AtlasTheme.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
      Text("\(percentText) · \(subtitle)")
        .font(.caption)
        .foregroundStyle(AtlasTheme.ink3)
      PortfolioAllocationBar(fraction: entry.fraction, color: barColor)
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .contentShape(Rectangle())
  }

  private func regularContent(showsChevron: Bool) -> some View {
    HStack(alignment: .center, spacing: 12) {
      TokenMonogram(symbol: title, size: 38, isPlaceholder: isOther)

      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(title)
            .font(.body.weight(.semibold))
            .foregroundStyle(AtlasTheme.ink)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 8)
          Text(money(entry.valueUsd))
            .font(.callout.monospacedDigit().weight(.semibold))
            .foregroundStyle(AtlasTheme.ink)
            .lineLimit(1)
            .layoutPriority(1)
        }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(AtlasTheme.ink3)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 8)
          Text(percentText)
            .font(.caption.monospacedDigit())
            .foregroundStyle(AtlasTheme.ink3)
            .lineLimit(1)
            .layoutPriority(1)
        }
        PortfolioAllocationBar(fraction: entry.fraction, color: barColor)
      }

      if showsChevron {
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(AtlasTheme.ink3)
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(minHeight: 66)
    .contentShape(Rectangle())
  }
}

private struct PortfolioRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(configuration.isPressed ? AtlasTheme.surfaceMuted.opacity(0.6) : Color.clear)
  }
}

private struct PortfolioAllocationBar: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var fraction: Double
  var color: Color

  private var clampedFraction: CGFloat {
    guard fraction.isFinite else { return 0 }
    return CGFloat(min(1, max(0, fraction)))
  }

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(AtlasTheme.surfaceMuted)
        Capsule()
          .fill(color)
          .frame(width: max(clampedFraction > 0 ? 4 : 0, clampedFraction * proxy.size.width))
      }
    }
    .frame(height: 5)
    .animation(
      AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
      value: fraction
    )
    .accessibilityHidden(true)
  }
}
