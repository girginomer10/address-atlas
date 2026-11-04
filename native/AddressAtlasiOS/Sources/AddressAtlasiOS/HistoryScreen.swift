import AddressAtlasCore
import SwiftUI

/// The scans saved on this device, newest first, under a small chart of the
/// total over time. Each row shows when the scan ran, its total and the
/// change against the scan before it; a row opens that scan. Removal always
/// asks first and goes through `AppState.removeScanRun(id:)`.
struct HistoryScreen: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: IOSNavigationModel
  @State private var pendingRemoval: ScanRunRecord?
  @State private var removingID: UUID?

  private var sortedRuns: [ScanRunRecord] {
    state.document.scanRuns.sorted { $0.generatedAt > $1.generatedAt }
  }

  private var hasPersistentStatus: Bool {
    state.operatorMessage != nil || state.persistentOperationGuidance != nil
      || !state.isAppVersionSupported
  }

  var body: some View {
    let runs = sortedRuns
    List {
      if hasPersistentStatus {
        IOSPersistentStatus()
          .iosListRow()
      }

      if runs.isEmpty {
        emptyState
          .iosListRow()
      } else {
        if runs.count > 1 {
          IOSChartCard(
            visualization: .overTime,
            input: state.iosChartInput(
              grouping: .asset, density: .compact,
              onSelect: { selection in
                state.handleChartSelection(selection, navigation: navigation)
              }),
            proportionOverride: 1.55
          )
          .iosListRow()
          .accessibilityIdentifier("history-chart")
        }
        ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
          row(run, previous: index + 1 < runs.count ? runs[index + 1] : nil)
            .iosListRow()
        }
        footer
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
          .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 24, trailing: 20))
      }
    }
    .listStyle(.plain)
    .demoScrollOffset()
    .scrollContentBackground(.hidden)
    .background(AtlasCanvasBackground().ignoresSafeArea())
    .iosTitle("History")
  }

  // MARK: Rows

  private func row(_ run: ScanRunRecord, previous: ScanRunRecord?) -> some View {
    let isRemoving = removingID == run.id
    let change = SnapshotChange(run: run, previous: previous, state: state)
    return Button {
      navigation.push(.snapshot(run.id))
    } label: {
      SnapshotRowView(run: run, change: change)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .iosCardSurface(radius: AtlasRadius.control)
        .opacity(isRemoving ? 0.4 : 1)
    }
    .buttonStyle(.plain)
    .disabled(isRemoving)
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button {
        pendingRemoval = run
      } label: {
        Label("Delete", systemImage: "trash")
      }
      .tint(AtlasTheme.loss)
      .disabled(state.vaultEditsDisabled)
    }
    .contextMenu {
      Button(role: .destructive) {
        pendingRemoval = run
      } label: {
        Label("Delete scan", systemImage: "trash")
      }
      .disabled(state.vaultEditsDisabled)
    }
    .accessibilityHint("Shows the scan's holdings.")
    .accessibilityAction(named: "Delete scan") {
      guard !state.vaultEditsDisabled else { return }
      pendingRemoval = run
    }
    .accessibilityIdentifier("snapshot-row-\(run.id.uuidString.lowercased())")
    // Attached per row so the dialog (a popover on newer systems) points at
    // the scan being removed.
    .confirmationDialog(
      "Delete this scan?",
      isPresented: Binding(
        get: { pendingRemoval?.id == run.id },
        set: { if !$0, pendingRemoval?.id == run.id { pendingRemoval = nil } }),
      titleVisibility: .visible
    ) {
      Button("Delete scan", role: .destructive) { remove(run) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(Self.removalMessage(run, isLatest: state.latestScan?.id == run.id))
    }
    .accessibilityLabel(SnapshotRowView.accessibilityText(run: run, change: change))
  }

  private func remove(_ run: ScanRunRecord) {
    guard !state.vaultEditsDisabled else { return }
    pendingRemoval = nil
    removingID = run.id
    Task {
      await state.removeScanRun(id: run.id)
      removingID = nil
    }
  }

  static func removalMessage(_ run: ScanRunRecord, isLatest: Bool) -> String {
    let base = "\(AtlasFormatting.dateTime(run.generatedAt)) · \(money(run.totalUsd))."
    return isLatest
      ? "\(base) Portfolio and Assets will show the scan before it."
      : "\(base) This removes it from this device."
  }

  // MARK: Footer and empty state

  private var footer: some View {
    VStack(alignment: .leading, spacing: 6) {
      let removedCount = state.lastSaveRemovedScanRunCount
      if removedCount > 0 {
        Label(
          "Removed the \(removedCount == 1 ? "oldest scan" : "\(removedCount) oldest scans") to stay within the size limit.",
          systemImage: "info.circle")
      }
      Text("Keeps the latest \(AppState.maximumStoredScanRuns) scans on this device.")
    }
    .font(AtlasTheme.font(.body, .footnote))
    .foregroundStyle(AtlasTheme.ink3)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var emptyState: some View {
    if state.scanning {
      IOSEmptyState(
        systemImage: "clock.arrow.circlepath",
        title: "Scanning",
        copy: "The first scan appears here when it finishes.",
        showsProgress: true)
    } else if state.hasScanSources {
      IOSEmptyState(
        systemImage: "clock.arrow.circlepath",
        title: "No scans yet",
        copy: "Every scan is saved here.",
        actionTitle: "Go to Portfolio",
        action: { navigation.open(.portfolio) })
    } else {
      IOSEmptyState(
        systemImage: "clock.arrow.circlepath",
        title: "No scans yet",
        copy: "Add a wallet address or an exchange, then scan. Every scan is saved here.",
        actionTitle: "Add wallet",
        action: { navigation.open(.sources, then: .addWallet) })
    }
  }
}

