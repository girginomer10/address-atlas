import AddressAtlasCore
import SwiftUI
import UIKit

/// Every holding from the latest snapshot, list first. Search lives in the
/// navigation bar; the price filter, the shared small-balance preference
/// (also in Settings), and grouping sit in one toolbar filter menu. Rows open
/// a detail sheet with the full, untruncated holding.
struct AssetsScreen: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: IOSNavigationModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var query = ""
  @State private var hideUnpriced = false
  @AppStorage("assets.groupByAsset.v1") private var groupByAsset = false
  @State private var isUpdatingDustPreference = false
  @State private var selectedAsset: TrackedAsset?
  @State private var expandedGroups: Set<String> = []
  @State private var editingThreshold = false
  @State private var thresholdDraft = ""
  /// Set when Portfolio opened Assets for one symbol: while the search text
  /// still equals it, only holdings with exactly that symbol match (so "ETH"
  /// does not also list WETH or every Ethereum token).
  @State private var exactSymbol: String?

  private static let thresholdFormat = FloatingPointFormatStyle<Double>.number
    .locale(AtlasFormatting.locale)
    .precision(.fractionLength(0...2))

  // MARK: Data

  /// Latest-snapshot holdings whose wallet, exchange, or manual holding is
  /// still saved; a removed source stops counting before the next scan.
  private var savedSourceKeys: Set<String> { state.savedScanSourceKeys }

  /// Wallet labels edited after the scan are applied for display; the stored
  /// snapshot is never rewritten.
  private var labeledHoldings: [TrackedAsset] {
    let keys = savedSourceKeys
    return AppState.applyingWalletLabels(
      to: state.visibleLatestHoldings.filter {
        AppState.holdingSourceIsSaved($0, savedKeys: keys)
      },
      wallets: state.document.wallets)
  }

  /// Holdings left after the dust preference and the price filter, before
  /// search. Used for the "N hidden" count.
  private var filteredHoldings: [TrackedAsset] {
    let holdings = labeledHoldings
    guard hideUnpriced else { return holdings }
    return holdings.filter(AppState.isPricedForDisplay)
  }

  private var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var displayedAssets: [TrackedAsset] {
    let holdings = filteredHoldings
    let query = trimmedQuery
    guard !query.isEmpty else { return holdings }
    if let exactSymbol, exactSymbol.caseInsensitiveCompare(query) == .orderedSame {
      return holdings.filter { $0.symbol.caseInsensitiveCompare(exactSymbol) == .orderedSame }
    }
    return holdings.filter { Self.matches($0, query: query) }
  }

  private var snapshotHoldingCount: Int {
    let keys = savedSourceKeys
    return (state.latestScan?.holdings ?? []).filter {
      AppState.holdingSourceIsSaved($0, savedKeys: keys)
    }.count
  }

  /// The header total no longer equals the portfolio total.
  private var isFiltered: Bool { hiddenByFilters > 0 || !trimmedQuery.isEmpty }

  private var hasSnapshotHoldings: Bool { snapshotHoldingCount > 0 }

  private var hiddenByFilters: Int { max(0, snapshotHoldingCount - filteredHoldings.count) }

  private var hideDust: Bool { state.document.preferences.hideDust }

  private var activeFilterCount: Int { (hideUnpriced ? 1 : 0) + (hideDust ? 1 : 0) }

  private var hasPersistentStatus: Bool {
    state.operatorMessage != nil || state.persistentOperationGuidance != nil
      || !state.isAppVersionSupported
  }

  // MARK: Body

  var body: some View {
    Group {
      if hasSnapshotHoldings {
        list
          .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Asset, network, or wallet"
          )
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
      } else {
        list
      }
    }
    .listStyle(.insetGrouped)
    .listSectionSpacing(.compact)
    .scrollContentBackground(.hidden)
    .scrollDismissesKeyboard(.immediately)
    .background(AtlasTheme.canvas)
    .navigationTitle("Assets")
    .navigationBarTitleDisplayMode(.large)
    .toolbarBackground(AtlasTheme.canvas, for: .navigationBar)
    .toolbar {
      if hasSnapshotHoldings {
        ToolbarItem(placement: .topBarTrailing) {
          filterMenu
        }
      }
    }
    .sheet(item: $selectedAsset) { asset in
      AssetDetailSheet(asset: asset)
    }
    .onAppear { applyPendingQuery() }
    .onChange(of: navigation.assetsQuery) { _, _ in applyPendingQuery() }
    .onChange(of: query) { _, newValue in
      // Typing replaces the symbol filter with a normal search.
      if let exactSymbol,
        exactSymbol.caseInsensitiveCompare(
          newValue.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame
      {
        self.exactSymbol = nil
      }
    }
    .alert("Small-balance threshold", isPresented: $editingThreshold) {
      TextField("USD", text: $thresholdDraft)
        .keyboardType(.decimalPad)
      Button("Save") { commitThreshold() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Priced holdings below this USD value are hidden. Portfolio totals still include them.")
    }
  }

  private var list: some View {
    List {
      if hasPersistentStatus {
        Section {
          IOSPersistentStatus()
            .listRowBackground(AtlasTheme.surface)
        }
      }

      if !hasSnapshotHoldings {
        Section {
          emptySnapshotState
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 24, leading: 0, bottom: 0, trailing: 0))
        }
      } else {
        let assets = displayedAssets
        if !assets.isEmpty || hiddenByFilters > 0 {
          Section {
            summary(for: assets)
              .listRowBackground(Color.clear)
              .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))
          }
        }

        if assets.isEmpty {
          Section {
            noResultsState
              .listRowBackground(Color.clear)
              .listRowInsets(EdgeInsets())
          }
        } else if groupByAsset {
          Section {
            ForEach(AssetGroup.grouping(assets)) { group in
              groupRow(group)
            }
          }
          .listRowBackground(AtlasTheme.surface)
          .listRowSeparatorTint(AtlasTheme.ruleSoft)
        } else {
          Section {
            ForEach(assets) { asset in
              assetButton(asset)
            }
          }
          .listRowBackground(AtlasTheme.surface)
          .listRowSeparatorTint(AtlasTheme.ruleSoft)
        }
      }
    }
  }

  // MARK: Summary

  private func summary(for assets: [TrackedAsset]) -> some View {
    let total = AppState.validatedPortfolioTotal(assets) ?? 0
    let unpriced = assets.filter { $0.pricingStatus != .priced }.count
    let countText =
      trimmedQuery.isEmpty
      ? "\(assets.count) asset\(assets.count == 1 ? "" : "s")"
      : "\(assets.count) result\(assets.count == 1 ? "" : "s")"
    let detail = unpriced > 0 ? "\(countText) · \(unpriced) unpriced" : countText
    let filtered = isFiltered
    return VStack(alignment: .leading, spacing: 4) {
      if !assets.isEmpty {
        let totalLayout =
          dynamicTypeSize.isAccessibilitySize
          ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
          : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        totalLayout {
          Text(money(total))
            .font(.title2.weight(.semibold).monospacedDigit())
            .foregroundStyle(AtlasTheme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
          // The total follows search and filters, so it is labeled whenever
          // it is not the whole portfolio.
          if filtered {
            Badge("Filtered", color: AtlasTheme.accent)
              .fixedSize()
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(filtered ? "Filtered total \(money(total))" : "Total \(money(total))")
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(AtlasTheme.ink3)
          .fixedSize(horizontal: false, vertical: true)
      }
      if state.latestScanSourceDrift.hasChanges {
        Button {
          state.clearTransientMessagesForNavigation()
          navigation.open(.portfolio)
        } label: {
          HStack(spacing: 4) {
            Text("Sources changed since the last scan ·")
              .foregroundStyle(AtlasTheme.ink3)
            Text("Scan")
              .fontWeight(.semibold)
              .foregroundStyle(AtlasTheme.accent)
          }
          .font(.subheadline)
          .frame(minHeight: 32, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sources changed since the last scan")
        .accessibilityHint("Opens Portfolio to scan again.")
        .accessibilityAddTraits(.isButton)
      }
      if hiddenByFilters > 0 {
        Button(action: showAll) {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
              hiddenCountText
              showAllText
            }
            VStack(alignment: .leading, spacing: 2) {
              hiddenCountText
              showAllText
            }
          }
          .font(.subheadline)
          .frame(minHeight: 32, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canShowAll)
        .accessibilityLabel("\(hiddenByFilters) hidden by filters")
        .accessibilityHint("Turns off the filters and shows every holding.")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
  }

  private var hiddenCountText: some View {
    Text("\(hiddenByFilters) hidden ·")
      .foregroundStyle(AtlasTheme.ink3)
  }

  private var showAllText: some View {
    Text("Show all")
      .fontWeight(.semibold)
      .foregroundStyle(canShowAll ? AtlasTheme.accent : AtlasTheme.ink3)
  }

  /// Dust hiding is a vault preference; it can only be turned off while the
  /// vault accepts edits.
  private var canShowAll: Bool {
    hideUnpriced || (hideDust && !state.vaultEditsDisabled && !isUpdatingDustPreference)
  }

  private func showAll() {
    withAnimation(AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion)) {
      hideUnpriced = false
    }
    if hideDust { setHideDust(false) }
  }

  // MARK: Rows

  private func assetButton(_ asset: TrackedAsset) -> some View {
    Button {
      selectedAsset = asset
    } label: {
      AssetRowView(asset: asset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AtlasIOSAccessibility.holding(asset))
    }
    .buttonStyle(.plain)
    .accessibilityHint("Shows the full holding.")
    .accessibilityIdentifier("portfolio-asset-row-\(asset.id)")
  }

  @ViewBuilder
  private func groupRow(_ group: AssetGroup) -> some View {
    if group.members.count == 1, let only = group.members.first {
      assetButton(only)
    } else {
      DisclosureGroup(isExpanded: expansionBinding(for: group.id)) {
        ForEach(group.members) { asset in
          assetButton(asset)
        }
      } label: {
        AssetGroupRowView(group: group)
      }
      .tint(AtlasTheme.ink3)
    }
  }

  private func expansionBinding(for id: String) -> Binding<Bool> {
    Binding(
      get: { expandedGroups.contains(id) },
      set: { expanded in
        withAnimation(AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion)) {
          if expanded { expandedGroups.insert(id) } else { expandedGroups.remove(id) }
        }
      })
  }

  // MARK: Empty states

  @ViewBuilder
  private var emptySnapshotState: some View {
    if state.scanning {
      AssetsEmptyView(
        systemImage: "arrow.triangle.2.circlepath",
        title: "Scanning…",
        copy: "Your holdings appear here when the scan finishes.",
        showsProgress: true)
    } else if state.hasScanSources {
      AssetsEmptyView(
        systemImage: "list.bullet.rectangle",
        title: "No assets yet",
        copy: "Run a scan to see every holding here.",
        actionTitle: "Go to Portfolio",
        action: { navigation.open(.portfolio) })
    } else {
      AssetsEmptyView(
        systemImage: "wallet.pass",
        title: "No assets yet",
        copy: "Add a wallet, then scan to see your holdings.",
        actionTitle: "Add a wallet",
        action: { navigation.open(.wallets, then: .addWallet) })
    }
  }

  @ViewBuilder
  private var noResultsState: some View {
    if !trimmedQuery.isEmpty {
      ContentUnavailableView.search(text: trimmedQuery)
    } else {
      AssetsEmptyView(
        systemImage: "line.3.horizontal.decrease.circle",
        title: "Everything is filtered out",
        copy: "Every holding in the latest snapshot is hidden by your filters.",
        actionTitle: canShowAll ? "Show all" : nil,
        action: showAll)
    }
  }

  // MARK: Filter menu

  private var filterMenu: some View {
    Menu {
      Section {
        Toggle(isOn: $hideUnpriced.animation(
          AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion))
        ) {
          Text("Hide assets without a price")
        }
        Toggle(isOn: hideDustBinding) {
          Text("Hide small balances")
          Text("Below \(money(state.document.preferences.dustThreshold))")
        }
        .disabled(state.vaultEditsDisabled || isUpdatingDustPreference)
        Button {
          thresholdDraft = state.document.preferences.dustThreshold.formatted(Self.thresholdFormat)
          editingThreshold = true
        } label: {
          Text("Small-balance threshold…")
        }
        .disabled(state.vaultEditsDisabled || isUpdatingDustPreference)
      }
      Section {
        Toggle(isOn: $groupByAsset.animation(
          AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion))
        ) {
          Text("Group by asset")
        }
      }
    } label: {
      Image(
        systemName: activeFilterCount > 0
          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
      )
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(activeFilterCount > 0 ? AtlasTheme.accent : AtlasTheme.ink2)
      .frame(minWidth: 44, minHeight: 44)
      .contentShape(Rectangle())
    }
    .accessibilityLabel("Filters")
    .accessibilityValue(
      activeFilterCount == 0
        ? "None active" : "\(activeFilterCount) active, \(hiddenByFilters) hidden")
    .accessibilityIdentifier("assets-filter-menu")
  }

  private var hideDustBinding: Binding<Bool> {
    Binding(
      get: { state.document.preferences.hideDust },
      set: { value in setHideDust(value) })
  }

  private func setHideDust(_ value: Bool) {
    guard value != state.document.preferences.hideDust else { return }
    isUpdatingDustPreference = true
    Task {
      await state.setHideDust(value)
      isUpdatingDustPreference = false
    }
  }

  /// Same parsing and rejection rules as the Settings threshold field;
  /// `setDustThreshold` still rejects non-finite or negative values itself.
  private func commitThreshold() {
    let current = state.document.preferences.dustThreshold
    let trimmed = thresholdDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard let value = try? Double(trimmed, format: Self.thresholdFormat),
      value.isFinite, value >= 0
    else {
      state.notice = ""
      state.error = "Dust threshold must be a finite, non-negative USD value."
      return
    }
    guard value != current else { return }
    isUpdatingDustPreference = true
    Task {
      await state.setDustThreshold(value)
      isUpdatingDustPreference = false
    }
  }

  /// Portfolio's allocation rows open Assets for one symbol ("Other" and
  /// "All assets" open it unfiltered).
  private func applyPendingQuery() {
    guard let request = navigation.consumeAssetsQuery() else { return }
    selectedAsset = nil
    if let symbol = request.symbol {
      exactSymbol = symbol
      query = symbol
    } else {
      exactSymbol = nil
      query = ""
    }
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

// MARK: - Presentation helpers

extension TrackedAsset {
  /// Network for chain holdings; the exchange (or manual venue) otherwise.
  fileprivate var atlasNetworkLabel: String {
    exchangeProvider?.label ?? chainName
  }

  /// The human name only when it adds information: native coins carry the
  /// network name as their name (`ETH` on Base is named "Base"), which the
  /// secondary line already shows.
  fileprivate var atlasDisplayName: String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      trimmed.caseInsensitiveCompare(symbol) != .orderedSame,
      trimmed.caseInsensitiveCompare(chainName) != .orderedSame,
      trimmed.caseInsensitiveCompare(atlasNetworkLabel) != .orderedSame
    else { return nil }
    return trimmed
  }

  fileprivate var atlasIsManual: Bool { id.hasPrefix("manual-") }

  /// Wallet label (or short address) for chain holdings; the connection or
  /// manual-holding label for exchange rows.
  fileprivate var atlasSourceLabel: String? {
    if family == .exchange {
      let label = (walletLabel ?? address).trimmingCharacters(in: .whitespacesAndNewlines)
      return label.isEmpty || label == atlasNetworkLabel ? nil : label
    }
    if let walletLabel, !walletLabel.isEmpty { return walletLabel }
    return AssetsFormatting.shortAddress(address)
  }

  fileprivate var atlasSecondaryLine: String {
    [atlasNetworkLabel, atlasSourceLabel].compactMap { $0 }.joined(separator: " · ")
  }

  /// Token contract (EVM, Solana mint, Tron) or XRPL issuer, recovered from
  /// the scanner's stable holding ID; nil for native coins and exchanges.
  fileprivate var atlasContract: (title: String, value: String)? {
    switch source {
    case .erc20, .spl, .trc20:
      let prefix = "\(address)-\(chainId)-\(symbol)-"
      guard id.hasPrefix(prefix) else { return nil }
      let contract = String(id.dropFirst(prefix.count))
      guard !contract.isEmpty, !contract.contains(where: \.isWhitespace) else { return nil }
      return (source == .spl ? "Mint" : "Contract", contract)
    case .issued:
      guard let issuer = id.split(separator: "-").last, issuer.count > 20 else { return nil }
      return ("Issuer", String(issuer))
    default:
      return nil
    }
  }

}

private enum AssetsFormatting {
  static func shortAddress(_ address: String) -> String {
    guard address.count > 14 else { return address }
    return "\(address.prefix(6))…\(address.suffix(4))"
  }

  /// Unit prices below a dollar keep their significant digits.
  static func price(_ value: Double) -> String {
    guard value.isFinite else { return "–" }
    if value > 0, value < 1 {
      return value.formatted(
        .currency(code: "USD").precision(.significantDigits(2...6))
          .locale(AtlasFormatting.locale))
    }
    return money(value)
  }

  /// `percent` is in percentage points (2.5 = 2.5%).
  static func change24h(_ percent: Double) -> String {
    AtlasPercent.signedChange(percent / 100)
  }
}

// MARK: - Row

/// Monogram, symbol (plus name when it adds information), and network ·
/// source; value and amount trailing. At accessibility sizes the row stacks
/// vertically so nothing is pushed off screen.
private struct AssetRowView: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var asset: TrackedAsset

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        stacked
      } else {
        inline
      }
    }
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
    .contentShape(Rectangle())
  }

  private var inline: some View {
    HStack(spacing: 12) {
      TokenMonogram(symbol: asset.symbol, size: 40)
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(asset.symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(AtlasTheme.ink)
            .lineLimit(1)
            .layoutPriority(1)
          if let name = asset.atlasDisplayName {
            Text(name)
              .font(.subheadline)
              .foregroundStyle(AtlasTheme.ink3)
              .lineLimit(1)
          }
        }
        // Every row has the same shape: network, then the source, which
        // truncates first (the detail sheet shows it in full).
        HStack(spacing: 0) {
          Text(asset.atlasNetworkLabel)
            .layoutPriority(1)
          if let source = asset.atlasSourceLabel {
            Text(" · \(source)")
              .truncationMode(.tail)
          }
        }
        .font(.subheadline)
        .foregroundStyle(AtlasTheme.ink3)
        .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .trailing, spacing: 3) {
        AssetValueText(asset: asset)
          .fixedSize()
        Text(AtlasAmount.compact(asset))
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(AtlasTheme.ink2)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .truncationMode(.middle)
      }
      .layoutPriority(1)
    }
  }

  private var stacked: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 12) {
        TokenMonogram(symbol: asset.symbol, size: 44)
        Text(asset.symbol)
          .font(.body.weight(.semibold))
          .foregroundStyle(AtlasTheme.ink)
          .lineLimit(2)
      }
      if let name = asset.atlasDisplayName {
        Text(name)
          .font(.subheadline)
          .foregroundStyle(AtlasTheme.ink3)
      }
      // Money and amounts shrink instead of breaking mid-number.
      AssetValueText(asset: asset)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
      Text(AtlasAmount.compact(asset))
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(AtlasTheme.ink2)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
      Text(asset.atlasSecondaryLine)
        .font(.subheadline)
        .foregroundStyle(AtlasTheme.ink3)
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}

