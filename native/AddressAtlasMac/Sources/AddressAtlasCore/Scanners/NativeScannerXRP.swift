import Foundation

private enum XrpResponseBindingError: Error {
  case accountMismatch
  case unvalidated
  case invalidLedgerIdentity
  case ledgerChanged

  var accountInfoMessage: String {
    switch self {
    case .accountMismatch:
      "XRP account lookup did not match the requested account."
    case .unvalidated:
      "XRP account lookup did not come from a validated ledger."
    case .invalidLedgerIdentity, .ledgerChanged:
      "XRP account lookup did not identify one validated ledger."
    }
  }

  var trustLineWarning: String {
    switch self {
    case .accountMismatch:
      "XRP trust-line pagination returned another account; issued-currency balances were omitted because the result was incomplete."
    case .unvalidated:
      "XRP trust-line pagination returned an unvalidated page; issued-currency balances were omitted because the result was incomplete."
    case .invalidLedgerIdentity:
      "XRP trust-line pagination did not identify one validated ledger; issued-currency balances were omitted because the result was incomplete."
    case .ledgerChanged:
      "XRP trust-line pagination changed ledger; issued-currency balances were omitted because the result was incomplete."
    }
  }
}

private struct XrpLedgerIdentity: Equatable, Sendable {
  var hash: String?
  var index: Int?

  func addRequestBinding(to parameters: inout [String: XRPValue]) {
    if let hash {
      parameters["ledger_hash"] = .string(hash)
    } else if let index {
      parameters["ledger_index"] = .number(index)
    }
  }

  func matches(_ page: XrpLedgerIdentity) -> Bool {
    if let hash {
      guard page.hash == hash else { return false }
    } else if let index {
      guard page.index == index else { return false }
    } else {
      return false
    }
    if let index, let pageIndex = page.index, pageIndex != index {
      return false
    }
    return true
  }
}

extension NativeScanner {
  func scanXRP(
    address: String,
    chain: ChainConfig,
    prices: [String: PricePoint],
    networkIdentityProofs: ChainNetworkValueCache<Void>? = nil
  )
    async throws -> NativeScanResult
  {
    struct ServerInfoResponse: Decodable {
      var result: Result?
      struct Result: Decodable {
        var info: Info?
      }
      struct Info: Decodable {
        var networkID: UInt32?
        enum CodingKeys: String, CodingKey {
          case networkID = "network_id"
        }
      }
    }
    struct Response: Decodable {
      var result: Result?
      struct Result: Decodable {
        var status: String?
        var accountData: Account?
        var ledgerHash: String?
        var ledgerIndex: Int?
        var validated: Bool?
        var error: String?
        var errorMessage: String?
        enum CodingKeys: String, CodingKey {
          case status
          case accountData = "account_data"
          case ledgerHash = "ledger_hash"
          case ledgerIndex = "ledger_index"
          case validated
          case error
          case errorMessage = "error_message"
        }
      }
      struct Account: Decodable {
        var account: String?
        var balance: String?

        enum CodingKeys: String, CodingKey {
          case account = "Account"
          case balance = "Balance"
        }
      }
    }
    guard let rpc = chain.rpcUrl else { return NativeScanResult() }
    guard case .xrpNetworkID(let expectedNetworkID) = chain.networkIdentity else {
      throw Self.messageError(domain: "XRP", message: "XRP network identity is missing.")
    }
    let proofCache = networkIdentityProofs ?? ChainNetworkValueCache<Void>()
    try await proofCache.prove(
      chainID: chain.id,
      endpoint: rpc,
      identity: chain.networkIdentity
    ) {
      let serverInfo = try await http.post(
        rpc,
        body: XRPRequest(method: "server_info", params: [[:]]),
        as: ServerInfoResponse.self
      )
      guard serverInfo.result?.info?.networkID == expectedNetworkID else {
        throw Self.messageError(
          domain: "XRP", message: "XRP endpoint returned the wrong network identity.")
      }
    }
    let response = try await http.post(
      rpc,
      body: XRPRequest(
        method: "account_info",
        params: [
          [
            "account": .string(address),
            "ledger_index": .string("validated"),
          ]
        ]
      ),
      as: Response.self
    )
    guard let result = response.result else {
      throw Self.messageError(
        domain: "XRP", message: "XRP account lookup returned an empty result.")
    }
    if result.error == "actNotFound" { return NativeScanResult() }
    if result.status == "error" || result.error != nil {
      throw Self.messageError(
        domain: "XRP",
        message: result.errorMessage ?? result.error ?? "XRP account lookup failed."
      )
    }
    guard let accountData = result.accountData, let rawBalance = accountData.balance else {
      throw Self.messageError(domain: "XRP", message: "XRP account lookup returned no balance.")
    }
    let ledgerIdentity: XrpLedgerIdentity
    do {
      ledgerIdentity = try Self.validatedXrpLedgerIdentity(
        echoedAccount: accountData.account,
        ledgerHash: result.ledgerHash,
        ledgerIndex: result.ledgerIndex,
        validated: result.validated,
        expectedAddress: address
      )
    } catch let bindingError as XrpResponseBindingError {
      throw Self.messageError(domain: "XRP", message: bindingError.accountInfoMessage)
    }
    var assets: [TrackedAsset] = []
    var warnings: [String] = []
    if let drops = Double(rawBalance), drops.isFinite, drops >= 0 {
      assets = assetIfPositive(
        amount: drops / pow(10, Double(chain.decimals)),
        address: address,
        chain: chain,
        prices: prices
      )
    } else {
      warnings.append(
        "Native XRP balance was invalid; issued-currency balances may still be available.")
    }

    let trustLines = try await fetchXrpTrustLines(
      rpc: rpc,
      address: address,
      ledgerIdentity: ledgerIdentity
    )
    let parsedTrustLines = Self.parseXrpTrustLineResult(
      trustLines.lines,
      address: address,
      chain: chain
    )
    assets.append(contentsOf: parsedTrustLines.assets)
    warnings.append(contentsOf: parsedTrustLines.warnings)
    warnings.append(contentsOf: trustLines.warnings)
    return NativeScanResult(assets: assets, warnings: warnings)
  }

