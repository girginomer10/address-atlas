import Foundation

public enum Base64URL {
  public static func encode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public static func decode(_ value: String) throws -> Data {
    var normalized = value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while normalized.count % 4 != 0 {
      normalized.append("=")
    }
    guard let data = Data(base64Encoded: normalized) else {
      throw VaultCryptoError.invalidBase64
    }
    return data
  }
}

extension Data {
  public init(hex: String) throws {
    let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "0x", with: "")
    guard clean.count % 2 == 0 else { throw VaultCryptoError.invalidHex }
    var bytes = [UInt8]()
    bytes.reserveCapacity(clean.count / 2)
    var index = clean.startIndex
    while index < clean.endIndex {
      let next = clean.index(index, offsetBy: 2)
      guard let byte = UInt8(clean[index..<next], radix: 16) else {
        throw VaultCryptoError.invalidHex
      }
      bytes.append(byte)
      index = next
    }
    self = Data(bytes)
  }

  public var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
