import Foundation

extension NativeScanner {
  func scanSolana(
    address: String,
    chain: ChainConfig,
    tokens: [TokenConfig],
    prices: [String: PricePoint]
  ) async throws -> NativeScanResult {
    struct Response: Decodable {
      var result: NativeBalance?
      var error: JSONRPCError?
      struct NativeBalance: Decodable { var value: Double }
    }
    guard let rpc = chain.rpcUrl else { return NativeScanResult() }
    var assets: [TrackedAsset] = []
    var warnings: [String] = []

    do {
      let response = try await http.post(
        rpc,
        body: JSONRPCRequest(
          method: "getBalance",
          params: [.string(address), .object(["commitment": .string("confirmed")])]),
        as: Response.self
      )
      if let error = response.error {
        throw Self.rpcError(
          domain: "Solana", error: error, fallback: "Native SOL balance lookup failed.")
      }
      guard let lamports = response.result?.value else {
        throw Self.messageError(
          domain: "Solana", message: "Native SOL balance lookup returned an empty result.")
      }
      guard lamports.isFinite, lamports >= 0 else {
        throw Self.messageError(
          domain: "Solana", message: "Native SOL balance lookup returned an invalid amount.")
      }
      assets.append(
        contentsOf: assetIfPositive(
          amount: lamports / pow(10, Double(chain.decimals)), address: address, chain: chain,
          prices: prices))
    } catch {
      try throwIfCancellation(error)
      warnings.append("Native SOL balance could not be read: \(error.localizedDescription)")
    }

    do {
      let splScan = try await fetchSolanaTokenBalances(rpc: rpc, owner: address, registry: tokens)
      assets.append(
        contentsOf: splScan.balances.compactMap { balance in
          tokenAsset(
            amount: balance.amount, address: address, chain: chain, token: balance.token,
            prices: prices, source: .spl)
        })
      warnings.append(contentsOf: splScan.warnings)
    } catch {
      try throwIfCancellation(error)
      warnings.append("SPL token balances failed: \(error.localizedDescription)")
    }

    return NativeScanResult(assets: assets, warnings: warnings)
  }

  func fetchSolanaTokenBalances(
    rpc: URL,
    owner: String,
    registry: [TokenConfig]
  ) async throws -> SolanaTokenBalanceScan {
    guard !registry.isEmpty else { return SolanaTokenBalanceScan() }
    let programs = [
      "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
      "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb",
    ]
    let outcomes = try await boundedConcurrentMap(programs, maxConcurrent: 2) { program in
      do {
        let response = try await http.post(
          rpc,
          body: JSONRPCRequest(
            method: "getTokenAccountsByOwner",
            params: [
              .string(owner),
              .object(["programId": .string(program)]),
              .object([
                "encoding": .string("jsonParsed"),
                "commitment": .string("confirmed"),
              ]),
            ]
          ),
          as: SolanaTokenAccountsResponse.self
        )
        if let error = response.error {
          throw Self.rpcError(
            domain: "SolanaTokenAccounts", error: error, fallback: "Token account lookup failed.")
        }
        guard let accounts = response.result?.value else {
          throw Self.messageError(
            domain: "SolanaTokenAccounts", message: "Token account lookup returned an empty result."
          )
        }
        let parsed = Self.parseSolanaTokenAccountResult(accounts)
        return SolanaProgramOutcome(
          accounts: parsed.accounts,
          invalidMints: parsed.invalidMints,
          unidentifiedInvalidAccountCount: parsed.unidentifiedInvalidAccountCount
        )
      } catch {
        try throwIfCancellation(error)
        return SolanaProgramOutcome(
          warnings: [
            "\(Self.solanaProgramLabel(program)) token account scan failed; SPL balances may be incomplete."
          ]
        )
      }
    }
    let parsedAccounts = outcomes.flatMap(\.accounts)
    var warnings = outcomes.flatMap(\.warnings)

    let registryByMint = registry.reduce(into: [String: TokenConfig]()) { result, token in
      if result[token.address] == nil { result[token.address] = token }
    }
    let malformedSymbols =
      outcomes
      .flatMap(\.invalidMints)
      .compactMap { registryByMint[$0]?.symbol }
    if !malformedSymbols.isEmpty {
      warnings.append(
        "SPL token balance data was invalid for \(Self.formattedSymbols(malformedSymbols)); balances may be incomplete."
      )
    }
    if outcomes.reduce(0, { $0 + $1.unidentifiedInvalidAccountCount }) > 0 {
      warnings.append(
        "Some SPL token accounts returned invalid parsed amount data; balances may be incomplete.")
    }
    var totals: [String: Double] = [:]
    var warnedMints = Set<String>()
    var overflowedMints = Set<String>()
    for account in parsedAccounts {
      guard let token = registryByMint[account.mint] else { continue }
      guard !overflowedMints.contains(account.mint) else { continue }
      guard (0...36).contains(account.decimals), account.rawAmount.isFinite, account.rawAmount >= 0
      else {
        if warnedMints.insert(account.mint).inserted {
          warnings.append(
            "\(token.symbol) returned invalid on-chain amount metadata and was skipped.")
        }
        continue
      }
      // Trust the on-chain decimals for the conversion rather than silently
      // dropping the balance when they differ from the bundled registry value
      // (which previously made real balances read as zero with no warning).
      if token.decimals != account.decimals, !warnedMints.contains(account.mint) {
        warnedMints.insert(account.mint)
        warnings.append(
          "\(token.symbol) on-chain decimals (\(account.decimals)) differ from the registry (\(token.decimals)); using on-chain decimals."
        )
      }
      let scaledAmount = account.rawAmount / pow(10, Double(account.decimals))
      guard scaledAmount.isFinite,
        let nextTotal = FiniteValueMath.addingNonnegative(
          totals[account.mint, default: 0], scaledAmount)
      else {
        totals.removeValue(forKey: account.mint)
        overflowedMints.insert(account.mint)
        continue
      }
      totals[account.mint] = nextTotal
    }
    if !overflowedMints.isEmpty {
      let symbols = overflowedMints.compactMap { registryByMint[$0]?.symbol }
      warnings.append(
        "SPL balances exceeded the supported numeric range for \(Self.formattedSymbols(symbols)); those tokens were skipped."
      )
    }
    let balances: [(token: TokenConfig, amount: Double)] = totals.compactMap { mint, amount in
      guard let token = registryByMint[mint] else { return nil }
      return (token, amount)
    }
    return SolanaTokenBalanceScan(balances: balances, warnings: warnings)
  }

  public static func parseSolanaTokenAccounts(_ accounts: [SolanaTokenAccount])
    -> [ParsedSplAccount]
  {
    parseSolanaTokenAccountResult(accounts).accounts
  }

  static func parseSolanaTokenAccountResult(_ accounts: [SolanaTokenAccount])
    -> SolanaAccountParseResult
  {
    var result = SolanaAccountParseResult()
    for account in accounts {
      guard let info = account.account.data.parsed?.info else {
        result.unidentifiedInvalidAccountCount += 1
        continue
      }
      guard let amount = Double(info.tokenAmount.amount), amount.isFinite, amount >= 0 else {
        result.invalidMints.append(info.mint)
        continue
      }
      result.accounts.append(
        ParsedSplAccount(mint: info.mint, rawAmount: amount, decimals: info.tokenAmount.decimals)
      )
    }
    return result
  }

  static func solanaProgramLabel(_ program: String) -> String {
    switch program {
    case "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA":
      return "SPL Token"
    case "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb":
      return "Token-2022"
    default:
      return program
    }
  }
}
