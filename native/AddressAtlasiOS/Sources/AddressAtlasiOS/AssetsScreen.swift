import AddressAtlasCore
import SwiftUI

/// Every holding from the latest snapshot. Ported from the macOS `AssetsView`
/// (search and the price filter) plus the shared dust preference that the
/// desktop keeps in Settings, so the list can be tuned where it is read.
struct AssetsScreen: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var query = ""
  @State private var hideUnpriced = false
  @State private var isUpdatingDustPreference = false
  @FocusState private var searchFocused: Bool
  @FocusState private var thresholdFocused: Bool

  /// Wallet labels edited after the scan are applied for display; the stored
  /// snapshot is never rewritten.
  private var labeledHoldings: [TrackedAsset] {
    AppState.applyingWalletLabels(
      to: state.visibleLatestHoldings, wallets: state.document.wallets)
  }

  private var filteredAssets: [TrackedAsset] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return labeledHoldings.filter { asset in
      let matchesQuery = trimmedQuery.isEmpty || Self.matches(asset, query: trimmedQuery)
      let matchesPricing = !hideUnpriced || AppState.isPricedForDisplay(asset)
      return matchesQuery && matchesPricing
    }
  }

  private var hasSnapshotHoldings: Bool {
    !(state.latestScan?.holdings ?? []).isEmpty
  }

  var body: some View {
    IOSPage(
      title: "Assets",
      subtitle: "Search every balance by asset, network, wallet, or exchange source."
    ) {
      filterCard
      SectionHeader(title: "Holdings", meta: holdingsMeta)
      holdingsList
    }
  }

  private var holdingsMeta: String {
    let visible = filteredAssets.count
    return "\(visible) visible row\(visible == 1 ? "" : "s")"
  }

  // MARK: Filters

  private var filterCard: some View {
    Surface {
      VStack(alignment: .leading, spacing: 16) {
        PanelHeader(
          title: "Find a holding",
          subtitle: "Filter the latest portfolio snapshot",
          systemImage: "magnifyingglass"
        )
        searchField
        Toggle(isOn: $hideUnpriced) {
          AssetsToggleLabel(
            title: "Hide assets without a price",
            copy: "Show only holdings with a known USD value.")
        }
        Divider().overlay(AtlasTheme.ruleSoft)
        Toggle(isOn: hideDustBinding) {
          AssetsToggleLabel(
            title: "Hide small balances",
            copy: "Keep low-value holdings out of the asset list without deleting them.",
            showsProgress: isUpdatingDustPreference)
        }
        .disabled(state.vaultEditsDisabled || isUpdatingDustPreference)
        if state.document.preferences.hideDust {
          thresholdField
          Text(dustNote)
            .font(.caption)
            .foregroundStyle(AtlasTheme.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Small balances: \(dustNote)")
        }
      }
      .animation(
        AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
        value: state.document.preferences.hideDust
      )
    }
  }

  private var searchField: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(AtlasTheme.ink3)
        .accessibilityHidden(true)
      TextField("Search assets, networks, or names", text: $query)
        .textFieldStyle(.plain)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .submitLabel(.search)
        .focused($searchFocused)
        .accessibilityLabel("Search holdings")
      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(AtlasTheme.ink3)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.leading, 13)
    .padding(.trailing, query.isEmpty ? 13 : 0)
    .frame(minHeight: 44)
    .background(AtlasTheme.surface)
    .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
        .stroke(searchFocused ? AtlasTheme.accent : AtlasTheme.ruleSoft, lineWidth: 1)
    }
    .contentShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
    .onTapGesture { searchFocused = true }
    .animation(
      AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion),
      value: searchFocused
    )
  }

  private var thresholdField: some View {
    VStack(alignment: .leading, spacing: 7) {
      FieldLabel("Small-balance threshold", detail: "USD")
      TextField(
        "0.00",
        value: dustThresholdBinding,
        format: FloatingPointFormatStyle<Double>.number.locale(AtlasFormatting.locale)
      )
      .textFieldStyle(AtlasTextFieldStyle())
      .atlasDecimalInput()
      .focused($thresholdFocused)
      .accessibilityLabel("Dust threshold in US dollars")
      .accessibilityHint("Holdings priced below this value are hidden from the list.")
      .toolbar {
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("Done") { thresholdFocused = false }
        }
      }
      .disabled(state.vaultEditsDisabled || isUpdatingDustPreference)
    }
  }

  private var hideDustBinding: Binding<Bool> {
    Binding(
      get: { state.document.preferences.hideDust },
      set: { value in
        guard value != state.document.preferences.hideDust else { return }
        isUpdatingDustPreference = true
        Task {
          await state.setHideDust(value)
          isUpdatingDustPreference = false
        }
      })
  }

  /// The format-backed field commits on submit or focus loss and reverts text
  /// it cannot parse; `setDustThreshold` still rejects non-finite or negative
  /// values with its own message.
  private var dustThresholdBinding: Binding<Double> {
    Binding(
      get: { state.document.preferences.dustThreshold },
      set: { value in
        guard value != state.document.preferences.dustThreshold else { return }
        isUpdatingDustPreference = true
        Task {
          await state.setDustThreshold(value)
          isUpdatingDustPreference = false
        }
      })
  }

  private var dustNote: String {
    let hidden = state.hiddenDustHoldingCount
    guard hidden > 0 else {
      return "No priced holding in the latest snapshot is below the threshold."
    }
    return
      "\(hidden) holding\(hidden == 1 ? "" : "s") hidden as dust (\(money(state.hiddenDustValueUsd))). Portfolio totals still include them."
  }

  // MARK: Holdings

  @ViewBuilder
  private var holdingsList: some View {
    let assets = filteredAssets
    if !hasSnapshotHoldings {
      EmptyState(
        title: "No assets yet", systemImage: "wallet.pass",
        copy: "Add a wallet and run a scan.")
    } else if assets.isEmpty {
      EmptyState(
        title: "No matching assets", systemImage: "magnifyingglass",
        copy: emptyFilterCopy)
    } else {
      Surface(padding: 0) {
        VStack(spacing: 0) {
          ForEach(assets) { asset in
            AssetsCompactRow(asset: asset)
            if asset.id != assets.last?.id {
              Divider().overlay(AtlasTheme.ruleSoft)
            }
          }
        }
      }
    }
  }

  private var emptyFilterCopy: String {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedQuery.isEmpty {
      return "Nothing in the latest snapshot matches “\(trimmedQuery)”."
    }
    return "Every holding in the latest snapshot is hidden by the current filters."
  }

  private static func matches(_ asset: TrackedAsset, query: String) -> Bool {
    asset.symbol.localizedCaseInsensitiveContains(query)
      || asset.name.localizedCaseInsensitiveContains(query)
      || asset.chainName.localizedCaseInsensitiveContains(query)
      || asset.address.localizedCaseInsensitiveContains(query)
      || (asset.walletLabel?.localizedCaseInsensitiveContains(query) ?? false)
      || (asset.exchangeProvider?.label.localizedCaseInsensitiveContains(query) ?? false)
  }
}

