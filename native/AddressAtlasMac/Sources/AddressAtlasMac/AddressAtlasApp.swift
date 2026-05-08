import AddressAtlasCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    .windowStyle(.hiddenTitleBar)
  }
}

private enum AtlasTheme {
  static let paper = Color(red: 0.965, green: 0.952, blue: 0.92)
  static let paper2 = Color(red: 0.925, green: 0.912, blue: 0.88)
  static let paper3 = Color(red: 0.885, green: 0.872, blue: 0.84)
  static let ink = Color(red: 0.16, green: 0.15, blue: 0.13)
  static let ink2 = Color(red: 0.34, green: 0.32, blue: 0.28)
  static let ink3 = Color(red: 0.55, green: 0.52, blue: 0.46)
  static let rule = Color(red: 0.78, green: 0.755, blue: 0.69)
  static let ruleSoft = Color(red: 0.84, green: 0.82, blue: 0.76)
  static let accent = Color(red: 0.18, green: 0.31, blue: 0.56)
  static let gain = Color(red: 0.12, green: 0.45, blue: 0.27)
  static let loss = Color(red: 0.72, green: 0.17, blue: 0.12)
}

struct RootView: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    Group {
      if state.isUnlocked {
        MainView()
      } else {
        UnlockView()
      }
    }
    .background(AtlasTheme.paper)
    .foregroundStyle(AtlasTheme.ink)
    .preferredColorScheme(.light)
    .tint(AtlasTheme.accent)
  }
}

struct UnlockView: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 22) {
        BrandLockup()
        Spacer()
        Text("Encrypted local vault")
          .font(.system(size: 58, weight: .regular, design: .serif))
          .italic()
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        Text("A random 256-bit vault key lives in macOS Keychain. Portfolio data, exchange credentials, scan history, and sync blobs stay encrypted before storage.")
          .font(.system(size: 15))
          .foregroundStyle(AtlasTheme.ink2)
          .lineSpacing(4)
          .frame(maxWidth: 560, alignment: .leading)
        Button {
          Task { await state.unlock() }
        } label: {
          Label("Unlock vault", systemImage: "lock.open")
        }
        .buttonStyle(AtlasPrimaryButtonStyle())
        Spacer()
        StatusLine()
      }
      .padding(42)
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: 20) {
        SidebarTrustLine(title: "No signing", copy: "Public addresses only")
        SidebarTrustLine(title: "No custody", copy: "Private keys never enter the app")
        SidebarTrustLine(title: "Zero knowledge sync", copy: "Server stores opaque vault snapshots")
      }
      .padding(34)
      .frame(width: 340)
      .frame(maxHeight: .infinity, alignment: .topLeading)
      .background(AtlasTheme.paper2)
      .overlay(alignment: .leading) {
        Rectangle().fill(AtlasTheme.rule).frame(width: 1)
      }
    }
    .frame(minWidth: 980, minHeight: 640)
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

    var systemImage: String {
      switch self {
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

    var ordinal: String {
      let index = Self.allCases.firstIndex(of: self) ?? 0
      return String(format: "%02d", index + 1)
    }
  }

  @State private var selected: Section = .portfolio

  var body: some View {
    HStack(spacing: 0) {
      Sidebar(selection: $selected)
      Rectangle().fill(AtlasTheme.rule).frame(width: 1)
      Group {
        switch selected {
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
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 1220, minHeight: 780)
    .background(AtlasTheme.paper)
  }
}

struct Sidebar: View {
  @Binding var selection: MainView.Section

  var body: some View {
    VStack(alignment: .leading, spacing: 26) {
      BrandLockup()
        .padding(.bottom, 20)
        .overlay(alignment: .bottom) {
          Rectangle().fill(AtlasTheme.rule).frame(height: 1)
        }

      VStack(spacing: 2) {
        ForEach(MainView.Section.allCases) { item in
          Button {
            selection = item
          } label: {
            HStack(spacing: 12) {
              Image(systemName: item.systemImage)
                .frame(width: 18)
              Text(item.rawValue)
                .frame(maxWidth: .infinity, alignment: .leading)
              Text(item.ordinal)
                .font(.system(size: 12, design: .serif))
                .italic()
                .opacity(0.72)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .contentShape(Rectangle())
          }
          .buttonStyle(SidebarButtonStyle(active: selection == item))
        }
      }

      Spacer()

      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Circle().stroke(AtlasTheme.gain, lineWidth: 1).frame(width: 8, height: 8)
          Text("LOCAL VAULT")
        }
        Text("Encrypted locally")
        Text("RPC/API from Mac")
        Text("Server cannot decrypt")
      }
      .font(.system(size: 10, design: .monospaced))
      .textCase(.uppercase)
      .foregroundStyle(AtlasTheme.ink3)
      .padding(.top, 18)
      .overlay(alignment: .top) {
        Rectangle().fill(AtlasTheme.rule).frame(height: 1)
      }
    }
    .padding(28)
    .frame(width: 248)
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .background(AtlasTheme.paper)
  }
}

struct PortfolioView: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    Page(
      eyebrow: "Read-only command center",
      title: "Portfolio",
      subtitle: "Balances from saved public addresses, custom tokens, exchange connections, and manual holdings.",
      statTitle: "Latest snapshot",
      statValue: latestSnapshotLabel
    ) {
      HStack(alignment: .top, spacing: 28) {
        VStack(alignment: .leading, spacing: 18) {
          TotalBlock(
            total: state.latestScan?.totalUsd ?? 0,
            generatedAt: state.latestScan?.generatedAt,
            assetCount: state.latestScan?.holdings.count ?? 0
          )
          MetricStrip(items: [
            ("Wallets", "\(state.document.wallets.count)"),
            ("Assets", "\(state.latestScan?.holdings.count ?? 0)"),
            ("Tokens", "\(state.document.customTokens.filter(\.enabled).count)")
          ])
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        QuickActionsPanel()
          .frame(width: 290)
      }

      SectionHeader(title: "Top holdings", meta: "\(state.latestScan?.holdings.count ?? 0) rows")
      AssetList(assets: state.latestScan?.holdings ?? [])
    }
  }

  private var latestSnapshotLabel: String {
    state.latestScan?.generatedAt.formatted(date: .abbreviated, time: .shortened) ?? "None"
  }
}

