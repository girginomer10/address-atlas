import AddressAtlasCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PortfolioView: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    Page(
      eyebrow: "Read-only command center",
      title: "Portfolio",
      subtitle:
        "Balances from saved public addresses, custom tokens, exchange connections, and manual holdings.",
      statTitle: "Latest snapshot",
      statValue: latestSnapshotLabel
    ) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 28) {
          portfolioSummary
          QuickActionsPanel()
            .frame(width: 290)
        }
        VStack(alignment: .leading, spacing: 22) {
          portfolioSummary
          QuickActionsPanel()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      if let warnings = state.latestScan?.warnings, !warnings.isEmpty {
        ScanWarningsView(warnings: warnings)
      }

      SectionHeader(
        title: "Top holdings",
        meta: holdingsVisibilitySummary
      )
      AssetList(assets: state.visibleLatestHoldings)
    }
  }

  private var latestSnapshotLabel: String {
    state.latestScan?.generatedAt.formatted(date: .abbreviated, time: .shortened) ?? "None"
  }

  private var portfolioSummary: some View {
    VStack(alignment: .leading, spacing: 18) {
      TotalBlock(
        total: state.latestKnownValueUsd,
        generatedAt: state.latestScan?.generatedAt,
        assetCount: state.latestScan?.holdings.count ?? 0,
        unpricedCount: state.unpricedHoldingCount
      )
      MetricStrip(items: [
        ("Wallets", "\(state.document.wallets.count)"),
        ("Visible assets", "\(state.visibleLatestHoldings.count)"),
        ("Tokens", "\(state.document.customTokens.filter(\.enabled).count)"),
      ])
    }
    .frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
  }

  private var holdingsVisibilitySummary: String {
    guard state.hiddenDustHoldingCount > 0 else {
      return "\(state.visibleLatestHoldings.count) visible rows"
    }
    return
      "\(state.visibleLatestHoldings.count) visible, \(state.hiddenDustHoldingCount) hidden as dust (\(money(state.hiddenDustValueUsd)))"
  }
}

struct WalletsView: View {
  @EnvironmentObject private var state: AppState
  @State private var address = ""