  private func fetchXrpTrustLines(
    rpc: URL,
    address: String,
    ledgerIdentity: XrpLedgerIdentity
  ) async throws -> XrpTrustLineScan {
    var lines: [XrpTrustLine] = []
    var warnings: [String] = []
    let requestLedgerIdentity = ledgerIdentity
    var expectedLedgerIdentity = ledgerIdentity
    var marker: JSONValue?
    var seenMarkers = Set<String>()

    for page in 1...maxXrpPages {
      try Task.checkCancellation()
      var parameters: [String: XRPValue] = [
        "account": .string(address),
        "limit": .number(400),
      ]
      requestLedgerIdentity.addRequestBinding(to: &parameters)
      if let marker { parameters["marker"] = .json(marker) }

      do {
        let response = try await http.post(
          rpc,
          body: XRPRequest(method: "account_lines", params: [parameters]),
          as: XrpAccountLinesResponse.self
        )
        guard let result = response.result else {
          throw Self.messageError(
            domain: "XRP", message: "XRP trust lines lookup returned an empty result.")
        }
        if result.status == "error" || result.error != nil {
          throw Self.messageError(
            domain: "XRP",
            message: result.errorMessage ?? result.error ?? "XRP trust lines lookup failed."
          )
        }
        let pageLedgerIdentity = try Self.validatedXrpLedgerIdentity(
          echoedAccount: result.account,
          ledgerHash: result.ledgerHash,
          ledgerIndex: result.ledgerIndex,
          validated: result.validated,
          expectedAddress: address
        )
        guard expectedLedgerIdentity.matches(pageLedgerIdentity) else {
          throw XrpResponseBindingError.ledgerChanged
        }
        // Keep the request's original exact ledger selector stable because a
        // pagination marker belongs to that request shape. Separately retain
        // any additional identity echoed by the first page so later pages
        // cannot swap hashes at the same index (or indexes at the same hash).
        if expectedLedgerIdentity.hash == nil {
          expectedLedgerIdentity.hash = pageLedgerIdentity.hash
        }
        if expectedLedgerIdentity.index == nil {
          expectedLedgerIdentity.index = pageLedgerIdentity.index
        }
        guard let pageLines = result.lines else {
          throw Self.messageError(
            domain: "XRP", message: "XRP trust lines lookup returned no lines.")
        }
        lines.append(contentsOf: pageLines)
        guard let nextMarker = result.marker else { break }
        let markerKey = try nextMarker.stableKey()
        guard seenMarkers.insert(markerKey).inserted else {
          warnings.append(
            "XRP pagination returned a repeated marker; later trustlines were skipped.")
          break
        }
        guard page < maxXrpPages else {
          warnings.append(
            "XRP trustline pagination reached the \(maxXrpPages)-page safety limit; later trustlines were skipped."
          )
          break
        }
        marker = nextMarker
      } catch {
        try throwIfCancellation(error)
        if let bindingError = error as? XrpResponseBindingError {
          lines.removeAll(keepingCapacity: true)
          warnings.append(bindingError.trustLineWarning)
          break
        }
        let prefix =
          lines.isEmpty
          ? "Issued-currency trustlines could not be read"
          : "Later issued-currency trustline pages could not be read"
        warnings.append("\(prefix); available XRP balances are still shown.")
        break
      }
    }
    return XrpTrustLineScan(lines: lines, warnings: warnings)
  }