struct WalletsView: View {
  @EnvironmentObject private var state: AppState
  @State private var address = ""

  var body: some View {
    Page(
      eyebrow: "Address intake",
      title: "Wallets",
      subtitle: "Public addresses saved inside the encrypted local vault.",
      statTitle: "Saved",
      statValue: "\(state.document.wallets.count)"
    ) {
      Surface {
        VStack(alignment: .leading, spacing: 14) {
          SectionHeader(title: "Add public address", meta: "No seed phrases")
          HStack(spacing: 10) {
            TextField("Public wallet address", text: $address)
              .textFieldStyle(AtlasTextFieldStyle())
            Button {
              state.addWallet(address: address)
              address = ""
            } label: {
              Label("Add", systemImage: "plus")
            }
            .buttonStyle(AtlasPrimaryButtonStyle())
          }
        }
      }

      SectionHeader(title: "Saved wallets", meta: "\(state.document.wallets.count) encrypted records")
      if state.document.wallets.isEmpty {
        EmptyState(title: "No wallets yet", systemImage: "wallet.pass", copy: "Add a public address to start scanning.")
      } else {
        Surface(padding: 0) {
          VStack(spacing: 0) {
            ForEach(state.document.wallets) { wallet in
              WalletRow(wallet: wallet)
              if wallet.id != state.document.wallets.last?.id {
                Divider().overlay(AtlasTheme.ruleSoft)
              }
            }
          }
        }
      }
    }
  }
}

struct WalletRow: View {
  @EnvironmentObject private var state: AppState
  var wallet: WalletRecord

