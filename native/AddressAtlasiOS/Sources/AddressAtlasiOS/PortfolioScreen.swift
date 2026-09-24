import AddressAtlasCore
import SwiftUI

/// Portfolio overview for compact widths. Every number comes from the same
/// `AppState` derivations the macOS `PortfolioView` uses (validated snapshot
/// total, dust visibility, unpriced counts, scan warnings); only the layout is
/// rebuilt for a phone: a hero value card with source metrics, the scan
/// action, partial-scan warnings, and a proportional allocation of the latest
/// snapshot.
struct PortfolioScreen: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    IOSPage(
      title: "Portfolio",
      subtitle:
        "A unified view of wallets, exchange balances, custom tokens, staking, and rewards."
    ) {
      Surface {
        VStack(alignment: .leading, spacing: 18) {
          PortfolioHero(
            total: state.latestKnownValueUsd,
            generatedAt: state.latestScan?.generatedAt,
            assetCount: state.latestScan?.holdings.count ?? 0,
            unpricedCount: state.unpricedHoldingCount,
            hiddenDustCount: state.hiddenDustHoldingCount,
            hiddenDustValueUsd: state.hiddenDustValueUsd
          )
          PortfolioMetricStrip(metrics: metrics)
        }
      }

      PortfolioQuickActions()

      if let warnings = state.latestScan?.warnings, !warnings.isEmpty {
        PortfolioWarnings(warnings: warnings)
      }

      if state.latestScan != nil || state.hasScanSources {
        SectionHeader(title: "Allocation", meta: holdingsVisibilitySummary)
        PortfolioAllocationSection(
          allocation: allocation,
          hasSnapshot: state.latestScan != nil,
          unpricedCount: state.unpricedHoldingCount
        )
      }

      Link(destination: AppState.coinGeckoAttributionURL) {
        Label("Data provided by CoinGecko", systemImage: "chart.line.uptrend.xyaxis")
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink3)
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      .accessibilityHint("Opens the CoinGecko website.")
    }
  }

  private var metrics: [PortfolioMetric] {
    let warningCount = state.latestScan?.warnings.count ?? 0
    return [
      PortfolioMetric(
        id: "wallets", title: "Wallets", value: "\(state.document.wallets.count)"),
      PortfolioMetric(
        id: "exchanges", title: "Exchanges",
        value: "\(state.document.exchangeConnections.count)"),
      PortfolioMetric(
        id: "assets", title: "Visible assets", value: "\(state.visibleLatestHoldings.count)"),
      PortfolioMetric(
        id: "warnings", title: "Warnings", value: "\(warningCount)",
        highlighted: warningCount > 0),
    ]
  }

  private var allocation: PortfolioAllocation {
    PortfolioAllocation.make(
      visibleHoldings: state.visibleLatestHoldings,
      hiddenDustCount: state.hiddenDustHoldingCount,
      total: state.latestKnownValueUsd
    )
  }

  private var holdingsVisibilitySummary: String {
    guard state.hiddenDustHoldingCount > 0 else {
      return "\(state.visibleLatestHoldings.count) visible rows"
    }
    return
      "\(state.visibleLatestHoldings.count) visible, \(state.hiddenDustHoldingCount) hidden as dust (\(money(state.hiddenDustValueUsd)))"
  }
}

// MARK: - Hero

private struct PortfolioHero: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ScaledMetric(relativeTo: .largeTitle) private var totalSize: CGFloat = 40
  var total: Double
  var generatedAt: Date?
  var assetCount: Int
  var unpricedCount: Int
  var hiddenDustCount: Int
  var hiddenDustValueUsd: Double

  private var snapshotLine: String {
    let assets = "\(assetCount) asset\(assetCount == 1 ? "" : "s")"
    guard let generatedAt else { return "\(assets) · No snapshot yet" }
    return "\(assets) · Last scan \(AtlasFormatting.dateTime(generatedAt))"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text(unpricedCount > 0 ? "Priced subtotal" : "Known portfolio value")
          .font(.callout.weight(.medium))
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
        .minimumScaleFactor(0.6)
        .contentTransition(reduceMotion ? .identity : .numericText(value: total))
        .animation(
          AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
          value: total
        )
        .accessibilityIdentifier("portfolio-total-value")
      VStack(alignment: .leading, spacing: 4) {
        Text(snapshotLine)
        if unpricedCount > 0 {
          Text(
            "\(unpricedCount) awaiting a USD value; not included in the subtotal."
          )
        }
        if hiddenDustCount > 0 {
          Text(
            "\(hiddenDustCount) hidden as dust (\(money(hiddenDustValueUsd))); still counted in the total."
          )
        }
      }
      .font(.caption)
      .foregroundStyle(AtlasTheme.ink3)
      .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Metric strip

private struct PortfolioMetric: Identifiable {
  var id: String
  var title: String
  var value: String
  var highlighted = false
}

/// Four compact tiles: one row on wide layouts, two rows of two on a phone,
/// and a single column at accessibility text sizes.
private struct PortfolioMetricStrip: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var metrics: [PortfolioMetric]

  private var rows: [[PortfolioMetric]] {
    stride(from: 0, to: metrics.count, by: 2).map { start in
      Array(metrics[start..<min(start + 2, metrics.count)])
    }
  }

  var body: some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(spacing: 10) {
        ForEach(metrics) { metric in
          PortfolioMetricTile(metric: metric)
        }
      }
    } else {
      AdaptiveStack(horizontalSpacing: 10, verticalSpacing: 10) {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          HStack(spacing: 10) {
            ForEach(row) { metric in
              PortfolioMetricTile(metric: metric)
            }
          }
        }
      }
    }
  }
}

