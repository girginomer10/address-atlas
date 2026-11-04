import Foundation

// MARK: - Portfolio analytics
//
// Pure, deterministic, `Sendable` value types and functions over
// `[TrackedAsset]` and `[ScanRunRecord]`. They hold every number the portfolio
// visualizations (map, ring, strip, grid, bubbles, rings-in-rings, flow, list,
// over time, what changed, atlas, slope, concentration gauge, calendar
// heatmap) and the coin views (state split, location map, amount over time,
// price-versus-amount effect, self-custody share) need, so the views only lay
// out and colour what they are given. Nothing here reads preferences, the
// clock, the locale, the network, or the vault: dust and hidden-holding rules
// are applied by the caller (see `PortfolioHoldingFilter`) before calling in.
// Equal inputs give equal outputs, independent of input order (every sum adds
// its terms smallest first and every list has a total order ending in an id).
//
// The code is split by concern:
//   PortfolioAnalytics.swift         identity, state, kind, grouping, breakdown,
//                                    coin summaries, flow graph, concentration
//   PortfolioAnalyticsHistory.swift  change attribution, rank change, per-run,
//                                    stacked, and daily series
//
// ## Entry points (all `static` on `PortfolioAnalytics`)
//
//   breakdown(_:by:then:)          -> PortfolioBreakdown   treemap / ring / strip /
//                                                          grid / bubbles / list;
//                                                          `then:` adds the second
//                                                          level for nested
//                                                          treemaps and the
//                                                          two-ring sunburst
//   coinSummaries(_:)              -> [CoinSummary]        every coin, largest first
//   coinSummary(_:coin:)           -> CoinSummary?         one coin's state split,
//                                                          locations, unlock dates,
//                                                          self-custody share
//   flowGraph(_:)                  -> FlowGraph            source -> coin -> state
//   concentration(_:by:)           -> Concentration        top share, top three,
//                                                          Herfindahl, effective N
//   attribution(from:to:context:)  -> ChangeAttribution    what changed between
//                                                          two scans
//   rankChanges(from:to:limit:)    -> [RankChange]         slope chart
//   runTotals(_:)                  -> [RunTotal]           value per scan
//   coinSeries(_:coin:)            -> [CoinSeriesPoint]    one coin's amount,
//                                                          value, price per scan
//   stackedSeries(_:by:coin:measure:maximumLayers:)
//                                  -> StackedSeries        over-time composition
//   dailySeries(_:timeZone:)       -> [DailyPortfolioPoint] calendar heatmap
//
// ## Definitions
//
// Priced and unpriced. A holding contributes to any value only when its
// `pricingStatus` is `.priced` and its USD value is finite and non-negative.
// Everything else is *unpriced*: it never enters a value, share, or ranking,
// and the functions that split by value return those holdings separately
// (`PortfolioBreakdown.unpriced`, `FlowGraph.unpriced`, per-coin unpriced
// counts) so a view can say "plus N unpriced" instead of silently dropping
// them. Amounts are the one thing unpriced holdings still contribute to.
//
// Coin identity. Holdings are the same coin when `CoinIdentity.key` matches:
// the trimmed, upper-cased symbol. ETH on Ethereum, Base, Arbitrum and an
// exchange is one coin, and so is USDC on every network. Bridged variants of a
// stablecoin fold into the stablecoin they are pegged to (`USDC.e` -> `USDC`,
// `USDT.e`/`USDT0` -> `USDT`, `DAI.e` -> `DAI`). Wrapped and bridged
// volatile assets (WETH, WBTC, stETH, cbBTC, BTC.b) stay separate coins, because
// they are priced as separate tokens. This is the same symbol-based grouping
// the Assets screen uses; analytics also sums amounts, which is only done
// per coin.
//
// State (`HoldingState`). The mapping from `AssetSource`: native, erc20, spl,
// trc20, and issued are `liquid`; `staked`, `unbonding`, and `rewards` map to
// themselves; `exchange` (exchange connections and manual holdings, which share
// the exchange-style presentation) is `onExchange`.
//
// Kind (`HoldingKind`). `native` for a chain's own coin in any state (liquid,
// staked, unbonding, rewards), `stablecoin` for symbols in
// `CoinIdentity.stablecoinSymbols`, `token` for every other contract token. An
// exchange reports no contract information, so an exchange holding is `native`
// only if its symbol is a registered chain's coin or one of the well-known
// layer-1 coins in `CoinIdentity.nativeSymbols`, `stablecoin` if it is on the
// stablecoin list, and `token` otherwise.
//
// Grouping (`PortfolioGrouping`). `asset` is the coin; `network` is the chain
// (or the exchange or manual venue, matching the Assets screen); `source` is the
// wallet (one address across all its EVM networks), exchange connection, or
// manual holding, labelled with the user's own label; `state` is
// `HoldingState`; `kind` is `HoldingKind`.
//
// ## Change attribution
//
// For every coin in the older and newer scan, using only priced holdings:
//
//     pOld, pNew   priced amount of the coin in each scan
//     PA,   PB     its price in each scan, valued / priced amount
//     delta        newerValue - olderValue
//
//     price effect  = pOld * (PB - PA)       what the price move did to what
//                                            you already held
//     amount effect = (pNew - pOld) * PB     what coins arriving or leaving
//                                            did, at today's price
//     price effect + amount effect = delta   (up to floating-point rounding)
//
// A coin in only one scan is added or removed: its price effect is zero and its
// amount effect is the whole value. A coin that is held in both scans but has a
// price in only one has no meaningful split; its delta is reported as
// `valuationGapUsd` instead of being credited to price or amount. At portfolio
// level `priceEffectUsd + amountEffectUsd + valuationGapUsd == totalDeltaUsd`.
// Attribution compares whatever two scans it is given and sets `sourcesDiffer`
// when they did not read the same wallets, exchanges, and manual holdings, so a
// view can caveat a difference that is not a market move.
//
// ## Concentration
//
// Over each group's share of priced value: top share, top-three share,
// Herfindahl-Hirschman index (the sum of squared shares, 1 for a single group),
// and effective number of holdings (1 / HHI: how many equal-sized positions
// would be as concentrated). Computed by coin unless another grouping is given.

