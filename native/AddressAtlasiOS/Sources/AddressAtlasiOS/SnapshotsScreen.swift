import AddressAtlasCore
import SwiftUI

/// Encrypted scan history kept on this device, newest first. Each row shows
/// when the scan ran, its total, the change against the previous (older)
/// snapshot, and any partial-scan warnings; tapping opens the snapshot with
/// its top holdings. Removal (swipe, context menu, or the detail sheet)
/// always asks first and goes through `AppState.removeScanRun(id:)`.
struct SnapshotsScreen: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: IOSNavigationModel
  @State private var selectedRunID: UUID?
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
        Section {
          IOSPersistentStatus()
            .listRowBackground(AtlasTheme.surface)
        }
      }

      if runs.isEmpty {
        Section {
          emptyState
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 24, leading: 0, bottom: 0, trailing: 0))
        }
      } else {
        Section {
          ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
            row(run, previous: index + 1 < runs.count ? runs[index + 1] : nil)
          }
        } footer: {
          footer
        }
        .listRowBackground(AtlasTheme.surface)
        .listRowSeparatorTint(AtlasTheme.ruleSoft)
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(AtlasTheme.canvas)
    .navigationTitle("Snapshots")
    .navigationBarTitleDisplayMode(.large)
    .toolbarBackground(AtlasTheme.canvas, for: .navigationBar)
    .sheet(item: selectedRunBinding(runs)) { selection in
      SnapshotDetailSheet(
        run: selection.run,
        previous: selection.previous,
        isLatest: isLatest(selection.run),
        onDelete: { remove(selection.run) })
    }
  }

  // MARK: Rows

  private func row(_ run: ScanRunRecord, previous: ScanRunRecord?) -> some View {
    let isRemoving = removingID == run.id
    return Button {
      selectedRunID = run.id
    } label: {
      SnapshotRowView(run: run, change: SnapshotChange(run: run, previous: previous, state: state))
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
        Label("Delete snapshot", systemImage: "trash")
      }
      .disabled(state.vaultEditsDisabled)
    }
    .accessibilityHint("Shows the snapshot's holdings.")
    .accessibilityAction(named: "Remove snapshot") {
      guard !state.vaultEditsDisabled else { return }
      pendingRemoval = run
    }
    .accessibilityIdentifier("snapshot-row-\(run.id.uuidString.lowercased())")
    // Attached per row so the dialog (a popover on newer systems) points at
    // the snapshot being removed.
    .confirmationDialog(
      "Delete this snapshot?",
      isPresented: Binding(
        get: { pendingRemoval?.id == run.id },
        set: { if !$0, pendingRemoval?.id == run.id { pendingRemoval = nil } }),
      titleVisibility: .visible
    ) {
      Button("Delete snapshot", role: .destructive) { remove(run) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(Self.removalMessage(run, isLatest: isLatest(run)))
    }
    .accessibilityLabel(
      SnapshotRowView.accessibilityText(
        run: run, change: SnapshotChange(run: run, previous: previous, state: state)))
  }

  private func isLatest(_ run: ScanRunRecord) -> Bool {
    state.latestScan?.id == run.id
  }

  private func remove(_ run: ScanRunRecord) {
    guard !state.vaultEditsDisabled else { return }
    pendingRemoval = nil
    if selectedRunID == run.id { selectedRunID = nil }
    removingID = run.id
    Task {
      await state.removeScanRun(id: run.id)
      removingID = nil
    }
  }

  static func removalMessage(_ run: ScanRunRecord, isLatest: Bool) -> String {
    let base = "\(AtlasFormatting.dateTime(run.generatedAt)) · \(money(run.totalUsd))."
    return isLatest
      ? "\(base) Portfolio and Assets will show the previous snapshot."
      : "\(base) This removes it from this device."
  }

  private struct Selection: Identifiable {
    var run: ScanRunRecord
    var previous: ScanRunRecord?
    var id: UUID { run.id }
  }

  /// The sheet follows the stored record, so a removal (here or from another
  /// device via sync) closes it instead of showing a stale snapshot.
  private func selectedRunBinding(_ runs: [ScanRunRecord]) -> Binding<Selection?> {
    Binding(
      get: {
        guard let id = selectedRunID, let index = runs.firstIndex(where: { $0.id == id })
        else { return nil }
        return Selection(run: runs[index], previous: index + 1 < runs.count ? runs[index + 1] : nil)
      },
      set: { selectedRunID = $0?.id })
  }

  // MARK: Footer and empty state

  private var footer: some View {
    VStack(alignment: .leading, spacing: 6) {
      let removedCount = state.lastSaveRemovedScanRunCount
      if removedCount > 0 {
        Label(
          "Removed \(removedCount) oldest snapshot\(removedCount == 1 ? "" : "s") to stay within the size limit.",
          systemImage: "info.circle")
      }
      Text("Keeps the latest \(AppState.maximumStoredScanRuns) snapshots on this device.")
    }
    .font(.footnote)
    .foregroundStyle(AtlasTheme.ink3)
    .textCase(nil)
    .padding(.top, 4)
  }

  @ViewBuilder
  private var emptyState: some View {
    if state.scanning {
      SnapshotsEmptyView(
        systemImage: "clock.arrow.circlepath",
        title: "Scanning…",
        copy: "The first snapshot appears here when the scan finishes.",
        showsProgress: true)
    } else if state.hasScanSources {
      SnapshotsEmptyView(
        systemImage: "clock.arrow.circlepath",
        title: "No snapshots yet",
        copy: "Every scan saves a snapshot here.",
        actionTitle: "Go to Portfolio",
        action: { navigation.open(.portfolio) })
    } else {
      SnapshotsEmptyView(
        systemImage: "clock.arrow.circlepath",
        title: "No snapshots yet",
        copy: "Add a wallet, then scan. Every scan saves a snapshot here.",
        actionTitle: "Add a wallet",
        action: { navigation.open(.wallets, then: .addWallet) })
    }
  }
}

