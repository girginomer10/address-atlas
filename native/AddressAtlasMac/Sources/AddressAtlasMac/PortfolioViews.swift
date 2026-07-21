import AddressAtlasCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PortfolioView: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    Page(
      eyebrow: "Portfolio overview",
      title: "Portfolio",
      subtitle:
        "A unified view of wallets, exchange balances, custom tokens, staking, and rewards.",
      statTitle: "Latest snapshot",
      statValue: latestSnapshotLabel
    ) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 28) {
          Surface {
            portfolioSummary
          }
          QuickActionsPanel()
            .frame(width: 290)
        }
        VStack(alignment: .leading, spacing: 22) {
          Surface {
            portfolioSummary
          }
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
      eyebrow: "On-chain sources",
      title: "Wallets",
      subtitle:
        "Track public addresses across supported networks. Private keys never enter the app.",
      statTitle: "Saved",
      statValue: "\(state.document.wallets.count)"
    ) {
      Surface {
        VStack(alignment: .leading, spacing: 18) {
          PanelHeader(
            title: "Add a wallet",
            subtitle: "Paste a public address—never a seed phrase or private key",
            systemImage: "wallet.pass.fill"
          )
          VStack(alignment: .leading, spacing: 8) {
            FieldLabel("Public wallet address")
            AdaptiveStack(horizontalSpacing: 12) {
              TextField("0x…, bc1…, solana, cosmos, or another supported address", text: $address)
                .textFieldStyle(AtlasTextFieldStyle())
                .accessibilityLabel("Public wallet address")
              Button {
                Task {
                  if await state.addWallet(address: address) {
                    address = ""
                  }
                }
              } label: {
                Label("Add wallet", systemImage: "plus")
              }
              .buttonStyle(AtlasPrimaryButtonStyle())
              .disabled(!hasAddressInput)
            }
          }
          InfoCallout(
            title: "Watch-only access",
            copy:
              "Address Atlas reads public blockchain data. It cannot sign transactions or move funds.",
            tone: .success
          )
        }
      }
      .disabled(state.vaultEditsDisabled)

      SectionHeader(
        title: "Saved wallets", meta: "\(state.document.wallets.count) encrypted on this Mac")
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
      Image(systemName: "wallet.pass.fill")
        .font(.body.weight(.semibold))
        .foregroundStyle(AtlasTheme.accent)
        .frame(width: 40, height: 40)
        .background(AtlasTheme.accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

      HStack(spacing: 7) {
        TextField("Wallet name", text: labelDraftBinding)
          .textFieldStyle(.plain)
          .font(.body.weight(.semibold))
          .focused($labelIsFocused)
          .accessibilityLabel("Label for wallet \(AtlasAccessibility.walletIdentity(wallet))")
          .accessibilityHint("Edit the local display label for this saved wallet.")
          .onSubmit(commitLabel)
          .onChange(of: labelIsFocused) { _, isFocused in
            if !isFocused { commitLabel() }
          }
        Image(systemName: "pencil")
          .font(.caption)
          .foregroundStyle(labelIsFocused ? AtlasTheme.accent : AtlasTheme.ink3)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 9)
      .frame(width: 190)
      .frame(minHeight: 36)
      .background(labelIsFocused ? AtlasTheme.accent.opacity(0.08) : Color.clear)
      .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.small, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: AtlasRadius.small, style: .continuous)
          .stroke(labelIsFocused ? AtlasTheme.accent : AtlasTheme.ruleSoft, lineWidth: 1)
      }

      Text(wallet.address)
        .font(.caption.monospaced())
        .foregroundStyle(AtlasTheme.ink2)
        .lineLimit(1)
        .truncationMode(.middle)

      Spacer()

      Badge(wallet.chainKind.rawValue.capitalized)

      Button(role: .destructive) {
        confirmingRemoval = true
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(IconButtonStyle())
      .accessibilityLabel("Remove wallet \(AtlasAccessibility.walletIdentity(wallet))")
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .frame(minHeight: 70)
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
      eyebrow: "Portfolio detail",
      title: "Assets",
      subtitle: "Search every balance by asset, network, wallet, or exchange source.",
      statTitle: "Visible rows",
      statValue: "\(filteredAssets.count)"
    ) {
      Surface {
        VStack(alignment: .leading, spacing: 16) {
          PanelHeader(
            title: "Find a holding",
            subtitle: "Filter the latest portfolio snapshot",
            systemImage: "magnifyingglass"
          )
          AdaptiveStack(horizontalSpacing: 14) {
            HStack(spacing: 10) {
              Image(systemName: "magnifyingglass")
                .foregroundStyle(AtlasTheme.ink3)
              TextField("Search assets, networks, or names", text: $query)
                .textFieldStyle(.plain)
            }
            .padding(.horizontal, 13)
            .frame(minHeight: 42)
            .background(AtlasTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
                .stroke(AtlasTheme.ruleSoft, lineWidth: 1)
            }
            Toggle("Hide assets without a price", isOn: $hideUnpriced)
              .toggleStyle(.checkbox)
          }
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
      eyebrow: "Custom assets",
      title: "Tokens",
      subtitle:
        "Add a verified contract or mint when an asset is not yet in the built-in registry.",
      statTitle: "Enabled",
      statValue: "\(state.document.customTokens.filter(\.enabled).count)"
    ) {
      if !state.document.customTokens.isEmpty {
        savedTokensSection
      }

      Surface {
        VStack(alignment: .leading, spacing: 20) {
          PanelHeader(
            title: "Add a custom token",
            subtitle: "Verify the contract or mint address before saving",
            systemImage: "tag.fill"
          )

          AdaptiveStack(horizontalSpacing: 12, verticalSpacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
              FieldLabel("Network family")
              Picker("Network family", selection: $chainKind) {
                Text("EVM").tag(ChainFamily.evm)
                Text("Solana").tag(ChainFamily.solana)
              }
              .pickerStyle(.segmented)
              .labelsHidden()
              .frame(minWidth: 170)
            }
            VStack(alignment: .leading, spacing: 8) {
              FieldLabel("Network")
              Picker("Network", selection: $chainId) {
                if chainKind == .evm {
                  ForEach(ChainRegistry.evmChains, id: \.id) { chain in
                    Text(chain.name).tag(chain.id)
                  }
                } else {
                  Text("Solana").tag("solana")
                }
              }
              .labelsHidden()
              .accessibilityLabel("Network")
              .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
            }
          }

          VStack(alignment: .leading, spacing: 8) {
            FieldLabel(chainKind == .evm ? "Token contract" : "Token mint")
            TextField(
              chainKind == .evm ? "0x… contract address" : "Solana mint address",
              text: $address
            )
            .textFieldStyle(AtlasTextFieldStyle())
          }

          AdaptiveStack(horizontalSpacing: 12, verticalSpacing: 14) {
            tokenField(title: "Symbol", placeholder: "USDC", text: $symbol)
            tokenField(title: "Token name", placeholder: "USD Coin", text: $name)
            tokenField(
              title: "Decimals", placeholder: chainKind == .evm ? "18" : "6", text: $decimals)
          }

          AdaptiveStack(horizontalSpacing: 12, verticalSpacing: 14) {
            tokenField(
              title: "CoinGecko ID",
              detail: "Optional",
              placeholder: "usd-coin",
              text: $coinGeckoId
            )
            tokenField(
              title: "Manual USD price",
              detail: "Optional",
              placeholder: "0.00",
              text: $priceUsd
            )
          }

          InfoCallout(
            title: "Contract addresses are authoritative",
            copy:
              "A misleading symbol or name cannot change which on-chain token is scanned. Confirm the address from a trusted source.",
            tone: .info
          )

          Button {
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
          } label: {
            Label("Add token", systemImage: "plus")
          }
          .buttonStyle(AtlasPrimaryButtonStyle())
          .disabled(!hasRequiredTokenInput)
        }
      }
      .disabled(state.vaultEditsDisabled)

      if state.document.customTokens.isEmpty {
        savedTokensSection
      }
    }
    .onChange(of: chainKind) { _, next in
      chainId = next == .solana ? "solana" : "ethereum"
      decimals = next == .solana ? "6" : "18"
    }
  }

  private var savedTokensSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionHeader(
        title: "Saved tokens",
        meta: "\(state.document.customTokens.count) custom records"
      )
      if state.document.customTokens.isEmpty {
        EmptyState(
          title: "No custom tokens",
          systemImage: "tag",
          copy: "The built-in registry is still used during scans."
        )
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
  }

  private func tokenField(
    title: String,
    detail: String? = nil,
    placeholder: String,
    text: Binding<String>
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      FieldLabel(title, detail: detail)
      TextField(placeholder, text: text)
        .textFieldStyle(AtlasTextFieldStyle())
    }
    .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
  }
}

