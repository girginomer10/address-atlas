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
        VStack(spacing: 0) {
          HStack {
            TableHeader("Asset", width: 210)
            TableHeader("Chain / source")
            TableHeader("Amount", alignment: .trailing, width: 150)
            TableHeader("Value", alignment: .trailing, width: 150)
          }
          .padding(.horizontal, 18)
          .frame(height: 38)
          .background(AtlasTheme.paper2)
          Divider().overlay(AtlasTheme.rule)
          ForEach(assets) { asset in
            AssetRow(asset: asset)
            if asset.id != assets.last?.id {
              Divider().overlay(AtlasTheme.ruleSoft)
            }
          }
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
              .foregroundStyle(Color.orange)
            Text(warning)
              .font(.system(size: 12))
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

  var body: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(asset.symbol)
            .font(.system(size: 16, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .help(asset.symbol)
          if asset.priceUsd <= 0 && asset.valueUsd <= 0 {
            Badge("UNPRICED", color: Color.orange)
          }
        }
        Text(asset.name)
          .font(.system(size: 12))
          .foregroundStyle(AtlasTheme.ink3)
          .lineLimit(1)
      }
      .frame(width: 210, alignment: .leading)

      VStack(alignment: .leading, spacing: 4) {
        Text(asset.chainName)
          .font(.system(size: 14))
        Text(asset.walletLabel ?? asset.address)
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(AtlasTheme.ink3)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Text(asset.amount.formatted())
        .font(.system(size: 13, design: .monospaced))
        .frame(width: 150, alignment: .trailing)
      Text(money(asset.valueUsd))
        .font(.system(size: 13, weight: .semibold, design: .monospaced))
        .frame(width: 150, alignment: .trailing)
    }
    .padding(.horizontal, 18)
    .frame(height: 62)
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
  var total: Double
  var generatedAt: Date?
  var assetCount: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      AtlasLabel("TOTAL VALUE")
      Text(money(total))
        .font(.system(size: 62, weight: .regular, design: .serif))
        .italic()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
      Text(
        "\(assetCount) assets - \(generatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "no snapshot")"
      )
      .font(.system(size: 12, design: .monospaced))
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
            .font(.system(size: 34, weight: .regular, design: .serif))
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
