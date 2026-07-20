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
          "Address Atlas could not access the vault key in Keychain. Unlock this Mac, then try again."
      case .invalidItem:
        return "The saved vault key is invalid. Restore your recovery kit before making changes."
      }
    }
    if let crypto = error as? VaultCryptoError {
      switch crypto {
      case .authenticationFailed:
        return "Vault integrity verification failed. No data was changed."
      case .invalidKeyLength:
        return "The vault key is invalid. Restore your recovery kit before making changes."
      case .invalidBase64, .invalidHex, .invalidEnvelope:
        return "Encrypted vault data is invalid or damaged. No data was changed."
      }
    }
    if let store = error as? EncryptedSQLiteVaultStoreError {
      if store == .staleDocument {
        return store.errorDescription
      }
      return
        "The encrypted local vault could not be read or saved. Check available disk space and file permissions, then try again."
    }
    if error is URLError {
      return "The network request could not be completed. Check your connection and try again."
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
