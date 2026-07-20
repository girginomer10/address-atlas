import Foundation

extension NativeScanner {
  func scanXRP(address: String, chain: ChainConfig, prices: [String: PricePoint])
    async throws -> NativeScanResult
  {
    struct Response: Decodable {
      var result: Result?
      struct Result: Decodable {
        var status: String?
        var accountData: Account?
        var error: String?
        var errorMessage: String?
        enum CodingKeys: String, CodingKey {
          case status
          case accountData = "account_data"
          case error
          case errorMessage = "error_message"
        }
      }
      struct Account: Decodable {
        var balance: String?

        enum CodingKeys: String, CodingKey {
          case balance = "Balance"
        }
      }
    }
    guard let rpc = chain.rpcUrl else { return NativeScanResult() }
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
    guard let rawBalance = result.accountData?.balance else {
      throw Self.messageError(domain: "XRP", message: "XRP account lookup returned no balance.")
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

    let trustLines = try await fetchXrpTrustLines(rpc: rpc, address: address)
    assets.append(
      contentsOf: Self.parseXrpTrustLines(trustLines.lines, address: address, chain: chain))
    warnings.append(contentsOf: trustLines.warnings)
    return NativeScanResult(assets: assets, warnings: warnings)
  }

  func fetchXrpTrustLines(rpc: URL, address: String) async throws -> XrpTrustLineScan {
    var lines: [XrpTrustLine] = []
    var warnings: [String] = []
    var marker: JSONValue?
    var seenMarkers = Set<String>()

    for page in 1...maxXrpPages {
      try Task.checkCancellation()
      var parameters: [String: XRPValue] = [
        "account": .string(address),
        "ledger_index": .string("validated"),
        "limit": .number(400),
      ]
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
  public static func parseXrpTrustLines(
    _ lines: [XrpTrustLine], address: String, chain: ChainConfig
  ) -> [TrackedAsset] {
    lines.compactMap { line in
      guard
        let amount = Double(line.balance),
        amount.isFinite,
        amount > 0
      else {
        return nil
      }
      let canonicalCurrency = canonicalXrplCurrencyIdentity(line.currency)
      let symbol = decodeXrplCurrency(line.currency)
      let issuer = line.account
      let shortIssuer = String(issuer.prefix(6)) + "..." + String(issuer.suffix(4))
      return TrackedAsset(
        // The raw 160-bit currency code and issuer are the XRPL asset
        // identity. Display text is presentation-only: deriving identity from
        // it collapses distinct issued assets and enables lookalike rows.
        id: "\(address)-\(chain.id)-issued-\(canonicalCurrency)-\(issuer)",
        address: address,
        chainId: chain.id,
        chainName: chain.name,
        family: chain.family,
        symbol: symbol,
        name: "\(symbol) issued by \(shortIssuer)",
        amount: amount,
        priceUsd: 0,
        valueUsd: 0,
        change24h: nil,
        explorerUrl: chain.explorerURL(for: address).absoluteString,
        source: .issued
      )
    }
  }

  public static func decodeXrplCurrency(_ value: String) -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count == 40, normalized.allSatisfy(\.isHexDigit) else {
      return normalized
    }
    // XRPL JSON represents standard three-character currencies directly as
    // text (for example, "USD"). Every 40-hex value is a nonstandard 160-bit
    // identity, even when its first bytes spell a familiar ticker. Showing the
    // complete code prevents a custom issued asset from visually spoofing USD.
    return "HEX:\(normalized.uppercased())"
  }

  public static func canonicalXrplCurrencyIdentity(_ value: String) -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.count == 40, normalized.allSatisfy(\.isHexDigit) {
      return normalized.lowercased()
    }
    // Three-character currency codes are wire identities too. Preserve case
    // while adding an explicit discriminator so they cannot collide with a
    // hex representation.
    return "text:\(normalized)"
  }

}
