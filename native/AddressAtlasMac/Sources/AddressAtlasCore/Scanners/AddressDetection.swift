import CryptoKit
import Foundation

public struct AddressParseResult: Equatable, Sendable {
  public var addresses: [String]
  public var wasTruncated: Bool

  public init(addresses: [String], wasTruncated: Bool) {
    self.addresses = addresses
    self.wasTruncated = wasTruncated
  }
}

public enum AddressDetection {
  private static let bitcoinBase58Alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  private static let rippleBase58Alphabet = "rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz"
  private static let bech32Alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

  public static func parse(_ input: String, maxCount: Int = 24) -> [String] {
    parseWithMetadata(input, maxCount: maxCount).addresses
  }

  public static func parseWithMetadata(_ input: String, maxCount: Int = 24) -> AddressParseResult {
    let limit = max(0, maxCount)
    var seen = Set<String>()
    var addresses: [String] = []
    var wasTruncated = false
    let tokens = input
      .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

    for value in tokens where !value.isEmpty {
      // EVM and valid Bech32 addresses are case-insensitive. Base58 addresses are not.
      let isValidBech32 = (value.lowercased().hasPrefix("bc1") && isBitcoin(value))
        || ChainRegistry.cosmosChains.contains { chain in
          chain.addressPrefix.map { isCosmos(value, prefix: $0) } ?? false
        }
        || retiredCosmosNetworkName(for: value) != nil
      let key = isEvm(value) || isValidBech32 ? value.lowercased() : value
      guard seen.insert(key).inserted else { continue }
      guard addresses.count < limit else {
        wasTruncated = true
        break
      }
      addresses.append(value)
    }
    return AddressParseResult(addresses: addresses, wasTruncated: wasTruncated)
  }

  public static func detectChains(for address: String) -> [ChainConfig] {
    let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 90 else { return [] }
    if isEvm(value) { return ChainRegistry.evmChains }
    if isBitcoin(value) { return [ChainRegistry.bitcoin] }
    if isTron(value) { return [ChainRegistry.tron] }
    if isXrp(value) { return [ChainRegistry.xrp] }
    if let cosmos = ChainRegistry.cosmosChains.first(where: {
      guard let prefix = $0.addressPrefix else { return false }
      return isCosmos(value, prefix: prefix)
    }) {
      return [cosmos]
    }
    if isSolana(value) { return [ChainRegistry.solana] }
    return []
  }

  /// Validates the token contract/mint formats supported by the custom-token scanner.
  public static func isValidCustomTokenAddress(_ address: String, family: ChainFamily) -> Bool {
    switch family {
    case .evm:
      return isEvm(address.trimmingCharacters(in: .whitespacesAndNewlines))
    case .solana:
      return isSolana(address.trimmingCharacters(in: .whitespacesAndNewlines))
    case .tron:
      return isTron(address.trimmingCharacters(in: .whitespacesAndNewlines))
    case .bitcoin, .cosmos, .xrp, .exchange:
      return false
    }
  }

  /// Returns a validated representation suitable for duplicate detection/storage.
  public static func canonicalAddress(_ address: String, family: ChainFamily) -> String? {
    let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 90 else { return nil }
    let valid: Bool
    switch family {
    case .bitcoin: valid = isBitcoin(value)
    case .cosmos:
      valid = ChainRegistry.cosmosChains.contains { chain in
        chain.addressPrefix.map { isCosmos(value, prefix: $0) } ?? false
      } || retiredCosmosNetworkName(for: value) != nil
    case .evm: valid = isEvm(value)
    case .solana: valid = isSolana(value)
    case .tron: valid = isTron(value)
    case .xrp: valid = isXrp(value)
    case .exchange: valid = false
    }
    guard valid else { return nil }
    if family == .evm || family == .cosmos || value.lowercased().hasPrefix("bc1") {
      return value.lowercased()
    }
    return value
  }

  static func tronHexAddress(_ address: String) -> String? {
    let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.utf8.count == 34,
      let payload = decodeBase58Check(value, alphabet: bitcoinBase58Alphabet),
      payload.count == 21,
      payload[0] == 0x41
    else { return nil }
    return payload.map { String(format: "%02x", $0) }.joined()
  }

  /// Recognizes a retired Cosmos address only for persisted-record compatibility.
  /// A retired address is never returned by `detectChains`, so it cannot be
  /// newly added or sent to a dead provider for scanning.
  public static func retiredCosmosNetworkName(for address: String) -> String? {
    let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 90 else { return nil }
    for (prefix, name) in ChainRegistry.retiredCosmosAddressPrefixes {
      if isCosmos(value, prefix: prefix) { return name }
    }
    return nil
  }

  public static func defaultWalletLabel(_ address: String) -> String {
    guard address.count > 14 else { return address }
    return "\(address.prefix(6))...\(address.suffix(6))"
  }

  public static func isSafePublicAddress(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.range(of: #"(?i)(xprv|seed phrase|mnemonic|private key)"#, options: .regularExpression) != nil {
      return false
    }
    let words = normalized
      .split(whereSeparator: { $0.isWhitespace })
      .map { $0.filter(\.isLetter) }
      .filter { $0.count >= 2 }
    if words.count >= 12 { return false }
    return true
  }