  var body: some View {
    HStack(spacing: 16) {
      TextField("Label", text: Binding(get: {
        state.document.wallets.first(where: { $0.id == wallet.id })?.label ?? wallet.label
      }, set: { newValue in
        state.updateWalletLabel(id: wallet.id, label: newValue)
      }))
      .textFieldStyle(.plain)
      .font(.system(size: 16, weight: .semibold))
      .frame(width: 180)

      Text(wallet.address)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(AtlasTheme.ink2)
        .lineLimit(1)
        .truncationMode(.middle)

      Spacer()

      Badge(wallet.chainKind.rawValue.uppercased())

      Button(role: .destructive) {
        state.removeWallet(id: wallet.id)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(IconButtonStyle())
    }
    .padding(.horizontal, 18)
    .frame(height: 62)
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
    Page(
      eyebrow: "Holdings ledger",
      title: "Assets",
      subtitle: "One row per asset, chain, and wallet or exchange source.",
      statTitle: "Visible rows",
      statValue: "\(filteredAssets.count)"
    ) {
      Surface {
        HStack(spacing: 14) {
          Image(systemName: "magnifyingglass").foregroundStyle(AtlasTheme.ink3)
          TextField("Filter assets", text: $query)
            .textFieldStyle(.plain)
          Toggle("Hide unpriced", isOn: $hideUnpriced)
            .toggleStyle(.checkbox)
        }
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
    Page(
      eyebrow: "Token registry",
      title: "Token Allowlist",
      subtitle: "Custom EVM contracts and Solana mints scanned alongside the built-in registry.",
      statTitle: "Enabled",
      statValue: "\(state.document.customTokens.filter(\.enabled).count)"
    ) {
      Surface {
        VStack(alignment: .leading, spacing: 14) {
          SectionHeader(title: "Add token", meta: chainKind.rawValue.uppercased())
          HStack(spacing: 10) {
            Picker("Family", selection: $chainKind) {
              Text("EVM").tag(ChainFamily.evm)
              Text("Solana").tag(ChainFamily.solana)
            }
            .frame(width: 145)
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
            TextField(chainKind == .evm ? "0x token contract" : "Solana mint", text: $address)
              .textFieldStyle(AtlasTextFieldStyle())
          }
          HStack(spacing: 10) {
            TextField("Symbol", text: $symbol)
              .textFieldStyle(AtlasTextFieldStyle())
              .frame(width: 110)
            TextField("Decimals", text: $decimals)
              .textFieldStyle(AtlasTextFieldStyle())
              .frame(width: 95)
            TextField("Name", text: $name)
              .textFieldStyle(AtlasTextFieldStyle())
            TextField("CoinGecko id", text: $coinGeckoId)
              .textFieldStyle(AtlasTextFieldStyle())
              .frame(width: 180)
            TextField("USD price", text: $priceUsd)
              .textFieldStyle(AtlasTextFieldStyle())
              .frame(width: 120)
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
            .buttonStyle(AtlasPrimaryButtonStyle())
          }
        }
      }

      SectionHeader(title: "Saved tokens", meta: "\(state.document.customTokens.count) records")
      if state.document.customTokens.isEmpty {
        EmptyState(title: "No custom tokens", systemImage: "tag", copy: "The built-in registry is still used during scans.")
      } else {
        Surface(padding: 0) {
          VStack(spacing: 0) {
            ForEach(state.document.customTokens) { token in
              TokenRow(token: token)
              if token.id != state.document.customTokens.last?.id {
                Divider().overlay(AtlasTheme.ruleSoft)
              }
            }
          }
        }
      }
    }
    .onChange(of: chainKind) { _, next in
      chainId = next == .solana ? "solana" : "ethereum"
      decimals = next == .solana ? "6" : "18"
    }
  }
}

struct TokenRow: View {
  @EnvironmentObject private var state: AppState
  var token: CustomTokenRecord

  var body: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(token.symbol)
            .font(.system(size: 16, weight: .semibold))
          Text(token.name)
            .foregroundStyle(AtlasTheme.ink2)
        }
        Text("\(token.chainId) - \(token.address)")
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(AtlasTheme.ink3)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      Badge(token.enabled ? "ENABLED" : "PAUSED", color: token.enabled ? AtlasTheme.gain : AtlasTheme.ink3)
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
      .buttonStyle(IconButtonStyle())
    }
    .padding(.horizontal, 18)
    .frame(height: 64)
  }
}

struct SnapshotsView: View {
  @EnvironmentObject private var state: AppState
  @State private var symbol = ""
  @State private var amount = ""
  @State private var value = ""

