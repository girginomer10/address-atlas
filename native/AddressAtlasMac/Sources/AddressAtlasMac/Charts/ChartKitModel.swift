import AddressAtlasCore
import Foundation

// MARK: - Chart data
//
// Turns a `PortfolioChartInput` into what the part-C1 views draw: the
// `PortfolioAnalytics.breakdown` slices, each with a colour key, the selection
// it reports, and its VoiceOver wording. All numbers come from analytics; this
// file only maps them. It has no SwiftUI types, so it can be unit-tested
// without a view hierarchy.

/// Which theme colour a slice takes. Resolved to a colour with
/// `AtlasThemeTokens.chartKitRGB(_:)`, so one slice is the same colour in every
/// view and in every theme.
enum ChartKitColorKey: Hashable, Sendable {
  case asset(String)
  case network(key: String, label: String)
  case state(HoldingState)
  case kind(HoldingKind)
  /// A position in the theme's categorical series (wallets and exchanges, which
  /// have no fixed colour).
  case index(Int)
  /// The folded "Other" slice.
  case neutral
}

struct ChartKitSlice: Identifiable, Equatable, Sendable {
  /// Unique within the whole tree (`parent>child` for a second-level slice).
  let id: String
  let key: String
  /// Short label drawn on the chart: the symbol, network, state.
  let label: String
  /// Secondary line for lists: the coin's name when it differs from its symbol.
  let subtitle: String?
  /// How VoiceOver names the slice ("Bitcoin").
  let spokenName: String
  let grouping: PortfolioGrouping
  let valueUsd: Double
  /// Of the whole priced total, 0...1.
  let share: Double
  /// Of the parent slice, 0...1 (equal to `share` at the top level).
  let shareOfParent: Double
  let holdingCount: Int
  let color: ChartKitColorKey
  /// What `onSelect` receives, or nil for the folded "Other" slice.
  let selection: PortfolioChartSelection?
  /// Second level, empty unless the data was built with a secondary grouping.
  let children: [ChartKitSlice]
  let isOther: Bool

  /// "Bitcoin, 57 percent, $27,980"
  var accessibilityLabel: String {
    ChartKitFormat.spokenSlice(name: spokenName, share: share, valueUsd: valueUsd)
  }

  /// The slice's label followed by its second level, for a block that is one
  /// element but shows a split: "Ethereum, 27 percent, $13,000. Ethereum
  /// network, 61 percent. Base, 31 percent."
  var accessibilityLabelWithChildren: String {
    let parts = children.filter { $0.valueUsd > 0 }.map {
      "\($0.spokenName), \(ChartKitFormat.spokenPercent($0.shareOfParent))"
    }
    guard !parts.isEmpty else { return accessibilityLabel }
    return accessibilityLabel + ". " + parts.joined(separator: ". ") + "."
  }

  /// The same slice with another second level (folded, or cut for lack of room).
  func replacingChildren(_ replacement: [ChartKitSlice]) -> ChartKitSlice {
    ChartKitSlice(
      id: id, key: key, label: label, subtitle: subtitle, spokenName: spokenName,
      grouping: grouping, valueUsd: valueUsd, share: share, shareOfParent: shareOfParent,
      holdingCount: holdingCount, color: color, selection: selection, children: replacement,
      isOther: isOther)
  }

  /// "Bitcoin, Staked, 12 percent, $5,800", for a second-level slice.
  func accessibilityLabel(inside parent: ChartKitSlice) -> String {
    ChartKitFormat.spokenSlice(
      name: "\(parent.spokenName), \(spokenName)", share: share, valueUsd: valueUsd)
  }
}

/// A coin that has no price, listed after the priced rows.
struct ChartKitUnpricedRow: Identifiable, Equatable, Sendable {
  /// `CoinIdentity.key`.
  let id: String
  let symbol: String
  let name: String?
  let holdingCount: Int
}

struct ChartKitData: Equatable, Sendable {
  let grouping: PortfolioGrouping
  let secondaryGrouping: PortfolioGrouping?
  let totalValueUsd: Double
  /// Largest first, including priced slices worth exactly zero (a list shows
  /// them, a graphic skips them).
  let slices: [ChartKitSlice]
  let unpricedRows: [ChartKitUnpricedRow]
  let unpricedHoldingCount: Int
  let isCoinView: Bool

  /// Slices worth something, for graphics.
  var drawable: [ChartKitSlice] { slices.filter { $0.valueUsd > 0 } }

  var isEmpty: Bool { totalValueUsd <= 0 || drawable.isEmpty }