  private static func isEvm(_ address: String) -> Bool {
    guard address.utf8.count == 42 else { return false }
    guard address.range(of: #"^0x[a-fA-F0-9]{40}$"#, options: .regularExpression) != nil else {
      return false
    }
    let body = String(address.dropFirst(2))
    // All-lowercase and all-uppercase forms remain valid for EIP-55 backwards
    // compatibility. Mixed-case input is claiming a checksum, so enforce it.
    guard body != body.lowercased(), body != body.uppercased() else { return true }
    let hash = Keccak256.hash(Data(body.lowercased().utf8))
    for (index, character) in body.enumerated() where character.isLetter {
      let byte = hash[index / 2]
      let nibble = index.isMultiple(of: 2) ? byte >> 4 : byte & 0x0f
      if (nibble >= 8) != character.isUppercase { return false }
    }
    return true
  }

  private static func isBitcoin(_ address: String) -> Bool {
    guard (26...90).contains(address.utf8.count) else { return false }
    let lower = address.lowercased()
    if lower.hasPrefix("bc1") {
      guard let decoded = decodeBech32(address), decoded.hrp == "bc", !decoded.data.isEmpty else { return false }
      let witnessVersion = Int(decoded.data[0])
      guard witnessVersion <= 16 else { return false }
      let expectedConstant: UInt32 = witnessVersion == 0 ? 1 : 0x2bc830a3
      guard decoded.polymod == expectedConstant,
            let program = convertBits(Array(decoded.data.dropFirst()), from: 5, to: 8, pad: false),
            (2...40).contains(program.count)
      else { return false }
      return witnessVersion != 0 || program.count == 20 || program.count == 32
    }

    guard let decoded = decodeBase58Check(address, alphabet: bitcoinBase58Alphabet), decoded.count == 21 else {
      return false
    }
    return decoded[0] == 0x00 || decoded[0] == 0x05
  }

  private static func isSolana(_ address: String) -> Bool {
    guard (32...44).contains(address.utf8.count) else { return false }
    return decodeBase58(address, alphabet: bitcoinBase58Alphabet)?.count == 32
  }

  private static func isTron(_ address: String) -> Bool {
    guard address.utf8.count == 34, address.first == "T" else { return false }
    guard let decoded = decodeBase58Check(address, alphabet: bitcoinBase58Alphabet), decoded.count == 21 else {
      return false
    }
    return decoded[0] == 0x41
  }

  private static func isXrp(_ address: String) -> Bool {
    guard (25...35).contains(address.utf8.count), address.first == "r",
          let decoded = decodeBase58Check(address, alphabet: rippleBase58Alphabet),
          decoded.count == 21
    else { return false }
    return decoded[0] == 0x00
  }

  private static func isCosmos(_ address: String, prefix: String) -> Bool {
    guard address.utf8.count <= 90 else { return false }
    guard let decoded = decodeBech32(address), decoded.hrp == prefix.lowercased(), decoded.polymod == 1,
          let bytes = convertBits(decoded.data, from: 5, to: 8, pad: false)
    else { return false }
    // Cosmos SDK reserves both legacy 20-byte account addresses and newer
    // 32-byte account/module address forms. Other lengths are not account IDs.
    return bytes.count == 20 || bytes.count == 32
  }

  private static func decodeBase58Check(_ value: String, alphabet: String) -> [UInt8]? {
    guard let decoded = decodeBase58(value, alphabet: alphabet), decoded.count > 4 else { return nil }
    let payload = Array(decoded.dropLast(4))
    let checksum = Array(decoded.suffix(4))
    let first = SHA256.hash(data: Data(payload))
    let second = SHA256.hash(data: Data(first))
    return Array(second.prefix(4)) == checksum ? payload : nil
  }

