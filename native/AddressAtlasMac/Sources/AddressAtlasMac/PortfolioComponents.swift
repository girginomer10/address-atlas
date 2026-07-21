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
        ScrollView(.horizontal) {
          VStack(spacing: 0) {
            HStack {
              TableHeader("Asset", width: 210)
              TableHeader("Chain / source")
              TableHeader("Amount", alignment: .trailing, width: 150)
              TableHeader("Value", alignment: .trailing, width: 150)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(minHeight: 38)
            .background(AtlasTheme.paper2)
            .accessibilityHidden(true)
            Divider().overlay(AtlasTheme.rule)
            ForEach(assets) { asset in
              AssetRow(asset: asset)
              if asset.id != assets.last?.id {
                Divider().overlay(AtlasTheme.ruleSoft)
              }
            }
          }
          .frame(minWidth: 760)
        }
      }
    }
  }
}

struct ScanWarningsView: View {
  var warnings: [String]

  var body: some View {
    Surface {
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
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(asset.symbol)
            .font(.body.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .help(asset.symbol)
          if asset.pricingStatus != .priced {
            Badge(
              asset.pricingStatus == .unpriced ? "UNPRICED" : "VALUE UNKNOWN",
              color: AtlasTheme.warning
            )
          }
        }
        Text(asset.name)
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink3)
          .lineLimit(1)
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

struct QuickActionsPanel: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      SectionHeader(title: "Quick actions", meta: "Local")
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
        !state.scanning && (state.syncing || state.syncPersistencePending || !state.hasScanSources))
      SidebarTrustLine(title: "Storage", copy: "Encrypted on device")
      SidebarTrustLine(title: "Sync", copy: "Encrypted blobs only")
      SidebarTrustLine(title: "Network", copy: "RPC/API from Mac")
    }
    .padding(18)
    .background(AtlasTheme.paper2)
    .overlay(Rectangle().stroke(AtlasTheme.rule, lineWidth: 1))
  }
}

struct TotalBlock: View {
  @ScaledMetric(relativeTo: .largeTitle) private var totalSize: CGFloat = 62
  var total: Double
  var generatedAt: Date?
  var assetCount: Int
  var unpricedCount: Int = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      AtlasLabel(unpricedCount > 0 ? "PRICED SUBTOTAL (PARTIAL)" : "KNOWN VALUE")
      Text(money(total))
        .font(.system(size: totalSize, weight: .regular, design: .serif))
        .italic()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
      Text(
        unpricedCount > 0
          ? "\(assetCount) assets - \(unpricedCount) without a known USD value - \(generatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "no snapshot")"
          : "\(assetCount) assets - \(generatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "no snapshot")"
      )
      .font(.caption.monospaced())
      .foregroundStyle(AtlasTheme.ink3)
    }
    .padding(.bottom, 22)
    .overlay(alignment: .bottom) {
      Rectangle().fill(AtlasTheme.rule).frame(height: 1)
    }
  }
}

struct MetricStrip: View {
  var items: [(String, String)]

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        VStack(alignment: .leading, spacing: 5) {
          AtlasLabel(item.0)
          Text(item.1)
            .font(.system(.largeTitle, design: .serif))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, index == 0 ? 0 : 18)
        .overlay(alignment: .leading) {
          if index != 0 {
            Rectangle().fill(AtlasTheme.rule).frame(width: 1)
          }
        }
      }
    }
  }
}
