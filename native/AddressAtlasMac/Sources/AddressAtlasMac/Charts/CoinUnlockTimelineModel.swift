import AddressAtlasCore
import Foundation

/// When a coin's unbonding amounts free up, and how the timeline reads. From a
/// coin summary plus (optionally) the saved runs, which tell when the
/// unbonding was first seen. Pure and `Sendable`; "today" is passed in.
struct CoinUnlockTimelineModel: Equatable, Sendable {
  /// An unbonding amount with a known completion time.
  struct DatedUnlock: Identifiable, Equatable, Sendable {
    var id: Int { index }
    let index: Int
    let date: Date
    let amount: Double
    let valueUsd: Double
    /// The unlock date is at or before `now`, yet the latest scan still shows
    /// the amount as unbonding.
    let hasPassed: Bool
    /// Whole calendar days from today to the unlock day, in the chart's time
    /// zone; zero or negative once it is today or past.
    let daysAway: Int
  }

  /// Unbonding amounts whose completion time the network does not report.
  struct UndatedUnlock: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
      /// Solana stake accounts in cooldown free up when the epoch ends.
      case endOfEpoch
      case notReported
    }
    let amount: Double
    let valueUsd: Double
    let reason: Reason
  }

  let symbol: String
  let now: Date
  let timeZone: TimeZone
  /// The first scan of the latest unbroken stretch of scans that showed this
  /// coin unbonding; nil when the runs say nothing about it.
  let seenSince: Date?
  /// Soonest first.
  let dated: [DatedUnlock]
  let undated: UndatedUnlock?
  let priced: Bool

  init(
    summary: CoinSummary,
    runs: [ScanRunRecord] = [],
    now: Date,
    timeZone: TimeZone
  ) {
    symbol = summary.symbol
    self.now = now
    self.timeZone = timeZone
    priced = summary.priceUsd != nil
    seenSince = Self.firstSeenUnbonding(runs: runs, coinKey: summary.id)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let today = calendar.startOfDay(for: now)
    var dated: [DatedUnlock] = []
    var undated: UndatedUnlock?
    let isSolana = summary.locations.contains {
      $0.networkID == "solana" && $0.states.contains(.unbonding)
    }
    for unlock in summary.unlocks where unlock.amount > 0 {
      if let date = unlock.date {
        let days =
          calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
        dated.append(
          DatedUnlock(
            index: dated.count, date: date, amount: unlock.amount, valueUsd: unlock.valueUsd,
            hasPassed: date <= now, daysAway: days))
      } else {
        undated = UndatedUnlock(
          amount: (undated?.amount ?? 0) + unlock.amount,
          valueUsd: (undated?.valueUsd ?? 0) + unlock.valueUsd,
          reason: isSolana ? .endOfEpoch : .notReported)
      }
    }
    self.dated = dated
    self.undated = undated
  }

  var isEmpty: Bool { dated.isEmpty && undated == nil }

  /// Sum of everything unbonding.
  var totalAmount: Double {
    dated.map(\.amount).reduce(0, +) + (undated?.amount ?? 0)
  }

  // MARK: Derived runs information

  /// The first scan of the unbroken stretch, ending at the latest scan, in
  /// which `coinKey` has an unbonding holding.
  static func firstSeenUnbonding(runs: [ScanRunRecord], coinKey: String) -> Date? {
    let ordered = HistoryRuns.ordered(runs)
    func hasUnbonding(_ run: ScanRunRecord) -> Bool {
      run.holdings.contains {
        CoinIdentity.key(for: $0) == coinKey && HoldingState($0) == .unbonding && $0.amount > 0
      }
    }
    var first: Date?
    for run in ordered.reversed() {
      guard hasUnbonding(run) else { break }
      first = run.generatedAt
    }
    return first
  }

  // MARK: Wording

  func amountText(_ amount: Double) -> String {
    "\(HistoryChartFormat.amount(amount)) \(symbol)"
  }

  func dayText(_ date: Date) -> String {
    HistoryChartFormat.day(date, timeZone: timeZone)
  }

  /// "24.79 ATOM free on 16 Nov", or for one already past, "24.79 ATOM \u{00B7}
  /// Unlocked on 16 Nov. Scan again to see it as liquid."
  func sentence(for unlock: DatedUnlock) -> String {
    if unlock.hasPassed {
      return
        "\(amountText(unlock.amount)) \u{00B7} Unlocked on \(dayText(unlock.date)). Scan again to see it as liquid."
    }
    return "\(amountText(unlock.amount)) free on \(dayText(unlock.date))"
  }

  /// "in 12 days", "tomorrow", "today"; nil once it has passed.
  func relativeText(for unlock: DatedUnlock) -> String? {
    guard !unlock.hasPassed else { return nil }
    switch unlock.daysAway {
    case ...0: return "today"
    case 1: return "tomorrow"
    default: return "in \(unlock.daysAway) days"
    }
  }

  func sentence(for undated: UndatedUnlock) -> String {
    switch undated.reason {
    case .endOfEpoch:
      return "\(amountText(undated.amount)) unlocks at the end of the current epoch"
    case .notReported:
      return "\(amountText(undated.amount)): Unlock time not reported by the network"
    }
  }

  /// "Seen unbonding on 21 Oct", from the saved scans.
  var seenSinceText: String? {
    seenSince.map { "Seen unbonding on \(dayText($0))" }
  }

  var spokenSummary: String {
    var sentences = ["\(symbol) unbonding, \(amountText(totalAmount))."]
    sentences += dated.map { sentence(for: $0) + ($0.hasPassed ? "" : ", \(relativeText(for: $0) ?? "")") }
    if let undated { sentences.append(sentence(for: undated)) }
    if let seenSinceText { sentences.append(seenSinceText) }
    return sentences.joined(separator: ". ")
  }
}

// MARK: - Timeline geometry

/// Positions of the markers on the timeline, in a unit interval, so the view
/// and tests agree. The line runs from the first scan that showed the
/// unbonding (or today, when that is unknown) to the last unlock.
struct CoinUnlockTimelineScale: Equatable, Sendable {
  let start: Date
  let end: Date

  init(model: CoinUnlockTimelineModel) {
    let first = model.seenSince.map { min($0, model.now) } ?? model.now
    let last = max(model.dated.map(\.date).max() ?? model.now, model.now)
    start = first
    // A zero-length line (everything is today) is stretched to a day.
    end = last > first ? last : first.addingTimeInterval(86_400)
  }

  /// 0 at `start`, 1 at `end`.
  func position(of date: Date) -> Double {
    let span = end.timeIntervalSince(start)
    guard span > 0 else { return 0 }
    return min(max(date.timeIntervalSince(start) / span, 0), 1)
  }
}