private struct AssetValueText: View {
  var asset: TrackedAsset

  var body: some View {
    switch asset.pricingStatus {
    case .priced:
      Text(money(asset.valueUsd))
        .font(.body.weight(.semibold).monospacedDigit())
        .foregroundStyle(AtlasTheme.ink)
    case .unpriced:
      Text("Unpriced")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(AtlasTheme.warning)
    case .valuationUnavailable:
      Text("Value unavailable")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(AtlasTheme.warning)
    }
  }
}

// MARK: - Grouping

/// Holdings that share a symbol across networks and sources. The group shows
/// only the sum of priced values; amounts are not added up because the same
/// symbol can name different tokens on different networks.
private struct AssetGroup: Identifiable {
  var id: String
  var symbol: String
  var members: [TrackedAsset]

  var pricedTotal: Double {
    FiniteValueMath.sumNonnegative(
      members.filter { $0.pricingStatus == .priced }.map(\.valueUsd)) ?? 0
  }

  var unpricedCount: Int { members.filter { $0.pricingStatus != .priced }.count }

  var networks: [String] {
    var seen: [String] = []
    for member in members where !seen.contains(member.atlasNetworkLabel) {
      seen.append(member.atlasNetworkLabel)
    }
    return seen
  }

  /// Keeps the input's display order inside each group and orders groups by
  /// their priced total.
  static func grouping(_ assets: [TrackedAsset]) -> [AssetGroup] {
    var order: [String] = []
    var bySymbol: [String: [TrackedAsset]] = [:]
    for asset in assets {
      let key = asset.symbol.uppercased()
      if bySymbol[key] == nil { order.append(key) }
      bySymbol[key, default: []].append(asset)
    }
    let groups = order.compactMap { key -> AssetGroup? in
      guard let members = bySymbol[key], let first = members.first else { return nil }
      return AssetGroup(id: key, symbol: first.symbol, members: members)
    }
    return groups.enumerated().sorted { lhs, rhs in
      let lhsPriced = lhs.element.unpricedCount < lhs.element.members.count
      let rhsPriced = rhs.element.unpricedCount < rhs.element.members.count
      if lhsPriced != rhsPriced { return lhsPriced }
      if lhs.element.pricedTotal != rhs.element.pricedTotal {
        return lhs.element.pricedTotal > rhs.element.pricedTotal
      }
      return lhs.offset < rhs.offset
    }.map(\.element)
  }
}

