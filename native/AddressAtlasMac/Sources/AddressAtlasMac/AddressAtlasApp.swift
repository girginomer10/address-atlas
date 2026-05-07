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
        VStack(spacing: 18) {
          Text("Address Atlas")
            .font(.largeTitle.bold())
          Text("Encrypted local vault, unlocked with macOS Keychain.")
            .foregroundStyle(.secondary)
          Button("Unlock Vault") {
            Task { await state.unlock() }
          }
          .buttonStyle(.borderedProminent)
          StatusLine()
        }
        .frame(minWidth: 720, minHeight: 460)
      }
    }
  }
}

struct MainView: View {
  enum Section: String, CaseIterable, Identifiable {
    case portfolio = "Portfolio"
    case wallets = "Wallets"
    case assets = "Assets"
    case tokens = "Tokens"
    case snapshots = "Snapshots"
    case exchanges = "Exchanges"
    case sync = "Sync"
    case export = "Export"
    case settings = "Settings"

    var id: String { rawValue }
  }

  @State private var selected: Section? = .portfolio

  var body: some View {
    NavigationSplitView {
      List(Section.allCases, selection: $selected) { section in
        Label(section.rawValue, systemImage: icon(for: section)).tag(section)
      }
      .navigationTitle("Address Atlas")
    } detail: {
      switch selected ?? .portfolio {
      case .portfolio: PortfolioView()
      case .wallets: WalletsView()
      case .assets: AssetsView()
      case .tokens: TokenAllowlistView()
      case .snapshots: SnapshotsView()
      case .exchanges: ExchangesView()
      case .sync: SyncView()
      case .export: ExportView()
      case .settings: SettingsView()
      }
    }
    .frame(minWidth: 1180, minHeight: 760)
  }

  private func icon(for section: Section) -> String {
    switch section {
    case .portfolio: "chart.pie"
    case .wallets: "wallet.pass"
    case .assets: "list.bullet.rectangle"
    case .tokens: "tag"
    case .snapshots: "clock.arrow.circlepath"
    case .exchanges: "building.columns"
    case .sync: "arrow.triangle.2.circlepath"
    case .export: "square.and.arrow.down"
    case .settings: "gearshape"
    }
  }
}

struct PortfolioView: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    Page(title: "Portfolio", subtitle: "Read-only balances from saved public addresses, tokens, exchanges, and manual holdings.") {
      HStack(spacing: 12) {
        MetricCard(title: "Total value", value: money(state.latestScan?.totalUsd ?? 0))
        MetricCard(title: "Wallets", value: "\(state.document.wallets.count)")
        MetricCard(title: "Assets", value: "\(state.latestScan?.holdings.count ?? 0)")
        MetricCard(title: "Tokens", value: "\(state.document.customTokens.filter(\.enabled).count)")
      }

      HStack {
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
        Text("Latest snapshot: \(state.latestScan?.generatedAt.formatted(date: .abbreviated, time: .shortened) ?? "none")")
          .foregroundStyle(.secondary)
      }

      AssetList(assets: state.latestScan?.holdings ?? [])
    }
  }
}

struct WalletsView: View {
  @EnvironmentObject private var state: AppState
  @State private var address = ""

  var body: some View {
    Page(title: "Wallets", subtitle: "Public addresses saved in the encrypted local vault.") {
      FormRow {
        TextField("Public wallet address", text: $address)
        Button("Add") {
          state.addWallet(address: address)
          address = ""
        }
        .buttonStyle(.borderedProminent)
      }

      List {
        ForEach(state.document.wallets) { wallet in
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(wallet.label).font(.headline)
              Text(wallet.address).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(wallet.chainKind.rawValue.uppercased()).foregroundStyle(.secondary)
            Button(role: .destructive) {
              state.removeWallet(id: wallet.id)
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
          }
        }
      }
    }
  }
}

struct AssetsView: View {
  @EnvironmentObject private var state: AppState
  @State private var query = ""
  @State private var hideUnpriced = false

  var filteredAssets: [TrackedAsset] {
    (state.latestScan?.holdings ?? []).filter { asset in
      let matchesQuery = query.isEmpty
        || asset.symbol.localizedCaseInsensitiveContains(query)
        || asset.chainName.localizedCaseInsensitiveContains(query)
        || asset.name.localizedCaseInsensitiveContains(query)
      let matchesPricing = !hideUnpriced || asset.priceUsd > 0
      return matchesQuery && matchesPricing
    }
  }

  var body: some View {
    Page(title: "Assets", subtitle: "One row per asset, per chain, per wallet or exchange source.") {
      FormRow {
        TextField("Filter assets", text: $query)
        Toggle("Hide unpriced", isOn: $hideUnpriced)
      }
      AssetList(assets: filteredAssets)
    }
  }
}