  var body: some View {
    Page(
      eyebrow: "History and manual balances",
      title: "Snapshots",
      subtitle: "Saved scan runs plus manually entered CEX or OTC balances.",
      statTitle: "Runs",
      statValue: "\(state.document.scanRuns.count)"
    ) {
      Surface {
        VStack(alignment: .leading, spacing: 14) {
          SectionHeader(title: "Add manual holding", meta: "Merged into next snapshot")
          HStack(spacing: 10) {
            TextField("Symbol", text: $symbol)
              .textFieldStyle(AtlasTextFieldStyle())
              .frame(width: 110)
            TextField("Amount", text: $amount)
              .textFieldStyle(AtlasTextFieldStyle())
              .frame(width: 150)
            TextField("Value USD", text: $value)
              .textFieldStyle(AtlasTextFieldStyle())
              .frame(width: 150)
            Button("Add manual") {
              state.addManualHolding(symbol: symbol, amount: amount, valueUsd: value)
              symbol = ""; amount = ""; value = ""
            }
            .buttonStyle(AtlasPrimaryButtonStyle())
          }
        }
      }

      HStack(alignment: .top, spacing: 24) {
        SnapshotList()
        ManualHoldingList()
      }
    }
  }
}

struct SnapshotList: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionHeader(title: "Snapshot history", meta: "\(state.document.scanRuns.count) saved")
      Surface(padding: 0) {
        if state.document.scanRuns.isEmpty {
          EmptyState(title: "No snapshots", systemImage: "clock.arrow.circlepath", copy: "Run a scan to create the first snapshot.")
            .padding(28)
        } else {
          VStack(spacing: 0) {
            ForEach(state.document.scanRuns.sorted { $0.generatedAt > $1.generatedAt }) { run in
              HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                  Text(run.generatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 15, weight: .semibold))
                  Text("\(run.holdings.count) assets")
                    .foregroundStyle(AtlasTheme.ink3)
                }
                Spacer()
                Text(money(run.totalUsd))
                  .font(.system(size: 14, design: .monospaced))
                Button(role: .destructive) {
                  state.removeScanRun(id: run.id)
                } label: {
                  Image(systemName: "trash")
                }
                .buttonStyle(IconButtonStyle())
              }
              .padding(.horizontal, 18)
              .frame(height: 58)
              if run.id != state.document.scanRuns.sorted(by: { $0.generatedAt > $1.generatedAt }).last?.id {
                Divider().overlay(AtlasTheme.ruleSoft)
              }
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

struct ManualHoldingList: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionHeader(title: "Manual holdings", meta: "\(state.document.manualHoldings.count) entries")
      Surface(padding: 0) {
        if state.document.manualHoldings.isEmpty {
          EmptyState(title: "No manual entries", systemImage: "pencil.and.list.clipboard", copy: "Add offline balances above.")
            .padding(28)
        } else {
          VStack(spacing: 0) {
            ForEach(state.document.manualHoldings) { holding in
              HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                  Text("\(holding.symbol) - \(holding.label)")
                    .font(.system(size: 15, weight: .semibold))
                  Text("\(holding.amount.formatted()) - \(money(holding.valueUsd))")
                    .foregroundStyle(AtlasTheme.ink3)
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
                .buttonStyle(IconButtonStyle())
              }
              .padding(.horizontal, 18)
              .frame(height: 58)
              if holding.id != state.document.manualHoldings.last?.id {
                Divider().overlay(AtlasTheme.ruleSoft)
              }
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
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
    Page(
      eyebrow: "Read-only API connectors",
      title: "Exchanges",
      subtitle: "API credentials are encrypted with a dedicated vault subkey before storage.",
      statTitle: "Connections",
      statValue: "\(state.document.exchangeConnections.count)"
    ) {
      Surface {
        VStack(alignment: .leading, spacing: 14) {
          SectionHeader(title: "Save encrypted credentials", meta: "Balance/read permissions only")
          HStack(spacing: 10) {
            Picker("Provider", selection: $provider) {
              ForEach(ExchangeProvider.allCases, id: \.self) { provider in
                Text(provider.label).tag(provider)
              }
            }
            .frame(width: 170)
            TextField("Label", text: $label)
              .textFieldStyle(AtlasTextFieldStyle())
          }
          HStack(spacing: 10) {
            SecureField("API key", text: $apiKey)
              .textFieldStyle(AtlasTextFieldStyle())
            SecureField("Secret", text: $secret)
              .textFieldStyle(AtlasTextFieldStyle())
            SecureField("Passphrase", text: $passphrase)
              .textFieldStyle(AtlasTextFieldStyle())
              .frame(width: 170)
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
            .buttonStyle(AtlasPrimaryButtonStyle())
          }
        }
      }

      HStack(spacing: 12) {
        Button {
          Task { await state.scanSavedWallets() }
        } label: {
          if state.scanning {
            ProgressView()
          } else {
            Label("Scan exchange balances", systemImage: "arrow.clockwise")
          }
        }
        .buttonStyle(AtlasPrimaryButtonStyle())
        Text("\(state.document.exchangeConnections.count) encrypted connections")
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(AtlasTheme.ink3)
      }

      SectionHeader(title: "Saved connections", meta: "\(state.document.exchangeConnections.count) records")
      Surface(padding: 0) {
        if state.document.exchangeConnections.isEmpty {
          EmptyState(title: "No exchange connections", systemImage: "building.columns", copy: "Add read-only API credentials to scan exchange balances.")
            .padding(28)
        } else {
          VStack(spacing: 0) {
            ForEach(state.document.exchangeConnections) { connection in
              ExchangeRow(connection: connection)
              if connection.id != state.document.exchangeConnections.last?.id {
                Divider().overlay(AtlasTheme.ruleSoft)
              }
            }
          }
        }
      }
    }
  }
}

struct ExchangeRow: View {
  @EnvironmentObject private var state: AppState
  var connection: ExchangeConnectionRecord

  var body: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text(connection.label)
          .font(.system(size: 16, weight: .semibold))
        Text(connection.lastError?.isEmpty == false ? connection.lastError ?? "" : connection.provider.label)
          .font(.system(size: 12))
          .foregroundStyle(connection.lastError?.isEmpty == false ? AtlasTheme.loss : AtlasTheme.ink3)
          .lineLimit(1)
      }
      Spacer()
      Badge(connection.status.rawValue.uppercased(), color: connection.status == .failed ? AtlasTheme.loss : AtlasTheme.gain)
      if let lastSync = connection.lastSyncAt {
        Text(lastSync, style: .relative)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(AtlasTheme.ink3)
      }
      Button(role: .destructive) {
        state.removeExchangeConnection(id: connection.id)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(IconButtonStyle())
    }
    .padding(.horizontal, 18)
    .frame(height: 64)
  }
}