// MARK: - Change

/// Difference against the previous (older) snapshot's stored total. When the
/// two scans read different wallets, exchanges, or manual holdings, the
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
    // Below 0.1% the percentage adds nothing the amount does not already
    // say, matching the Portfolio hero.
    guard let fraction, abs(fraction) >= 0.001 else { return amount }
    return "\(amount) (\(AtlasPercent.signedChange(fraction)))"
  }

  /// The header line in the detail sheet.
  var detailText: String {
    if sourcesChanged { return "Sources changed since the previous snapshot" }
    return "\(text) since previous"
  }

  var accessibilityText: String {
    if sourcesChanged { return "sources changed since the previous snapshot" }
    guard direction != 0 else { return "no change since the previous snapshot" }
    var text = "\(direction > 0 ? "up" : "down") \(money(abs(delta)))"
    if let fraction, abs(fraction) >= 0.001 { text += ", \(AtlasPercent.text(abs(fraction)))" }
    return text + " since the previous snapshot"
  }
}

// MARK: - Row

/// Date and relative time lead; the total and change sit trailing only when
/// everything fits on one line, otherwise (narrow widths, large text) they
/// move under the date so the date is never squeezed.
private struct SnapshotRowView: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var run: ScanRunRecord
  var change: SnapshotChange?

  var body: some View {
    Group {
      // Every row uses the same layout; the date side wraps before the
      // total moves, so rows never switch shape with "Just now" vs
      // "2 minutes ago".
      if dynamicTypeSize.isAccessibilitySize {
        stacked
      } else {
        inline
      }
    }
    .padding(.vertical, 6)
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
      .font(.body.weight(.semibold))
      .foregroundStyle(AtlasTheme.ink)
  }

  private var metaText: some View {
    TimelineView(.everyMinute) { context in
      Text(
        "\(SnapshotFormatting.relative(run.generatedAt, now: context.date)) · \(SnapshotFormatting.assetCount(run))"
      )
    }
    .font(.subheadline)
    .foregroundStyle(AtlasTheme.ink3)
  }

  @ViewBuilder
  private var metaLine: some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 4) {
        metaText
        if !run.warnings.isEmpty {
          SnapshotWarningBadge(count: run.warnings.count)
        }
      }
    } else if run.warnings.isEmpty {
      metaText
    } else {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          metaText.fixedSize()
          SnapshotWarningBadge(count: run.warnings.count)
        }
        VStack(alignment: .leading, spacing: 4) {
          metaText
          SnapshotWarningBadge(count: run.warnings.count)
        }
      }
    }
  }

  private var totalText: some View {
    Text(money(run.totalUsd))
      .font(.body.weight(.semibold).monospacedDigit())
      .foregroundStyle(AtlasTheme.ink)
  }

  @ViewBuilder
  private var changeText: some View {
    if let change {
      Text(change.text)
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(change.color)
    }
  }

  static func accessibilityText(run: ScanRunRecord, change: SnapshotChange?) -> String {
    var parts = [
      AtlasFormatting.dateTime(run.generatedAt),
      SnapshotFormatting.relative(run.generatedAt),
      money(run.totalUsd),
      SnapshotFormatting.assetCount(run),
    ]
    if let change { parts.append(change.accessibilityText) }
    if !run.warnings.isEmpty {
      parts.append("\(run.warnings.count) warning\(run.warnings.count == 1 ? "" : "s")")
    }
    return parts.joined(separator: ", ")
  }
}