struct TokenAllowlistView: View {
  @EnvironmentObject private var state: AppState
  @State private var chainKind: ChainFamily = .evm
  @State private var chainId = "ethereum"
  @State private var address = ""
  @State private var symbol = ""
  @State private var name = ""
  @State private var decimals = "18"
  @State private var coinGeckoId = ""
  @State private var priceUsd = ""

  var body: some View {
    Page(title: "Token Allowlist", subtitle: "Custom EVM contracts and Solana mints scanned alongside the built-in registry.") {
      VStack(alignment: .leading, spacing: 12) {
        FormRow {
          Picker("Family", selection: $chainKind) {
            Text("EVM").tag(ChainFamily.evm)
            Text("Solana").tag(ChainFamily.solana)
          }
          .frame(width: 160)
          Picker("Chain", selection: $chainId) {
            if chainKind == .evm {
              ForEach(ChainRegistry.evmChains, id: \.id) { chain in
                Text(chain.name).tag(chain.id)
              }
            } else {
              Text("Solana").tag("solana")
            }
          }
          .frame(width: 220)
        }
        FormRow {
          TextField(chainKind == .evm ? "0x token contract" : "Solana mint", text: $address)
          TextField("Symbol", text: $symbol).frame(width: 100)
          TextField("Decimals", text: $decimals).frame(width: 90)
        }
        FormRow {
          TextField("Name", text: $name)
          TextField("CoinGecko id", text: $coinGeckoId)
          TextField("Manual USD price", text: $priceUsd).frame(width: 150)
          Button("Add token") {
            state.addCustomToken(
              chainKind: chainKind,
              chainId: chainKind == .solana ? "solana" : chainId,
              address: address,
              symbol: symbol,
              name: name,
              decimals: decimals,
              coinGeckoId: coinGeckoId,
              priceUsd: priceUsd
            )
            address = ""; symbol = ""; name = ""; decimals = chainKind == .evm ? "18" : "6"; coinGeckoId = ""; priceUsd = ""
          }
          .buttonStyle(.borderedProminent)
        }
      }
      .padding()
      .background(.thinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 8))

      List {
        ForEach(state.document.customTokens) { token in
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text(token.symbol).font(.headline)
                Text(token.name).foregroundStyle(.secondary)
              }
              Text("\(token.chainId) · \(token.address)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: {
              token.enabled
            }, set: { _ in
              state.toggleCustomToken(id: token.id)
            }))
            .labelsHidden()
            Button(role: .destructive) {
              state.removeCustomToken(id: token.id)
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
          }
        }
      }
    }
    .onChange(of: chainKind) { next in
      chainId = next == .solana ? "solana" : "ethereum"
      decimals = next == .solana ? "6" : "18"
    }
  }
}

struct SnapshotsView: View {
  @EnvironmentObject private var state: AppState
  @State private var symbol = ""
  @State private var amount = ""
  @State private var value = ""

  var body: some View {
    Page(title: "Snapshots & Manual Holdings", subtitle: "Saved scan runs plus manually entered CEX or OTC balances.") {
      FormRow {
        TextField("Symbol", text: $symbol).frame(width: 110)
        TextField("Amount", text: $amount).frame(width: 140)
        TextField("Value USD", text: $value).frame(width: 140)
        Button("Add manual") {
          state.addManualHolding(symbol: symbol, amount: amount, valueUsd: value)
          symbol = ""; amount = ""; value = ""
        }
        .buttonStyle(.borderedProminent)
      }

      HStack(alignment: .top, spacing: 14) {
        VStack(alignment: .leading) {
          Text("Snapshots").font(.headline)
          List(state.document.scanRuns.sorted { $0.generatedAt > $1.generatedAt }) { run in
            HStack {
              Text(run.generatedAt, style: .date)
              Text(run.generatedAt, style: .time)
              Spacer()
              Text(money(run.totalUsd))
              Text("\(run.holdings.count) assets").foregroundStyle(.secondary)
            }
          }
        }
        VStack(alignment: .leading) {
          Text("Manual Holdings").font(.headline)
          List {
            ForEach(state.document.manualHoldings) { holding in
              HStack {
                VStack(alignment: .leading) {
                  Text("\(holding.symbol) · \(holding.label)").font(.headline)
                  Text("\(holding.amount.formatted()) · \(money(holding.valueUsd))").foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: {
                  holding.enabled
                }, set: { _ in
                  state.toggleManualHolding(id: holding.id)
                }))
                .labelsHidden()
                Button(role: .destructive) {
                  state.removeManualHolding(id: holding.id)
                } label: {
                  Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
              }
            }
          }
        }
      }
    }
  }
}

struct ExchangesView: View {
  @EnvironmentObject private var state: AppState
  @State private var provider: ExchangeProvider = .binance
  @State private var label = ""
  @State private var apiKey = ""
  @State private var secret = ""
  @State private var passphrase = ""

