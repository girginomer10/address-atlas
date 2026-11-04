import AddressAtlasCore
import Foundation

/// The rank of every coin in an earlier scan against the latest scan (the
/// slope chart): which scans are compared, which coins are drawn, and in which
/// slot of each column.
struct SlopeModel: Equatable {
  /// Scans this far back (and no further) are candidates for the earlier side.
  static let windowDays = 30

  struct Row: Identifiable, Equatable {
    /// `CoinIdentity.key`.
    let id: String
    let symbol: String
    let olderRank: Int?
    let newerRank: Int?
    let olderValueUsd: Double
    let newerValueUsd: Double
    /// Slot (row index) in the left and right column.
    let leftSlot: Int
    let rightSlot: Int
    /// True when the coin sits below the ranked rows on that side: it was
    /// ranked past the limit, or not ranked at all (new or gone).
    let leftOutside: Bool
    let rightOutside: Bool

    /// Positive when the coin moved toward rank 1; nil unless ranked in both.
    var placesGained: Int? {
      guard let olderRank, let newerRank else { return nil }
      return olderRank - newerRank
    }

    var isNew: Bool { olderRank == nil && newerRank != nil }
    var isGone: Bool { newerRank == nil && olderRank != nil }
  }

  let olderRunID: UUID
  let newerRunID: UUID
  let olderDate: Date
  let newerDate: Date
  /// True when the two scans did not read the same sources, so some rank moves
  /// are a wallet appearing rather than the market.
  let sourcesDiffer: Bool
  let rows: [Row]
  /// Ranked rows drawn at the top of each column (rank 1 up to this).
  let rankedSlots: Int
  /// Rows in each column including the gap and the rows below it.
  let slotCount: Int

  var hasUnrankedRows: Bool { rows.contains { $0.isNew || $0.isGone } }

  // MARK: Choosing the two scans

  /// The latest scan, and the oldest scan from the last 30 days that read the
  /// same sources as it; when there is none (including when the only earlier
  /// scans are older than 30 days), the scan before the latest. Nil with fewer
  /// than two scans.
  static func choosePair(
    runs: [ScanRunRecord],
    context: ScanSourceContext?
  ) -> (older: ScanRunRecord, newer: ScanRunRecord)? {
    let ordered = HistoryRuns.ordered(runs)
    guard let latest = ordered.last, ordered.count >= 2 else { return nil }
    let earlier = ordered.dropLast()
    let cutoff = latest.generatedAt.addingTimeInterval(-Double(windowDays) * 86_400)
    let inWindow = earlier.filter { $0.generatedAt >= cutoff }
    if let oldest = inWindow.first(where: {
      PortfolioAnalytics.runsShareSources($0, latest, context: context)
    }) {
      return (oldest, latest)
    }
    // Nothing in the window read the same sources: the closest scan differs
    // least, and the view says the sources differ.
    return (earlier[earlier.count - 1], latest)
  }

  // MARK: Building the rows

  /// `desiredLimit` ranks per column; reduced until the rows (ranked, a gap,
  /// and unranked) fit in `maximumSlots`.
  static func make(
    older: ScanRunRecord,
    newer: ScanRunRecord,
    context: ScanSourceContext?,
    desiredLimit: Int,
    maximumSlots: Int
  ) -> SlopeModel {
    var limit = max(2, desiredLimit)
    var model = build(older: older, newer: newer, context: context, limit: limit)
    while model.slotCount > maximumSlots, limit > 3 {
      limit -= 1
      model = build(older: older, newer: newer, context: context, limit: limit)
    }
    return model
  }

