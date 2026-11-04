import AddressAtlasCore
import SwiftUI

/// Every coin from the latest scan, largest first. A coin is all of its
/// holdings across networks, wallets and exchanges; a row opens the coin.
/// Search sits in the navigation bar; the small-balance preference (also in
/// Settings), the price filter and the slice a chart sent here sit in one
/// filter menu and one banner.
struct AssetsScreen: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: IOSNavigationModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var query = ""
  @AppStorage("assets.hideUnpriced.v1") private var hideUnpriced = false
  @State private var isUpdatingDustPreference = false
  @State private var editingThreshold = false
  @State private var thresholdDraft = ""

  private static let thresholdFormat = FloatingPointFormatStyle<Double>.number
    .locale(AtlasFormatting.locale)
    .precision(.fractionLength(0...2))

  // MARK: Data

  /// Latest-scan holdings whose wallet, exchange or manual holding is still
  /// saved, with the dust preference applied and edited wallet names shown.
  private var baseHoldings: [TrackedAsset] {
    AppState.applyingWalletLabels(to: state.chartHoldings, wallets: state.document.wallets)
  }

  /// Ids of the holdings inside the slice a chart sent here, if any.
  private func sliceIDs(for filter: IOSAssetsFilter) -> Set<String> {
    let slices = PortfolioAnalytics.breakdown(baseHoldings, by: filter.grouping).slices
    return Set(slices.first(where: { $0.key == filter.key })?.holdingIDs ?? [])
  }

  private var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Holdings left after the slice, the price filter and the search.
  private var shownHoldings: [TrackedAsset] {
    var holdings = baseHoldings
    if let filter = navigation.assetsFilter {
      let ids = sliceIDs(for: filter)
      holdings = holdings.filter { ids.contains($0.id) }
    }
    if hideUnpriced { holdings = holdings.filter(AppState.isPricedForDisplay) }
    let query = trimmedQuery
    if !query.isEmpty { holdings = holdings.filter { Self.matches($0, query: query) } }
    return holdings
  }

  /// Everything in the latest scan that is still a saved source, before the
  /// dust preference: the base for "N hidden".
  private var scanHoldingCount: Int {
    let keys = state.savedScanSourceKeys
    return (state.latestScan?.holdings ?? []).filter {
      AppState.holdingSourceIsSaved($0, savedKeys: keys)
    }.count
  }

  private var hasScan: Bool { scanHoldingCount > 0 }

  private var hideDust: Bool { state.document.preferences.hideDust }

  /// Holdings hidden by the dust preference or the price filter (not by
  /// search or a slice, which the banner and the list make obvious).
  private var hiddenByPreferences: Int {
    let afterPrice = hideUnpriced ? baseHoldings.filter(AppState.isPricedForDisplay) : baseHoldings
    return max(0, scanHoldingCount - afterPrice.count)
  }

  private var activeFilterCount: Int { (hideUnpriced ? 1 : 0) + (hideDust ? 1 : 0) }

  // MARK: Body

  var body: some View {
    let holdings = shownHoldings
    let summaries = PortfolioAnalytics.coinSummaries(holdings)
    IOSPage(title: "Assets") {
      if !hasScan {
        emptyScanState
      } else {
        if let filter = navigation.assetsFilter {
          sliceBanner(filter)
        }
        if state.latestScanSourceDrift.hasChanges {
          sourcesChangedNotice
        }
        if summaries.isEmpty {
          noResultsState
        } else {
          summary(summaries: summaries)
          IOSCoinList(
            summaries: summaries,
            total: summaries.reduce(0) { $0 + $1.valueUsd })
        }
        if hiddenByPreferences > 0 { hiddenRow }
      }
    }
    .modifier(AssetsSearch(isActive: hasScan, query: $query))
    .toolbar {
      if hasScan {
        ToolbarItem(placement: .topBarTrailing) { filterMenu }
      }
    }
    .alert("Small-balance threshold", isPresented: $editingThreshold) {
      TextField("USD", text: $thresholdDraft)
        .keyboardType(.decimalPad)
      Button("Save") { commitThreshold() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Balances worth less than this are hidden. The portfolio total still counts them.")
    }
  }

  // MARK: Summary and notices

  private func summary(summaries: [CoinSummary]) -> some View {
    let total = summaries.reduce(0) { $0 + $1.valueUsd }
    let filtered = !trimmedQuery.isEmpty || navigation.assetsFilter != nil || hideUnpriced
    let unpriced = summaries.filter { $0.pricedAmount == 0 && $0.valueUsd == 0 }.count
    var detail = IOSNumber.count(summaries.count, "coin")
    if unpriced > 0 { detail += " · \(unpriced) without a price" }
    return VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(money(total))
          .font(AtlasTheme.font(.number, .title2, weight: .bold))
          .foregroundStyle(AtlasTheme.ink)
          .lineLimit(1)
          .minimumScaleFactor(0.5)
        if filtered {
          Badge("Filtered", color: AtlasTheme.accent).fixedSize()
        }
      }
      Text(detail)
        .font(AtlasTheme.font(.body, .subheadline))
        .foregroundStyle(AtlasTheme.ink3)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(filtered ? "Filtered total" : "Total") \(money(total)), \(detail)")
  }

  private func sliceBanner(_ filter: IOSAssetsFilter) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "line.3.horizontal.decrease.circle")
        .foregroundStyle(AtlasTheme.accent)
        .accessibilityHidden(true)
      Text("\(filter.grouping.displayName): \(filter.label)")
        .font(AtlasTheme.font(.body, .callout, weight: .semibold))
        .foregroundStyle(AtlasTheme.ink)
        .lineLimit(2)
      Spacer(minLength: 8)
      Button("Clear") {
        withAnimation(AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion)) {
          navigation.assetsFilter = nil
        }
      }
      .font(AtlasTheme.font(.body, .callout, weight: .semibold))
      .foregroundStyle(AtlasTheme.accent)
      .frame(minHeight: 44)
      .accessibilityHint("Shows every coin again.")
      .accessibilityIdentifier("assets-slice-clear")
    }
    .padding(.horizontal, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .atlasChrome(
      fill: AtlasTheme.accentSoft,
      border: AtlasTheme.shape.hasBoldBorders ? AtlasTheme.outline : AtlasTheme.accent.opacity(0.3),
      level: .control,
      radius: AtlasRadius.control,
      borderWidth: AtlasTheme.shape.hasBoldBorders ? AtlasTheme.shape.controlBorderWidth : 1,
      showsShadow: false
    )
    .accessibilityElement(children: .contain)
  }

  private var sourcesChangedNotice: some View {
    HStack(spacing: 8) {
      IOSNotice(
        systemImage: "arrow.triangle.2.circlepath",
        text: "Sources changed since the last scan.",
        tone: .info)
      Button("Scan") {
        state.clearTransientMessagesForNavigation()
        navigation.open(.portfolio)
      }
      .buttonStyle(AtlasSecondaryButtonStyle())
      .fixedSize()
      .accessibilityHint("Opens Portfolio, where you can scan again.")
    }
  }

  private var hiddenRow: some View {
    Button(action: showAll) {
      HStack(spacing: 4) {
        Text("\(hiddenByPreferences) hidden ·")
          .foregroundStyle(AtlasTheme.ink3)
        Text("Show all")
          .fontWeight(.semibold)
          .foregroundStyle(canShowAll ? AtlasTheme.accent : AtlasTheme.ink3)
      }
      .font(AtlasTheme.font(.body, .subheadline))
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!canShowAll)
    .accessibilityLabel("\(hiddenByPreferences) hidden by filters")
    .accessibilityHint("Turns off the filters and shows every coin.")
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

  // MARK: Empty states

  @ViewBuilder
  private var emptyScanState: some View {
    if state.scanning {
      IOSEmptyState(
        systemImage: "arrow.triangle.2.circlepath",
        title: "Scanning",
        copy: "Your holdings appear here when the scan finishes.",
        showsProgress: true)
    } else if state.hasScanSources {
      IOSEmptyState(
        systemImage: "list.bullet.rectangle",
        title: "No assets yet",
        copy: "Scan to see every coin you hold.",
        actionTitle: "Go to Portfolio",
        action: { navigation.open(.portfolio) })
    } else {
      IOSEmptyState(
        systemImage: "wallet.pass",
        title: "No assets yet",
        copy: "Add a wallet address or an exchange to see what you hold.",
        actionTitle: "Add wallet",
        action: { navigation.open(.sources, then: .addWallet) })
    }
  }

  @ViewBuilder
  private var noResultsState: some View {
    if !trimmedQuery.isEmpty {
      ContentUnavailableView.search(text: trimmedQuery)
    } else if navigation.assetsFilter != nil {
      IOSEmptyState(
        systemImage: "line.3.horizontal.decrease.circle",
        title: "Nothing here",
        copy: "No coin in this slice has a price. Clear the filter to see every coin.",
        actionTitle: "Clear filter",
        action: { navigation.assetsFilter = nil })
    } else {
      IOSEmptyState(
        systemImage: "line.3.horizontal.decrease.circle",
        title: "Everything is hidden",
        copy: "Your filters hide every coin.",
        actionTitle: canShowAll ? "Show all" : nil,
        action: showAll)
    }
  }

  // MARK: Filter menu

  private var filterMenu: some View {
    Menu {
      Section {
        Toggle(
          isOn: $hideUnpriced.animation(
            AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion))
        ) {
          Text("Hide coins without a price")
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
          Text("Set threshold")
        }
        .disabled(state.vaultEditsDisabled || isUpdatingDustPreference)
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
        ? "None active" : "\(activeFilterCount) active, \(hiddenByPreferences) hidden")
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
      state.error = "Enter an amount of 0 or more."
      return
    }
    guard value != current else { return }
    isUpdatingDustPreference = true
    Task {
      await state.setDustThreshold(value)
      isUpdatingDustPreference = false
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

/// Search appears only once there is something to search.
private struct AssetsSearch: ViewModifier {
  var isActive: Bool
  @Binding var query: String

  func body(content: Content) -> some View {
    if isActive {
      content
        .searchable(
          text: $query,
          placement: .navigationBarDrawer(displayMode: .always),
          prompt: "Coin, network or wallet"
        )
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
    } else {
      content
    }
  }
}