  private var hasAddressInput: Bool {
    !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

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
          AdaptiveStack {
            TextField("Public wallet address", text: $address)
              .textFieldStyle(AtlasTextFieldStyle())
            Button {
              Task {
                if await state.addWallet(address: address) {
                  address = ""
                }
              }
            } label: {
              Label("Add", systemImage: "plus")
            }
            .buttonStyle(AtlasPrimaryButtonStyle())
            .disabled(!hasAddressInput)
          }
        }
      }
      .disabled(state.vaultEditsDisabled)

      SectionHeader(
        title: "Saved wallets", meta: "\(state.document.wallets.count) encrypted records")
      if state.document.wallets.isEmpty {
        EmptyState(
          title: "No wallets yet", systemImage: "wallet.pass",
          copy: "Add a public address to start scanning.")
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
  @State private var confirmingRemoval = false
  @FocusState private var labelIsFocused: Bool
  var wallet: WalletRecord

  var body: some View {
    HStack(spacing: 16) {
      TextField("Label", text: labelDraftBinding)
        .textFieldStyle(.plain)
        .font(.body.weight(.semibold))
        .frame(width: 180)
        .focused($labelIsFocused)
        .accessibilityLabel("Label for wallet \(AtlasAccessibility.walletIdentity(wallet))")
        .accessibilityHint("Edit the local display label for this saved wallet.")
        .onSubmit(commitLabel)
        .onChange(of: labelIsFocused) { _, isFocused in
          if !isFocused { commitLabel() }
        }

      Text(wallet.address)
        .font(.caption.monospaced())
        .foregroundStyle(AtlasTheme.ink2)
        .lineLimit(1)
        .truncationMode(.middle)

      Spacer()

      Badge(wallet.chainKind.rawValue.uppercased())

      Button(role: .destructive) {
        confirmingRemoval = true
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(IconButtonStyle())
      .accessibilityLabel("Remove wallet \(AtlasAccessibility.walletIdentity(wallet))")
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 10)
    .frame(minHeight: 62)
    .confirmationDialog(
      "Remove \(AtlasAccessibility.walletIdentity(wallet))?",
      isPresented: $confirmingRemoval,
      titleVisibility: .visible
    ) {
      Button("Remove wallet", role: .destructive) {
        Task { await state.removeWallet(id: wallet.id) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The public address will be removed from this vault. Existing snapshots are unchanged.")
    }
    .onDisappear(perform: commitLabel)
    .disabled(state.vaultEditsDisabled)
  }

  private func commitLabel() {
    Task { await state.commitWalletLabelDraft(id: wallet.id) }
  }

  private var labelDraftBinding: Binding<String> {
    Binding(
      get: { state.walletLabelDraft(for: wallet) },
      set: { _ = state.setWalletLabelDraft(id: wallet.id, label: $0) }
    )
  }
}

struct AssetsView: View {
  @EnvironmentObject private var state: AppState
  @State private var query = ""
  @State private var hideUnpriced = false

  var filteredAssets: [TrackedAsset] {
    state.visibleLatestHoldings.filter { asset in
      let matchesQuery =
        query.isEmpty
        || asset.symbol.localizedCaseInsensitiveContains(query)
        || asset.chainName.localizedCaseInsensitiveContains(query)
        || asset.name.localizedCaseInsensitiveContains(query)
      let matchesPricing = !hideUnpriced || AppState.isPricedForDisplay(asset)
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

  private var hasRequiredTokenInput: Bool {
    !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !decimals.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

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
          AdaptiveStack {
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
          AdaptiveStack {
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
              Task {
                if await state.addCustomToken(
                  chainKind: chainKind,
                  chainId: chainKind == .solana ? "solana" : chainId,
                  address: address,
                  symbol: symbol,
                  name: name,
                  decimals: decimals,
                  coinGeckoId: coinGeckoId,
                  priceUsd: priceUsd
                ) {
                  address = ""
                  symbol = ""
                  name = ""
                  decimals = chainKind == .evm ? "18" : "6"
                  coinGeckoId = ""
                  priceUsd = ""
                }
              }
            }
            .buttonStyle(AtlasPrimaryButtonStyle())
            .disabled(!hasRequiredTokenInput)
          }
        }
      }
      .disabled(state.vaultEditsDisabled)

      SectionHeader(title: "Saved tokens", meta: "\(state.document.customTokens.count) records")
      if state.document.customTokens.isEmpty {
        EmptyState(
          title: "No custom tokens", systemImage: "tag",
          copy: "The built-in registry is still used during scans.")
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
  @State private var confirmingRemoval = false
  var token: CustomTokenRecord

  var body: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(token.symbol)
            .font(.body.weight(.semibold))
          Text(token.name)
            .foregroundStyle(AtlasTheme.ink2)
        }
        Text("\(token.chainId) - \(token.address)")
          .font(.caption.monospaced())
          .foregroundStyle(AtlasTheme.ink3)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      Badge(
        token.enabled ? "ENABLED" : "PAUSED",
        color: token.enabled ? AtlasTheme.gain : AtlasTheme.ink3)
      Toggle(
        "Enable \(token.symbol)",
        isOn: Binding(
          get: {
            token.enabled
          },
          set: { _ in
            Task { await state.toggleCustomToken(id: token.id) }
          })
      )
      .labelsHidden()
      .accessibilityLabel(
        "\(token.enabled ? "Disable" : "Enable") token \(AtlasAccessibility.tokenIdentity(token))"
      )
      Button(role: .destructive) {
        confirmingRemoval = true
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(IconButtonStyle())
      .accessibilityLabel("Remove token \(AtlasAccessibility.tokenIdentity(token))")
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 10)
    .frame(minHeight: 64)
    .confirmationDialog(
      "Remove \(AtlasAccessibility.tokenIdentity(token))?",
      isPresented: $confirmingRemoval,
      titleVisibility: .visible
    ) {
      Button("Remove token", role: .destructive) {
        Task { await state.removeCustomToken(id: token.id) }
      }
      Button("Cancel", role: .cancel) {}
    }
    .disabled(state.vaultEditsDisabled)
  }
}

struct SnapshotsView: View {
  @EnvironmentObject private var state: AppState
  @State private var symbol = ""
  @State private var amount = ""
  @State private var value = ""

  private var hasRequiredManualHoldingInput: Bool {
    !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

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
          AdaptiveStack {
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
              Task {
                if await state.addManualHolding(symbol: symbol, amount: amount, valueUsd: value) {
                  symbol = ""
                  amount = ""
                  value = ""
                }
              }
            }
            .buttonStyle(AtlasPrimaryButtonStyle())
            .disabled(!hasRequiredManualHoldingInput)
          }
        }
      }
      .disabled(state.vaultEditsDisabled)

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 24) {
          SnapshotList()
          ManualHoldingList()
        }
        VStack(alignment: .leading, spacing: 24) {
          SnapshotList()
          ManualHoldingList()
        }
      }
    }
  }
}

struct SnapshotList: View {
  @EnvironmentObject private var state: AppState
  @State private var pendingRemoval: UUID?

