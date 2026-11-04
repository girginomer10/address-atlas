import Foundation

// Analytics that compare or sequence scans: change attribution, rank change,
// and the per-run, stacked, and daily series. See the overview and the
// attribution formulas at the top of PortfolioAnalytics.swift.

// MARK: - Which sources a scan read

/// What the vault knows about its sources, so two scans can be told apart as
/// "the market moved" versus "a wallet was added or removed". Built from the
/// vault document or assembled by hand; analytics never reads the vault itself.
public struct ScanSourceContext: Equatable, Sendable {
  /// Keys (`PortfolioAnalytics.sourceKey(for:)`) of every source the next scan
  /// would read: saved wallets, exchange connections, and enabled manual
  /// holdings.
  public var savedSourceKeys: Set<String>
  /// When a wallet or exchange connection was added, by source key.
  public var sourceCreatedAt: [String: Date]

  public init(savedSourceKeys: Set<String>, sourceCreatedAt: [String: Date] = [:]) {
    self.savedSourceKeys = savedSourceKeys
    self.sourceCreatedAt = sourceCreatedAt
  }

  public init(document: VaultDocument) {
    var keys = Set<String>()
    var created: [String: Date] = [:]
    for wallet in document.wallets {
      guard
        let canonical = AddressDetection.canonicalAddress(wallet.address, family: wallet.chainKind)
      else { continue }
      let key = "wallet:\(wallet.chainKind.rawValue):\(canonical)"
      keys.insert(key)
      created[key] = wallet.createdAt
    }
    for connection in document.exchangeConnections {
      let key = "exchange:" + connection.id.uuidString.lowercased()
      keys.insert(key)
      created[key] = connection.createdAt
    }
    for holding in document.manualHoldings where holding.enabled {
      keys.insert("manual:" + holding.id.uuidString.lowercased())
    }
    self.init(savedSourceKeys: keys, sourceCreatedAt: created)
  }
}

// MARK: - Change attribution

public struct LocationAmountChange: Identifiable, Equatable, Sendable {
  public let id: String
  public let networkID: String
  public let networkLabel: String
  public let sourceID: String
  public let sourceLabel: String
  public let olderAmount: Double
  public let newerAmount: Double

  public var deltaAmount: Double { newerAmount - olderAmount }
}

/// One coin's change between two scans.
public struct CoinChange: Identifiable, Equatable, Sendable {
  public enum Status: String, Sendable {
    /// Not held in the older scan.
    case added
    /// Not held in the newer scan.
    case removed
    case changed
  }

  /// `CoinIdentity.key`.
  public let id: String
  public let symbol: String
  public let status: Status
  /// Total amount, priced or not.
  public let olderAmount: Double
  public let newerAmount: Double
  /// Value over priced amount; nil when nothing was priced in that scan.
  public let olderPriceUsd: Double?
  public let newerPriceUsd: Double?
  public let olderValueUsd: Double
  public let newerValueUsd: Double
  /// `newerValueUsd - olderValueUsd`.
  public let deltaUsd: Double
  /// `priced amount then * (price now - price then)`.
  public let priceEffectUsd: Double
  /// `(priced amount now - priced amount then) * price now`; for a coin that is
  /// no longer held, the old value negated.
  public let amountEffectUsd: Double
  /// The part of `deltaUsd` that is only a missing price in one of the scans
  /// (the coin was held in both but priced in one); zero otherwise.
  /// `priceEffectUsd + amountEffectUsd + valuationGapUsd == deltaUsd`.
  public let valuationGapUsd: Double
  /// Where the coin's amount moved, largest absolute change first.
  public let locationChanges: [LocationAmountChange]
}

public struct ChangeAttribution: Equatable, Sendable {
  public let olderRunID: UUID
  public let newerRunID: UUID
  public let olderDate: Date
  public let newerDate: Date
  public let olderTotalUsd: Double
  public let newerTotalUsd: Double
  public let totalDeltaUsd: Double
  public let priceEffectUsd: Double
  public let amountEffectUsd: Double
  public let valuationGapUsd: Double
  /// Coins whose amount or value changed, largest absolute change first.
  /// Unchanged coins are left out.
  public let coins: [CoinChange]
  /// True when the two scans did not read the same wallets, exchanges, and
  /// manual holdings, so part of the difference is not a market move.
  public let sourcesDiffer: Bool
  /// True when either scan had holdings without a price, so its total is a
  /// lower bound.
  public let hasUnpricedHoldings: Bool

