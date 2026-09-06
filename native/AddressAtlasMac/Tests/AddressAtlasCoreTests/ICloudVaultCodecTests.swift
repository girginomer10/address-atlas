import XCTest
@testable import AddressAtlasCore

final class ICloudVaultCodecTests: XCTestCase {
  func testDifferentMacKeysRoundTripAndCredentialsRemainUsable() throws {
    let crypto = VaultCrypto()
    let firstKey = try crypto.generateVaultKey()
    let secondKey = try crypto.generateVaultKey()
    let cloudKey = try crypto.generateVaultKey()
    let id = UUID()
    let credentialVault = ExchangeCredentialVault()
    let credentials = ExchangeCredentials(apiKey: "test-public-key", secret: "test-secret")
    let connection = ExchangeConnectionRecord(id: id, provider: .coinbase, label: "Test",
      encryptedCredentials: try credentialVault.seal(credentials, vaultKey: firstKey, connectionId: id))
    var document = VaultDocument(exchangeConnections: [connection])
    document.syncState.serverURL = "https://retired.example"
    document.syncState.sessionToken = "never-upload-this-token"
    document.iCloudState = ICloudVaultState(account: "old-account", revision: "old-revision")
    let codec = ICloudVaultCodec()
    let data = try codec.seal(document, localKey: firstKey, cloudKey: cloudKey,
      account: "account", revision: "revision")
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("test-secret"))
    let restored = try codec.open(data, localKey: secondKey, cloudKey: cloudKey,
      account: "account", revision: "revision")
    XCTAssertEqual(restored.syncState, SyncState())
    XCTAssertEqual(restored.iCloudState?.revision, "revision")
    let opened = try credentialVault.open(restored.exchangeConnections[0].encryptedCredentials,
      vaultKey: secondKey, connectionId: id)
    XCTAssertEqual(opened.secret, credentials.secret)
    XCTAssertThrowsError(try credentialVault.open(restored.exchangeConnections[0].encryptedCredentials,
      vaultKey: firstKey, connectionId: id))
  }

  func testAccountRevisionKeyAndTamperingAreAuthenticated() throws {
    let crypto = VaultCrypto()
    let key = try crypto.generateVaultKey()
    let codec = ICloudVaultCodec()
    let data = try codec.seal(VaultDocument(), localKey: key, cloudKey: key,
      account: "alice", revision: "v1")
    XCTAssertThrowsError(try codec.open(data, localKey: key, cloudKey: key,
      account: "bob", revision: "v1"))
    XCTAssertThrowsError(try codec.open(data, localKey: key, cloudKey: key,
      account: "alice", revision: "v2"))
    XCTAssertThrowsError(try codec.open(data, localKey: key, cloudKey: crypto.generateVaultKey(),
      account: "alice", revision: "v1"))
    var altered = data
    altered[altered.count / 2] ^= 1
    XCTAssertThrowsError(try codec.open(altered, localKey: key, cloudKey: key,
      account: "alice", revision: "v1"))
  }

  func testLegacyDocumentsDecodeWithoutCloudState() throws {
    let data = try JSONEncoder.addressAtlas.encode(VaultDocument())
    let document = try JSONDecoder.addressAtlas.decode(VaultDocument.self, from: data)
    XCTAssertNil(document.iCloudState)
  }
}
