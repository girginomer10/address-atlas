import CryptoKit
import Foundation

public struct ExchangeCredentialVault: Sendable {
  private let crypto: VaultCrypto

  public init(crypto: VaultCrypto = VaultCrypto()) {
    self.crypto = crypto
  }

  public func seal(_ credentials: ExchangeCredentials, vaultKey: Data, connectionId: UUID) throws -> EncryptedVaultEnvelope {
    let key = try crypto.deriveKey(from: vaultKey, purpose: .exchangeCredentials)
    return try crypto.sealJSON(credentials, with: key, keyId: "exchange-\(connectionId.uuidString)")
  }

  public func open(
    _ envelope: EncryptedVaultEnvelope,
    vaultKey: Data,
    connectionId: UUID
  ) throws -> ExchangeCredentials {
    guard envelope.keyId == "exchange-\(connectionId.uuidString)" else {
      throw VaultCryptoError.invalidEnvelope
    }
    let key = try crypto.deriveKey(from: vaultKey, purpose: .exchangeCredentials)
    return try crypto.openJSON(ExchangeCredentials.self, envelope: envelope, with: key)
  }
}