public enum PortfolioAnalytics {}

// MARK: - Coin identity

public enum CoinIdentity {
  /// USD-pegged stablecoins, upper-cased. Small and explicit on purpose: a
  /// symbol only counts as a stablecoin if it is listed here, so an unknown
  /// token is never presented as a dollar.
  public static let stablecoinSymbols: Set<String> = [
    "USDC", "USDT", "DAI", "USDE", "PYUSD", "FDUSD", "TUSD", "USDS", "USDP", "GUSD",
    "BUSD", "LUSD", "FRAX", "CRVUSD", "GHO", "USD1", "RLUSD", "USDG",
  ]

  /// Bridged spellings of a listed stablecoin, folded into the stablecoin.
  static let bridgedStablecoinAliases: [String: String] = [
    "USDC.E": "USDC", "USDT.E": "USDT", "DAI.E": "DAI", "USDT0": "USDT",
  ]

  /// Layer-1 coins an exchange can hold besides the registered chains' own
  /// coins. Exchange rows carry no contract address, so this list is the only
  /// way to tell Dogecoin from a token held on an exchange.
  static let additionalNativeSymbols: Set<String> = [
    "ADA", "DOT", "LTC", "DOGE", "BCH", "XLM", "NEAR", "ALGO", "ETC", "XMR", "HBAR", "SUI",
    "APT", "TON", "FIL", "ICP", "KAS", "ZEC", "DASH", "EOS", "XTZ", "FLOW", "EGLD", "KSM",
    "MATIC",
  ]

  /// Coins that are the native coin of a supported chain (taken from the
  /// registry, so a new chain is picked up automatically) plus
  /// `additionalNativeSymbols`.
  public static let nativeSymbols: Set<String> = {
    var symbols = additionalNativeSymbols
    for chain in ChainRegistry.allChains { symbols.insert(chain.symbol.uppercased()) }
    return symbols
  }()

  /// The key two holdings share when they are the same coin.
  public static func key(forSymbol symbol: String) -> String {
    let normalized = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if normalized.isEmpty { return "?" }
    return bridgedStablecoinAliases[normalized] ?? normalized
  }

  public static func key(for asset: TrackedAsset) -> String { key(forSymbol: asset.symbol) }

  /// How the coin is written on screen: the holding's own spelling (so `stETH`
  /// stays `stETH`), or the stablecoin's name for a bridged variant.
  public static func displaySymbol(for asset: TrackedAsset) -> String {
    let trimmed = asset.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "?" }
    return bridgedStablecoinAliases[trimmed.uppercased()] ?? trimmed
  }

  public static func isStablecoin(symbol: String) -> Bool {
    stablecoinSymbols.contains(key(forSymbol: symbol))
  }
}

// MARK: - State, kind, custody

/// What a holding can do right now.
public enum HoldingState: String, CaseIterable, Hashable, Sendable {
  case liquid
  case staked
  case unbonding
  case rewards
  case onExchange

