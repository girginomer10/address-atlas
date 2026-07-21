import Foundation

extension NativeScanner {
  private struct ExactParsedSplAccount: Equatable, Sendable {
    var accountPublicKey: String
    var program: String
    var mint: String
    var rawAmount: UInt64
    var decimals: Int
  }

  private struct SolanaFetchedProgramOutcome: Sendable {
    var accounts: [ExactParsedSplAccount] = []
    var malformedAccountPublicKeys = Set<String>()
    var warnings: [String] = []
    var invalidMints: [String] = []
    var invalidAccountCount = 0
  }

  private struct SolanaParsedAccountResult {
    var accounts: [ExactParsedSplAccount] = []
    var malformedAccountPublicKeys = Set<String>()
    var invalidMints: [String] = []
    var invalidAccountCount = 0
  }

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
        let parsed = Self.parseSolanaTokenAccountResult(
          accounts,
          expectedOwner: owner,
          expectedProgram: program
        )
        return SolanaFetchedProgramOutcome(
          accounts: parsed.accounts,
          malformedAccountPublicKeys: parsed.malformedAccountPublicKeys,
          invalidMints: parsed.invalidMints,
          invalidAccountCount: parsed.invalidAccountCount
        )
      } catch {
        try throwIfCancellation(error)
        return SolanaFetchedProgramOutcome(
          warnings: [
            "\(Self.solanaProgramLabel(program)) token account scan failed; SPL balances may be incomplete."
          ]
        )
      }
    }
    var warnings = outcomes.flatMap(\.warnings)
    let malformedAccountPublicKeys = outcomes.reduce(into: Set<String>()) { result, outcome in
      result.formUnion(outcome.malformedAccountPublicKeys)
    }
    let deduplicatedAccounts = Self.deduplicateSolanaAccountRecords(
      outcomes.flatMap(\.accounts),
      taintedAccountPublicKeys: malformedAccountPublicKeys,
      publicKey: \.accountPublicKey
    )
    warnings.append(contentsOf: deduplicatedAccounts.warnings)
    let parsedAccounts = deduplicatedAccounts.accounts

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
    if outcomes.reduce(0, { $0 + $1.invalidAccountCount }) > 0 {
      warnings.append(
        "Some SPL token accounts returned invalid parsed data; balances may be incomplete.")
    }
    let accountsByMint = Dictionary(
      grouping: parsedAccounts.filter { registryByMint[$0.mint] != nil },
      by: \.mint
    )
    var balances: [(token: TokenConfig, amount: Double)] = []
    var inconsistentDecimalsSymbols: [String] = []
    var overflowedSymbols: [String] = []
    for mint in accountsByMint.keys.sorted() {
      guard let token = registryByMint[mint], let mintAccounts = accountsByMint[mint] else {
        continue
      }
      let decimalsValues = Set(mintAccounts.map(\.decimals))
      guard decimalsValues.count == 1, let decimals = decimalsValues.first else {
        inconsistentDecimalsSymbols.append(token.symbol)
        continue
      }

      var rawTotal: UInt64 = 0
      var didOverflow = false
      for account in mintAccounts {
        let addition = rawTotal.addingReportingOverflow(account.rawAmount)
        guard !addition.overflow else {
          didOverflow = true
          break
        }
        rawTotal = addition.partialValue
      }
      guard !didOverflow else {
        overflowedSymbols.append(token.symbol)
        continue
      }

      // Trust the one consistent on-chain decimals value for conversion rather
      // than silently dropping a real balance when the bundled registry differs.
      if token.decimals != decimals {
        warnings.append(
          "\(token.symbol) on-chain decimals (\(decimals)) differ from the registry (\(token.decimals)); using on-chain decimals."
        )
      }
      let scaledAmount = Double(rawTotal) / pow(10, Double(decimals))
      guard scaledAmount.isFinite else {
        overflowedSymbols.append(token.symbol)
        continue
      }
      balances.append((token, scaledAmount))
    }
    if !inconsistentDecimalsSymbols.isEmpty {
      warnings.append(
        "SPL balances used inconsistent on-chain decimals for \(Self.formattedSymbols(inconsistentDecimalsSymbols)); those tokens were skipped."
      )
    }
    if !overflowedSymbols.isEmpty {
      warnings.append(
        "SPL balances exceeded the supported numeric range for \(Self.formattedSymbols(overflowedSymbols)); those tokens were skipped."
      )
    }
    return SolanaTokenBalanceScan(balances: balances, warnings: warnings)
  }

  static func deduplicateSolanaAccounts(
    _ accounts: [ParsedSplAccount],
    taintedAccountPublicKeys: Set<String> = []
  ) -> SolanaProgramOutcome {
    let result = deduplicateSolanaAccountRecords(
      accounts,
      taintedAccountPublicKeys: taintedAccountPublicKeys,
      publicKey: \.accountPublicKey
    )
    return SolanaProgramOutcome(accounts: result.accounts, warnings: result.warnings)
  }

  private static func deduplicateSolanaAccountRecords<Account: Equatable>(
    _ accounts: [Account],
    taintedAccountPublicKeys: Set<String>,
    publicKey: (Account) -> String
  ) -> (accounts: [Account], warnings: [String]) {
    var accountsByPublicKey: [String: Account] = [:]
    var conflictingAccountPublicKeys = Set<String>()
    var identicalDuplicateAccountCount = 0
    let validAccountPublicKeys = Set(accounts.map(publicKey))
    let malformedDuplicatePublicKeys = taintedAccountPublicKeys.intersection(
      validAccountPublicKeys
    )
    for account in accounts {
      let accountPublicKey = publicKey(account)
      guard !taintedAccountPublicKeys.contains(accountPublicKey) else { continue }
      guard !conflictingAccountPublicKeys.contains(accountPublicKey) else { continue }
      if let existing = accountsByPublicKey[accountPublicKey] {
        if existing == account {
          identicalDuplicateAccountCount += 1
        } else {
          accountsByPublicKey.removeValue(forKey: accountPublicKey)
          conflictingAccountPublicKeys.insert(accountPublicKey)
        }
        continue
      }
      accountsByPublicKey[accountPublicKey] = account
    }
    var warnings: [String] = []
    if !malformedDuplicatePublicKeys.isEmpty {
      warnings.append(
        malformedDuplicatePublicKeys.count == 1
          ? "Solana discarded one token account because a malformed duplicate used the same public key."
          : "Solana discarded \(malformedDuplicatePublicKeys.count) token accounts because malformed duplicates used the same public keys."
      )
    }
    if identicalDuplicateAccountCount > 0 {
      warnings.append(
        identicalDuplicateAccountCount == 1
          ? "Solana repeated one identical token account record; the duplicate was skipped to avoid double-counting."
          : "Solana repeated \(identicalDuplicateAccountCount) identical token account records; the duplicates were skipped to avoid double-counting."
      )
    }
    if !conflictingAccountPublicKeys.isEmpty {
      warnings.append(
        conflictingAccountPublicKeys.count == 1
          ? "Solana returned conflicting data for one repeated token account; every version was skipped."
          : "Solana returned conflicting data for \(conflictingAccountPublicKeys.count) repeated token accounts; every version was skipped."
      )
    }
    let parsedAccounts = accountsByPublicKey.keys.sorted().compactMap {
      accountsByPublicKey[$0]
    }
    return (parsedAccounts, warnings)
  }

  public static func parseSolanaTokenAccounts(
    _ accounts: [SolanaTokenAccount],
    expectedOwner: String,
    expectedProgram: String
  )
    -> [ParsedSplAccount]
  {
    parseSolanaTokenAccountResult(
      accounts,
      expectedOwner: expectedOwner,
      expectedProgram: expectedProgram
    ).accounts.map { account in
      ParsedSplAccount(
        accountPublicKey: account.accountPublicKey,
        mint: account.mint,
        rawAmount: Double(account.rawAmount),
        decimals: account.decimals
      )
    }
  }

  private static func parseSolanaTokenAccountResult(
    _ accounts: [SolanaTokenAccount],
    expectedOwner: String,
    expectedProgram: String
  )
    -> SolanaParsedAccountResult
  {
    var result = SolanaParsedAccountResult()
    for account in accounts {
      guard
        let publicKey = account.pubkey.flatMap({
          AddressDetection.canonicalAddress($0, family: .solana)
        })
      else {
        result.invalidAccountCount += 1
        continue
      }
      guard
        let rpcAccount = account.account,
        let parsed = rpcAccount.data?.parsed,
        let info = parsed.info
      else {
        result.malformedAccountPublicKeys.insert(publicKey)
        result.invalidAccountCount += 1
        continue
      }
      guard
        rpcAccount.owner == expectedProgram,
        parsed.type == "account",
        info.owner == expectedOwner
      else {
        result.malformedAccountPublicKeys.insert(publicKey)
        if let mint = info.mint { result.invalidMints.append(mint) }
        result.invalidAccountCount += 1
        continue
      }
      guard
        let rawMint = info.mint,
        let mint = AddressDetection.canonicalAddress(rawMint, family: .solana),
        let tokenAmount = info.tokenAmount,
        let decimals = tokenAmount.decimals,
        (0...36).contains(decimals),
        let rawAmount = tokenAmount.amount,
        let amount = solanaRawAmount(rawAmount)
      else {
        result.malformedAccountPublicKeys.insert(publicKey)
        if let mint = info.mint { result.invalidMints.append(mint) }
        result.invalidAccountCount += 1
        continue
      }
      result.accounts.append(
        ExactParsedSplAccount(
          accountPublicKey: publicKey,
          program: expectedProgram,
          mint: mint,
          rawAmount: amount,
          decimals: decimals
        )
      )
    }
    return result
  }

  private static func solanaRawAmount(_ value: String) -> UInt64? {
    let bytes = value.utf8
    guard !bytes.isEmpty,
      bytes.allSatisfy({ byte in byte >= 48 && byte <= 57 }),
      bytes.count == 1 || bytes.first != 48,
      let amount = UInt64(value)
    else { return nil }
    return amount
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