struct TokenRow: View {
  @EnvironmentObject private var state: AppState
  @State private var confirmingRemoval = false
  var token: CustomTokenRecord

  var body: some View {
    HStack(spacing: 14) {
      Text(String(token.symbol.prefix(1)).uppercased())
        .font(.caption.weight(.bold))
        .foregroundStyle(AtlasTheme.accent)
        .frame(width: 38, height: 38)
        .background(AtlasTheme.accent.opacity(0.10))
        .clipShape(Circle())
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(token.symbol)
            .font(.body.weight(.semibold))
          Text(token.name)
            .foregroundStyle(AtlasTheme.ink2)
        }
        Text("\(token.chainId) · \(token.address)")
          .font(.caption.monospaced())
          .foregroundStyle(AtlasTheme.ink3)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      Badge(
        token.enabled ? "Enabled" : "Paused",
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
    .padding(.vertical, 12)
    .frame(minHeight: 70)
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
      eyebrow: "History and offline assets",
      title: "Snapshots",
      subtitle:
        "Review previous portfolio states and include balances that cannot be scanned automatically.",
      statTitle: "Runs",
      statValue: "\(state.document.scanRuns.count)"
    ) {
      Surface {
        VStack(alignment: .leading, spacing: 18) {
          PanelHeader(
            title: "Add an offline holding",
            subtitle: "Included in the next portfolio snapshot",
            systemImage: "pencil.and.list.clipboard"
          )
          AdaptiveStack(horizontalSpacing: 12, verticalSpacing: 14) {
            manualField(title: "Asset symbol", placeholder: "BTC", text: $symbol)
            manualField(title: "Amount", placeholder: "0.00", text: $amount)
            manualField(title: "Total value (USD)", placeholder: "0.00", text: $value)
          }
          AdaptiveStack(horizontalSpacing: 12) {
            Button {
              Task {
                if await state.addManualHolding(
                  symbol: symbol,
                  amount: amount,
                  valueUsd: value
                ) {
                  symbol = ""
                  amount = ""
                  value = ""
                }
              }
            } label: {
              Label("Add holding", systemImage: "plus")
            }
            .buttonStyle(AtlasPrimaryButtonStyle())
            .disabled(!hasRequiredManualHoldingInput)
            Text("Manual values are stored in the encrypted local vault.")
              .font(.caption)
              .foregroundStyle(AtlasTheme.ink3)
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

  private func manualField(
    title: String,
    placeholder: String,
    text: Binding<String>
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      FieldLabel(title)
      TextField(placeholder, text: text)
        .textFieldStyle(AtlasTextFieldStyle())
    }
    .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
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
                Image(systemName: "clock.arrow.circlepath")
                  .foregroundStyle(AtlasTheme.accent)
                  .frame(width: 34, height: 34)
                  .background(AtlasTheme.accent.opacity(0.09))
                  .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
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
                Image(systemName: "pencil.and.list.clipboard")
                  .foregroundStyle(AtlasTheme.accent)
                  .frame(width: 34, height: 34)
                  .background(AtlasTheme.accent.opacity(0.09))
                  .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                  Text("\(holding.symbol) · \(holding.label)")
                    .font(.body.weight(.semibold))
                  Text("\(holding.amount.formatted()) · \(money(holding.valueUsd))")
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