private struct AssetGroupRowView: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var group: AssetGroup

  /// One rule for every group: the network (or network count), then the
  /// holding count only when it differs from the network count.
  private var subtitle: String {
    let networks = group.networks
    let count = group.members.count
    if networks.count == 1, let network = networks.first {
      return "\(network) · \(count) holdings"
    }
    if networks.count == count { return "\(count) networks" }
    return "\(networks.count) networks · \(count) holdings"
  }

  private var valueText: some View {
    let allUnpriced = group.unpricedCount == group.members.count
    return VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 3) {
      if allUnpriced {
        Text("Unpriced")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(AtlasTheme.warning)
      } else {
        Text(money(group.pricedTotal))
          .font(.body.weight(.semibold).monospacedDigit())
          .foregroundStyle(AtlasTheme.ink)
        if group.unpricedCount > 0 {
          Text("+ \(group.unpricedCount) unpriced")
            .font(.subheadline)
            .foregroundStyle(AtlasTheme.warning)
        }
      }
    }
  }

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 12) {
            TokenMonogram(symbol: group.symbol, size: 44)
            Text(group.symbol)
              .font(.body.weight(.semibold))
              .foregroundStyle(AtlasTheme.ink)
          }
          valueText
            .lineLimit(1)
            .minimumScaleFactor(0.5)
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(AtlasTheme.ink3)
        }
        .fixedSize(horizontal: false, vertical: true)
      } else {
        HStack(spacing: 12) {
          TokenMonogram(symbol: group.symbol, size: 40)
          VStack(alignment: .leading, spacing: 3) {
            Text(group.symbol)
              .font(.body.weight(.semibold))
              .foregroundStyle(AtlasTheme.ink)
              .lineLimit(1)
            Text(subtitle)
              .font(.subheadline)
              .foregroundStyle(AtlasTheme.ink3)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          valueText
            .fixedSize()
            .layoutPriority(1)
        }
      }
    }
    .padding(.vertical, 6)
    .frame(minHeight: 48)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityText)
  }

  private var accessibilityText: String {
    var parts = ["\(group.symbol), \(subtitle)"]
    if group.unpricedCount < group.members.count {
      parts.append("value \(money(group.pricedTotal))")
    }
    if group.unpricedCount > 0 { parts.append("\(group.unpricedCount) unpriced") }
    return parts.joined(separator: ", ")
  }
}