// MARK: - Change

/// Difference against the previous (older) scan's stored total. When the two
/// scans read different wallets, exchanges or manual holdings, the
/// difference is not a market move and is not shown as one.
private struct SnapshotChange {
  var delta: Double
  var fraction: Double?
  var sourcesChanged: Bool

  @MainActor
  init?(run: ScanRunRecord, previous: ScanRunRecord?, state: AppState) {
    guard let previous, run.totalUsd.isFinite, previous.totalUsd.isFinite else { return nil }
    sourcesChanged = !state.scanRunsShareSources(previous, run)
    delta = run.totalUsd - previous.totalUsd
    fraction = previous.totalUsd > 0 ? delta / previous.totalUsd : nil
  }

  /// Cent-level differences read as no change.
  private var direction: Int {
    if delta >= 0.005 { return 1 }
    if delta <= -0.005 { return -1 }
    return 0
  }

  var color: Color {
    guard !sourcesChanged else { return AtlasTheme.ink3 }
    switch direction {
    case 1: return AtlasTheme.gain
    case -1: return AtlasTheme.loss
    default: return AtlasTheme.ink3
    }
  }

  var text: String {
    if sourcesChanged { return "Sources changed" }
    guard direction != 0 else { return "No change" }
    let amount = (direction > 0 ? "+" : "−") + money(abs(delta))
    // Below 0.1% the percentage adds nothing the amount does not already say.
    guard let fraction, abs(fraction) >= 0.001 else { return amount }
    return "\(amount) · \(AtlasPercent.signedChange(fraction))"
  }

  /// The header line on the scan's own page.
  var detailText: String {
    if sourcesChanged { return "Sources changed since the scan before, so no change is shown." }
    return direction == 0 ? "No change since the scan before" : "\(text) since the scan before"
  }

  var accessibilityText: String {
    if sourcesChanged { return "sources changed since the scan before" }
    guard direction != 0 else { return "no change since the scan before" }
    var text = "\(direction > 0 ? "up" : "down") \(money(abs(delta)))"
    if let fraction, abs(fraction) >= 0.001 { text += ", \(AtlasPercent.text(abs(fraction)))" }
    return text + " since the scan before"
  }
}

// MARK: - Row