  public init(source: AssetSource) {
    switch source {
    case .native, .erc20, .spl, .trc20, .issued: self = .liquid
    case .staked: self = .staked
    case .unbonding: self = .unbonding
    case .rewards: self = .rewards
    case .exchange: self = .onExchange
    }
  }

  public init(_ asset: TrackedAsset) {
    self = asset.family == .exchange ? .onExchange : HoldingState(source: asset.source)
  }

  public var displayName: String {
    switch self {
    case .liquid: "Liquid"
    case .staked: "Staked"
    case .unbonding: "Unbonding"
    case .rewards: "Rewards"
    case .onExchange: "On exchange"
    }
  }
}

public enum HoldingKind: String, CaseIterable, Hashable, Sendable {
  case native
  case token
  case stablecoin

  public init(_ asset: TrackedAsset) {
    let key = CoinIdentity.key(for: asset)
    switch asset.source {
    case .native, .staked, .unbonding, .rewards:
      self = .native
    case .erc20, .spl, .trc20, .issued:
      self = CoinIdentity.stablecoinSymbols.contains(key) ? .stablecoin : .token
    case .exchange:
      if CoinIdentity.stablecoinSymbols.contains(key) {
        self = .stablecoin
      } else if CoinIdentity.nativeSymbols.contains(key) {
        self = .native
      } else {
        self = .token
      }
    }
  }

  public var displayName: String {
    switch self {
    case .native: "Native"
    case .token: "Token"
    case .stablecoin: "Stablecoin"
    }
  }
}

/// Who holds the keys. Scanned wallets are self-custody, exchange connections
/// are not, and manual holdings are whatever the user typed in, so custody is
/// unknown for them.
public enum HoldingCustody: String, CaseIterable, Hashable, Sendable {
  case wallet
  case exchange
  case manual

  public init(_ asset: TrackedAsset) {
    if asset.family != .exchange && asset.source != .exchange {
      self = .wallet
    } else if asset.exchangeId == nil && asset.id.hasPrefix("manual-") {
      self = .manual
    } else {
      self = .exchange
    }
  }
}

// MARK: - Grouping

public enum PortfolioGrouping: String, CaseIterable, Hashable, Sendable {
  case asset
  case network
  case source
  case state
  case kind

  public var displayName: String {
    switch self {
    case .asset: "Asset"
    case .network: "Network"
    case .source: "Wallet or exchange"
    case .state: "State"
    case .kind: "Type"
    }
  }
}

/// Hides priced holdings worth less than a threshold, like the dust setting.
/// Unpriced holdings are never hidden because their value is unknown, not
/// small. Analytics never reads the setting itself; pass what the user chose.
public struct PortfolioHoldingFilter: Equatable, Sendable {
  public var dustThresholdUsd: Double?

  public init(dustThresholdUsd: Double? = nil) {
    self.dustThresholdUsd = dustThresholdUsd
  }

  public func apply(_ holdings: [TrackedAsset]) -> [TrackedAsset] {
    guard let threshold = dustThresholdUsd, threshold.isFinite, threshold > 0 else {
      return holdings
    }
    return holdings.filter { asset in
      guard PortfolioAnalytics.isPriced(asset) else { return true }
      return asset.valueUsd >= threshold
    }
  }
}

// MARK: - Breakdown

public struct PortfolioSlice: Identifiable, Equatable, Sendable {
  /// Unique within the whole tree: a child's id is `parent.id>child.key`.
  public let id: String
  /// The group's own key (`ETH`, `ethereum`, `staked`, ...), unique among
  /// siblings. Use it to colour consistently across views.
  public let key: String
  public let label: String
  public let grouping: PortfolioGrouping
  public let valueUsd: Double
  /// Of the whole breakdown's priced value, 0...1.
  public let share: Double
  /// Of the parent slice's value (equal to `share` at the top level), 0...1.
  public let shareOfParent: Double
  /// Priced holdings in this slice.
  public let holdingCount: Int
  /// Ids of those holdings, largest value first.
  public let holdingIDs: [String]
  /// The second grouping inside this slice; empty without `then:`.
  public let children: [PortfolioSlice]
}

public struct PortfolioBreakdown: Equatable, Sendable {
  public let grouping: PortfolioGrouping
  public let secondaryGrouping: PortfolioGrouping?
  /// Sum of every priced holding.
  public let totalValueUsd: Double
  /// Largest first. A priced holding worth exactly zero still appears, with a
  /// zero share, so a list view can show it; a graphical view should skip
  /// zero-value slices.
  public let slices: [PortfolioSlice]
  /// Holdings with no usable value, never counted in any slice.
  public let unpriced: [TrackedAsset]
}