private struct PortfolioMetricTile: View {
  var metric: PortfolioMetric

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(metric.title)
        .font(.caption.weight(.medium))
        .foregroundStyle(AtlasTheme.ink3)
      Text(metric.value)
        .font(.title2.monospacedDigit().weight(.semibold))
        .foregroundStyle(metric.highlighted ? AtlasTheme.warning : AtlasTheme.ink)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(AtlasTheme.surfaceMuted.opacity(0.44))
    .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
        .stroke(AtlasTheme.ruleSoft, lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("portfolio-metric-\(metric.id)")
  }
}

// MARK: - Quick actions

private struct PortfolioQuickActions: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var reachability: NetworkReachability

  /// Same admission rule as the macOS quick-actions panel: cancelling is
  /// always allowed while a scan runs; starting waits for sync activity and
  /// pending sync persistence and needs at least one source.
  private var scanControlDisabled: Bool {
    !state.scanning
      && (state.syncing || state.syncPersistencePending || !state.hasScanSources)
  }

  var body: some View {
    Surface(style: .accent) {
      VStack(alignment: .leading, spacing: 16) {
        PanelHeader(
          title: "Refresh portfolio",
          subtitle: "Scan every saved wallet and exchange",
          systemImage: "arrow.clockwise"
        )

        if !reachability.isReachable {
          InfoCallout(
            title: "Offline",
            copy: "Connect to a network before scanning. The last snapshot stays as it is.",
            tone: .warning
          )
        }

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
              Text("Cancel scan")
            } else {
              Label("Scan now", systemImage: "arrow.clockwise")
            }
          }
          .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(AtlasPrimaryButtonStyle())
        .disabled(scanControlDisabled)
        .accessibilityHint(
          state.scanning
            ? "Stops the running scan. The previous snapshot is kept."
            : "Reads public balances for every saved wallet and exchange and saves a new snapshot on this device."
        )
        .accessibilityIdentifier("portfolio-scan-button")

        if !state.hasScanSources {
          EmptyState(
            title: "Add a source first",
            systemImage: "wallet.pass",
            copy:
              "Scans need at least one public wallet address or read-only exchange connection. Add one in Wallets or Exchanges; private keys never enter the app."
          )
        }

        VStack(alignment: .leading, spacing: 12) {
          SidebarTrustLine(title: "Encrypted storage", copy: "Protected on this device")
          SidebarTrustLine(
            title: "Read-only by design", copy: "No private keys, no withdrawal rights")
          SidebarTrustLine(
            title: "Direct connections", copy: "Addresses and balance requests go to providers")
          SidebarTrustLine(
            title: "Optional iCloud copy", copy: "Manual and encrypted; nothing uploads on its own")
        }
      }
    }
  }
}

// MARK: - Warnings

private struct PortfolioWarnings: View {
  var warnings: [String]