/// Date and relative time lead; the total and change sit trailing only when
/// everything fits on one line, otherwise they move under the date.
private struct SnapshotRowView: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var run: ScanRunRecord
  var change: SnapshotChange?

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        stacked
      } else {
        inline
      }
    }
    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
    .contentShape(Rectangle())
  }

  private var inline: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        dateText
        metaLine
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .trailing, spacing: 3) {
        totalText
        changeText
      }
      .fixedSize()
    }
  }

  private var stacked: some View {
    VStack(alignment: .leading, spacing: 4) {
      dateText
      metaLine
      totalText
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .padding(.top, 2)
      changeText
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private var dateText: some View {
    Text(AtlasFormatting.dateTime(run.generatedAt))
      .font(AtlasTheme.font(.body, .body, weight: .semibold))
      .foregroundStyle(AtlasTheme.ink)
  }

  private var metaText: some View {
    TimelineView(.everyMinute) { context in
      Text(
        "\(IOSNumber.relative(run.generatedAt, now: context.date)) · \(SnapshotFormatting.assetCount(run))"
      )
    }
    .font(AtlasTheme.font(.body, .subheadline))
    .foregroundStyle(AtlasTheme.ink3)
  }

  @ViewBuilder
  private var metaLine: some View {
    if run.warnings.isEmpty {
      metaText
    } else {
      VStack(alignment: .leading, spacing: 4) {
        metaText
        SnapshotWarningBadge(count: run.warnings.count)
      }
    }
  }

  private var totalText: some View {
    Text(money(run.totalUsd))
      .font(AtlasTheme.font(.number, .body, weight: .semibold))
      .foregroundStyle(AtlasTheme.ink)
  }

  @ViewBuilder
  private var changeText: some View {
    if let change {
      Text(change.text)
        .font(AtlasTheme.font(.number, .subheadline))
        .foregroundStyle(change.color)
    }
  }

  static func accessibilityText(run: ScanRunRecord, change: SnapshotChange?) -> String {
    var parts = [
      AtlasFormatting.dateTime(run.generatedAt),
      IOSNumber.relative(run.generatedAt),
      money(run.totalUsd),
      SnapshotFormatting.assetCount(run),
    ]
    if let change { parts.append(change.accessibilityText) }
    if !run.warnings.isEmpty {
      parts.append(IOSNumber.count(run.warnings.count, "warning"))
    }
    return parts.joined(separator: ", ")
  }
}

private struct SnapshotWarningBadge: View {
  var count: Int

  var body: some View {
    Badge(IOSNumber.count(count, "warning"), color: AtlasTheme.warning)
      .fixedSize()
      .accessibilityLabel(IOSNumber.count(count, "warning"))
  }
}

private enum SnapshotFormatting {
  static func assetCount(_ run: ScanRunRecord) -> String {
    IOSNumber.count(run.holdings.count, "holding")
  }
}

// MARK: - One scan

/// One saved scan: total, date, change against the scan before it, its
/// warnings, a chart of what it held, and its holdings largest first.
struct SnapshotDetailScreen: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: IOSNavigationModel
  @Environment(\.atlasTheme) private var tokens
  @ScaledMetric(relativeTo: .largeTitle) private var totalSize: CGFloat = 38
  @State private var showsAllHoldings = false
  @State private var confirmingRemoval = false
  @AppStorage("snapshot.visualization.v1") private var storedVisualization = PortfolioVisualization.map.rawValue
  var runID: UUID

  private static let topHoldingCount = 8
  /// Views that read one scan's holdings, not the whole history.
  private static let visualizations: [PortfolioVisualization] = [
    .map, .ring, .strip, .grid, .bubbles, .list,
  ]

  private var runs: [ScanRunRecord] {
    state.document.scanRuns.sorted { $0.generatedAt > $1.generatedAt }
  }

  private var visualization: PortfolioVisualization {
    let value = PortfolioVisualization(rawValue: storedVisualization) ?? .map
    return Self.visualizations.contains(value) ? value : .map
  }

  var body: some View {
    let runs = runs
    if let index = runs.firstIndex(where: { $0.id == runID }) {
      let run = runs[index]
      let previous = index + 1 < runs.count ? runs[index + 1] : nil
      content(run: run, previous: previous, isLatest: index == 0)
    } else {
      // Removed here or from another device: nothing left to show.
      IOSPage(title: "Scan") {
        IOSEmptyState(
          systemImage: "clock.arrow.circlepath",
          title: "Scan removed",
          copy: "This scan is no longer on this device.",
          actionTitle: "Back to History",
          action: { navigation.paths[.history] = [] })
      }
    }
  }

  private var sortedHoldings: (ScanRunRecord) -> [TrackedAsset] {
    { run in
      AppState.sortedHoldingsForDisplay(
        AppState.applyingWalletLabels(to: run.holdings, wallets: state.document.wallets))
    }
  }

  private func content(run: ScanRunRecord, previous: ScanRunRecord?, isLatest: Bool) -> some View {
    let holdings = sortedHoldings(run)
    let visible = showsAllHoldings ? holdings : Array(holdings.prefix(Self.topHoldingCount))
    let change = SnapshotChange(run: run, previous: previous, state: state)
    return IOSPage(title: "Scan") {
      header(run: run, change: change)

      ForEach(Array(run.warnings.enumerated()), id: \.offset) { _, warning in
        IOSNotice(systemImage: "exclamationmark.triangle.fill", text: warning)
          .accessibilityLabel("Warning: \(warning)")
      }

      if !holdings.isEmpty {
        chartSection(run: run)

        VStack(alignment: .leading, spacing: 10) {
          IOSSectionTitle(showsAllHoldings ? "Holdings" : "Top holdings")
          VStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, asset in
              SnapshotHoldingRow(asset: asset, total: run.totalUsd)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
              if index < visible.count - 1 {
                Rectangle()
                  .fill(AtlasTheme.shape.hasBoldBorders ? AtlasTheme.outline : AtlasTheme.ruleSoft)
                  .frame(height: AtlasTheme.shape.hasBoldBorders ? 1.5 : 1)
                  .padding(.horizontal, 14)
                  .accessibilityHidden(true)
              }
            }
          }
          .iosCardSurface()
          if holdings.count > Self.topHoldingCount {
            Button(showsAllHoldings ? "Show top \(Self.topHoldingCount)" : "Show all \(holdings.count)") {
              showsAllHoldings.toggle()
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            .frame(minHeight: 44)
          }
        }
      }

      Button(role: .destructive) {
        confirmingRemoval = true
      } label: {
        Label("Delete scan", systemImage: "trash")
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      .buttonStyle(AtlasSecondaryButtonStyle())
      .foregroundStyle(AtlasTheme.loss)
      .disabled(state.vaultEditsDisabled)
      .confirmationDialog(
        "Delete this scan?",
        isPresented: $confirmingRemoval,
        titleVisibility: .visible
      ) {
        Button("Delete scan", role: .destructive) {
          navigation.paths[.history] = []
          let id = run.id
          Task { await state.removeScanRun(id: id) }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(HistoryScreen.removalMessage(run, isLatest: isLatest))
      }
    }
  }

  private func header(run: ScanRunRecord, change: SnapshotChange?) -> some View {
    let hero = IOSHeroStyle.current(tokens)
    return IOSCard(padding: 18, fill: hero.fill, ink: hero.ink) {
      VStack(alignment: .leading, spacing: 6) {
        Text(AtlasFormatting.dateTime(run.generatedAt))
          .font(AtlasTheme.font(.label, .subheadline, weight: .semibold))
          .foregroundStyle(hero.secondaryInk)
        Text(money(run.totalUsd))
          .font(AtlasTheme.font(.number, size: totalSize, relativeTo: .largeTitle, weight: .heavy))
          .tracking(AtlasTheme.tracking(.display, size: totalSize))
          .foregroundStyle(hero.ink)
          .lineLimit(1)
          .minimumScaleFactor(0.5)
        if let change {
          Text(change.detailText)
            .font(AtlasTheme.font(.number, .subheadline))
            .foregroundStyle(hero.isTinted ? hero.ink : change.color)
        }
        Text(summaryLine(run))
          .font(AtlasTheme.font(.body, .subheadline))
          .foregroundStyle(hero.secondaryInk)
      }
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityElement(children: .combine)
    }
  }

  private func summaryLine(_ run: ScanRunRecord) -> String {
    var parts = [IOSNumber.relative(run.generatedAt), SnapshotFormatting.assetCount(run)]
    if run.inputCount > 0 {
      // `inputCount` is the number of wallet addresses the scan read.
      parts.append("\(IOSNumber.count(run.inputCount, "wallet")) scanned")
    }
    return parts.joined(separator: " · ")
  }

  private func chartSection(run: ScanRunRecord) -> some View {
    let input = PortfolioChartInput(
      holdings: AppState.applyingWalletLabels(to: run.holdings, wallets: state.document.wallets),
      runs: [run], grouping: .asset, sourceContext: nil, density: .full)
    return VStack(alignment: .leading, spacing: 10) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(Self.visualizations) { item in
            IOSChip(item.title, isSelected: item == visualization) {
              storedVisualization = item.rawValue
            }
          }
        }
        .padding(.horizontal, 16)
      }
      .padding(.horizontal, -16)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Chart view")
      IOSChartCard(visualization: visualization, input: input)
        .id(visualization)
    }
  }
}

