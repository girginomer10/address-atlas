import AddressAtlasCore
import SwiftUI

/// Saved scans: the portfolio's value over time, and every snapshot with how it
/// differs from the one before. Picking a snapshot (here or in a chart) shows
/// what it held.
struct HistoryView: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: MacNavigationModel
  @State private var pendingRemoval: UUID?

  private var runsNewestFirst: [ScanRunRecord] {
    state.document.scanRuns.sorted { $0.generatedAt > $1.generatedAt }
  }

  var body: some View {
    let runs = runsNewestFirst
    let rows = MacSnapshotRow.rows(
      runs: runs, context: ScanSourceContext(document: state.document))
    let selected = runs.first { $0.id == navigation.selectedRunID }
    MacPage("History") {
      if runs.isEmpty {
        MacEmptyState(
          "No snapshots yet",
          copy: "Each scan saves a snapshot. Scan to save the first one.",
          systemImage: "clock.arrow.circlepath"
        ) {
          MacScanButton()
        }
      } else {
        if runs.count > 1 {
          Surface(padding: 16) {
            OverTimeChartView(
              input: state.chartInput(
                grouping: .asset, density: .full, onSelect: { navigation.handle($0) })
            )
            .frame(maxWidth: .infinity)
            .frame(height: 240)
          }
        }
        if let selected {
          MacSnapshotDetail(run: selected) { navigation.selectedRunID = nil }
        }
        VStack(alignment: .leading, spacing: 12) {
          MacHeading("Snapshots") {
            Text(MacFormat.count(runs.count, "snapshot"))
              .font(AtlasTheme.font(.label, .callout, weight: .medium, figuresIn: MacFormat.count(runs.count, "snapshot")))
              .foregroundStyle(AtlasTheme.ink3)
          }
          Surface(padding: 0) {
            VStack(spacing: 0) {
              ForEach(rows) { row in
                snapshotRow(row, isSelected: row.id == navigation.selectedRunID)
                if row.id != rows.last?.id {
                  Divider().overlay(AtlasTheme.ruleSoft)
                }
              }
            }
          }
        }
      }
    }
    .confirmationDialog(
      "Remove \(pendingRemovalIdentity)?",
      isPresented: Binding(
        get: { pendingRemoval != nil },
        set: { if !$0 { pendingRemoval = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Remove snapshot", role: .destructive) {
        if let pendingRemoval {
          if navigation.selectedRunID == pendingRemoval { navigation.selectedRunID = nil }
          Task { await state.removeScanRun(id: pendingRemoval) }
        }
        pendingRemoval = nil
      }
      Button("Cancel", role: .cancel) { pendingRemoval = nil }
    } message: {
      Text("The snapshot is deleted from this Mac. Your wallets and exchanges are not affected.")
    }
  }

  private var pendingRemovalIdentity: String {
    guard let pendingRemoval,
      let run = state.document.scanRuns.first(where: { $0.id == pendingRemoval })
    else { return "this snapshot" }
    return AtlasAccessibility.snapshotIdentity(run)
  }

  private func snapshotRow(_ row: MacSnapshotRow, isSelected: Bool) -> some View {
    HStack(spacing: 4) {
      MacRowButton(
        accessibilityLabel: row.spokenText,
        accessibilityIdentifier: "snapshot-row-\(row.id.uuidString.lowercased())",
        action: {
          navigation.selectedRunID = isSelected ? nil : row.id
        }
      ) {
        HStack(spacing: 14) {
          Image(systemName: isSelected ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AtlasTheme.ink3)
            .frame(width: 12)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 3) {
            Text(AtlasFormatting.dateTime(row.run.generatedAt))
              .font(AtlasTheme.font(.body, .body, weight: .semibold))
              .foregroundStyle(AtlasTheme.ink)
              .lineLimit(1)
            Text(row.detailText)
              .font(AtlasTheme.font(.label, .caption, figuresIn: row.detailText))
              .foregroundStyle(AtlasTheme.ink3)
              .lineLimit(1)
          }
          Spacer(minLength: 8)
          changeText(row.change)
          MacFigure(text: money(row.run.totalUsd), size: 14, weight: .semibold)
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(minHeight: 56)
      }
      Button(role: .destructive) {
        pendingRemoval = row.id
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(IconButtonStyle())
      .disabled(state.vaultEditsDisabled)
      .accessibilityLabel("Remove snapshot \(AtlasAccessibility.snapshotIdentity(row.run))")
      .padding(.trailing, 10)
    }
  }

  @ViewBuilder
  private func changeText(_ change: MacPortfolioSnapshot.Change) -> some View {
    switch change {
    case .none:
      EmptyView()
    case .sourcesChanged:
      Text("Sources changed")
        .font(AtlasTheme.font(.label, .caption))
        .foregroundStyle(AtlasTheme.ink3)
    case .moved(let delta, _, _):
      MacFigure(
        text: delta == 0 ? "No change" : MacFormat.signedMoney(delta), size: 12,
        weight: .medium,
        color: delta == 0 ? AtlasTheme.ink3 : (delta > 0 ? AtlasTheme.gain : AtlasTheme.loss)
      )
      .frame(minWidth: 90, alignment: .trailing)
    }
  }
}

// MARK: - Rows

/// A snapshot and how it compares with the scan before it.
struct MacSnapshotRow: Identifiable {
  var id: UUID { run.id }
  let run: ScanRunRecord
  let change: MacPortfolioSnapshot.Change

  /// "15 assets · 2 warnings".
  var detailText: String {
    var parts = [MacFormat.count(run.holdings.count, "holding")]
    if !run.warnings.isEmpty { parts.append(MacFormat.count(run.warnings.count, "warning")) }
    return parts.joined(separator: " \u{00B7} ")
  }

  var spokenText: String {
    var text =
      "\(AtlasFormatting.dateTime(run.generatedAt)), \(detailText), \(money(run.totalUsd))"
    switch change {
    case .none: break
    case .sourcesChanged: text += ", sources changed since the scan before"
    case .moved(let delta, _, _):
      text += delta == 0 ? ", no change" : ", \(MacFormat.signedMoney(delta)) since the scan before"
    }
    return text
  }

  /// Newest first. A scan is compared with the one before it only when both
  /// read the same sources.
  static func rows(runs newestFirst: [ScanRunRecord], context: ScanSourceContext?)
    -> [MacSnapshotRow]
  {
    newestFirst.enumerated().map { index, run in
      guard index + 1 < newestFirst.count else {
        return MacSnapshotRow(run: run, change: .none)
      }
      let previous = newestFirst[index + 1]
      guard PortfolioAnalytics.runsShareSources(previous, run, context: context) else {
        return MacSnapshotRow(run: run, change: .sourcesChanged)
      }
      let older = PortfolioAnalytics.totalValueUsd(previous.holdings)
      let newer = PortfolioAnalytics.totalValueUsd(run.holdings)
      let delta = newer - older
      guard delta.isFinite else { return MacSnapshotRow(run: run, change: .none) }
      return MacSnapshotRow(
        run: run,
        change: .moved(
          delta: delta, fraction: older > 0 ? delta / older : nil, since: previous.generatedAt))
    }
  }
}

// MARK: - Detail

/// What one snapshot held.
struct MacSnapshotDetail: View {
  @Environment(\.atlasTheme) private var tokens
  var run: ScanRunRecord
  var onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      MacHeading(AtlasFormatting.dateTime(run.generatedAt)) {
        HStack(spacing: 12) {
          MacFigure(text: money(run.totalUsd), size: 16, weight: .bold)
          Button("Close", action: onClose)
            .buttonStyle(MacSecondaryButtonStyle())
        }
      }
      if !run.warnings.isEmpty {
        MacScanWarnings(warnings: run.warnings)
      }
      MacHoldingsTable(
        holdings: AppState.sortedHoldingsForDisplay(run.holdings), showsSymbol: true)
      let unpriced = MacPortfolioSnapshot.unpricedSentence(
        run.holdings.filter { $0.pricingStatus != .priced })
      if let unpriced {
        MacNote(text: unpriced, tone: .warning)
      }
    }
    .accessibilityElement(children: .contain)
  }
}