extension PortfolioAnalytics {
  /// Groups holdings by one dimension, optionally splitting each group by a
  /// second one. Slices are sorted by value, then label, then key.
  public static func breakdown(
    _ holdings: [TrackedAsset],
    by grouping: PortfolioGrouping,
    then secondary: PortfolioGrouping? = nil
  ) -> PortfolioBreakdown {
    let (priced, unpriced) = partition(holdings)
    let total = sum(priced.map(\.valueUsd))
    return PortfolioBreakdown(
      grouping: grouping,
      secondaryGrouping: secondary,
      totalValueUsd: total,
      slices: makeSlices(
        priced, by: grouping, then: secondary, pathPrefix: nil, parentValue: total,
        totalValue: total),
      unpriced: unpriced.sorted(by: unpricedOrder)
    )
  }

  private static func makeSlices(
    _ holdings: [TrackedAsset],
    by grouping: PortfolioGrouping,
    then secondary: PortfolioGrouping?,
    pathPrefix: String?,
    parentValue: Double,
    totalValue: Double
  ) -> [PortfolioSlice] {
    var groups: [String: [(asset: TrackedAsset, label: String)]] = [:]
    for asset in holdings {
      let descriptor = descriptor(of: asset, in: grouping)
      groups[descriptor.key, default: []].append((asset, descriptor.label))
    }
    var slices: [PortfolioSlice] = []
    slices.reserveCapacity(groups.count)
    for (key, members) in groups {
      // The label comes from the group's largest holding, so one spelling
      // difference between members cannot make it depend on input order.
      let ordered = members.sorted { lhs, rhs in
        if lhs.asset.valueUsd != rhs.asset.valueUsd { return lhs.asset.valueUsd > rhs.asset.valueUsd }
        if lhs.label != rhs.label { return lhs.label < rhs.label }
        return lhs.asset.id < rhs.asset.id
      }
      let value = sum(members.map(\.asset.valueUsd))
      let id = pathPrefix.map { "\($0)>\(key)" } ?? key
      let children =
        secondary.map {
          makeSlices(
            members.map(\.asset), by: $0, then: nil, pathPrefix: id, parentValue: value,
            totalValue: totalValue)
        } ?? []
      slices.append(
        PortfolioSlice(
          id: id,
          key: key,
          label: ordered[0].label,
          grouping: grouping,
          valueUsd: value,
          share: fraction(value, of: totalValue),
          shareOfParent: fraction(value, of: parentValue),
          holdingCount: members.count,
          holdingIDs: ordered.map(\.asset.id),
          children: children
        ))
    }
    slices.sort { lhs, rhs in
      if lhs.valueUsd != rhs.valueUsd { return lhs.valueUsd > rhs.valueUsd }
      if lhs.label != rhs.label { return lhs.label < rhs.label }
      return lhs.key < rhs.key
    }
    return slices
  }

  // MARK: Group descriptors

  struct GroupDescriptor: Equatable, Sendable {
    var key: String
    var label: String
  }

  static func descriptor(of asset: TrackedAsset, in grouping: PortfolioGrouping)
    -> GroupDescriptor
  {
    switch grouping {
    case .asset:
      return GroupDescriptor(
        key: CoinIdentity.key(for: asset), label: CoinIdentity.displaySymbol(for: asset))
    case .network:
      return networkDescriptor(of: asset)
    case .source:
      return sourceDescriptor(of: asset)
    case .state:
      let state = HoldingState(asset)
      return GroupDescriptor(key: state.rawValue, label: state.displayName)
    case .kind:
      let kind = HoldingKind(asset)
      return GroupDescriptor(key: kind.rawValue, label: kind.displayName)
    }
  }

  /// The chain for wallet holdings; the exchange (or manual venue) otherwise,
  /// so an exchange is a "network" of its own, as on the Assets screen.
  static func networkDescriptor(of asset: TrackedAsset) -> GroupDescriptor {
    let label = asset.exchangeProvider?.label ?? asset.chainName
    // Manual holdings from one provider can name different venues.
    let key = HoldingCustody(asset) == .manual ? "\(asset.chainId)|\(asset.chainName)" : asset.chainId
    return GroupDescriptor(key: key, label: label)
  }

  static func sourceDescriptor(of asset: TrackedAsset) -> GroupDescriptor {
    let key = sourceKey(for: asset) ?? "asset:\(asset.id)"
    let walletLabel = asset.walletLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
    let label: String
    if let walletLabel, !walletLabel.isEmpty {
      label = walletLabel
    } else if asset.family == .exchange {
      let address = asset.address.trimmingCharacters(in: .whitespacesAndNewlines)
      label = address.isEmpty ? (asset.exchangeProvider?.label ?? asset.chainName) : address
    } else {
      label = shortAddress(asset.address)
    }
    return GroupDescriptor(key: key, label: label)
  }