struct SyncView: View {
  @EnvironmentObject private var state: AppState
  @State private var serverURL = ""

  var body: some View {
    Page(
      eyebrow: "Zero knowledge sync",
      title: "Encrypted Sync",
      subtitle: "Only opaque encrypted vault snapshots are uploaded. The server never receives decryptable key material.",
      statTitle: "Remote version",
      statValue: "\(state.document.syncState.latestRemoteVersion)"
    ) {
      Surface {
        VStack(alignment: .leading, spacing: 14) {
          SectionHeader(title: "Passkey account", meta: "Authentication only")
          TextField("Sync server URL", text: $serverURL)
            .textFieldStyle(AtlasTextFieldStyle())
          HStack(spacing: 10) {
            Button("Create passkey account") {
              Task {
                await state.createPasskeyAccount(serverURL: serverURL)
                serverURL = state.document.syncState.serverURL
              }
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            Button("Sign in with passkey") {
              Task {
                await state.signInWithPasskey(serverURL: serverURL)
                serverURL = state.document.syncState.serverURL
              }
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            Button("Save server") {
              state.saveSyncSettings(serverURL: serverURL)
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
          }
          HStack(spacing: 10) {
            Button {
              Task { await state.uploadEncryptedVault() }
            } label: {
              if state.syncing {
                ProgressView()
              } else {
                Label("Upload encrypted vault", systemImage: "arrow.up.doc")
              }
            }
            .buttonStyle(AtlasPrimaryButtonStyle())
            Button("Download encrypted vault") {
              Task { await state.downloadEncryptedVault() }
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
          }
        }
      }

      Surface {
        VStack(alignment: .leading, spacing: 12) {
          SectionHeader(title: "Sync state", meta: "Plain metadata only")
          KeyValueGrid(rows: [
            ("Account", state.document.syncState.accountId ?? "not connected"),
            ("Session", state.document.syncState.sessionToken.isEmpty ? "sign in required" : "active"),
            ("Last synced", state.document.syncState.lastSyncedAt?.formatted(date: .abbreviated, time: .shortened) ?? "never"),
            ("Checksum", state.document.syncState.lastChecksum ?? "none")
          ])
        }
      }
    }
    .onAppear {
      serverURL = state.document.syncState.serverURL
    }
  }
}

struct ExportView: View {
  @EnvironmentObject private var state: AppState
  @State private var exported = ""

  var body: some View {
    Page(
      eyebrow: "Local reports",
      title: "Export",
      subtitle: "Generate CSV or JSON from the encrypted vault after unlock.",
      statTitle: "Latest assets",
      statValue: "\(state.latestScan?.holdings.count ?? 0)"
    ) {
      HStack(spacing: 10) {
        Button("Generate CSV") {
          exported = AddressAtlasExporter.csv(for: state.latestScan?.holdings ?? [])
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        Button("Save CSV") {
          let csv = AddressAtlasExporter.csv(for: state.latestScan?.holdings ?? [])
          exported = csv
          save(text: csv, suggestedName: "address-atlas-holdings.csv", contentType: .commaSeparatedText)
        }
        .buttonStyle(AtlasPrimaryButtonStyle())
        Button("Generate JSON") {
          if let data = try? AddressAtlasExporter.json(for: state.document) {
            exported = String(decoding: data, as: UTF8.self)
          }
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        Button("Save JSON") {
          do {
            let data = try AddressAtlasExporter.json(for: state.document)
            let json = String(decoding: data, as: UTF8.self)
            exported = json
            save(text: json, suggestedName: "address-atlas-vault.json", contentType: .json)
          } catch {
            state.error = error.localizedDescription
          }
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
      }
      Surface {
        TextEditor(text: $exported)
          .font(.system(size: 12, design: .monospaced))
          .scrollContentBackground(.hidden)
          .frame(minHeight: 430)
      }
    }
  }

  private func save(text: String, suggestedName: String, contentType: UTType) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = suggestedName
    panel.allowedContentTypes = [contentType]
    panel.canCreateDirectories = true
    if panel.runModal() == .OK, let url = panel.url {
      do {
        try text.write(to: url, atomically: true, encoding: .utf8)
        state.notice = "Export saved."
        state.error = ""
      } catch {
        state.error = error.localizedDescription
      }
    }
  }
}

struct SettingsView: View {
  @EnvironmentObject private var state: AppState
  @State private var recoveryCode = ""
  @State private var restoreCode = ""

  var body: some View {
    Page(
      eyebrow: "Local preferences",
      title: "Settings",
      subtitle: "Display and scan preferences stored inside the encrypted vault.",
      statTitle: "Currency",
      statValue: state.document.preferences.currency
    ) {
      Surface {
        VStack(alignment: .leading, spacing: 18) {
          SectionHeader(title: "Scan behavior", meta: "Encrypted preferences")
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
          HStack(spacing: 12) {
            TextField("Dust threshold USD", value: Binding(get: {
              state.document.preferences.dustThreshold
            }, set: {
              state.document.preferences.dustThreshold = $0
              state.save()
            }), format: .number)
            .textFieldStyle(AtlasTextFieldStyle())
            TextField("Display currency", text: Binding(get: {
              state.document.preferences.currency
            }, set: {
              state.document.preferences.currency = $0.uppercased()
              state.save()
            }))
            .textFieldStyle(AtlasTextFieldStyle())
          }
        }
      }

      Surface {
        VStack(alignment: .leading, spacing: 16) {
          SectionHeader(title: "Recovery kit", meta: "File plus code")
          Text("Export a recovery file and store the recovery code separately. Both are required to restore the Mac vault key.")
            .font(.system(size: 13))
            .foregroundStyle(AtlasTheme.ink2)
          HStack(spacing: 10) {
            Button("Export recovery kit") {
              exportRecoveryKit()
            }
            .buttonStyle(AtlasPrimaryButtonStyle())
            TextField("Recovery code for restore", text: $restoreCode)
              .textFieldStyle(AtlasTextFieldStyle())
            Button("Restore from kit") {
              restoreRecoveryKit()
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
          }
          if !recoveryCode.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              AtlasLabel("Store this code separately")
              Text(recoveryCode)
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AtlasTheme.paper2)
                .overlay(Rectangle().stroke(AtlasTheme.ruleSoft, lineWidth: 1))
            }
          }
        }
      }
    }
  }

  private func exportRecoveryKit() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "address-atlas.atlas-recovery"
    panel.allowedContentTypes = [UTType(filenameExtension: "atlas-recovery") ?? .data]
    panel.canCreateDirectories = true
    if panel.runModal() == .OK, let url = panel.url {
      do {
        recoveryCode = try state.exportRecoveryKit(to: url)
      } catch {
        state.error = error.localizedDescription
      }
    }
  }

  private func restoreRecoveryKit() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "atlas-recovery") ?? .data]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    if panel.runModal() == .OK, let url = panel.url {
      Task {
        await state.restoreRecoveryKit(from: url, recoveryCode: restoreCode)
      }
    }
  }
}

