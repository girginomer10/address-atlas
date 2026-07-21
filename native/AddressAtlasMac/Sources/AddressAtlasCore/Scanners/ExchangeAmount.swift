import Foundation

/// A nonnegative provider amount represented exactly in base 10.
///
/// Exchange wire formats use decimal strings, while binary floating point can
/// silently discard both large integer units and high-scale fractional units.
/// This type accepts the finite range Foundation's checked decimal arithmetic
/// can preserve without rounding and exposes a canonical, locale-independent
/// string for persistence and display.
public struct ExchangeAmount: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
  enum ParseResult {
    case value(ExchangeAmount)
    case outOfRange
    case invalid
  }

  private static let posixLocale = Locale(identifier: "en_US_POSIX")
  private static let maximumWireByteCount = 512
  private static let maximumSignificantDigitCount = 38

  public let canonicalString: String
  static let zero = ExchangeAmount(decimal: 0)

  public init?(providerString: String) {
    guard case .value(let amount) = Self.parse(providerString) else { return nil }
    self = amount
  }

  public init?(legacyDouble: Double) {
    guard legacyDouble.isFinite, legacyDouble >= 0,
      case .value(let amount) = Self.parse(String(legacyDouble))
    else { return nil }
    self = amount
  }

  public var description: String { canonicalString }

  public var approximateDouble: Double? {
    let value = NSDecimalNumber(decimal: decimalValue).doubleValue
    return value.isFinite && value >= 0 ? value : nil
  }

  var isPositive: Bool { decimalValue > 0 }

  func adding(_ other: ExchangeAmount) -> ExchangeAmount? {
    var lhs = decimalValue
    var rhs = other.decimalValue
    var result = Decimal()
    guard NSDecimalAdd(&result, &lhs, &rhs, .plain) == .noError else { return nil }
    return ExchangeAmount(decimal: result)
  }

  static func parse(_ raw: String) -> ParseResult {
    guard !raw.isEmpty, raw.utf8.count <= maximumWireByteCount,
      raw.range(
        of: #"^\+?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
        options: .regularExpression
      ) != nil
    else { return .invalid }

    let mantissa = raw.prefix { $0 != "e" && $0 != "E" }
    let digits = mantissa.filter { $0 >= "0" && $0 <= "9" }
    let withoutLeadingZeros = digits.drop { $0 == "0" }
    let significantDigitCount = withoutLeadingZeros.reversed().drop { $0 == "0" }.count
    if significantDigitCount == 0 {
      return .value(ExchangeAmount(decimal: 0))
    }
    guard significantDigitCount <= maximumSignificantDigitCount,
      let decimal = Decimal(string: raw, locale: posixLocale), decimal >= 0
    else { return .outOfRange }
    return .value(ExchangeAmount(decimal: decimal))
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    guard case .value(let amount) = Self.parse(raw) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Exchange amount is not a supported nonnegative decimal value."
      )
    }
    self = amount
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(canonicalString)
  }

  private init(decimal: Decimal) {
    var decimal = decimal
    canonicalString = NSDecimalString(&decimal, Self.posixLocale)
  }

  private var decimalValue: Decimal {
    // Every instance is created from a checked Decimal and its canonical
    // string, so reparsing cannot fail or lose precision.
    Decimal(string: canonicalString, locale: Self.posixLocale)!
  }
}