private struct SnapshotWarningBadge: View {
  var count: Int

  var body: some View {
    Label("\(count)", systemImage: "exclamationmark.triangle.fill")
      .labelStyle(.titleAndIcon)
      .font(.caption.weight(.semibold))
      .foregroundStyle(AtlasTheme.warning)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(AtlasTheme.warning.opacity(0.12))
      .clipShape(Capsule())
      .accessibilityLabel("\(count) warning\(count == 1 ? "" : "s")")
  }
}

private enum SnapshotFormatting {
  static func relative(_ date: Date, now: Date = Date()) -> String {
    if abs(now.timeIntervalSince(date)) < 60 { return "Just now" }
    return date.formatted(
      .relative(presentation: .named, unitsStyle: .wide).locale(AtlasFormatting.locale))
  }

  static func assetCount(_ run: ScanRunRecord) -> String {
    "\(run.holdings.count) asset\(run.holdings.count == 1 ? "" : "s")"
  }
}

// MARK: - Empty state

private struct SnapshotsEmptyView: View {
  var systemImage: String
  var title: String
  var copy: String
  var showsProgress = false
  var actionTitle: String?
  var action: () -> Void = {}

  var body: some View {
    VStack(spacing: 14) {
      ZStack {
        if showsProgress {
          ProgressView()
        } else {
          Image(systemName: systemImage)
            .font(.title2.weight(.semibold))
            .foregroundStyle(AtlasTheme.accent)
        }
      }
      .frame(width: 60, height: 60)
      .background(AtlasTheme.accent.opacity(0.10))
      .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
      .accessibilityHidden(true)
      VStack(spacing: 6) {
        Text(title)
          .font(.title3.weight(.semibold))
          .foregroundStyle(AtlasTheme.ink)
        Text(copy)
          .font(.callout)
          .foregroundStyle(AtlasTheme.ink3)
      }
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      if let actionTitle {
        Button(actionTitle, action: action)
          .buttonStyle(AtlasPrimaryButtonStyle())
          .padding(.top, 4)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 32)
    .padding(.horizontal, 20)
  }
}

// MARK: - Detail sheet

/// One snapshot: total, date, change against the previous snapshot, its
/// warnings, and its holdings (largest first, with share of the total).
private struct SnapshotDetailSheet: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.dismiss) private var dismiss
  var run: ScanRunRecord
  var previous: ScanRunRecord?
  var isLatest: Bool
  var onDelete: () -> Void
  @State private var showsAllHoldings = false
  @State private var confirmingRemoval = false

  private static let topHoldingCount = 8

  private var sortedHoldings: [TrackedAsset] {
    AppState.sortedHoldingsForDisplay(
      AppState.applyingWalletLabels(to: run.holdings, wallets: state.document.wallets))
  }

  var body: some View {
    let holdings = sortedHoldings
    let visible = showsAllHoldings ? holdings : Array(holdings.prefix(Self.topHoldingCount))
    NavigationStack {
      List {
        Section {
          header
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))
        }

        if !run.warnings.isEmpty {
          Section("Warnings") {
            ForEach(Array(run.warnings.enumerated()), id: \.offset) { _, warning in
              HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                  .font(.subheadline)
                  .foregroundStyle(AtlasTheme.warning)
                  .padding(.top, 2)
                  .accessibilityHidden(true)
                Text(warning)
                  .font(.callout)
                  .foregroundStyle(AtlasTheme.ink2)
                  .textSelection(.enabled)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .padding(.vertical, 2)
              .accessibilityElement(children: .combine)
              .accessibilityLabel("Warning: \(warning)")
            }
          }
          .listRowBackground(AtlasTheme.surface)
        }

        if !holdings.isEmpty {
          Section {
            ForEach(visible) { asset in
              SnapshotHoldingRow(asset: asset, total: run.totalUsd)
            }
            if holdings.count > Self.topHoldingCount {
              Button(showsAllHoldings ? "Show top \(Self.topHoldingCount)" : "Show all \(holdings.count)") {
                showsAllHoldings.toggle()
              }
              .font(.callout.weight(.semibold))
              .foregroundStyle(AtlasTheme.accent)
              .frame(minHeight: 44)
            }
          } header: {
            Text(showsAllHoldings ? "Holdings" : "Top holdings")
          }
          .listRowBackground(AtlasTheme.surface)
        }

        Section {
          Button(role: .destructive) {
            confirmingRemoval = true
          } label: {
            Label("Delete snapshot", systemImage: "trash")
              .frame(maxWidth: .infinity, minHeight: 44)
          }
          .foregroundStyle(AtlasTheme.loss)
          .disabled(state.vaultEditsDisabled)
          .confirmationDialog(
            "Delete this snapshot?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
          ) {
            Button("Delete snapshot", role: .destructive) {
              dismiss()
              onDelete()
            }
            Button("Cancel", role: .cancel) {}
          } message: {
            Text(SnapshotsScreen.removalMessage(run, isLatest: isLatest))
          }
        }
        .listRowBackground(AtlasTheme.surface)
      }
      .listStyle(.insetGrouped)
      .listSectionSpacing(.compact)
      .scrollContentBackground(.hidden)
      .background(AtlasTheme.canvas)
      .navigationTitle("Snapshot")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(AtlasTheme.canvas, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .atlasDetailSheetPresentation()
  }

  private var header: some View {
    let change = SnapshotChange(run: run, previous: previous, state: state)
    return VStack(alignment: .leading, spacing: 6) {
      Text(AtlasFormatting.dateTime(run.generatedAt))
        .font(.subheadline.weight(.medium))
        .foregroundStyle(AtlasTheme.ink3)
      Text(money(run.totalUsd))
        .font(.largeTitle.weight(.semibold).monospacedDigit())
        .foregroundStyle(AtlasTheme.ink)
        .lineLimit(2)
        .minimumScaleFactor(0.5)
      if let change {
        Text(change.detailText)
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(change.color)
      }
      Text(summaryLine)
        .font(.subheadline)
        .foregroundStyle(AtlasTheme.ink3)
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private var summaryLine: String {
    var parts = [
      SnapshotFormatting.relative(run.generatedAt), SnapshotFormatting.assetCount(run),
    ]
    if run.inputCount > 0 {
      // `inputCount` is the number of wallet addresses the scan read.
      parts.append("\(run.inputCount) wallet\(run.inputCount == 1 ? "" : "s") scanned")
    }
    return parts.joined(separator: " · ")
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
    case .unpriced: "Unpriced"
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
              .font(.body.weight(.semibold))
          }
          Text(network)
            .font(.subheadline)
            .foregroundStyle(AtlasTheme.ink3)
          value
        }
        .fixedSize(horizontal: false, vertical: true)
      } else {
        HStack(spacing: 12) {
          TokenMonogram(symbol: asset.symbol, size: 36)
          VStack(alignment: .leading, spacing: 2) {
            Text(asset.symbol)
              .font(.body.weight(.semibold))
              .lineLimit(1)
            Text(network)
              .font(.subheadline)
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
    .padding(.vertical, 2)
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
            ? .body.weight(.semibold).monospacedDigit() : .subheadline.weight(.medium)
        )
        .foregroundStyle(asset.pricingStatus == .priced ? AtlasTheme.ink : AtlasTheme.warning)
      if let shareText {
        Text(shareText)
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(AtlasTheme.ink3)
      }
    }
  }
}