struct AssetList: View {
  var assets: [TrackedAsset]

  var body: some View {
    if assets.isEmpty {
      EmptyState(title: "No assets yet", systemImage: "wallet.pass", copy: "Add a wallet and run a scan.")
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

struct AssetRow: View {
  var asset: TrackedAsset

  var body: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(asset.symbol)
            .font(.system(size: 16, weight: .semibold))
          if asset.priceUsd <= 0 {
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
        Text(asset.source.rawValue.uppercased())
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(AtlasTheme.ink3)
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
        Task { await state.scanSavedWallets() }
      } label: {
        if state.scanning {
          ProgressView()
        } else {
          Label("Scan saved wallets", systemImage: "arrow.clockwise")
        }
      }
      .buttonStyle(AtlasPrimaryButtonStyle())
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
      Text("\(assetCount) assets - \(generatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "no snapshot")")
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

struct Page<Content: View>: View {
  var eyebrow: String
  var title: String
  var subtitle: String
  var statTitle: String
  var statValue: String
  var content: Content

  init(
    eyebrow: String,
    title: String,
    subtitle: String,
    statTitle: String,
    statValue: String,
    @ViewBuilder content: () -> Content
  ) {
    self.eyebrow = eyebrow
    self.title = title
    self.subtitle = subtitle
    self.statTitle = statTitle
    self.statValue = statValue
    self.content = content()
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        HStack(alignment: .top, spacing: 28) {
          VStack(alignment: .leading, spacing: 12) {
            AtlasLabel(eyebrow)
            Text(title)
              .font(.system(size: 58, weight: .regular, design: .serif))
              .italic()
              .lineLimit(1)
              .minimumScaleFactor(0.7)
            Text(subtitle)
              .font(.system(size: 15))
              .foregroundStyle(AtlasTheme.ink2)
              .lineSpacing(3)
              .frame(maxWidth: 680, alignment: .leading)
          }
          Spacer()
          VStack(alignment: .trailing, spacing: 5) {
            AtlasLabel(statTitle)
            Text(statValue)
              .font(.system(size: 13, weight: .semibold, design: .monospaced))
          }
          .frame(minWidth: 170, alignment: .trailing)
        }
        .padding(.bottom, 28)
        .overlay(alignment: .bottom) {
          Rectangle().fill(AtlasTheme.rule).frame(height: 1)
        }

        StatusLine()
        content
      }
      .padding(.horizontal, 48)
      .padding(.vertical, 30)
      .frame(maxWidth: 1220, alignment: .leading)
    }
    .scrollContentBackground(.hidden)
    .background(AtlasTheme.paper)
  }
}

struct Surface<Content: View>: View {
  var padding: CGFloat
  var content: Content

  init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
    self.padding = padding
    self.content = content()
  }

  var body: some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(AtlasTheme.paper)
      .foregroundStyle(AtlasTheme.ink)
      .overlay(Rectangle().stroke(AtlasTheme.rule, lineWidth: 1))
  }
}