  static func shortAddress(_ address: String) -> String {
    let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 14 else { return trimmed }
    return "\(trimmed.prefix(6))…\(trimmed.suffix(4))"
  }

  /// A stable identity for where a holding was read from: the wallet's network
  /// family plus canonical address (so one EVM address on many networks is one
  /// source), the exchange connection, or the manual holding. Nil when a
  /// wallet address cannot be canonicalized.
  public static func sourceKey(for asset: TrackedAsset) -> String? {
    if asset.id.hasPrefix("manual-") {
      return "manual:" + asset.id.dropFirst("manual-".count).lowercased()
    }
    if let exchangeId = asset.exchangeId {
      return "exchange:" + exchangeId.uuidString.lowercased()
    }
    guard asset.family != .exchange,
      let canonical = AddressDetection.canonicalAddress(asset.address, family: asset.family)
    else { return nil }
    return "wallet:\(asset.family.rawValue):\(canonical)"
  }

  // MARK: Shared arithmetic and ordering

  static func isPriced(_ asset: TrackedAsset) -> Bool {
    asset.pricingStatus == .priced && asset.valueUsd.isFinite && asset.valueUsd >= 0
  }

  static func partition(_ holdings: [TrackedAsset]) -> (
    priced: [TrackedAsset], unpriced: [TrackedAsset]
  ) {
    var priced: [TrackedAsset] = []
    var unpriced: [TrackedAsset] = []
    for asset in holdings {
      if isPriced(asset) { priced.append(asset) } else { unpriced.append(asset) }
    }
    return (priced, unpriced)
  }

  /// Floating-point addition is not associative; adding smallest first makes
  /// the result independent of the order the terms arrived in. Works for
  /// signed terms too.
  static func sum(_ values: [Double]) -> Double {
    values.sorted().reduce(0, +)
  }

  static func fraction(_ part: Double, of whole: Double) -> Double {
    guard whole.isFinite, whole > 0, part.isFinite else { return 0 }
    return min(max(part / whole, 0), 1)
  }

  static func unpricedOrder(_ lhs: TrackedAsset, _ rhs: TrackedAsset) -> Bool {
    if lhs.symbol != rhs.symbol { return lhs.symbol < rhs.symbol }
    return lhs.id < rhs.id
  }

  static func holdingOrder(_ lhs: TrackedAsset, _ rhs: TrackedAsset) -> Bool {
    let lhsValue = isPriced(lhs) ? lhs.valueUsd : 0
    let rhsValue = isPriced(rhs) ? rhs.valueUsd : 0
    if lhsValue != rhsValue { return lhsValue > rhsValue }
    if lhs.symbol != rhs.symbol { return lhs.symbol < rhs.symbol }
    return lhs.id < rhs.id
  }

  /// Sum of every priced holding.
  public static func totalValueUsd(_ holdings: [TrackedAsset]) -> Double {
    sum(holdings.filter(isPriced).map(\.valueUsd))
  }
}

// MARK: - Coin summaries

/// One state of one coin: how much of it, what it is worth, and (for
/// unbonding) when the first of it frees up.
public struct CoinStateBreakdown: Identifiable, Equatable, Sendable {
  public var id: String { state.rawValue }
  public let state: HoldingState
  public let amount: Double
  public let valueUsd: Double
  /// Of the coin's priced value, 0...1.
  public let share: Double
  public let holdingCount: Int
  /// Earliest `unlocksAt` among the holdings in this state; nil when none has
  /// one (every state except unbonding, and Solana unbonding).
  public let earliestUnlock: Date?
}

/// Amount of a coin that frees up at one time.
public struct CoinUnlock: Equatable, Sendable {
  /// Nil for unbonding amounts whose completion time is not known.
  public let date: Date?
  public let amount: Double
  public let valueUsd: Double
}

/// Where a coin is: one network as held through one source.
public struct CoinLocation: Identifiable, Equatable, Sendable {
  public let id: String
  public let networkID: String
  public let networkLabel: String
  public let sourceID: String
  public let sourceLabel: String
  public let amount: Double
  public let valueUsd: Double
  /// Of the coin's priced value, 0...1.
  public let share: Double
  /// The states the coin is in at this location, in `HoldingState` order.
  public let states: [HoldingState]
}

/// How much of a coin sits in the user's own wallets, on exchanges, and in
/// manual entries (whose custody is unknown).
public struct CoinCustody: Equatable, Sendable {
  public let walletAmount: Double
  public let exchangeAmount: Double
  public let manualAmount: Double
  public let walletValueUsd: Double
  public let exchangeValueUsd: Double
  public let manualValueUsd: Double

