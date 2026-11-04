import Foundation

private enum XrpResponseBindingError: Error {
  case accountMismatch
  case unvalidated
  case invalidLedgerIdentity
  case ledgerChanged

  var accountInfoMessage: String {
    switch self {
    case .accountMismatch:
      "The server's reply was for a different XRP account, so balances are missing from this scan. Scan again later."
    case .unvalidated:
      "The server's reply wasn't from a validated XRP ledger, so balances are missing from this scan. Scan again later."
    case .invalidLedgerIdentity, .ledgerChanged:
      "The server didn't identify a single validated XRP ledger, so balances are missing from this scan. Scan again later."
    }
  }

  var trustLineWarning: String {
    switch self {
    case .accountMismatch:
      "The server's reply for trust lines was for a different account, so issued-currency balances are missing from this scan. Scan again later."
    case .unvalidated:
      "The server sent trust lines from an unvalidated ledger, so issued-currency balances are missing from this scan. Scan again later."
    case .invalidLedgerIdentity:
      "The server didn't identify a single validated ledger for trust lines, so issued-currency balances are missing from this scan. Scan again later."
    case .ledgerChanged:
      "The XRP ledger changed while trust lines were being read, so issued-currency balances are missing from this scan. Scan again later."
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
      throw Self.messageError(domain: "XRP", message: "Couldn't confirm the XRP network, so balances are missing from this scan. Check the server settings in Settings.")
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
          domain: "XRP", message: "The server isn't on the XRP network, so balances are missing from this scan. Check the server settings in Settings.")
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
        domain: "XRP", message: "The server's reply was empty, so this wallet's XRP balance is missing from this scan. Scan again later.")
    }
    if result.error == "actNotFound" { return NativeScanResult() }
    if result.status == "error" || result.error != nil {
      throw Self.messageError(
        domain: "XRP",
        message: result.errorMessage ?? result.error ?? "The XRP account lookup failed."
      )
    }
    guard let accountData = result.accountData, let rawBalance = accountData.balance else {
      throw Self.messageError(domain: "XRP", message: "The server sent no XRP balance, so it's missing from this scan. Scan again later.")
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
        "The server sent an XRP balance Address Atlas couldn't read, so it's missing from this scan. Issued-currency balances may still be included.")
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
            "The server repeated a page marker while listing trust lines, so later ones are missing from this scan. Scan again later.")
          break
        }
        guard page < maxXrpPages else {
          warnings.append(
            "Address Atlas stopped after \(maxXrpPages) pages of trust lines, so later ones are missing from this scan."
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
        warnings.append(
          lines.isEmpty
            ? "Couldn't read issued-currency trust lines, so those balances are missing from this scan. The XRP balance is still included. Scan again later."
            : "Couldn't read later pages of trust lines, so some issued-currency balances may be missing from this scan. The XRP balance is still included. Scan again later."
        )
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
        guard let amount = Double(candidate.line.balance), amount.isFinite, amount >= 0 else {
          return nil
        }
        return amount
      }
      // Resolve every row for an identity before accepting any version. A
      // malformed or negative duplicate taints the whole identity in either
      // ordering instead of allowing the valid-looking row to win, and a zero
      // row next to a positive one is a conflict, not a silent skip.
      guard amounts.count == candidates.count else {
        invalidBalanceIdentities.insert(identity)
        continue
      }
      guard let amount = amounts.first, let first = candidates.first else { continue }
      guard amounts.dropFirst().allSatisfy({ $0 == amount }) else {
        conflictingIdentities.insert(identity)
        continue
      }
      // A consistent zero is a normal empty trust line (new lines start at
      // zero on the XRPL). There is nothing to hold or double-count, so skip
      // it without a scan warning.
      guard amount > 0 else { continue }
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
          ? "One XRP trust line has an invalid issuer or currency code, so it's left out of this scan."
          : "\(invalidIdentityCount) XRP trust lines have invalid issuers or currency codes, so they're left out of this scan."
      )
    }
    if !invalidBalanceIdentities.isEmpty {
      warnings.append(
        invalidBalanceIdentities.count == 1
          ? "One issued asset on XRP has an invalid or negative balance, so it's left out of this scan."
          : "\(invalidBalanceIdentities.count) issued assets on XRP have invalid or negative balances, so they're left out of this scan."
      )
    }
    if identicalDuplicateCount > 0 {
      warnings.append(
        identicalDuplicateCount == 1
          ? "The server listed the same XRP trust line twice. It was counted once."
          : "The server listed \(identicalDuplicateCount) XRP trust lines more than once. Each was counted once."
      )
    }
    if !conflictingIdentities.isEmpty {
      warnings.append(
        conflictingIdentities.count == 1
          ? "The server sent conflicting balances for one issued XRP asset, so it's left out of this scan. Scan again later."
          : "The server sent conflicting balances for \(conflictingIdentities.count) issued XRP assets, so they're left out of this scan. Scan again later."
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