  private static func decodeBase58(_ value: String, alphabet: String) -> [UInt8]? {
    guard !value.isEmpty else { return nil }
    let digits = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, $0.offset) })
    var littleEndian: [UInt8] = []
    for character in value {
      guard let digit = digits[character] else { return nil }
      var carry = digit
      for index in littleEndian.indices {
        let total = Int(littleEndian[index]) * 58 + carry
        littleEndian[index] = UInt8(total & 0xff)
        carry = total >> 8
      }
      while carry > 0 {
        littleEndian.append(UInt8(carry & 0xff))
        carry >>= 8
      }
    }
    let leadingZeroes = value.prefix { $0 == alphabet.first! }.count
    return Array(repeating: 0, count: leadingZeroes) + Array(littleEndian.reversed())
  }

  private struct Bech32Decoded {
    var hrp: String
    var data: [UInt8]
    var polymod: UInt32
  }

  private static func decodeBech32(_ value: String) -> Bech32Decoded? {
    guard value.count >= 8, value.count <= 90,
          value == value.lowercased() || value == value.uppercased()
    else { return nil }
    let normalized = value.lowercased()
    guard let separator = normalized.lastIndex(of: "1"), separator != normalized.startIndex else { return nil }
    let dataStart = normalized.index(after: separator)
    guard normalized.distance(from: dataStart, to: normalized.endIndex) >= 6 else { return nil }
    let hrp = String(normalized[..<separator])
    let lookup = Dictionary(uniqueKeysWithValues: bech32Alphabet.enumerated().map { ($0.element, UInt8($0.offset)) })
    var values: [UInt8] = []
    for character in normalized[dataStart...] {
      guard let digit = lookup[character] else { return nil }
      values.append(digit)
    }
    let expanded = hrp.utf8.map { UInt8($0 >> 5) } + [0] + hrp.utf8.map { UInt8($0 & 31) }
    let polymod = bech32Polymod(expanded + values)
    return Bech32Decoded(hrp: hrp, data: Array(values.dropLast(6)), polymod: polymod)
  }

  private static func bech32Polymod(_ values: [UInt8]) -> UInt32 {
    let generators: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
    var checksum: UInt32 = 1
    for value in values {
      let top = checksum >> 25
      checksum = (checksum & 0x1ffffff) << 5 ^ UInt32(value)
      for index in 0..<5 where (top >> index) & 1 == 1 {
        checksum ^= generators[index]
      }
    }
    return checksum
  }

  private static func convertBits(_ values: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
    var accumulator = 0
    var bits = 0
    let maxValue = (1 << to) - 1
    var result: [UInt8] = []
    for value in values {
      guard Int(value) >> from == 0 else { return nil }
      accumulator = (accumulator << from) | Int(value)
      bits += from
      while bits >= to {
        bits -= to
        result.append(UInt8((accumulator >> bits) & maxValue))
      }
    }
    if pad {
      if bits > 0 { result.append(UInt8((accumulator << (to - bits)) & maxValue)) }
    } else if bits >= from || ((accumulator << (to - bits)) & maxValue) != 0 {
      return nil
    }
    return result
  }
}

/// Minimal Keccak-256 used for EIP-55 address checksums. CryptoKit's SHA3-256
/// uses different domain padding and therefore cannot validate Ethereum's
/// Keccak-based checksum format.
private enum Keccak256 {
  private static let rate = 136
  private static let roundConstants: [UInt64] = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808a,
    0x8000000080008000, 0x000000000000808b, 0x0000000080000001,
    0x8000000080008081, 0x8000000000008009, 0x000000000000008a,
    0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
    0x000000008000808b, 0x800000000000008b, 0x8000000000008089,
    0x8000000000008003, 0x8000000000008002, 0x8000000000000080,
    0x000000000000800a, 0x800000008000000a, 0x8000000080008081,
    0x8000000000008080, 0x0000000080000001, 0x8000000080008008
  ]
  private static let rotations = [
     0,  1, 62, 28, 27,
    36, 44,  6, 55, 20,
     3, 10, 43, 25, 39,
    41, 45, 15, 21,  8,
    18,  2, 61, 56, 14
  ]

  static func hash(_ data: Data) -> [UInt8] {
    var state = [UInt64](repeating: 0, count: 25)
    var offset = 0
    while data.count - offset >= rate {
      absorb(Array(data[offset..<(offset + rate)]), into: &state)
      permute(&state)
      offset += rate
    }

    var final = [UInt8](repeating: 0, count: rate)
    let remainder = Array(data[offset...])
    final.replaceSubrange(0..<remainder.count, with: remainder)
    final[remainder.count] ^= 0x01
    final[rate - 1] ^= 0x80
    absorb(final, into: &state)
    permute(&state)

    return (0..<32).map { index in
      UInt8(truncatingIfNeeded: state[index / 8] >> UInt64((index % 8) * 8))
    }
  }

  private static func absorb(_ block: [UInt8], into state: inout [UInt64]) {
    for (index, byte) in block.enumerated() {
      state[index / 8] ^= UInt64(byte) << UInt64((index % 8) * 8)
    }
  }

  private static func permute(_ state: inout [UInt64]) {
    for constant in roundConstants {
      var columns = [UInt64](repeating: 0, count: 5)
      for x in 0..<5 {
        columns[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
      }
      for x in 0..<5 {
        let delta = columns[(x + 4) % 5] ^ rotateLeft(columns[(x + 1) % 5], by: 1)
        for y in 0..<5 { state[x + 5 * y] ^= delta }
      }

      var moved = [UInt64](repeating: 0, count: 25)
      for x in 0..<5 {
        for y in 0..<5 {
          moved[y + 5 * ((2 * x + 3 * y) % 5)] = rotateLeft(
            state[x + 5 * y],
            by: rotations[x + 5 * y]
          )
        }
      }

      for x in 0..<5 {
        for y in 0..<5 {
          state[x + 5 * y] = moved[x + 5 * y]
            ^ ((~moved[(x + 1) % 5 + 5 * y]) & moved[(x + 2) % 5 + 5 * y])
        }
      }
      state[0] ^= constant
    }
  }

  private static func rotateLeft(_ value: UInt64, by amount: Int) -> UInt64 {
    guard amount != 0 else { return value }
    return (value << UInt64(amount)) | (value >> UInt64(64 - amount))
  }
}