struct SectionHeader: View {
  var title: String
  var meta: String

  var body: some View {
    HStack {
      AtlasLabel(title)
      Spacer()
      AtlasLabel(meta)
    }
  }
}

struct AtlasLabel: View {
  var text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text.uppercased())
      .font(.system(size: 10, weight: .medium, design: .monospaced))
      .foregroundStyle(AtlasTheme.ink3)
      .tracking(1.1)
  }
}

struct Badge: View {
  var text: String
  var color: Color

  init(_ text: String, color: Color = AtlasTheme.ink3) {
    self.text = text
    self.color = color
  }

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .medium, design: .monospaced))
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .frame(height: 22)
      .overlay(Rectangle().stroke(color.opacity(0.55), lineWidth: 1))
  }
}

struct TableHeader: View {
  var text: String
  var alignment: Alignment
  var width: CGFloat?

  init(_ text: String, alignment: Alignment = .leading, width: CGFloat? = nil) {
    self.text = text
    self.alignment = alignment
    self.width = width
  }

  var body: some View {
    AtlasLabel(text)
      .frame(width: width, alignment: alignment)
      .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
  }
}

struct KeyValueGrid: View {
  var rows: [(String, String)]

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
        HStack(alignment: .firstTextBaseline) {
          AtlasLabel(row.0)
            .frame(width: 140, alignment: .leading)
          Text(row.1)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(AtlasTheme.ink2)
            .textSelection(.enabled)
          Spacer()
        }
        .padding(.vertical, 10)
        if index != rows.count - 1 {
          Divider().overlay(AtlasTheme.ruleSoft)
        }
      }
    }
  }
}