  /// The second level a view asks for.
  enum Nesting: Equatable, Sendable {
    /// One level only.
    case none
    /// The grouping `secondaryGrouping(for:holdings:coinView:)` picks.
    case automatic
    /// A fixed grouping (ignored when it equals the first level).
    case grouping(PortfolioGrouping)
  }

  /// Builds the data for `input`, with a second level when `nesting` asks for
  /// one (the nested map and rings in rings).
  init(input: PortfolioChartInput, nesting: Nesting = .none) {
    let coinView = input.coinKey != nil
    // A single coin split by coin is one slice; show where it is instead.
    let grouping: PortfolioGrouping =
      (coinView && input.grouping == .asset) ? .network : input.grouping
    let secondary: PortfolioGrouping? =
      switch nesting {
      case .none: nil
      case .automatic:
        Self.secondaryGrouping(for: grouping, holdings: input.holdings, coinView: coinView)
      case .grouping(let fixed): fixed == grouping ? nil : fixed
      }
    let breakdown = PortfolioAnalytics.breakdown(input.holdings, by: grouping, then: secondary)

    var holdingsByID: [String: TrackedAsset] = [:]
    for holding in input.holdings { holdingsByID[holding.id] = holding }

    self.grouping = grouping
    self.secondaryGrouping = secondary
    self.totalValueUsd = breakdown.totalValueUsd
    self.isCoinView = coinView
    self.slices = breakdown.slices.enumerated().map { index, slice in
      Self.makeSlice(slice, index: index, parent: nil, holdings: holdingsByID)
    }
    self.unpricedHoldingCount = breakdown.unpriced.count
    self.unpricedRows = Self.unpricedRows(breakdown.unpriced)
  }

  // MARK: Secondary grouping

  /// The grouping for the second level, chosen so it adds information:
  ///
  /// - asset: state when any holding is staked, unbonding, or earning rewards
  ///   (an exchange already shows up as a network), otherwise network;
  /// - network, wallet or exchange, state, type: asset;
  /// - on a single coin's screen, where a split by asset is one slice: network
  ///   for state and type, state for network and wallet.
  static func secondaryGrouping(
    for primary: PortfolioGrouping, holdings: [TrackedAsset], coinView: Bool
  ) -> PortfolioGrouping {
    if coinView {
      switch primary {
      case .asset, .state, .kind: return .network
      case .network, .source: return .state
      }
    }
    switch primary {
    case .asset:
      let hasNonLiquid = holdings.contains { asset in
        // The same rule analytics uses for "priced".
        guard asset.pricingStatus == .priced, asset.valueUsd.isFinite, asset.valueUsd >= 0
        else { return false }
        switch HoldingState(asset) {
        case .staked, .unbonding, .rewards: return true
        case .liquid, .onExchange: return false
        }
      }
      return hasNonLiquid ? .state : .network
    case .network, .source, .state, .kind:
      return .asset
    }
  }

  // MARK: Slices

  private static func makeSlice(
    _ slice: PortfolioSlice, index: Int, parent: ChartKitSlice?, holdings: [String: TrackedAsset]
  ) -> ChartKitSlice {
    let largest = slice.holdingIDs.first.flatMap { holdings[$0] }
    var subtitle: String?
    var spoken = slice.label
    if slice.grouping == .asset, let name = largest?.name.trimmingCharacters(in: .whitespaces),
      !name.isEmpty, name.caseInsensitiveCompare(slice.label) != .orderedSame
    {
      subtitle = name
      spoken = name
    }
    let color: ChartKitColorKey =
      switch slice.grouping {
      case .asset: .asset(slice.key)
      case .network: .network(key: slice.key, label: slice.label)
      case .state: .state(HoldingState(rawValue: slice.key) ?? .liquid)
      case .kind: .kind(HoldingKind(rawValue: slice.key) ?? .token)
      case .source: .index(index)
      }
    let own: PortfolioChartSelection =
      slice.grouping == .asset
      ? .coin(slice.key) : .slice(grouping: slice.grouping, key: slice.key)
    // A second-level arc that is about a coin selects that coin; any other
    // second-level arc selects the first-level slice it sits in.
    let selection = (parent != nil && slice.grouping != .asset) ? parent?.selection : own
    let base = ChartKitSlice(
      id: slice.id,
      key: slice.key,
      label: slice.label,
      subtitle: subtitle,
      spokenName: spoken,
      grouping: slice.grouping,
      valueUsd: slice.valueUsd,
      share: slice.share,
      shareOfParent: slice.shareOfParent,
      holdingCount: slice.holdingCount,
      color: color,
      selection: selection,
      children: [],
      isOther: false
    )
    guard !slice.children.isEmpty else { return base }
    return ChartKitSlice(
      id: base.id, key: base.key, label: base.label, subtitle: base.subtitle,
      spokenName: base.spokenName, grouping: base.grouping, valueUsd: base.valueUsd,
      share: base.share, shareOfParent: base.shareOfParent, holdingCount: base.holdingCount,
      color: base.color, selection: base.selection,
      children: slice.children.enumerated().map { childIndex, child in
        makeSlice(child, index: childIndex, parent: base, holdings: holdings)
      },
      isOther: false
    )
  }