  public var totalAmount: Double { walletAmount + exchangeAmount + manualAmount }

  /// Wallet amount over total amount, 0...1, or nil when the coin has no
  /// amount. Staked, unbonding, and reward balances in the user's own wallet
  /// count as self-custody: delegating does not hand over the keys. Manual
  /// entries are in the denominator, not the numerator.
  public var selfCustodyShare: Double? {
    let total = totalAmount
    guard total > 0, total.isFinite else { return nil }
    return min(max(walletAmount / total, 0), 1)
  }
}

public struct CoinSummary: Identifiable, Equatable, Sendable {
  /// `CoinIdentity.key`.
  public let id: String
  public let symbol: String
  /// Amount across every holding, priced or not.
  public let totalAmount: Double
  /// Amount in priced holdings only: the amount `valueUsd` is the value of.
  public let pricedAmount: Double
  public let valueUsd: Double
  /// `valueUsd / pricedAmount`, nil when nothing is priced.
  public let priceUsd: Double?
  public let holdingCount: Int
  public let unpricedHoldingCount: Int
  /// States the coin is in, in `HoldingState` order.
  public let states: [CoinStateBreakdown]
  /// Unbonding amounts by completion time, soonest first, undated last.
  public let unlocks: [CoinUnlock]
  /// Locations, largest value first.
  public let locations: [CoinLocation]
  public let custody: CoinCustody
}

extension PortfolioAnalytics {
  /// Every coin in the holdings, largest value first (unpriced coins last,
  /// alphabetically).
  public static func coinSummaries(_ holdings: [TrackedAsset]) -> [CoinSummary] {
    var byKey: [String: [TrackedAsset]] = [:]
    for asset in holdings { byKey[CoinIdentity.key(for: asset), default: []].append(asset) }
    return byKey.map { makeCoinSummary(key: $0.key, members: $0.value) }.sorted { lhs, rhs in
      if lhs.valueUsd != rhs.valueUsd { return lhs.valueUsd > rhs.valueUsd }
      if lhs.symbol != rhs.symbol { return lhs.symbol < rhs.symbol }
      return lhs.id < rhs.id
    }
  }

  /// One coin's summary; `coin` is a symbol or an identity key. Nil when no
  /// holding is that coin.
  public static func coinSummary(_ holdings: [TrackedAsset], coin: String) -> CoinSummary? {
    let key = CoinIdentity.key(forSymbol: coin)
    let members = holdings.filter { CoinIdentity.key(for: $0) == key }
    guard !members.isEmpty else { return nil }
    return makeCoinSummary(key: key, members: members)
  }