  public var addedCoins: [CoinChange] { coins.filter { $0.status == .added } }
  public var removedCoins: [CoinChange] { coins.filter { $0.status == .removed } }
}

extension PortfolioAnalytics {
  /// Whether two scans read the same sources, so the difference between their
  /// totals is a market move rather than an added or removed wallet, exchange,
  /// or manual holding. `older` must precede `newer`.
  ///
  /// With a context this is exact: a source that only the newer scan has is
  /// fine unless it was added after the older scan, and one that only the older
  /// scan has is fine unless it is no longer saved. Without a context it is
  /// conservative: the scans must have read exactly the same sources.
  public static func runsShareSources(
    _ older: ScanRunRecord,
    _ newer: ScanRunRecord,
    context: ScanSourceContext? = nil
  ) -> Bool {
    guard older.inputCount == newer.inputCount else { return false }
    let olderKeys = Set(older.holdings.compactMap(sourceKey(for:)))
    let newerKeys = Set(newer.holdings.compactMap(sourceKey(for:)))
    guard olderKeys.filter({ $0.hasPrefix("manual:") }) == newerKeys.filter({ $0.hasPrefix("manual:") })
    else { return false }
    guard let context else { return olderKeys == newerKeys }
    for key in newerKeys.subtracting(olderKeys) {
      if let created = context.sourceCreatedAt[key], created > older.generatedAt { return false }
    }
    for key in olderKeys.subtracting(newerKeys) where !context.savedSourceKeys.contains(key) {
      return false
    }
    return true
  }

  /// What changed between two scans, coin by coin, with each coin's change
  /// split into price effect and amount effect (formulas in the file overview).
  /// Totals and effects use priced holdings only.
  public static func attribution(
    from older: ScanRunRecord,
    to newer: ScanRunRecord,
    context: ScanSourceContext? = nil
  ) -> ChangeAttribution {
    let olderCoins = coinTotals(older.holdings)
    let newerCoins = coinTotals(newer.holdings)
    var changes: [CoinChange] = []
    for key in Set(olderCoins.keys).union(newerCoins.keys) {
      if let change = coinChange(
        key: key, older: olderCoins[key], newer: newerCoins[key])
      {
        changes.append(change)
      }
    }
    changes.sort { lhs, rhs in
      if abs(lhs.deltaUsd) != abs(rhs.deltaUsd) { return abs(lhs.deltaUsd) > abs(rhs.deltaUsd) }
      if lhs.symbol != rhs.symbol { return lhs.symbol < rhs.symbol }
      return lhs.id < rhs.id
    }
    let olderTotal = totalValueUsd(older.holdings)
    let newerTotal = totalValueUsd(newer.holdings)
    return ChangeAttribution(
      olderRunID: older.id,
      newerRunID: newer.id,
      olderDate: older.generatedAt,
      newerDate: newer.generatedAt,
      olderTotalUsd: olderTotal,
      newerTotalUsd: newerTotal,
      totalDeltaUsd: newerTotal - olderTotal,
      priceEffectUsd: sum(changes.map(\.priceEffectUsd)),
      amountEffectUsd: sum(changes.map(\.amountEffectUsd)),
      valuationGapUsd: sum(changes.map(\.valuationGapUsd)),
      coins: changes,
      sourcesDiffer: !runsShareSources(older, newer, context: context),
      hasUnpricedHoldings: older.holdings.contains { !isPriced($0) }
        || newer.holdings.contains { !isPriced($0) }
    )
  }

  private struct CoinTotals {
    var symbol: String
    var amount: Double
    var pricedAmount: Double
    var valueUsd: Double
    var holdings: [TrackedAsset]

    var price: Double? { pricedAmount > 0 ? valueUsd / pricedAmount : nil }
  }

  private static func coinTotals(_ holdings: [TrackedAsset]) -> [String: CoinTotals] {
    var grouped: [String: [TrackedAsset]] = [:]
    for asset in holdings { grouped[CoinIdentity.key(for: asset), default: []].append(asset) }
    return grouped.mapValues { members in
      let ordered = members.sorted(by: holdingOrder)
      let priced = ordered.filter(isPriced)
      return CoinTotals(
        symbol: CoinIdentity.displaySymbol(for: ordered[0]),
        amount: sum(ordered.map(\.amount)),
        pricedAmount: sum(priced.map(\.amount)),
        valueUsd: sum(priced.map(\.valueUsd)),
        holdings: ordered
      )
    }
  }