  private static func unpricedRows(_ unpriced: [TrackedAsset]) -> [ChartKitUnpricedRow] {
    var groups: [String: [TrackedAsset]] = [:]
    for asset in unpriced { groups[CoinIdentity.key(for: asset), default: []].append(asset) }
    return groups.map { key, assets in
      let first = assets.sorted { $0.id < $1.id }[0]
      let symbol = CoinIdentity.displaySymbol(for: first)
      let name = first.name.trimmingCharacters(in: .whitespaces)
      return ChartKitUnpricedRow(
        id: key,
        symbol: symbol,
        name: name.isEmpty || name.caseInsensitiveCompare(symbol) == .orderedSame ? nil : name,
        holdingCount: assets.count
      )
    }
    .sorted { lhs, rhs in
      if lhs.symbol != rhs.symbol { return lhs.symbol < rhs.symbol }
      return lhs.id < rhs.id
    }
  }

  // MARK: Folding

  /// The drawable slices with the tail folded into one "Other" slice, so a
  /// portfolio of forty coins stays readable. See `fold`.
  func folded(maxCount: Int, minShare: Double, minimumKept: Int = 5) -> [ChartKitSlice] {
    Self.fold(
      drawable, grouping: grouping, maxCount: maxCount, minShare: minShare,
      minimumKept: minimumKept, ofParent: nil)
  }

  /// Folds the tail of `slices` (largest first, zero-value slices already
  /// removed) into one "Other" slice. The first `minimumKept` slices always
  /// survive; after that a slice survives while fewer than `maxCount` are kept
  /// and its share (of the parent, when `ofParent` is given) is at least
  /// `minShare`. A tail of one slice is kept as it is.
  static func fold(
    _ slices: [ChartKitSlice], grouping: PortfolioGrouping, maxCount: Int, minShare: Double,
    minimumKept: Int = 5, ofParent parent: ChartKitSlice?
  ) -> [ChartKitSlice] {
    func measure(_ slice: ChartKitSlice) -> Double {
      parent == nil ? slice.share : slice.shareOfParent
    }
    var keep = 0
    for (index, slice) in slices.enumerated() {
      if index < minimumKept || (index < maxCount && measure(slice) >= minShare) {
        keep = index + 1
      } else {
        break
      }
    }
    let tail = slices.dropFirst(keep)
    guard tail.count > 1 else { return slices }
    let share = min(1, tail.map(\.share).reduce(0, +))
    let shareOfParent = min(1, tail.map(\.shareOfParent).reduce(0, +))
    let other = ChartKitSlice(
      id: parent.map { "\($0.id)>chartkit.other" } ?? "chartkit.other",
      key: "other",
      label: "Other",
      subtitle: "\(tail.count) smaller",
      spokenName: "Other, \(tail.count) smaller",
      grouping: grouping,
      valueUsd: tail.map(\.valueUsd).reduce(0, +),
      share: share,
      shareOfParent: parent == nil ? share : shareOfParent,
      holdingCount: tail.map(\.holdingCount).reduce(0, +),
      color: .neutral,
      selection: nil,
      children: [],
      isOther: true
    )
    return Array(slices.prefix(keep)) + [other]
  }

  // MARK: Wording

  /// "Map of holdings by asset. Total $48,987 across 5 assets."
  func summary(viewName: String) -> String {
    guard !isEmpty else {
      let base = "\(viewName). \(ChartKitFormat.emptyTitle)."
      return unpricedHoldingCount > 0
        ? base + " " + ChartKitFormat.unpricedNote(count: unpricedHoldingCount) : base
    }
    var text =
      "\(viewName) of holdings \(ChartKitFormat.groupingPhrase(grouping)). Total \(ChartKitFormat.usd(totalValueUsd)) across \(ChartKitFormat.count(drawable.count, of: grouping))."
    if unpricedHoldingCount > 0 {
      text += " " + ChartKitFormat.unpricedNote(count: unpricedHoldingCount)
    }
    return text
  }
}