private struct AssetsToggleLabel: View {
  var title: String
  var copy: String
  var showsProgress = false

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout.weight(.medium))
          .foregroundStyle(AtlasTheme.ink)
        Text(copy)
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink3)
          .fixedSize(horizontal: false, vertical: true)
      }
      if showsProgress {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Saving preference")
      }
    }
  }
}

/// Two-line touch row: symbol and name, then amount and the wallet or
/// connection it came from; value (or the pricing badge) and the source chip
/// sit trailing. Accessibility mirrors the desktop `CompactAssetRow`.
private struct AssetsCompactRow: View {
  var asset: TrackedAsset

  private var sourceLabel: String {
    asset.exchangeProvider?.label ?? asset.chainName
  }

  /// Exchange rows carry the connection label; wallet rows fall back to the
  /// address when no label matched.
  private var attribution: String? {
    asset.source == .exchange ? asset.walletLabel : (asset.walletLabel ?? asset.address)
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Text(String(asset.symbol.prefix(1)).uppercased())
        .font(.caption.weight(.bold))
        .foregroundStyle(AtlasTheme.accent)
        .frame(width: 36, height: 36)
        .background(AtlasTheme.accent.opacity(0.10))
        .clipShape(Circle())
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(asset.symbol)
            .font(.body.weight(.semibold))
            .lineLimit(1)
          if asset.name != asset.symbol {
            Text(asset.name)
              .font(.caption)
              .foregroundStyle(AtlasTheme.ink3)
              .lineLimit(1)
          }
        }
        HStack(spacing: 6) {
          Text(asset.displayedAmount(locale: AtlasFormatting.locale))
            .font(.caption.monospaced())
            .foregroundStyle(AtlasTheme.ink2)
            .lineLimit(1)
          if let attribution {
            Text("· \(attribution)")
              .font(.caption)
              .foregroundStyle(AtlasTheme.ink3)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
      }

      Spacer(minLength: 10)

      VStack(alignment: .trailing, spacing: 6) {
        if asset.pricingStatus == .priced {
          Text(money(asset.valueUsd))
            .font(.callout.monospacedDigit().weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        } else {
          Badge(
            asset.pricingStatus == .unpriced ? "Unpriced" : "Value unavailable",
            color: AtlasTheme.warning
          )
        }
        Badge(sourceLabel)
      }
      .fixedSize(horizontal: true, vertical: false)
      .layoutPriority(1)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(minHeight: 66)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(AtlasAccessibility.assetRowIdentity(asset))
    .accessibilityIdentifier("portfolio-asset-row-\(asset.id)")
  }
}
