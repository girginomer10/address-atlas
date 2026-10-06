import AddressAtlasCore
import Foundation

struct UserFacingAppError: Error, Equatable, LocalizedError, Sendable {
  var message: String

  var errorDescription: String? { message }
}

/// The single UI boundary for errors. Framework/NSError descriptions and Swift
/// type names are never rendered directly; only explicitly localized domain
/// errors cross this boundary, with a privacy-safe generic fallback.
enum UserFacingErrorMapper {
  static func message(for error: Error) -> String? {
    if error is CancellationError { return nil }
    if case PasskeyAuthenticationError.cancelled = error { return nil }

    if let keychain = error as? KeychainVaultKeyStoreError {
      switch keychain {
      case .unexpectedStatus:
        return
          "Address Atlas couldn't read its encryption key from Keychain. Unlock this \(PlatformCopy.deviceNoun), then try again."
      case .invalidItem:
        return
          "This \(PlatformCopy.deviceNounPossessive) encryption key is damaged. Restore your recovery kit before making changes."
      }
    }
    if let crypto = error as? VaultCryptoError {
      switch crypto {
      case .authenticationFailed:
        return "Your encrypted data couldn't be verified. Nothing was changed."
      case .invalidKeyLength:
        return "The encryption key isn't valid. Restore your recovery kit before making changes."
      case .invalidBase64, .invalidHex, .invalidEnvelope:
        return "Your encrypted data is damaged or unreadable. Nothing was changed."
      }
    }
    if let store = error as? EncryptedSQLiteVaultStoreError {
      if store == .staleDocument {
        return
          "Your portfolio changed in another Address Atlas window. Reopen the app before saving again."
      }
      return
        "Your portfolio couldn't be read or saved on this \(PlatformCopy.deviceNoun). Check that there's free storage space, then try again."
    }
    if error is URLError {
      return "Couldn't connect. Check your internet connection and try again."
    }
    if let exchange = error as? ExchangeClientError,
      case .httpError(let statusCode, let message) = exchange
    {
      return ExchangeClientError.friendlyHTTPMessage(statusCode: statusCode, providerMessage: message)
    }

    // Domain errors intentionally conform to LocalizedError with reviewed,
    // secret-free messages. Foundation's raw localizedDescription is never a
    // fallback because it often exposes framework domains and implementation
    // type names.
    if let localized = error as? any LocalizedError,
      let description = localized.errorDescription,
      !description.isEmpty
    {
      return sanitized(description)
    }
    return "Something went wrong, but no data was changed. Try again."
  }

  private static func sanitized(_ input: String) -> String {
    let collapsed = String(
      input.unicodeScalars.map { scalar -> Character in
        CharacterSet.controlCharacters.contains(scalar) ? " " : Character(String(scalar))
      }
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " "))
    let scalars = collapsed.unicodeScalars
    guard scalars.count > 500 else { return collapsed }
    return String(String.UnicodeScalarView(scalars.prefix(500))) + "…"
  }
}

/// Scan warnings are produced by the scanner, which only sees addresses, as
/// "<Network> · <0x1234...abcd>: <message>". Before a snapshot is saved the
/// short address is replaced with the wallet's readable name, giving
/// "Base · Ethereum wallet: …". A short address shared by two saved wallets
/// is left as is rather than guessed.
enum ScanWarningCopy {
  static func namingWallets(in warnings: [String], wallets: [WalletRecord]) -> [String] {
    let displayNames = AppState.walletDisplayNames(wallets)
    var nameByHint: [String: String] = [:]
    var ambiguousHints = Set<String>()
    for wallet in wallets {
      guard let hint = shortAddress(wallet.address), let name = displayNames[wallet.id] else {
        continue
      }
      if let existing = nameByHint[hint], existing != name {
        ambiguousHints.insert(hint)
      }
      nameByHint[hint] = name
    }
    for hint in ambiguousHints { nameByHint.removeValue(forKey: hint) }
    guard !nameByHint.isEmpty else { return warnings }
    return warnings.map { warning in
      guard let separator = warning.range(of: " · "),
        let colon = warning.range(of: ": ", range: separator.upperBound..<warning.endIndex)
      else { return warning }
      let hint = String(warning[separator.upperBound..<colon.lowerBound])
      guard let name = nameByHint[hint] else { return warning }
      return warning.replacingCharacters(in: separator.upperBound..<colon.lowerBound, with: name)
    }
  }

  /// Mirrors the scanner's short address form (first six and last four
  /// characters); addresses too short to abbreviate have no hint.
  private static func shortAddress(_ address: String) -> String? {
    let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 12 else { return nil }
    return "\(trimmed.prefix(6))...\(trimmed.suffix(4))"
  }
}
