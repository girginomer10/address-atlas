import Foundation

public enum UserInputValidation {
  public static let maximumCoinGeckoIdLength = 128

  /// Parses a user-entered decimal amount using the user's locale without
  /// silently accepting partial, non-finite, or negative input. Locale-aware
  /// parsing is important here: `1,000` is one thousand in English locales but
  /// one in locales where comma is the decimal separator.
  public static func nonnegativeFiniteNumber(_ raw: String, locale: Locale = .current) -> Double? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 128 else { return nil }

    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    formatter.isLenient = false
    formatter.generatesDecimalNumbers = true

    guard let number = formatter.number(from: trimmed) else { return nil }
    let value = number.doubleValue
    guard
          value.isFinite,
          value >= 0
    else {
      return nil
    }
    return value
  }

  /// Returns the canonical CoinGecko identifier accepted by both the editor
  /// and scanner boundary. CoinGecko identifiers are deliberately restricted
  /// to their ASCII slug form so Unicode lookalikes cannot pass one boundary
  /// and fail at another.
  public static func normalizedCoinGeckoId(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !trimmed.isEmpty,
      trimmed.utf8.count <= maximumCoinGeckoIdLength,
      trimmed.utf8.allSatisfy({ byte in
        (65...90).contains(byte)
          || (97...122).contains(byte)
          || (48...57).contains(byte)
          || byte == 45
      })
    else {
      return nil
    }
    return trimmed.lowercased()
  }
}
