import AddressAtlasCore
import SwiftUI

@main
struct AddressAtlasMacApp: App {
  @StateObject private var state = AppState()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(state)
        .task {
          await state.unlock()
        }
    }
  }
}

struct RootView: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    Group {
      if state.isUnlocked {
        MainView()
      } else {
        VStack(spacing: 16) {
          Text("Address Atlas")
            .font(.largeTitle.bold())
          Text("Your encrypted local vault is unlocked with macOS Keychain.")
            .foregroundStyle(.secondary)
          Button("Unlock") {
            Task { await state.unlock() }
          }
          .buttonStyle(.borderedProminent)
          if !state.error.isEmpty {
            Text(state.error).foregroundStyle(.red)
          }
        }
        .frame(minWidth: 680, minHeight: 420)
      }
    }
  }
}

struct MainView: View {
  enum Section: String, CaseIterable, Identifiable {
    case portfolio = "Portfolio"
    case wallets = "Wallets"
    case assets = "Assets"
    case snapshots = "Snapshots"
    case export = "Export"
    case settings = "Settings"

    var id: String { rawValue }
  }

  @State private var selected: Section? = .portfolio

  var body: some View {
    NavigationSplitView {
      List(Section.allCases, selection: $selected) { section in
        Text(section.rawValue).tag(section)
      }
      .navigationTitle("Address Atlas")
    } detail: {
      switch selected ?? .portfolio {
      case .portfolio: PortfolioView()
      case .wallets: WalletsView()
      case .assets: AssetsView()
      case .snapshots: SnapshotsView()
      case .export: ExportView()
      case .settings: SettingsView()
      }
    }
    .frame(minWidth: 1100, minHeight: 720)
  }
}

struct PortfolioView: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading) {
          Text("Portfolio").font(.largeTitle.bold())
          Text("Read-only balances from saved public addresses and manual holdings.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          Task { await state.scanSavedWallets() }
        } label: {
          if state.scanning {
            ProgressView()
          } else {
            Text("Scan saved wallets")
          }
        }
        .buttonStyle(.borderedProminent)
      }

      HStack(spacing: 12) {
        MetricCard(title: "Total value", value: money(state.latestScan?.totalUsd ?? 0))
        MetricCard(title: "Wallets", value: "\(state.document.wallets.count)")
        MetricCard(title: "Assets", value: "\(state.latestScan?.holdings.count ?? 0)")
      }

      AssetList(assets: state.latestScan?.holdings ?? [])
      Spacer()
      StatusLine()
    }
    .padding(24)
  }
}

struct WalletsView: View {
  @EnvironmentObject private var state: AppState
  @State private var address = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Wallets").font(.largeTitle.bold())
      HStack {
        TextField("Public wallet address", text: $address)
        Button("Add") {
          state.addWallet(address: address)
          address = ""
        }
      }
      List(state.document.wallets) { wallet in
        VStack(alignment: .leading) {
          Text(wallet.label).font(.headline)
          Text(wallet.address).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        }
      }
      StatusLine()
    }
    .padding(24)
  }
}

struct AssetsView: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Assets").font(.largeTitle.bold())
      AssetList(assets: state.latestScan?.holdings ?? [])
    }
    .padding(24)
  }
}

struct SnapshotsView: View {
  @EnvironmentObject private var state: AppState
  @State private var symbol = ""
  @State private var amount = ""
  @State private var value = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Snapshots & Manual Holdings").font(.largeTitle.bold())
      HStack {
        TextField("Symbol", text: $symbol)
        TextField("Amount", text: $amount)
        TextField("Value USD", text: $value)
        Button("Add manual") {
          state.addManualHolding(symbol: symbol, amount: amount, valueUsd: value)
          symbol = ""; amount = ""; value = ""
        }
      }
      List(state.document.scanRuns.sorted { $0.generatedAt > $1.generatedAt }) { run in
        HStack {
          Text(run.generatedAt, style: .date)
          Text(run.generatedAt, style: .time)
          Spacer()
          Text(money(run.totalUsd))
          Text("\(run.holdings.count) assets").foregroundStyle(.secondary)
        }
      }
      StatusLine()
    }
    .padding(24)
  }
}

struct ExportView: View {
  @EnvironmentObject private var state: AppState
  @State private var exported = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Export").font(.largeTitle.bold())
      HStack {
        Button("Generate CSV") {
          exported = AddressAtlasExporter.csv(for: state.latestScan?.holdings ?? [])
        }
        Button("Generate JSON") {
          if let data = try? AddressAtlasExporter.json(for: state.document) {
            exported = String(decoding: data, as: UTF8.self)
          }
        }
      }
      TextEditor(text: $exported)
        .font(.system(.body, design: .monospaced))
    }
    .padding(24)
  }
}

struct SettingsView: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    Form {
      Toggle("Auto-refresh", isOn: Binding(get: {
        state.document.preferences.autoRefresh
      }, set: {
        state.document.preferences.autoRefresh = $0
        state.save()
      }))
      Toggle("Hide dust", isOn: Binding(get: {
        state.document.preferences.hideDust
      }, set: {
        state.document.preferences.hideDust = $0
        state.save()
      }))
      TextField("Display currency", text: Binding(get: {
        state.document.preferences.currency
      }, set: {
        state.document.preferences.currency = $0.uppercased()
        state.save()
      }))
    }
    .formStyle(.grouped)
    .padding(24)
  }
}

struct AssetList: View {
  var assets: [TrackedAsset]

  var body: some View {
    if assets.isEmpty {
      ContentUnavailableView("No assets yet", systemImage: "wallet.pass", description: Text("Add a wallet and run a scan."))
    } else {
      List(assets) { asset in
        HStack {
          VStack(alignment: .leading) {
            Text(asset.symbol).font(.headline)
            Text(asset.chainName).foregroundStyle(.secondary)
          }
          Spacer()
          VStack(alignment: .trailing) {
            Text(asset.amount.formatted())
            Text(money(asset.valueUsd)).foregroundStyle(.secondary)
          }
        }
      }
    }
  }
}

struct MetricCard: View {
  var title: String
  var value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).foregroundStyle(.secondary)
      Text(value).font(.title2.bold())
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.thinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}

struct StatusLine: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    VStack(alignment: .leading) {
      if !state.notice.isEmpty {
        Text(state.notice).foregroundStyle(.secondary)
      }
      if !state.error.isEmpty {
        Text(state.error).foregroundStyle(.red)
      }
    }
    .font(.footnote)
  }
}

private func money(_ value: Double) -> String {
  value.formatted(.currency(code: "USD"))
}
