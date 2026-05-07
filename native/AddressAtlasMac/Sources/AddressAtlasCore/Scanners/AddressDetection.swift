import Foundation

public enum AddressDetection {
  public static func parse(_ input: String, maxCount: Int = 24) -> [String] {
    var seen = Set<String>()
    return input
      .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .filter { value in
        let key = value.lowercased()
        guard !seen.contains(key) else { return false }
        seen.insert(key)
        return true
      }
      .prefix(maxCount)
      .map(String.init)
  }

  public static func detectChains(for address: String) -> [ChainConfig] {
    if isEvm(address) { return ChainRegistry.evmChains }
    if isBitcoin(address) { return [ChainRegistry.bitcoin] }
    if isSolana(address) { return [ChainRegistry.solana] }
    if isTron(address) { return [ChainRegistry.tron] }
    if isXrp(address) { return [ChainRegistry.xrp] }
    if let cosmos = ChainRegistry.cosmosChains.first(where: { prefix in
      guard let addressPrefix = prefix.addressPrefix else { return false }
      return address.lowercased().hasPrefix("\(addressPrefix)1")
    }) {
      return [cosmos]
    }
    return []
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
    address.range(of: #"^0x[a-fA-F0-9]{40}$"#, options: .regularExpression) != nil
  }

  private static func isBitcoin(_ address: String) -> Bool {
    address.range(of: #"^(bc1|[13])[a-zA-HJ-NP-Z0-9]{25,90}$"#, options: .regularExpression) != nil
  }

  private static func isSolana(_ address: String) -> Bool {
    address.range(of: #"^[1-9A-HJ-NP-Za-km-z]{32,44}$"#, options: .regularExpression) != nil
  }

  private static func isTron(_ address: String) -> Bool {
    address.range(of: #"^T[1-9A-HJ-NP-Za-km-z]{33}$"#, options: .regularExpression) != nil
  }

  private static func isXrp(_ address: String) -> Bool {
    address.range(of: #"^r[1-9A-HJ-NP-Za-km-z]{24,34}$"#, options: .regularExpression) != nil
  }
}