private struct SnapshotHoldingRow: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var asset: TrackedAsset
  var total: Double

  private var network: String { asset.exchangeProvider?.label ?? asset.chainName }

  private var valueText: String {
    switch asset.pricingStatus {
    case .priced: money(asset.valueUsd)
    case .unpriced: "No price"
    case .valuationUnavailable: "Value unavailable"
    }
  }

  /// Holdings worth less than a cent (shown as $0.00) get no share, so a
  /// zero balance never reads "<0.1%".
  private var shareText: String? {
    guard asset.pricingStatus == .priced, total > 0, asset.valueUsd.isFinite,
      asset.valueUsd >= 0.005
    else { return nil }
    return AtlasPercent.text(asset.valueUsd / total)
  }

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 10) {
            TokenMonogram(symbol: asset.symbol, size: 40)
            Text(asset.symbol)
              .font(AtlasTheme.font(.body, .body, weight: .semibold))
          }
          Text(network)
            .font(AtlasTheme.font(.body, .subheadline))
            .foregroundStyle(AtlasTheme.ink3)
          value
        }
        .fixedSize(horizontal: false, vertical: true)
      } else {
        HStack(spacing: 12) {
          TokenMonogram(symbol: asset.symbol, size: 36)
          VStack(alignment: .leading, spacing: 2) {
            Text(asset.symbol)
              .font(AtlasTheme.font(.body, .body, weight: .semibold))
              .lineLimit(1)
            Text(network)
              .font(AtlasTheme.font(.body, .subheadline))
              .foregroundStyle(AtlasTheme.ink3)
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          value
            .fixedSize()
            .layoutPriority(1)
        }
      }
    }
    .foregroundStyle(AtlasTheme.ink)
    .frame(minHeight: 44)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      [
        AtlasIOSAccessibility.holding(asset),
        shareText.map { "\($0) of total" },
      ]
      .compactMap { $0 }.joined(separator: ", "))
  }

  private var value: some View {
    VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
      Text(valueText)
        .font(
          asset.pricingStatus == .priced
            ? AtlasTheme.font(.number, .body, weight: .semibold)
            : AtlasTheme.font(.body, .subheadline, weight: .medium)
        )
        .foregroundStyle(asset.pricingStatus == .priced ? AtlasTheme.ink : AtlasTheme.warning)
      if let shareText {
        Text(shareText)
          .font(AtlasTheme.font(.number, .subheadline))
          .foregroundStyle(AtlasTheme.ink3)
      }
    }
  }
}