  var body: some View {
    Page(title: "Exchanges", subtitle: "Read-only API credentials are encrypted with a dedicated vault subkey before storage.") {
      VStack(alignment: .leading, spacing: 12) {
        FormRow {
          Picker("Provider", selection: $provider) {
            ForEach(ExchangeProvider.allCases, id: \.self) { provider in
              Text(provider.label).tag(provider)
            }
          }
          .frame(width: 180)
          TextField("Label", text: $label)
        }
        FormRow {
          SecureField("API key", text: $apiKey)
          SecureField("Secret", text: $secret)
          SecureField("Passphrase", text: $passphrase)
          Button("Save encrypted") {
            state.saveExchangeConnection(
              provider: provider,
              label: label,
              credentials: ExchangeCredentials(
                apiKey: apiKey,
                secret: secret,
                passphrase: passphrase.isEmpty ? nil : passphrase
              )
            )
            label = ""; apiKey = ""; secret = ""; passphrase = ""
          }
          .buttonStyle(.borderedProminent)
        }
      }
      .padding()
      .background(.thinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 8))

      List {
        ForEach(state.document.exchangeConnections) { connection in
          HStack {
            VStack(alignment: .leading) {
              Text(connection.label).font(.headline)
              Text("\(connection.provider.label) · \(connection.status.rawValue)").foregroundStyle(.secondary)
            }
            Spacer()
            if let lastSync = connection.lastSyncAt {
              Text(lastSync, style: .relative).foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
              state.removeExchangeConnection(id: connection.id)
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
          }
        }
      }
    }
  }
}

struct SyncView: View {
  @EnvironmentObject private var state: AppState
  @State private var serverURL = ""
  @State private var sessionToken = ""

  var body: some View {
    Page(title: "Encrypted Sync", subtitle: "Only opaque encrypted vault snapshots are uploaded. The server never receives decryptable key material.") {
      VStack(alignment: .leading, spacing: 12) {
        TextField("Sync server URL", text: $serverURL)
        SecureField("Session token", text: $sessionToken)
        HStack {
          Button("Save sync settings") {
            state.saveSyncSettings(serverURL: serverURL, sessionToken: sessionToken)
          }
          Button {
            Task { await state.uploadEncryptedVault() }
          } label: {
            state.syncing ? AnyView(ProgressView()) : AnyView(Text("Upload encrypted vault"))
          }
          .buttonStyle(.borderedProminent)
          Button {
            Task { await state.downloadEncryptedVault() }
          } label: {
            Text("Download encrypted vault")
          }
        }
      }
      .padding()
      .background(.thinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 8))

      VStack(alignment: .leading, spacing: 8) {
        Text("Sync State").font(.headline)
        Text("Remote version: \(state.document.syncState.latestRemoteVersion)")
        Text("Last synced: \(state.document.syncState.lastSyncedAt?.formatted(date: .abbreviated, time: .shortened) ?? "never")")
        Text("Checksum: \(state.document.syncState.lastChecksum ?? "none")")
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
      }
    }
    .onAppear {
      serverURL = state.document.syncState.serverURL
      sessionToken = state.document.syncState.sessionToken
    }
  }
}

struct ExportView: View {
  @EnvironmentObject private var state: AppState
  @State private var exported = ""

  var body: some View {
    Page(title: "Export", subtitle: "Generate local CSV or JSON from the encrypted vault after unlock.") {
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
  }
}

struct SettingsView: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    Page(title: "Settings", subtitle: "Local display and scan preferences stored inside the encrypted vault.") {
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
        TextField("Dust threshold USD", value: Binding(get: {
          state.document.preferences.dustThreshold
        }, set: {
          state.document.preferences.dustThreshold = $0
          state.save()
        }), format: .number)
        TextField("Display currency", text: Binding(get: {
          state.document.preferences.currency
        }, set: {
          state.document.preferences.currency = $0.uppercased()
          state.save()
        }))
      }
      .formStyle(.grouped)
    }
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
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(asset.symbol).font(.headline)
              if asset.priceUsd <= 0 {
                Text("Unpriced").font(.caption).foregroundStyle(.orange)
              }
            }
            Text("\(asset.chainName) · \(asset.source.rawValue)").foregroundStyle(.secondary)
          }
          Spacer()
          VStack(alignment: .trailing, spacing: 4) {
            Text(asset.amount.formatted())
            Text(money(asset.valueUsd)).foregroundStyle(.secondary)
          }
        }
      }
    }
  }
}

struct Page<Content: View>: View {
  var title: String
  var subtitle: String
  var content: Content

  init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.subtitle = subtitle
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.largeTitle.bold())
        Text(subtitle).foregroundStyle(.secondary)
      }
      content
      Spacer()
      StatusLine()
    }
    .padding(24)
  }
}

struct FormRow<Content: View>: View {
  var content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      content
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
    VStack(alignment: .leading, spacing: 4) {
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
