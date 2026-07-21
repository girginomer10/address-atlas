import AddressAtlasCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AssetList: View {
  var assets: [TrackedAsset]

  var body: some View {
    if assets.isEmpty {
      EmptyState(
        title: "No assets yet", systemImage: "wallet.pass", copy: "Add a wallet and run a scan.")
    } else {
      Surface(padding: 0) {
        ViewThatFits(in: .horizontal) {
          wideTable
            .frame(minWidth: 760)
          compactList
        }
      }
    }
  }

  private var wideTable: some View {
    VStack(spacing: 0) {
      HStack {
        TableHeader("Asset", width: 210)
        TableHeader("Chain / source")
        TableHeader("Amount", alignment: .trailing, width: 150)
        TableHeader("Value", alignment: .trailing, width: 150)
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 10)
      .frame(minHeight: 40)
      .background(AtlasTheme.surfaceMuted.opacity(0.44))
      .accessibilityHidden(true)
      Divider().overlay(AtlasTheme.rule)
      ForEach(assets) { asset in
        AssetRow(asset: asset)
        if asset.id != assets.last?.id {
          Divider().overlay(AtlasTheme.ruleSoft)
        }
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var compactList: some View {
    VStack(spacing: 0) {
      ForEach(assets) { asset in
        CompactAssetRow(asset: asset)
        if asset.id != assets.last?.id {
          Divider().overlay(AtlasTheme.ruleSoft)
        }
      }
    }
    .frame(maxWidth: .infinity)
  }
}

struct ScanWarningsView: View {
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
            Text(warning)
              .font(.callout)
              .foregroundStyle(AtlasTheme.ink2)
              .textSelection(.enabled)
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Partial scan warnings")
  }
}

struct AssetRow: View {
  var asset: TrackedAsset

  static func accessibilityIdentifier(for asset: TrackedAsset) -> String {
    "portfolio-asset-row-\(asset.id)"
  }

  var body: some View {
    HStack(spacing: 14) {
      HStack(spacing: 11) {
        Text(String(asset.symbol.prefix(1)).uppercased())
          .font(.caption.weight(.bold))
          .foregroundStyle(AtlasTheme.accent)
          .frame(width: 34, height: 34)
          .background(AtlasTheme.accent.opacity(0.10))
          .clipShape(Circle())
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(asset.symbol)
              .font(.body.weight(.semibold))
              .lineLimit(1)
              .truncationMode(.middle)
              .help(asset.symbol)
            if asset.pricingStatus != .priced {
              Badge(
                asset.pricingStatus == .unpriced ? "Unpriced" : "Value unavailable",
                color: AtlasTheme.warning
              )
            }
          }
          Text(asset.name)
            .font(.caption)
            .foregroundStyle(AtlasTheme.ink3)
            .lineLimit(1)
        }
      }
      .frame(width: 210, alignment: .leading)

      VStack(alignment: .leading, spacing: 4) {
        Text(asset.chainName)
          .font(.body)
        Text(asset.walletLabel ?? asset.address)
          .font(.caption2.monospaced())
          .foregroundStyle(AtlasTheme.ink3)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Text(asset.displayedAmount)
        .font(.callout.monospaced())
        .lineLimit(1)
        .minimumScaleFactor(0.65)
        .help(asset.canonicalAmount)
        .frame(width: 150, alignment: .trailing)
      Text(asset.pricingStatus == .priced ? money(asset.valueUsd) : "—")
        .font(.callout.monospaced().weight(.semibold))
        .frame(width: 150, alignment: .trailing)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 9)
    .frame(minHeight: 62)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(AtlasAccessibility.assetRowIdentity(asset))
    .accessibilityIdentifier(Self.accessibilityIdentifier(for: asset))
  }
}

private struct CompactAssetRow: View {
  var asset: TrackedAsset

  var body: some View {
    HStack(spacing: 12) {
      Text(String(asset.symbol.prefix(1)).uppercased())
        .font(.caption.weight(.bold))
        .foregroundStyle(AtlasTheme.accent)
        .frame(width: 36, height: 36)
        .background(AtlasTheme.accent.opacity(0.10))
        .clipShape(Circle())
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Text(asset.symbol)
            .font(.body.weight(.semibold))
          if asset.pricingStatus != .priced {
            Badge(
              asset.pricingStatus == .unpriced ? "Unpriced" : "Value unavailable",
              color: AtlasTheme.warning
            )
          }
        }
        Text("\(asset.chainName) · \(asset.walletLabel ?? asset.address)")
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink3)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer(minLength: 12)

      VStack(alignment: .trailing, spacing: 4) {
        Text(asset.pricingStatus == .priced ? money(asset.valueUsd) : "—")
          .font(.callout.monospacedDigit().weight(.semibold))
        Text(asset.displayedAmount)
          .font(.caption.monospaced())
          .foregroundStyle(AtlasTheme.ink3)
          .lineLimit(1)
          .help(asset.canonicalAmount)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(minHeight: 66)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(AtlasAccessibility.assetRowIdentity(asset))
    .accessibilityIdentifier(AssetRow.accessibilityIdentifier(for: asset))
  }
}

struct QuickActionsPanel: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    Surface(style: .accent) {
      VStack(alignment: .leading, spacing: 16) {
        PanelHeader(
          title: "Refresh portfolio",
          subtitle: "Scan every saved wallet and exchange",
          systemImage: "arrow.clockwise"
        )
        Button {
          if state.scanning {
            state.cancelScan()
          } else {
            state.startScan()
          }
        } label: {
          if state.scanning {
            Label("Cancel scan", systemImage: "xmark.circle")
          } else {
            Label("Scan all sources", systemImage: "arrow.clockwise")
          }
        }
        .buttonStyle(AtlasPrimaryButtonStyle())
        .disabled(
          !state.scanning
            && (state.syncing || state.syncPersistencePending || !state.hasScanSources))
        VStack(alignment: .leading, spacing: 12) {
          SidebarTrustLine(title: "Encrypted storage", copy: "Protected on this device")
          SidebarTrustLine(title: "Private sync", copy: "Only encrypted snapshots leave this Mac")
          SidebarTrustLine(
            title: "Direct connections", copy: "RPC and exchange requests run locally")
        }
      }
    }
  }
}

struct TotalBlock: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ScaledMetric(relativeTo: .largeTitle) private var totalSize: CGFloat = 52
  var total: Double
  var generatedAt: Date?
  var assetCount: Int
  var unpricedCount: Int = 0

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
        .tracking(-1.2)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .contentTransition(.numericText(value: total))
        .animation(
          AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
          value: total
        )
      Text(
        unpricedCount > 0
          ? "\(assetCount) assets · \(unpricedCount) awaiting a USD value · \(generatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "No snapshot yet")"
          : "\(assetCount) assets · \(generatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "No snapshot yet")"
      )
      .font(.caption)
      .foregroundStyle(AtlasTheme.ink3)
    }
    .padding(.bottom, 6)
  }
}

struct MetricStrip: View {
  var items: [(String, String)]

  var body: some View {
    HStack(spacing: 10) {
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        VStack(alignment: .leading, spacing: 5) {
          Text(item.0)
            .font(.caption.weight(.medium))
            .foregroundStyle(AtlasTheme.ink3)
          Text(item.1)
            .font(.title2.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AtlasTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
            .stroke(AtlasTheme.ruleSoft, lineWidth: 1)
        }
      }
    }
  }
}