  private static func build(
    older: ScanRunRecord, newer: ScanRunRecord, context: ScanSourceContext?, limit: Int
  ) -> SlopeModel {
    let changes = PortfolioAnalytics.rankChanges(from: older, to: newer, limit: limit)
    let ranked = changes.compactMap { $0.olderRank.flatMap { $0 <= limit ? $0 : nil } }
      + changes.compactMap { $0.newerRank.flatMap { $0 <= limit ? $0 : nil } }
    let rankedSlots = min(limit, ranked.max() ?? 0)

    func isOutside(_ rank: Int?) -> Bool { rank.map { $0 > rankedSlots } ?? true }
    let leftOutside = changes.filter { isOutside($0.olderRank) }.sorted {
      order($0.newerRank, $1.newerRank, $0.id, $1.id)
    }
    let rightOutside = changes.filter { isOutside($0.newerRank) }.sorted {
      order($0.olderRank, $1.olderRank, $0.id, $1.id)
    }
    var leftSlots: [String: Int] = [:]
    var rightSlots: [String: Int] = [:]
    for (index, change) in leftOutside.enumerated() { leftSlots[change.id] = rankedSlots + 1 + index }
    for (index, change) in rightOutside.enumerated() { rightSlots[change.id] = rankedSlots + 1 + index }
    let outsideRows = max(leftOutside.count, rightOutside.count)

    let rows = changes.map { change -> Row in
      Row(
        id: change.id, symbol: change.symbol, olderRank: change.olderRank,
        newerRank: change.newerRank, olderValueUsd: change.olderValueUsd,
        newerValueUsd: change.newerValueUsd,
        leftSlot: leftSlots[change.id] ?? ((change.olderRank ?? 1) - 1),
        rightSlot: rightSlots[change.id] ?? ((change.newerRank ?? 1) - 1),
        leftOutside: leftSlots[change.id] != nil, rightOutside: rightSlots[change.id] != nil)
    }
    return SlopeModel(
      olderRunID: older.id, newerRunID: newer.id, olderDate: older.generatedAt,
      newerDate: newer.generatedAt,
      sourcesDiffer: !PortfolioAnalytics.runsShareSources(older, newer, context: context),
      rows: rows, rankedSlots: rankedSlots,
      slotCount: rankedSlots + (outsideRows > 0 ? 1 + outsideRows : 0))
  }

  /// Rank ascending, unranked last, then by id.
  private static func order(_ lhs: Int?, _ rhs: Int?, _ lhsID: String, _ rhsID: String) -> Bool {
    switch (lhs, rhs) {
    case (let left?, let right?) where left != right: return left < right
    case (_?, nil): return true
    case (nil, _?): return false
    default: return lhsID < rhsID
    }
  }

  // MARK: Copy

  static func movement(_ row: Row) -> String {
    if row.isNew { return "new" }
    if row.isGone { return "out" }
    guard let gained = row.placesGained else { return "" }
    if gained > 0 { return "\u{25B2}\(gained)" }
    if gained < 0 { return "\u{25BC}\(-gained)" }
    return "\u{2013}"
  }

  static func spokenMovement(_ row: Row) -> String {
    if row.isNew { return "new in the ranking" }
    if row.isGone { return "no longer ranked" }
    guard let gained = row.placesGained else { return "not ranked" }
    if gained > 0 { return "up \(HistoryChartFormat.count(gained, "place"))" }
    if gained < 0 { return "down \(HistoryChartFormat.count(-gained, "place"))" }
    return "no change in rank"
  }

  func tooltipLines(for row: Row) -> [String] {
    var lines = [row.symbol]
    switch (row.olderRank, row.newerRank) {
    case (let before?, let after?):
      lines.append("Rank \(before) to \(after), \(Self.spokenMovement(row))")
    case (nil, let after?):
      lines.append("New at rank \(after)")
    case (let before?, nil):
      lines.append("Was rank \(before), no longer ranked")
    default:
      lines.append("Not ranked")
    }
    lines.append(
      "\(HistoryChartFormat.usd(row.olderValueUsd)) to \(HistoryChartFormat.usd(row.newerValueUsd))")
    return lines
  }

  func accessibilityLabel(for row: Row) -> String {
    tooltipLines(for: row).joined(separator: ", ")
  }

  func summary(timeZone: TimeZone) -> String {
    let before = HistoryChartFormat.day(olderDate, timeZone: timeZone)
    let after = HistoryChartFormat.day(newerDate, timeZone: timeZone)
    var text = "Rank of each coin by value, \(before) against \(after). "
    let movers = rows.compactMap { row -> (Row, Int)? in
      guard let gained = row.placesGained, gained != 0 else { return nil }
      return (row, gained)
    }.sorted { abs($0.1) > abs($1.1) }.prefix(3)
    if movers.isEmpty {
      text += "No coin changed rank. "
    } else {
      text +=
        "Biggest moves: "
        + movers.map { "\($0.0.symbol) \(Self.spokenMovement($0.0))" }.joined(separator: ", ")
        + ". "
    }
    let newCoins = rows.filter(\.isNew).map(\.symbol)
    let goneCoins = rows.filter(\.isGone).map(\.symbol)
    if !newCoins.isEmpty { text += "New: \(newCoins.joined(separator: ", ")). " }
    if !goneCoins.isEmpty { text += "No longer ranked: \(goneCoins.joined(separator: ", ")). " }
    if sourcesDiffer { text += "The scans read different sources, so some moves are not market moves." }
    return text.trimmingCharacters(in: .whitespaces)
  }
}