  static func makeCoinSummary(key: String, members: [TrackedAsset]) -> CoinSummary {
    let ordered = members.sorted(by: holdingOrder)
    let (priced, unpriced) = partition(ordered)
    let value = sum(priced.map(\.valueUsd))
    let pricedAmount = sum(priced.map(\.amount))

    var statesByState: [HoldingState: [TrackedAsset]] = [:]
    for asset in ordered { statesByState[HoldingState(asset), default: []].append(asset) }
    let states = HoldingState.allCases.compactMap { state -> CoinStateBreakdown? in
      guard let group = statesByState[state] else { return nil }
      let stateValue = sum(group.filter(isPriced).map(\.valueUsd))
      return CoinStateBreakdown(
        state: state,
        amount: sum(group.map(\.amount)),
        valueUsd: stateValue,
        share: fraction(stateValue, of: value),
        holdingCount: group.count,
        earliestUnlock: group.compactMap(\.unlocksAt).min()
      )
    }

    let unbonding = ordered.filter { HoldingState($0) == .unbonding }
    var unlockGroups: [Date?: [TrackedAsset]] = [:]
    for asset in unbonding { unlockGroups[asset.unlocksAt, default: []].append(asset) }
    let unlocks = unlockGroups.map { date, group in
      CoinUnlock(
        date: date,
        amount: sum(group.map(\.amount)),
        valueUsd: sum(group.filter(isPriced).map(\.valueUsd))
      )
    }.sorted { lhs, rhs in
      switch (lhs.date, rhs.date) {
      case (let left?, let right?): return left < right
      case (_?, nil): return true
      case (nil, _?): return false
      case (nil, nil): return false
      }
    }

    var locationGroups: [String: [TrackedAsset]] = [:]
    var locationDescriptors: [String: (network: GroupDescriptor, source: GroupDescriptor)] = [:]
    for asset in ordered {
      let network = networkDescriptor(of: asset)
      let source = sourceDescriptor(of: asset)
      let id = "\(network.key)|\(source.key)"
      locationGroups[id, default: []].append(asset)
      if locationDescriptors[id] == nil { locationDescriptors[id] = (network, source) }
    }
    let locations = locationGroups.compactMap { id, group -> CoinLocation? in
      guard let descriptors = locationDescriptors[id] else { return nil }
      let groupValue = sum(group.filter(isPriced).map(\.valueUsd))
      let groupStates = Set(group.map { HoldingState($0) })
      return CoinLocation(
        id: id,
        networkID: descriptors.network.key,
        networkLabel: descriptors.network.label,
        sourceID: descriptors.source.key,
        sourceLabel: descriptors.source.label,
        amount: sum(group.map(\.amount)),
        valueUsd: groupValue,
        share: fraction(groupValue, of: value),
        states: HoldingState.allCases.filter(groupStates.contains)
      )
    }.sorted { lhs, rhs in
      if lhs.valueUsd != rhs.valueUsd { return lhs.valueUsd > rhs.valueUsd }
      if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
      return lhs.id < rhs.id
    }

    func custodyTotals(_ custody: HoldingCustody) -> (amount: Double, value: Double) {
      let group = ordered.filter { HoldingCustody($0) == custody }
      return (sum(group.map(\.amount)), sum(group.filter(isPriced).map(\.valueUsd)))
    }
    let wallet = custodyTotals(.wallet)
    let exchange = custodyTotals(.exchange)
    let manual = custodyTotals(.manual)

    return CoinSummary(
      id: key,
      symbol: ordered.first.map(CoinIdentity.displaySymbol(for:)) ?? key,
      totalAmount: sum(ordered.map(\.amount)),
      pricedAmount: pricedAmount,
      valueUsd: value,
      priceUsd: pricedAmount > 0 ? value / pricedAmount : nil,
      holdingCount: ordered.count,
      unpricedHoldingCount: unpriced.count,
      states: states,
      unlocks: unlocks,
      locations: locations,
      custody: CoinCustody(
        walletAmount: wallet.amount,
        exchangeAmount: exchange.amount,
        manualAmount: manual.amount,
        walletValueUsd: wallet.value,
        exchangeValueUsd: exchange.value,
        manualValueUsd: manual.value
      )
    )
  }
}

// MARK: - Flow graph

public enum FlowColumn: Int, CaseIterable, Hashable, Sendable {
  case source = 0
  case coin = 1
  case state = 2

  var prefix: String {
    switch self {
    case .source: "source"
    case .coin: "coin"
    case .state: "state"
    }
  }
}

public struct FlowNode: Identifiable, Equatable, Sendable {
  /// `source:<key>`, `coin:<key>`, or `state:<key>`; unique across columns.
  public let id: String
  /// The group key without the column prefix, for colour lookups.
  public let key: String
  public let label: String
  public let column: FlowColumn
  public let valueUsd: Double
}

public struct FlowEdge: Equatable, Sendable {
  public let from: String
  public let to: String
  public let valueUsd: Double
}

/// Value flowing from where it is held (wallet, exchange, manual entry), to
/// the coin it is, to the state it is in.
public struct FlowGraph: Equatable, Sendable {
  /// Column by column, largest value first within each.
  public let nodes: [FlowNode]
  /// Source -> coin edges, then coin -> state edges, each largest first.
  /// Every coin node's incoming value equals its outgoing value.
  public let edges: [FlowEdge]
  public let totalValueUsd: Double
  public let unpriced: [TrackedAsset]
}