  private static func coinChange(
    key: String,
    older: CoinTotals?,
    newer: CoinTotals?
  ) -> CoinChange? {
    let olderAmount = older?.amount ?? 0
    let newerAmount = newer?.amount ?? 0
    let olderValue = older?.valueUsd ?? 0
    let newerValue = newer?.valueUsd ?? 0
    guard olderAmount != newerAmount || olderValue != newerValue else { return nil }

    let olderPriced = older?.pricedAmount ?? 0
    let newerPriced = newer?.pricedAmount ?? 0
    var priceEffect = 0.0
    var amountEffect = 0.0
    var valuationGap = 0.0
    if olderPriced > 0, newerPriced > 0, let olderPrice = older?.price, let newerPrice = newer?.price
    {
      priceEffect = olderPriced * (newerPrice - olderPrice)
      amountEffect = (newerPriced - olderPriced) * newerPrice
    } else if olderPriced > 0 {
      // Priced before, not now: gone, or still held without a price.
      if newerAmount == 0 {
        amountEffect = -olderValue
      } else {
        valuationGap = -olderValue
      }
    } else if newerPriced > 0 {
      if olderAmount == 0 {
        amountEffect = newerValue
      } else {
        valuationGap = newerValue
      }
    }

    let status: CoinChange.Status
    if olderAmount == 0 {
      status = .added
    } else if newerAmount == 0 {
      status = .removed
    } else {
      status = .changed
    }
    return CoinChange(
      id: key,
      symbol: (newer ?? older)?.symbol ?? key,
      status: status,
      olderAmount: olderAmount,
      newerAmount: newerAmount,
      olderPriceUsd: older?.price,
      newerPriceUsd: newer?.price,
      olderValueUsd: olderValue,
      newerValueUsd: newerValue,
      deltaUsd: newerValue - olderValue,
      priceEffectUsd: priceEffect,
      amountEffectUsd: amountEffect,
      valuationGapUsd: valuationGap,
      locationChanges: locationChanges(older: older?.holdings ?? [], newer: newer?.holdings ?? [])
    )
  }

  private static func locationChanges(
    older: [TrackedAsset],
    newer: [TrackedAsset]
  ) -> [LocationAmountChange] {
    struct Accumulator {
      var network: GroupDescriptor
      var source: GroupDescriptor
      var older: [Double] = []
      var newer: [Double] = []
    }
    var byLocation: [String: Accumulator] = [:]
    func add(_ assets: [TrackedAsset], toNewer: Bool) {
      for asset in assets {
        let network = networkDescriptor(of: asset)
        let source = sourceDescriptor(of: asset)
        let id = "\(network.key)|\(source.key)"
        var entry = byLocation[id] ?? Accumulator(network: network, source: source)
        // Labels follow the newer scan when the location exists in both.
        if toNewer {
          entry.network = network
          entry.source = source
          entry.newer.append(asset.amount)
        } else {
          entry.older.append(asset.amount)
        }
        byLocation[id] = entry
      }
    }
    add(older, toNewer: false)
    add(newer, toNewer: true)
    return byLocation.compactMap { id, entry -> LocationAmountChange? in
      let olderAmount = sum(entry.older)
      let newerAmount = sum(entry.newer)
      guard olderAmount != newerAmount else { return nil }
      return LocationAmountChange(
        id: id,
        networkID: entry.network.key,
        networkLabel: entry.network.label,
        sourceID: entry.source.key,
        sourceLabel: entry.source.label,
        olderAmount: olderAmount,
        newerAmount: newerAmount
      )
    }.sorted { lhs, rhs in
      if abs(lhs.deltaAmount) != abs(rhs.deltaAmount) {
        return abs(lhs.deltaAmount) > abs(rhs.deltaAmount)
      }
      return lhs.id < rhs.id
    }
  }
}

// MARK: - Rank change

/// A coin's place in the value ranking of two scans (the slope chart).
public struct RankChange: Identifiable, Equatable, Sendable {
  /// `CoinIdentity.key`.
  public let id: String
  public let symbol: String
  /// 1 is the most valuable coin; nil when the coin has no priced value in
  /// that scan (absent, or held without a price).
  public let olderRank: Int?
  public let newerRank: Int?
  public let olderValueUsd: Double
  public let newerValueUsd: Double