// MARK: - Empty state

private struct AssetsEmptyView: View {
  var systemImage: String
  var title: String
  var copy: String
  var showsProgress = false
  var actionTitle: String?
  var action: () -> Void = {}

  var body: some View {
    VStack(spacing: 14) {
      ZStack {
        if showsProgress {
          ProgressView()
        } else {
          Image(systemName: systemImage)
            .font(.title2.weight(.semibold))
            .foregroundStyle(AtlasTheme.accent)
        }
      }
      .frame(width: 60, height: 60)
      .background(AtlasTheme.accent.opacity(0.10))
      .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
      .accessibilityHidden(true)
      VStack(spacing: 6) {
        Text(title)
          .font(.title3.weight(.semibold))
          .foregroundStyle(AtlasTheme.ink)
        Text(copy)
          .font(.callout)
          .foregroundStyle(AtlasTheme.ink3)
      }
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      if let actionTitle {
        Button(actionTitle, action: action)
          .buttonStyle(AtlasPrimaryButtonStyle())
          .padding(.top, 4)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 32)
    .padding(.horizontal, 20)
  }
}

// MARK: - Detail sheet

/// Everything stored for one holding, untruncated: value, exact amount,
/// price, network, source (wallet with its full address, or the exchange),
/// contract, and valuation status.
private struct AssetDetailSheet: View {
  @Environment(\.dismiss) private var dismiss
  var asset: TrackedAsset