extension PortfolioAnalytics {
  public static func flowGraph(_ holdings: [TrackedAsset]) -> FlowGraph {
    struct NodeAccumulator {
      var key: String
      var label: String
      var column: FlowColumn
      var values: [Double] = []
    }
    struct EdgeAccumulator {
      var from: String
      var to: String
      var values: [Double] = []
    }
    let (priced, unpriced) = partition(holdings)
    var nodeAccumulators: [String: NodeAccumulator] = [:]
    var edgeAccumulators: [String: EdgeAccumulator] = [:]

    func record(_ column: FlowColumn, _ descriptor: GroupDescriptor, value: Double) -> String {
      let id = "\(column.prefix):\(descriptor.key)"
      var entry =
        nodeAccumulators[id]
        ?? NodeAccumulator(key: descriptor.key, label: descriptor.label, column: column)
      // Keep the lexicographically smallest label seen so the choice never
      // depends on input order.
      if descriptor.label < entry.label { entry.label = descriptor.label }
      entry.values.append(value)
      nodeAccumulators[id] = entry
      return id
    }

    for asset in priced {
      let value = asset.valueUsd
      let source = record(.source, sourceDescriptor(of: asset), value: value)
      let coin = record(.coin, descriptor(of: asset, in: .asset), value: value)
      let state = record(.state, descriptor(of: asset, in: .state), value: value)
      for (from, to) in [(source, coin), (coin, state)] {
        let id = "\(from)>\(to)"
        var entry = edgeAccumulators[id] ?? EdgeAccumulator(from: from, to: to)
        entry.values.append(value)
        edgeAccumulators[id] = entry
      }
    }

    let nodes = nodeAccumulators.map { id, entry in
      FlowNode(
        id: id, key: entry.key, label: entry.label, column: entry.column,
        valueUsd: sum(entry.values))
    }.sorted { lhs, rhs in
      if lhs.column != rhs.column { return lhs.column.rawValue < rhs.column.rawValue }
      if lhs.valueUsd != rhs.valueUsd { return lhs.valueUsd > rhs.valueUsd }
      if lhs.label != rhs.label { return lhs.label < rhs.label }
      return lhs.id < rhs.id
    }
    let columnOfNode = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.column.rawValue) })
    let edges = edgeAccumulators.values.map {
      FlowEdge(from: $0.from, to: $0.to, valueUsd: sum($0.values))
    }.sorted { lhs, rhs in
      let lhsColumn = columnOfNode[lhs.from] ?? 0
      let rhsColumn = columnOfNode[rhs.from] ?? 0
      if lhsColumn != rhsColumn { return lhsColumn < rhsColumn }
      if lhs.valueUsd != rhs.valueUsd { return lhs.valueUsd > rhs.valueUsd }
      if lhs.from != rhs.from { return lhs.from < rhs.from }
      return lhs.to < rhs.to
    }
    return FlowGraph(
      nodes: nodes,
      edges: edges,
      totalValueUsd: sum(priced.map(\.valueUsd)),
      unpriced: unpriced.sorted(by: unpricedOrder)
    )
  }
}

// MARK: - Concentration

/// Herfindahl-Hirschman bands (the usual 0.15 / 0.25 antitrust thresholds on a
/// 0...1 scale), used to label a gauge.
public enum ConcentrationLevel: String, CaseIterable, Hashable, Sendable {
  case diversified
  case moderate
  case concentrated

  public init(herfindahlIndex: Double) {
    if herfindahlIndex < 0.15 {
      self = .diversified
    } else if herfindahlIndex < 0.25 {
      self = .moderate
    } else {
      self = .concentrated
    }
  }
}

public struct ConcentrationEntry: Identifiable, Equatable, Sendable {
  public let id: String
  public let label: String
  public let share: Double
}

public struct Concentration: Equatable, Sendable {
  public let grouping: PortfolioGrouping
  public let totalValueUsd: Double
  /// Groups with a positive value.
  public let groupCount: Int
  /// Largest groups, largest first, at most three.
  public let leaders: [ConcentrationEntry]
  /// Share of the largest group, 0...1.
  public let topShare: Double
  /// Combined share of the three largest groups, 0...1.
  public let topThreeShare: Double
  /// Sum of squared shares: 1 for a single group, 1/N for N equal groups; 0
  /// when there is no value.
  public let herfindahlIndex: Double
  /// `1 / herfindahlIndex`: how many equal-sized groups would be as
  /// concentrated. 0 when there is no value.
  public let effectiveHoldings: Double
  /// Nil when there is no priced value to be concentrated.
  public let level: ConcentrationLevel?
}

extension PortfolioAnalytics {
  /// Shares are of priced value, so unpriced holdings neither dilute nor
  /// inflate the result. By coin unless another grouping is given.
  public static func concentration(
    _ holdings: [TrackedAsset],
    by grouping: PortfolioGrouping = .asset
  ) -> Concentration {
    let breakdown = breakdown(holdings, by: grouping)
    let valued = breakdown.slices.filter { $0.valueUsd > 0 }
    let shares = valued.map(\.share)
    let hhi = min(1, sum(shares.map { $0 * $0 }))
    let leaders = valued.prefix(3).map {
      ConcentrationEntry(id: $0.key, label: $0.label, share: $0.share)
    }
    return Concentration(
      grouping: grouping,
      totalValueUsd: breakdown.totalValueUsd,
      groupCount: valued.count,
      leaders: Array(leaders),
      topShare: leaders.first?.share ?? 0,
      topThreeShare: min(1, sum(leaders.map(\.share))),
      herfindahlIndex: hhi,
      effectiveHoldings: hhi > 0 ? 1 / hhi : 0,
      level: valued.isEmpty ? nil : ConcentrationLevel(herfindahlIndex: hhi)
    )
  }
}