  /// Positive when the coin moved toward rank 1; nil unless ranked in both.
  public var placesGained: Int? {
    guard let olderRank, let newerRank else { return nil }
    return olderRank - newerRank
  }
}

extension PortfolioAnalytics {
  public static func rankChanges(
    from older: ScanRunRecord,
    to newer: ScanRunRecord,
    limit: Int? = nil
  ) -> [RankChange] {
    rankChanges(from: older.holdings, to: newer.holdings, limit: limit)
  }

  /// Ranks coins by priced value in each set of holdings (ties by symbol) and
  /// pairs them up. With a `limit`, only coins inside that rank in either scan
  /// are returned. Coins ranked in the newer scan come first in rank order,
  /// then coins that only the older scan ranked.
  public static func rankChanges(
    from older: [TrackedAsset],
    to newer: [TrackedAsset],
    limit: Int? = nil
  ) -> [RankChange] {
    struct Ranked {
      var symbol: String
      var value: Double
      var rank: Int
    }
    func rank(_ holdings: [TrackedAsset]) -> [String: Ranked] {
      var grouped: [String: [TrackedAsset]] = [:]
      for asset in holdings where isPriced(asset) {
        grouped[CoinIdentity.key(for: asset), default: []].append(asset)
      }
      let entries = grouped.map { key, members -> (key: String, symbol: String, value: Double) in
        let ordered = members.sorted(by: holdingOrder)
        return (key, CoinIdentity.displaySymbol(for: ordered[0]), sum(ordered.map(\.valueUsd)))
      }.sorted { lhs, rhs in
        if lhs.value != rhs.value { return lhs.value > rhs.value }
        if lhs.symbol != rhs.symbol { return lhs.symbol < rhs.symbol }
        return lhs.key < rhs.key
      }
      var result: [String: Ranked] = [:]
      for (index, entry) in entries.enumerated() {
        result[entry.key] = Ranked(symbol: entry.symbol, value: entry.value, rank: index + 1)
      }
      return result
    }
    let olderRanks = rank(older)
    let newerRanks = rank(newer)
    var changes: [RankChange] = []
    for key in Set(olderRanks.keys).union(newerRanks.keys) {
      let before = olderRanks[key]
      let after = newerRanks[key]
      if let limit {
        let inside = (before.map { $0.rank <= limit } ?? false) || (after.map { $0.rank <= limit } ?? false)
        guard inside else { continue }
      }
      changes.append(
        RankChange(
          id: key,
          symbol: (after ?? before)?.symbol ?? key,
          olderRank: before?.rank,
          newerRank: after?.rank,
          olderValueUsd: before?.value ?? 0,
          newerValueUsd: after?.value ?? 0
        ))
    }
    return changes.sorted { lhs, rhs in
      switch (lhs.newerRank, rhs.newerRank) {
      case (let left?, let right?):
        if left != right { return left < right }
      case (_?, nil): return true
      case (nil, _?): return false
      case (nil, nil):
        if let left = lhs.olderRank, let right = rhs.olderRank, left != right { return left < right }
      }
      return lhs.id < rhs.id
    }
  }
}

// MARK: - Series across scans