  var body: some View {
    NavigationStack {
      List {
        Section {
          header
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))
        }

        Section("Holding") {
          AssetDetailRow(title: "Amount", value: AtlasAmount.full(asset), monospacedDigits: true)
          AssetDetailRow(title: "Price", value: priceText)
          if let change = asset.change24h, change.isFinite, asset.pricingStatus != .unpriced {
            // Below 0.005 points the value reads "0%" and stays neutral.
            AssetDetailRow(
              title: "24h change", value: AssetsFormatting.change24h(change),
              valueColor: change >= 0.005
                ? AtlasTheme.gain : (change <= -0.005 ? AtlasTheme.loss : AtlasTheme.ink))
          }
          AssetDetailRow(title: "Valuation", value: valuationText, valueColor: valuationColor)
        }
        .listRowBackground(AtlasTheme.surface)

        Section("Source") {
          AssetDetailRow(title: asset.family == .exchange ? "Venue" : "Network", value: asset.atlasNetworkLabel)
          AssetDetailRow(title: "Type", value: asset.atlasIOSKindLabel)
          sourceRows
          if let contract = asset.atlasContract {
            AssetDetailRow(title: contract.title, value: contract.value, copyable: true, stacked: true)
          }
        }
        .listRowBackground(AtlasTheme.surface)
      }
      .listStyle(.insetGrouped)
      .listSectionSpacing(.compact)
      .scrollContentBackground(.hidden)
      .background(AtlasTheme.canvas)
      .navigationTitle(asset.symbol)
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(AtlasTheme.canvas, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .atlasDetailSheetPresentation()
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        TokenMonogram(symbol: asset.symbol, size: 52)
        VStack(alignment: .leading, spacing: 2) {
          Text(asset.symbol)
            .font(.title3.weight(.semibold))
            .foregroundStyle(AtlasTheme.ink)
          Text(asset.atlasDisplayName ?? asset.atlasNetworkLabel)
            .font(.subheadline)
            .foregroundStyle(AtlasTheme.ink3)
        }
        .fixedSize(horizontal: false, vertical: true)
      }
      Group {
        if asset.pricingStatus == .priced {
          Text(money(asset.valueUsd))
            .font(.largeTitle.weight(.semibold).monospacedDigit())
            .foregroundStyle(AtlasTheme.ink)
        } else {
          Text(asset.pricingStatus == .unpriced ? "Unpriced" : "Value unavailable")
            .font(.title.weight(.semibold))
            .foregroundStyle(AtlasTheme.warning)
        }
      }
      .lineLimit(2)
      .minimumScaleFactor(0.5)
      .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var sourceRows: some View {
    if let provider = asset.exchangeProvider {
      AssetDetailRow(title: "Exchange", value: provider.label)
      if let connection = asset.walletLabel, !connection.isEmpty {
        AssetDetailRow(title: "Connection", value: connection)
      }
    } else if asset.atlasIsManual {
      if !asset.address.isEmpty,
        asset.address.caseInsensitiveCompare(asset.atlasNetworkLabel) != .orderedSame
      {
        AssetDetailRow(title: "Label", value: asset.address)
      }
    } else {
      if let label = asset.walletLabel, !label.isEmpty {
        AssetDetailRow(title: "Wallet", value: label)
      }
      AssetDetailRow(title: "Address", value: asset.address, copyable: true, stacked: true)
    }
  }