  var body: some View {
    Surface(style: .warning) {
      VStack(alignment: .leading, spacing: 10) {
        SectionHeader(
          title: "Partial scan warnings",
          meta: "\(warnings.count) issue\(warnings.count == 1 ? "" : "s")")
        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
          HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
              .foregroundStyle(AtlasTheme.warning)
              .accessibilityHidden(true)
            Text(warning)
              .font(.callout)
              .foregroundStyle(AtlasTheme.ink2)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Partial scan warnings")
  }
}

// MARK: - Allocation

private struct PortfolioAllocationEntry: Identifiable {
  enum Subject {
    case holding(TrackedAsset)
    case other(count: Int, hiddenDustCount: Int)
  }

  var id: String
  var subject: Subject
  var valueUsd: Double
  var fraction: Double
}

/// Top priced holdings by validated USD value plus an "Other" bucket that
/// absorbs the remaining priced value, including rows hidden as dust, so the
/// bars always sum to the same headline value the hero shows.
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
    let top = Array(priced.prefix(rowLimit))
    var entries = top.map { asset in
      PortfolioAllocationEntry(
        id: asset.id,
        subject: .holding(asset),
        valueUsd: asset.valueUsd,
        fraction: fraction(asset.valueUsd, of: denominator)
      )
    }
    let otherCount = priced.count - top.count + hiddenDustCount
    if otherCount > 0 {
      let topValue = AppState.validatedPortfolioTotal(top) ?? 0
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
  var hasSnapshot: Bool
  var unpricedCount: Int

  var body: some View {
    if !hasSnapshot {
      EmptyState(
        title: "No assets yet",
        systemImage: "wallet.pass",
        copy: "Run a scan to build the first snapshot on this device."
      )
    } else if allocation.entries.isEmpty {
      EmptyState(
        title: "Nothing priced yet",
        systemImage: "chart.pie",
        copy:
          "The latest snapshot has no holdings with a USD value, so there is no allocation to show."
      )
    } else {
      Surface(padding: 0) {
        VStack(spacing: 0) {
          ForEach(allocation.entries) { entry in
            PortfolioAllocationRow(entry: entry)
            if entry.id != allocation.entries.last?.id {
              Divider().overlay(AtlasTheme.ruleSoft)
            }
          }
          if unpricedCount > 0 {
            Divider().overlay(AtlasTheme.ruleSoft)
            Text(
              "\(unpricedCount) holding\(unpricedCount == 1 ? "" : "s") awaiting a USD value \(unpricedCount == 1 ? "is" : "are") not part of the allocation."
            )
            .font(.caption)
            .foregroundStyle(AtlasTheme.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
          }
        }
      }
    }
  }
}

private struct PortfolioAllocationRow: View {
  var entry: PortfolioAllocationEntry

  private var isOther: Bool {
    if case .other = entry.subject { return true }
    return false
  }

  private var title: String {
    switch entry.subject {
    case .holding(let asset): asset.symbol
    case .other: "Other"
    }
  }

  private var subtitle: String {
    switch entry.subject {
    case .holding(let asset):
      "\(asset.chainName) · \(asset.walletLabel ?? asset.address)"
    case .other(let count, let hiddenDustCount):
      hiddenDustCount > 0
        ? "\(count) more holding\(count == 1 ? "" : "s"), \(hiddenDustCount) hidden as dust"
        : "\(count) more holding\(count == 1 ? "" : "s")"
    }
  }

  private var percentText: String {
    if entry.fraction > 0, entry.fraction < 0.001 { return "<0.1%" }
    return entry.fraction.formatted(
      .percent.precision(.fractionLength(0...1)).locale(AtlasFormatting.locale))
  }

  private var accessibilityLabel: String {
    switch entry.subject {
    case .holding(let asset):
      "\(AtlasAccessibility.assetRowIdentity(asset)), \(percentText) of portfolio value"
    case .other:
      "Other, \(subtitle), known value \(money(entry.valueUsd)), \(percentText) of portfolio value"
    }
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Group {
        if isOther {
          Image(systemName: "ellipsis")
            .font(.caption.weight(.bold))
        } else {
          Text(String(title.prefix(1)).uppercased())
            .font(.caption.weight(.bold))
        }
      }
      .foregroundStyle(isOther ? AtlasTheme.ink3 : AtlasTheme.accent)
      .frame(width: 36, height: 36)
      .background((isOther ? AtlasTheme.ink3 : AtlasTheme.accent).opacity(0.10))
      .clipShape(Circle())
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(title)
            .font(.body.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 8)
          Text(money(entry.valueUsd))
            .font(.callout.monospacedDigit().weight(.semibold))
            .lineLimit(1)
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
        }
        PortfolioAllocationBar(
          fraction: entry.fraction,
          color: isOther ? AtlasTheme.ink3 : AtlasTheme.accent
        )
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(minHeight: 66)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityIdentifier("portfolio-allocation-row-\(entry.id)")
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
          .frame(width: clampedFraction * proxy.size.width)
      }
    }
    .frame(height: 6)
    .animation(
      AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
      value: fraction
    )
    .accessibilityHidden(true)
  }
}