  private static func validatedXrpLedgerIdentity(
    echoedAccount: String?,
    ledgerHash: String?,
    ledgerIndex: Int?,
    validated: Bool?,
    expectedAddress: String
  ) throws -> XrpLedgerIdentity {
    guard validated == true else {
      throw XrpResponseBindingError.unvalidated
    }
    guard
      let expected = AddressDetection.canonicalAddress(expectedAddress, family: .xrp),
      let echoedAccount,
      AddressDetection.canonicalAddress(echoedAccount, family: .xrp) == expected
    else {
      throw XrpResponseBindingError.accountMismatch
    }

    let canonicalHash: String?
    if let ledgerHash {
      let bytes = Array(ledgerHash.utf8)
      guard bytes.count == 64,
        bytes.allSatisfy({
          (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        })
      else {
        throw XrpResponseBindingError.invalidLedgerIdentity
      }
      canonicalHash = ledgerHash.uppercased()
    } else {
      canonicalHash = nil
    }

    if let ledgerIndex,
      !(1...Int(UInt32.max)).contains(ledgerIndex)
    {
      throw XrpResponseBindingError.invalidLedgerIdentity
    }
    guard canonicalHash != nil || ledgerIndex != nil else {
      throw XrpResponseBindingError.invalidLedgerIdentity
    }
    return XrpLedgerIdentity(hash: canonicalHash, index: ledgerIndex)
  }

  public static func parseXrpTrustLines(
    _ lines: [XrpTrustLine], address: String, chain: ChainConfig
  ) -> [TrackedAsset] {
    parseXrpTrustLineResult(lines, address: address, chain: chain).assets
  }

  static func parseXrpTrustLineResult(
    _ lines: [XrpTrustLine],
    address: String,
    chain: ChainConfig
  ) -> NativeScanResult {
    struct IdentifiedLine {
      var line: XrpTrustLine
      var issuer: String
      var currencyIdentity: String
      var symbol: String
    }

    struct ValidatedLine {
      var issuer: String
      var currencyIdentity: String
      var symbol: String
      var amount: Double
    }

    var candidatesByIdentity: [String: [IdentifiedLine]] = [:]
    var identicalDuplicateCount = 0
    var invalidIdentityCount = 0

    for line in lines {
      guard let issuer = AddressDetection.canonicalAddress(line.account, family: .xrp),
        let currency = validatedXrplCurrency(line.currency)
      else {
        invalidIdentityCount += 1
        continue
      }
      let identity = "\(currency.identity)|\(issuer)"
      candidatesByIdentity[identity, default: []].append(
        IdentifiedLine(
          line: line,
          issuer: issuer,
          currencyIdentity: currency.identity,
          symbol: currency.symbol
        )
      )
    }

    var linesByIdentity: [String: ValidatedLine] = [:]
    var invalidBalanceIdentities = Set<String>()
    var conflictingIdentities = Set<String>()
    for (identity, candidates) in candidatesByIdentity {
      let amounts = candidates.compactMap { candidate -> Double? in
        guard let amount = Double(candidate.line.balance), amount.isFinite, amount > 0 else {
          return nil
        }
        return amount
      }
      // Resolve every row for an identity before accepting any version. A
      // malformed, zero, or negative duplicate taints the whole identity in
      // either ordering instead of allowing the valid-looking row to win.
      guard amounts.count == candidates.count else {
        invalidBalanceIdentities.insert(identity)
        continue
      }
      guard let amount = amounts.first, let first = candidates.first else { continue }
      guard amounts.dropFirst().allSatisfy({ $0 == amount }) else {
        conflictingIdentities.insert(identity)
        continue
      }
      identicalDuplicateCount += candidates.count - 1
      linesByIdentity[identity] = ValidatedLine(
        issuer: first.issuer,
        currencyIdentity: first.currencyIdentity,
        symbol: first.symbol,
        amount: amount
      )
    }

    let assets = linesByIdentity.keys.sorted().compactMap { identity -> TrackedAsset? in
      guard let line = linesByIdentity[identity] else { return nil }
      let issuer = line.issuer
      let symbol = line.symbol
      let shortIssuer = String(issuer.prefix(6)) + "..." + String(issuer.suffix(4))
      return TrackedAsset(
        // The raw 160-bit currency code and issuer are the XRPL asset
        // identity. Display text is presentation-only: deriving identity from
        // it collapses distinct issued assets and enables lookalike rows.
        id: "\(address)-\(chain.id)-issued-\(line.currencyIdentity)-\(issuer)",
        address: address,
        chainId: chain.id,
        chainName: chain.name,
        family: chain.family,
        symbol: symbol,
        name: "\(symbol) issued by \(shortIssuer)",
        amount: line.amount,
        priceUsd: 0,
        valueUsd: 0,
        change24h: nil,
        explorerUrl: chain.explorerURL(for: address).absoluteString,
        source: .issued
      )
    }
    var warnings: [String] = []
    if invalidIdentityCount > 0 {
      warnings.append(
        invalidIdentityCount == 1
          ? "XRP skipped one trust line with an invalid issuer or currency code."
          : "XRP skipped \(invalidIdentityCount) trust lines with invalid issuers or currency codes."
      )
    }
    if !invalidBalanceIdentities.isEmpty {
      warnings.append(
        invalidBalanceIdentities.count == 1
          ? "XRP discarded one issued asset because its trust-line data included an invalid or non-positive balance."
          : "XRP discarded \(invalidBalanceIdentities.count) issued assets because their trust-line data included invalid or non-positive balances."
      )
    }
    if identicalDuplicateCount > 0 {
      warnings.append(
        identicalDuplicateCount == 1
          ? "XRP repeated one identical trust line; the duplicate was skipped to avoid double-counting."
          : "XRP repeated \(identicalDuplicateCount) identical trust lines; the duplicates were skipped to avoid double-counting."
      )
    }
    if !conflictingIdentities.isEmpty {
      warnings.append(
        conflictingIdentities.count == 1
          ? "XRP returned conflicting balances for one issued asset; every version was skipped."
          : "XRP returned conflicting balances for \(conflictingIdentities.count) issued assets; every version was skipped."
      )
    }
    return NativeScanResult(assets: assets, warnings: warnings)
  }

  public static func decodeXrplCurrency(_ value: String) -> String {
    validatedXrplCurrency(value)?.symbol ?? ""
  }

  public static func canonicalXrplCurrencyIdentity(_ value: String) -> String {
    validatedXrplCurrency(value)?.identity ?? ""
  }

  private static func validatedXrplCurrency(_ value: String) -> (
    identity: String,
    symbol: String
  )? {
    let bytes = Array(value.utf8)
    if bytes.count == 3,
      value != "XRP",
      bytes.allSatisfy({ (33...126).contains($0) })
    {
      // Three-character currency codes are wire identities too. Preserve case
      // while adding a discriminator so they cannot collide with a hex code.
      // Uppercase XRP is reserved for the native asset and is not a valid
      // issued-currency trust-line identity.
      return ("text:\(value)", value)
    }
    guard bytes.count == 40,
      bytes.allSatisfy({
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      })
    else { return nil }
    let uppercase = value.uppercased()
    // Every 40-hex value is a nonstandard 160-bit identity, even when its first
    // bytes spell a familiar ticker. Showing it in full prevents ticker spoofing.
    return (value.lowercased(), "HEX:\(uppercase)")
  }

}