struct EmptyState: View {
  var title: String
  var systemImage: String
  var copy: String

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 26))
        .foregroundStyle(AtlasTheme.ink3)
      Text(title)
        .font(.system(size: 18, weight: .semibold, design: .serif))
      Text(copy)
        .font(.system(size: 13))
        .foregroundStyle(AtlasTheme.ink3)
    }
    .frame(maxWidth: .infinity)
    .padding(36)
    .background(AtlasTheme.paper2)
    .overlay(Rectangle().stroke(AtlasTheme.rule, lineWidth: 1))
  }
}

struct BrandLockup: View {
  var body: some View {
    HStack(spacing: 12) {
      Text("A")
        .font(.system(size: 22, weight: .regular, design: .serif))
        .italic()
        .frame(width: 36, height: 36)
        .overlay(Circle().stroke(AtlasTheme.ink, lineWidth: 1))
      VStack(alignment: .leading, spacing: 1) {
        Text("Address Atlas")
          .font(.system(size: 19, weight: .regular, design: .serif))
          .italic()
        AtlasLabel("Private portfolio map")
      }
    }
  }
}

struct SidebarTrustLine: View {
  var title: String
  var copy: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      AtlasLabel(title)
      Text(copy)
        .font(.system(size: 13))
        .foregroundStyle(AtlasTheme.ink2)
    }
    .padding(.vertical, 11)
    .overlay(alignment: .bottom) {
      Rectangle().fill(AtlasTheme.ruleSoft).frame(height: 1)
    }
  }
}

struct StatusLine: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !state.notice.isEmpty {
        HStack(spacing: 8) {
          Image(systemName: "checkmark.circle")
          Text(state.notice)
        }
        .foregroundStyle(AtlasTheme.gain)
      }
      if !state.error.isEmpty {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle")
          Text(state.error)
        }
        .foregroundStyle(AtlasTheme.loss)
      }
    }
    .font(.system(size: 12))
  }
}

struct AtlasTextFieldStyle: TextFieldStyle {
  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration
      .textFieldStyle(.plain)
      .foregroundStyle(AtlasTheme.ink)
      .padding(.horizontal, 12)
      .frame(height: 40)
      .background(AtlasTheme.paper)
      .overlay(Rectangle().stroke(AtlasTheme.rule, lineWidth: 1))
  }
}

struct AtlasPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(AtlasTheme.paper)
      .padding(.horizontal, 15)
      .frame(minHeight: 40)
      .background(configuration.isPressed ? AtlasTheme.accent : AtlasTheme.ink)
      .contentShape(Rectangle())
  }
}

struct AtlasSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(configuration.isPressed ? AtlasTheme.accent : AtlasTheme.ink)
      .padding(.horizontal, 14)
      .frame(minHeight: 38)
      .background(AtlasTheme.paper)
      .overlay(Rectangle().stroke(configuration.isPressed ? AtlasTheme.accent : AtlasTheme.rule, lineWidth: 1))
      .contentShape(Rectangle())
  }
}

struct SidebarButtonStyle: ButtonStyle {
  var active: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: .medium))
      .foregroundStyle(active ? AtlasTheme.paper : AtlasTheme.ink2)
      .background(active ? AtlasTheme.ink : (configuration.isPressed ? AtlasTheme.paper2 : Color.clear))
  }
}

struct IconButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13))
      .foregroundStyle(configuration.isPressed ? AtlasTheme.loss : AtlasTheme.ink3)
      .frame(width: 30, height: 30)
      .contentShape(Rectangle())
  }
}

private func money(_ value: Double) -> String {
  value.formatted(.currency(code: "USD"))
}
