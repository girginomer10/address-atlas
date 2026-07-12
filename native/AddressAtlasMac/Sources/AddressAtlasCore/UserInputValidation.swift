import Foundation

public enum UserInputValidation {
  /// Parses a user-entered decimal amount without silently accepting partial,
  /// non-finite, or negative input. A single comma is accepted as a decimal
  /// separator so common localized input such as `1,5` behaves predictably.
  public static func nonnegativeFiniteNumber(_ raw: String) -> Double? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !(trimmed.contains(",") && trimmed.contains(".")) else { return nil }
    let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
    let pattern = #"^\+?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$"#
    guard normalized.range(of: pattern, options: .regularExpression) != nil,
          let value = Double(normalized),
          value.isFinite,
          value >= 0
    else {
      return nil
    }
    return value
  }
}