  private var priceText: String {
    asset.pricingStatus == .unpriced ? "No price found" : AssetsFormatting.price(asset.priceUsd)
  }

  private var valuationText: String {
    switch asset.pricingStatus {
    case .priced: "Included in totals"
    case .unpriced: "Unpriced · not in totals"
    case .valuationUnavailable: "Value too large to compute · not in totals"
    }
  }

  private var valuationColor: Color {
    asset.pricingStatus == .priced ? AtlasTheme.ink : AtlasTheme.warning
  }
}

/// Label and value; values that are long identifiers sit under the label and
/// can be copied. Everything is selectable and wraps instead of truncating.
private struct AssetDetailRow: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var title: String
  var value: String
  var valueColor: Color = AtlasTheme.ink
  var monospacedDigits = false
  var copyable = false
  var stacked = false
  @State private var copied = false

  var body: some View {
    Group {
      if stacked || dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 6) {
          titleText
          HStack(alignment: .top, spacing: 8) {
            valueText
              .frame(maxWidth: .infinity, alignment: .leading)
            if copyable { copyButton }
          }
        }
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .firstTextBaseline, spacing: 16) {
            titleText
            Spacer(minLength: 12)
            valueText
              .multilineTextAlignment(.trailing)
              .fixedSize()
          }
          VStack(alignment: .leading, spacing: 4) {
            titleText
            valueText
          }
        }
      }
    }
    .padding(.vertical, 4)
    .frame(minHeight: 36)
    .accessibilityElement(children: copyable ? .contain : .combine)
  }

  private var titleText: some View {
    Text(title)
      .font(.subheadline)
      .foregroundStyle(AtlasTheme.ink3)
  }

  private var valueText: some View {
    Text(value)
      .font(monospacedDigits ? .body.monospacedDigit() : .body)
      .foregroundStyle(valueColor)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var copyButton: some View {
    Button {
      UIPasteboard.general.string = value
      copied = true
      Task {
        try? await Task.sleep(for: .seconds(1.5))
        copied = false
      }
    } label: {
      Image(systemName: copied ? "checkmark" : "doc.on.doc")
        .font(.callout.weight(.semibold))
        .foregroundStyle(copied ? AtlasTheme.gain : AtlasTheme.accent)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(copied ? "Copied" : "Copy \(title.lowercased())")
  }
}