  private var sortedRuns: [ScanRunRecord] {
    state.document.scanRuns.sorted { $0.generatedAt > $1.generatedAt }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionHeader(title: "Snapshot history", meta: "\(state.document.scanRuns.count) saved")
      Surface(padding: 0) {
        if state.document.scanRuns.isEmpty {
          EmptyState(
            title: "No snapshots", systemImage: "clock.arrow.circlepath",
            copy: "Run a scan to create the first snapshot."
          )
          .padding(28)
        } else {
          VStack(spacing: 0) {
            ForEach(sortedRuns) { run in
              HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                  Text(run.generatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.body.weight(.semibold))
                  Text("\(run.holdings.count) assets")
                    .foregroundStyle(AtlasTheme.ink3)
                }
                Spacer()
                Text(money(run.totalUsd))
                  .font(.body.monospaced())
                Button(role: .destructive) {
                  pendingRemoval = run.id
                } label: {
                  Image(systemName: "trash")
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel(
                  "Remove snapshot \(AtlasAccessibility.snapshotIdentity(run))"
                )
              }
              .padding(.horizontal, 18)
              .padding(.vertical, 9)
              .frame(minHeight: 58)
              if run.id != sortedRuns.last?.id {
                Divider().overlay(AtlasTheme.ruleSoft)
              }
            }
          }
        }
      }
    }
    .frame(minWidth: 300, maxWidth: .infinity, alignment: .topLeading)
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
          Task { await state.removeScanRun(id: pendingRemoval) }
        }
        pendingRemoval = nil
      }
      Button("Cancel", role: .cancel) { pendingRemoval = nil }
    }
    .disabled(state.vaultEditsDisabled)
  }

  private var pendingRemovalIdentity: String {
    guard let pendingRemoval,
      let run = sortedRuns.first(where: { $0.id == pendingRemoval })
    else { return "this snapshot" }
    return AtlasAccessibility.snapshotIdentity(run)
  }
}

struct ManualHoldingList: View {
  @EnvironmentObject private var state: AppState
  @State private var pendingRemoval: UUID?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionHeader(
        title: "Manual holdings", meta: "\(state.document.manualHoldings.count) entries")
      Surface(padding: 0) {
        if state.document.manualHoldings.isEmpty {
          EmptyState(
            title: "No manual entries", systemImage: "pencil.and.list.clipboard",
            copy: "Add offline balances above."
          )
          .padding(28)
        } else {
          VStack(spacing: 0) {
            ForEach(state.document.manualHoldings) { holding in
              HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                  Text("\(holding.symbol) - \(holding.label)")
                    .font(.body.weight(.semibold))
                  Text("\(holding.amount.formatted()) - \(money(holding.valueUsd))")
                    .foregroundStyle(AtlasTheme.ink3)
                }
                Spacer()
                Toggle(
                  "Enable \(holding.symbol)",
                  isOn: Binding(
                    get: {
                      holding.enabled
                    },
                    set: { _ in
                      Task { await state.toggleManualHolding(id: holding.id) }
                    })
                )
                .labelsHidden()
                .accessibilityLabel(
                  "\(holding.enabled ? "Disable" : "Enable") manual holding \(AtlasAccessibility.manualHoldingIdentity(holding))"
                )
                Button(role: .destructive) {
                  pendingRemoval = holding.id
                } label: {
                  Image(systemName: "trash")
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel(
                  "Remove manual holding \(AtlasAccessibility.manualHoldingIdentity(holding))"
                )
              }
              .padding(.horizontal, 18)
              .padding(.vertical, 9)
              .frame(minHeight: 58)
              if holding.id != state.document.manualHoldings.last?.id {
                Divider().overlay(AtlasTheme.ruleSoft)
              }
            }
          }
        }
      }
    }
    .frame(minWidth: 300, maxWidth: .infinity, alignment: .topLeading)
    .confirmationDialog(
      "Remove \(pendingRemovalIdentity)?",
      isPresented: Binding(
        get: { pendingRemoval != nil },
        set: { if !$0 { pendingRemoval = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Remove holding", role: .destructive) {
        if let pendingRemoval {
          Task { await state.removeManualHolding(id: pendingRemoval) }
        }
        pendingRemoval = nil
      }
      Button("Cancel", role: .cancel) { pendingRemoval = nil }
    }
    .disabled(state.vaultEditsDisabled)
  }

  private var pendingRemovalIdentity: String {
    guard let pendingRemoval,
      let holding = state.document.manualHoldings.first(where: { $0.id == pendingRemoval })
    else { return "this manual holding" }
    return AtlasAccessibility.manualHoldingIdentity(holding)
  }
}