/// Scans oldest first. Scans at the same instant fall back to their id so the
/// order never depends on how the caller's array happened to be sorted.
func orderedRuns(_ runs: [ScanRunRecord]) -> [ScanRunRecord] {
  runs.sorted { lhs, rhs in
    if lhs.generatedAt != rhs.generatedAt { return lhs.generatedAt < rhs.generatedAt }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}

/// One scan's headline numbers, from its holdings.
public struct RunTotal: Identifiable, Equatable, Sendable {
  /// The scan's id.
  public let id: UUID
  public let generatedAt: Date
  /// Sum of priced holdings. Equals `ScanRunRecord.totalUsd` for any scan the
  /// vault validator accepts.
  public let totalValueUsd: Double
  public let pricedHoldingCount: Int
  public let unpricedHoldingCount: Int
  /// Distinct coins held, priced or not.
  public let coinCount: Int
}

/// One coin in one scan; zeros when the coin was not held then.
public struct CoinSeriesPoint: Identifiable, Equatable, Sendable {
  /// The scan's id.
  public let id: UUID
  public let generatedAt: Date
  public let amount: Double
  public let valueUsd: Double
  public let priceUsd: Double?
}

public enum SeriesMeasure: String, Sendable {
  /// Priced value in USD.
  case valueUsd
  /// Coin amount, priced or not. Only meaningful for one coin (`coin:`), since
  /// amounts of different coins do not add up.
  case amount
}

public struct StackedLayer: Identifiable, Equatable, Sendable {
  /// The group key, or `StackedSeries.otherLayerID`.
  public let id: String
  public let label: String
  /// One value per scan, in `StackedSeries.runIDs` order, zero where absent.
  public let values: [Double]

  public var total: Double { values.reduce(0, +) }
}

public struct StackedSeries: Equatable, Sendable {
  public static let otherLayerID = "__other__"

  public let grouping: PortfolioGrouping
  public let measure: SeriesMeasure
  /// Scans oldest first.
  public let runIDs: [UUID]
  public let dates: [Date]
  /// Largest total across all scans first; the combined "Other" layer, when
  /// `maximumLayers` forced one, comes last.
  public let layers: [StackedLayer]
  /// Per-scan sum over every layer.
  public let totals: [Double]
}

extension PortfolioAnalytics {
  /// Value, holding counts, and coin count of each scan, oldest first.
  public static func runTotals(_ runs: [ScanRunRecord]) -> [RunTotal] {
    orderedRuns(runs).map { run in
      let (priced, unpriced) = partition(run.holdings)
      return RunTotal(
        id: run.id,
        generatedAt: run.generatedAt,
        totalValueUsd: sum(priced.map(\.valueUsd)),
        pricedHoldingCount: priced.count,
        unpricedHoldingCount: unpriced.count,
        coinCount: Set(run.holdings.map(CoinIdentity.key(for:))).count
      )
    }
  }

  /// One coin's amount, value, and price in every scan, oldest first. `coin` is
  /// a symbol or an identity key.
  public static func coinSeries(_ runs: [ScanRunRecord], coin: String) -> [CoinSeriesPoint] {
    let key = CoinIdentity.key(forSymbol: coin)
    return orderedRuns(runs).map { run in
      let members = run.holdings.filter { CoinIdentity.key(for: $0) == key }
      let priced = members.filter(isPriced)
      let pricedAmount = sum(priced.map(\.amount))
      let value = sum(priced.map(\.valueUsd))
      return CoinSeriesPoint(
        id: run.id,
        generatedAt: run.generatedAt,
        amount: sum(members.map(\.amount)),
        valueUsd: value,
        priceUsd: pricedAmount > 0 ? value / pricedAmount : nil
      )
    }
  }

  /// A measure split by a grouping across scans, for stacked-area charts: every
  /// layer has one value per scan, so layers always stack to `totals`. Pass
  /// `coin:` to follow one coin (for example its amount by state, in coins
  /// rather than dollars so price moves do not hide what the user did). With
  /// `maximumLayers`, the smallest layers beyond that count fold into one
  /// "Other" layer.
  public static func stackedSeries(
    _ runs: [ScanRunRecord],
    by grouping: PortfolioGrouping,
    coin: String? = nil,
    measure: SeriesMeasure = .valueUsd,
    maximumLayers: Int? = nil
  ) -> StackedSeries {
    let ordered = orderedRuns(runs)
    let coinKey = coin.map(CoinIdentity.key(forSymbol:))
    // A layer's label comes from the newest scan that has it; within one scan
    // the smallest spelling wins, so the choice never depends on input order.
    var labels: [String: (runIndex: Int, label: String)] = [:]
    var valuesByKey: [String: [[Double]]] = [:]
    for (index, run) in ordered.enumerated() {
      var perKey: [String: [Double]] = [:]
      for asset in run.holdings {
        if let coinKey, CoinIdentity.key(for: asset) != coinKey { continue }
        let contribution: Double
        switch measure {
        case .valueUsd:
          guard isPriced(asset) else { continue }
          contribution = asset.valueUsd
        case .amount:
          guard asset.amount.isFinite, asset.amount >= 0 else { continue }
          contribution = asset.amount
        }
        let descriptor = descriptor(of: asset, in: grouping)
        perKey[descriptor.key, default: []].append(contribution)
        if let existing = labels[descriptor.key] {
          if existing.runIndex < index
            || (existing.runIndex == index && descriptor.label < existing.label)
          {
            labels[descriptor.key] = (index, descriptor.label)
          }
        } else {
          labels[descriptor.key] = (index, descriptor.label)
        }
      }
      for (key, values) in perKey {
        var rows = valuesByKey[key] ?? Array(repeating: [], count: ordered.count)
        rows[index] = values
        valuesByKey[key] = rows
      }
    }

    var layers = valuesByKey.map { key, rows in
      StackedLayer(id: key, label: labels[key]?.label ?? key, values: rows.map(sum))
    }.sorted { lhs, rhs in
      if lhs.total != rhs.total { return lhs.total > rhs.total }
      if lhs.label != rhs.label { return lhs.label < rhs.label }
      return lhs.id < rhs.id
    }
    if let maximumLayers, maximumLayers >= 1, layers.count > maximumLayers {
      let kept = Array(layers.prefix(maximumLayers - 1))
      let folded = layers.dropFirst(maximumLayers - 1)
      let other = StackedLayer(
        id: StackedSeries.otherLayerID,
        label: "Other",
        values: ordered.indices.map { index in sum(folded.map { $0.values[index] }) }
      )
      layers = kept + [other]
    }
    return StackedSeries(
      grouping: grouping,
      measure: measure,
      runIDs: ordered.map(\.id),
      dates: ordered.map(\.generatedAt),
      layers: layers,
      totals: ordered.indices.map { index in sum(layers.map { $0.values[index] }) }
    )
  }
}

// MARK: - Daily series (calendar heatmap)

/// A calendar day in some time zone, without a time zone attached.
public struct CalendarDay: Hashable, Comparable, Identifiable, Sendable {
  public let year: Int
  public let month: Int
  public let day: Int

  /// `yyyy-MM-dd`.
  public var id: String { String(format: "%04d-%02d-%02d", year, month, day) }

  public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
    (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
  }
}

/// A day that has at least one scan, represented by the last scan of that day.
public struct DailyPortfolioPoint: Identifiable, Equatable, Sendable {
  public var id: String { day.id }
  public let day: CalendarDay
  /// Midnight starting `day` in the requested time zone.
  public let dayStart: Date
  /// The day's last scan.
  public let runID: UUID
  public let generatedAt: Date
  public let totalValueUsd: Double
  public let hasUnpricedHoldings: Bool
  /// The previous day that has a scan; nil for the first one.
  public let previousDay: CalendarDay?
  /// `totalValueUsd` less the previous day's, nil for the first day.
  public let changeUsd: Double?
  /// `changeUsd` over the previous day's total; nil for the first day or when
  /// that total was zero.
  public let changeFraction: Double?
}

extension PortfolioAnalytics {
  /// The last scan of each calendar day in `timeZone`, oldest day first, each
  /// with its change from the previous day that has data (gaps are skipped, not
  /// filled).
  public static func dailySeries(
    _ runs: [ScanRunRecord],
    timeZone: TimeZone
  ) -> [DailyPortfolioPoint] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    var lastRunByDay: [CalendarDay: (run: ScanRunRecord, dayStart: Date)] = [:]
    for run in orderedRuns(runs) {
      let parts = calendar.dateComponents([.year, .month, .day], from: run.generatedAt)
      guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
      // Oldest first, so a later scan of the same day replaces an earlier one.
      lastRunByDay[CalendarDay(year: year, month: month, day: day)] = (
        run, calendar.startOfDay(for: run.generatedAt)
      )
    }
    var points: [DailyPortfolioPoint] = []
    var previous: (day: CalendarDay, total: Double)?
    for day in lastRunByDay.keys.sorted() {
      guard let entry = lastRunByDay[day] else { continue }
      let total = totalValueUsd(entry.run.holdings)
      let change = previous.map { total - $0.total }
      points.append(
        DailyPortfolioPoint(
          day: day,
          dayStart: entry.dayStart,
          runID: entry.run.id,
          generatedAt: entry.run.generatedAt,
          totalValueUsd: total,
          hasUnpricedHoldings: entry.run.holdings.contains { !isPriced($0) },
          previousDay: previous?.day,
          changeUsd: change,
          changeFraction: previous.flatMap { $0.total > 0 ? (total - $0.total) / $0.total : nil }
        ))
      previous = (day, total)
    }
    return points
  }
}
