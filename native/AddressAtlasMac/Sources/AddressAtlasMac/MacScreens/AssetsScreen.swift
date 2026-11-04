import AddressAtlasCore
import SwiftUI

/// Every coin in the last scan, one row each, largest first. Rows open the
/// coin's detail screen. A chart on Portfolio can limit the list to one slice
/// (a network, a state, a wallet).
struct AssetsView: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: MacNavigationModel
  @State private var query = ""
  @State private var hideUnpriced = false
  @FocusState private var searchFocused: Bool

  var body: some View {
    let snapshot = MacPortfolioSnapshot(state: state)
    let filtered = filteredHoldings(snapshot.visible)
    let rows = MacCoinRow.rows(for: filtered)
    MacPage(
      "Assets",
      trailing: {
        if snapshot.hasScan {
          Text(MacFormat.count(rows.count, "asset"))
            .font(AtlasTheme.font(.label, .callout, weight: .medium))
            .foregroundStyle(AtlasTheme.ink3)
        }
      }
    ) {
      if !snapshot.hasScan {
        emptyState
      } else {
        filterBar(snapshot)
        if rows.isEmpty {
          MacEmptyState(
            "No matches",
            copy: "Try another name, or clear the filters.",
            systemImage: "magnifyingglass"
          ) {
            Button("Clear filters") { clearFilters() }
              .buttonStyle(MacSecondaryButtonStyle())
          }
        } else {
          MacCoinList(rows: rows, showsHeader: true) { navigation.openCoin($0) }
        }
        if let dust = snapshot.dustSentence {
          MacNote(text: dust, tone: .info, systemImage: "line.3.horizontal.decrease.circle")
        }
        if let unpriced = snapshot.unpricedSentence {
          MacNote(text: unpriced, tone: .warning)
        }
      }
    }
    .onAppear { focusIfRequested() }
    .onChange(of: navigation.pendingAction) { _, _ in focusIfRequested() }
  }

  // MARK: Filtering

  private func filteredHoldings(_ holdings: [TrackedAsset]) -> [TrackedAsset] {
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return holdings.filter { asset in
      if let slice = navigation.assetsFilter, !slice.matches(asset) { return false }
      if hideUnpriced, !AppState.isPricedForDisplay(asset) { return false }
      guard !text.isEmpty else { return true }
      return asset.symbol.localizedCaseInsensitiveContains(text)
        || asset.name.localizedCaseInsensitiveContains(text)
        || asset.chainName.localizedCaseInsensitiveContains(text)
        || (asset.walletLabel?.localizedCaseInsensitiveContains(text) ?? false)
        || (asset.exchangeProvider?.label.localizedCaseInsensitiveContains(text) ?? false)
    }
  }

  private func clearFilters() {
    query = ""
    hideUnpriced = false
    navigation.assetsFilter = nil
  }

  private func focusIfRequested() {
    if navigation.consume(.focusAssetSearch) { searchFocused = true }
  }

  // MARK: Controls

  private func filterBar(_ snapshot: MacPortfolioSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(AtlasTheme.ink3)
          .accessibilityHidden(true)
        TextField("Search assets", text: $query)
          .textFieldStyle(.plain)
          .font(AtlasTheme.font(.body, .body))
          .focused($searchFocused)
          .accessibilityLabel("Search assets")
          .onSubmit { searchFocused = false }
        if !query.isEmpty {
          Button {
            query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(IconButtonStyle())
          .accessibilityLabel("Clear search")
        }
      }
      .padding(.horizontal, 13)
      .frame(minHeight: 42)
      .atlasChrome(
        fill: AtlasTheme.surface,
        border: searchFocused ? AtlasTheme.focusRing : AtlasTheme.controlBoundary,
        level: .control,
        radius: AtlasRadius.control,
        borderWidth: searchFocused ? 2.5 : max(1, min(AtlasTheme.shape.controlBorderWidth, 2)),
        showsShadow: false
      )

      AdaptiveStack(horizontalSpacing: 18, verticalSpacing: 8) {
        Toggle(
          isOn: Binding(
            get: { state.document.preferences.hideDust },
            set: { value in Task { await state.setHideDust(value) } })
        ) {
          Text(dustToggleTitle)
        }
        .toggleStyle(.checkbox)
        .disabled(state.vaultEditsDisabled)
        Toggle("Hide assets with no price", isOn: $hideUnpriced)
          .toggleStyle(.checkbox)
        if let slice = navigation.assetsFilter {
          MacFilterChip(
            title: "\(slice.grouping.displayName): \(slice.label(in: snapshot.current))"
          ) { navigation.assetsFilter = nil }
        }
      }
      .font(AtlasTheme.font(.body, .callout))
    }
  }

  private var dustToggleTitle: String {
    let preferences = state.document.preferences
    guard preferences.dustThreshold.isFinite, preferences.dustThreshold > 0 else {
      return "Hide small balances"
    }
    return "Hide balances under \(money(preferences.dustThreshold))"
  }

  // MARK: Empty

  @ViewBuilder
  private var emptyState: some View {
    if state.hasScanSources {
      MacEmptyState(
        "No scan yet", copy: "Scan to see what you hold.", systemImage: "arrow.clockwise"
      ) {
        MacScanButton()
      }
    } else {
      MacEmptyState(
        "No assets yet",
        copy: "Add a wallet address or an exchange to see what you hold.",
        systemImage: "wallet.pass"
      ) {
        Button {
          navigation.requestAddWallet()
        } label: {
          Label("Add wallet", systemImage: "plus")
        }
        .buttonStyle(MacPrimaryButtonStyle())
        Button {
          navigation.go(.exchanges)
        } label: {
          Label("Connect exchange", systemImage: "building.columns")
        }
        .buttonStyle(MacSecondaryButtonStyle())
      }
    }
  }
}
