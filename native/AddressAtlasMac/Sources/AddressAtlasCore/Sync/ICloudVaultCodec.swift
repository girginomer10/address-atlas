import CryptoKit
import Foundation

/// The cloud transport never receives the local vault key or legacy server session.
/// Credentials are rewrapped under a separate cloud key, then the entire document
/// is authenticated against the iCloud account and immutable snapshot revision.
public struct ICloudVaultCodec: Sendable {
  public static let maximumAssetBytes = 90_000_000
  public init() {}

  public func seal(_ document: VaultDocument, localKey: Data, cloudKey: Data,
                   account: String, revision: String) throws -> Data {
    var clean = try rewrap(document, from: localKey, to: cloudKey)
    clean.syncState = SyncState()
    clean.iCloudState = nil
    try VaultDocumentSemanticValidator.validate(clean)
    try VaultDocumentSemanticValidator.validateExchangeCredentialPayloads(in: clean, vaultKey: cloudKey)
    let crypto = VaultCrypto()
    let envelope = try crypto.sealJSON(clean,
      with: crypto.deriveKey(from: cloudKey, purpose: .syncBlob),
      keyId: "icloud-v1", schemaVersion: VaultDocument.currentSchemaVersion,
      authenticatedData: binding(account, revision))
    let data = try JSONEncoder.addressAtlas.encode(envelope)
    guard data.count <= Self.maximumAssetBytes else { throw VaultCryptoError.invalidEnvelope }
    return data
  }

  public func open(_ data: Data, localKey: Data, cloudKey: Data,
                   account: String, revision: String) throws -> VaultDocument {
    guard data.count <= Self.maximumAssetBytes else { throw VaultCryptoError.invalidEnvelope }
    let envelope = try JSONDecoder.addressAtlas.decode(EncryptedVaultEnvelope.self, from: data)
    guard envelope.keyId == "icloud-v1" else { throw VaultCryptoError.invalidEnvelope }
    let crypto = VaultCrypto()
    let decoded = try crypto.openJSON(VaultDocument.self, envelope: envelope,
      with: crypto.deriveKey(from: cloudKey, purpose: .syncBlob),
      authenticatedData: binding(account, revision))
    guard decoded.syncState == SyncState(), decoded.iCloudState == nil else {
      throw VaultCryptoError.invalidEnvelope
    }
    try VaultDocumentSemanticValidator.validate(decoded)
    try VaultDocumentSemanticValidator.validateExchangeCredentialPayloads(in: decoded, vaultKey: cloudKey)
    var result = try rewrap(decoded, from: cloudKey, to: localKey)
    result.iCloudState = ICloudVaultState(account: account, revision: revision)
    return result
  }

  private func binding(_ account: String, _ revision: String) -> Data {
    Data("address-atlas-icloud-v1\u{0}\(account)\u{0}\(revision)".utf8)
  }

  private func rewrap(_ document: VaultDocument, from: Data, to: Data) throws -> VaultDocument {
    var result = document
    let credentials = ExchangeCredentialVault()
    for index in result.exchangeConnections.indices {
      let connection = result.exchangeConnections[index]
      let plain = try credentials.open(connection.encryptedCredentials,
        vaultKey: from, connectionId: connection.id)
      result.exchangeConnections[index].encryptedCredentials = try credentials.seal(
        plain, vaultKey: to, connectionId: connection.id)
    }
    return result
  }
}
