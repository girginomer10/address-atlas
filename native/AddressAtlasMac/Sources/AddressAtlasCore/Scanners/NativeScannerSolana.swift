import Foundation

extension NativeScanner {
  private static let solanaTokenPrograms = [
    "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
    "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb",
  ]
  private static let maxSolanaSnapshotAttempts = 3

  private struct ExactParsedSplAccount: Equatable, Sendable {
    var accountPublicKey: String
    var program: String
    var mint: String
    var rawAmount: UInt64
    var decimals: Int
  }

  private struct SolanaFetchedProgramOutcome: Sendable {
    var contextSlot: UInt64
    var accounts: [ExactParsedSplAccount] = []
    var malformedAccountPublicKeys = Set<String>()
    var invalidMints: [String] = []
    var invalidAccountCount = 0
  }

  private struct SolanaNativeSnapshot: Sendable {
    var lamports: UInt64
    var contextSlot: UInt64
  }

  private struct SolanaNativeBalanceResponse: Decodable, Sendable {
    var jsonrpc: String?
    var id: Int?
    var result: NativeBalance?
    var error: JSONRPCError?

    struct NativeBalance: Decodable, Sendable {
      var context: Context?
      var value: UInt64
    }

    struct Context: Decodable, Sendable {
      var slot: UInt64?
    }
  }

  private struct SolanaSlotResponse: Decodable, Sendable {
    var jsonrpc: String?
    var id: Int?
    var result: UInt64?
    var error: JSONRPCError?
  }

  private struct SolanaGenesisResponse: Decodable, Sendable {
    var jsonrpc: String?
    var id: Int?
    var result: String?
    var error: JSONRPCError?
  }

  private enum SolanaSnapshotComponent: Hashable, Sendable {
    case native
    case tokenProgram(String)
  }

  private enum SolanaSnapshotPayload: Sendable {
    case native(SolanaNativeSnapshot)
    case tokenProgram(SolanaFetchedProgramOutcome)

    var contextSlot: UInt64 {
      switch self {
      case .native(let snapshot): snapshot.contextSlot
      case .tokenProgram(let outcome): outcome.contextSlot
      }
    }
  }

  private struct SolanaComponentFetch: Sendable {
    var component: SolanaSnapshotComponent
    var payload: SolanaSnapshotPayload?
    var warning: String?
    var retryableMinimumSlotFailure = false
  }

  private struct SolanaCoherentSnapshot: Sendable {
    var native: SolanaNativeSnapshot?
    var programOutcomes: [SolanaFetchedProgramOutcome]
    var warnings: [String]
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
    prices: [String: PricePoint],
    networkIdentityProofs: ChainNetworkValueCache<Void>? = nil
  ) async throws -> NativeScanResult {
    guard let rpc = chain.rpcUrl else { return NativeScanResult() }
    guard case .solanaGenesisHash(let expectedGenesisHash) = chain.networkIdentity else {
      throw Self.messageError(
        domain: "Solana", message: "Solana network identity is missing.")
    }
    let proofCache = networkIdentityProofs ?? ChainNetworkValueCache<Void>()
    try await proofCache.prove(
      chainID: chain.id,
      endpoint: rpc,
      identity: chain.networkIdentity
    ) {
      try await validateSolanaNetwork(rpc: rpc, expectedGenesisHash: expectedGenesisHash)
    }
    var assets: [TrackedAsset] = []
    var warnings: [String] = []
    var initialNative: SolanaNativeSnapshot?
    var snapshotFloor: UInt64?

    do {
      let native = try await fetchSolanaNativeSnapshot(
        rpc: rpc, owner: address, minimumSlot: nil)
      initialNative = native
      snapshotFloor = native.contextSlot
    } catch {
      try throwIfCancellation(error)
      warnings.append("Native SOL balance could not be read: \(error.localizedDescription)")
      if !tokens.isEmpty {
        do {
          snapshotFloor = try await fetchSolanaConfirmedSlot(rpc: rpc)
        } catch {
          try throwIfCancellation(error)
          warnings.append(
            "SPL token balances were skipped because a confirmed snapshot slot could not be established: \(error.localizedDescription)"
          )
        }
      }
    }

    guard initialNative != nil || snapshotFloor != nil else {
      return NativeScanResult(warnings: warnings)
    }

    let snapshot = try await fetchCoherentSolanaSnapshot(
      rpc: rpc,
      owner: address,
      programs: tokens.isEmpty ? [] : Self.solanaTokenPrograms,
      minimumSlot: snapshotFloor,
      initialNative: initialNative
    )
    warnings.append(contentsOf: snapshot.warnings)

    if let native = snapshot.native {
      assets.append(
        contentsOf: assetIfPositive(
          amount: Double(native.lamports) / pow(10, Double(chain.decimals)),
          address: address,
          chain: chain,
          prices: prices
        ))
    }

    let splScan = Self.makeSolanaTokenBalanceScan(
      outcomes: snapshot.programOutcomes,
      registry: tokens
    )
    assets.append(
      contentsOf: splScan.balances.compactMap { balance in
        tokenAsset(
          amount: balance.amount, address: address, chain: chain, token: balance.token,
          prices: prices, source: .spl)
      })
    warnings.append(contentsOf: splScan.warnings)

    return NativeScanResult(assets: assets, warnings: warnings)
  }

  private func validateSolanaNetwork(rpc: URL, expectedGenesisHash: String) async throws {
    let response = try await http.post(
      rpc,
      body: JSONRPCRequest(id: 0, method: "getGenesisHash", params: []),
      as: SolanaGenesisResponse.self
    )
    guard response.jsonrpc == "2.0", response.id == 0 else {
      throw Self.messageError(
        domain: "Solana", message: "Genesis-hash lookup returned a mismatched response.")
    }
    if let error = response.error {
      throw Self.rpcError(
        domain: "Solana", error: error, fallback: "Genesis-hash lookup failed.")
    }
    guard response.result == expectedGenesisHash else {
      throw Self.messageError(
        domain: "Solana", message: "RPC endpoint returned the wrong network identity.")
    }
  }

  func fetchSolanaTokenBalances(
    rpc: URL,
    owner: String,
    registry: [TokenConfig],
    minimumSlot: UInt64? = nil
  ) async throws -> SolanaTokenBalanceScan {
    guard !registry.isEmpty else { return SolanaTokenBalanceScan() }
    let snapshot = try await fetchCoherentSolanaSnapshot(
      rpc: rpc,
      owner: owner,
      programs: Self.solanaTokenPrograms,
      minimumSlot: minimumSlot,
      initialNative: nil
    )
    var result = Self.makeSolanaTokenBalanceScan(
      outcomes: snapshot.programOutcomes,
      registry: registry
    )
    result.warnings.insert(contentsOf: snapshot.warnings, at: 0)
    return result
  }

  private func fetchSolanaNativeSnapshot(
    rpc: URL,
    owner: String,
    minimumSlot: UInt64?
  ) async throws -> SolanaNativeSnapshot {
    var requestConfig: [String: RPCValue] = ["commitment": .string("confirmed")]
    if let minimumSlot {
      requestConfig["minContextSlot"] = .unsignedInteger(minimumSlot)
    }
    let response: SolanaNativeBalanceResponse
    do {
      response = try await http.post(
        rpc,
        body: JSONRPCRequest(
          id: 1,
          method: "getBalance",
          params: [.string(owner), .object(requestConfig)]
        ),
        as: SolanaNativeBalanceResponse.self
      )
    } catch is DecodingError {
      // `value` is protocol-defined integer lamports. JSONDecoder rejects
      // negative, fractional, and out-of-UInt64 values before the response can
      // reach the guards below; translate that implementation detail into the
      // same stable provider-data warning as every other malformed balance.
      throw Self.messageError(
        domain: "Solana", message: "Native SOL balance lookup returned invalid data."
      )
    }
    guard response.jsonrpc == "2.0", response.id == 1 else {
      throw Self.messageError(
        domain: "Solana", message: "Native SOL balance lookup returned a mismatched response."
      )
    }
    if let error = response.error {
      throw Self.rpcError(
        domain: "Solana", error: error, fallback: "Native SOL balance lookup failed.")
    }
    guard let nativeBalance = response.result,
      let contextSlot = nativeBalance.context?.slot
    else {
      throw Self.messageError(
        domain: "Solana", message: "Native SOL balance lookup returned an empty result.")
    }
    if let minimumSlot, contextSlot < minimumSlot {
      throw Self.messageError(
        domain: "Solana",
        message: "Native SOL balance lookup returned data older than the bound snapshot slot."
      )
    }
    return SolanaNativeSnapshot(
      lamports: nativeBalance.value,
      contextSlot: contextSlot
    )
  }

  private func fetchSolanaConfirmedSlot(rpc: URL) async throws -> UInt64 {
    let response = try await http.post(
      rpc,
      body: JSONRPCRequest(
        id: 3,
        method: "getSlot",
        params: [.object(["commitment": .string("confirmed")])]
      ),
      as: SolanaSlotResponse.self
    )
    guard response.jsonrpc == "2.0", response.id == 3 else {
      throw Self.messageError(
        domain: "Solana", message: "Snapshot-slot lookup returned a mismatched response.")
    }
    if let error = response.error {
      throw Self.rpcError(
        domain: "Solana", error: error, fallback: "Snapshot-slot lookup failed.")
    }
    guard let slot = response.result else {
      throw Self.messageError(
        domain: "Solana", message: "Snapshot-slot lookup returned an empty result.")
    }
    return slot
  }

  private func fetchSolanaProgramSnapshot(
    rpc: URL,
    owner: String,
    program: String,
    minimumSlot: UInt64?
  ) async throws -> SolanaFetchedProgramOutcome {
    var requestConfig: [String: RPCValue] = [
      "encoding": .string("jsonParsed"),
      "commitment": .string("confirmed"),
    ]
    if let minimumSlot {
      requestConfig["minContextSlot"] = .unsignedInteger(minimumSlot)
    }
    let response = try await http.post(
      rpc,
      body: JSONRPCRequest(
        id: 2,
        method: "getTokenAccountsByOwner",
        params: [
          .string(owner),
          .object(["programId": .string(program)]),
          .object(requestConfig),
        ]
      ),
      as: SolanaTokenAccountsResponse.self
    )
    guard response.jsonrpc == "2.0", response.id == 2 else {
      throw Self.messageError(
        domain: "SolanaTokenAccounts",
        message: "Token account lookup returned a mismatched response."
      )
    }
    if let error = response.error {
      throw Self.rpcError(
        domain: "SolanaTokenAccounts", error: error, fallback: "Token account lookup failed.")
    }
    guard let result = response.result, let contextSlot = result.context?.slot else {
      throw Self.messageError(
        domain: "SolanaTokenAccounts", message: "Token account lookup returned an empty result."
      )
    }
    if let minimumSlot, contextSlot < minimumSlot {
      throw Self.messageError(
        domain: "SolanaTokenAccounts",
        message: "Token account lookup returned data older than the bound snapshot slot."
      )
    }
    let parsed = Self.parseSolanaTokenAccountResult(
      result.value,
      expectedOwner: owner,
      expectedProgram: program
    )
    return SolanaFetchedProgramOutcome(
      contextSlot: contextSlot,
      accounts: parsed.accounts,
      malformedAccountPublicKeys: parsed.malformedAccountPublicKeys,
      invalidMints: parsed.invalidMints,
      invalidAccountCount: parsed.invalidAccountCount
    )
  }

  private func fetchCoherentSolanaSnapshot(
    rpc: URL,
    owner: String,
    programs: [String],
    minimumSlot: UInt64?,
    initialNative: SolanaNativeSnapshot?
  ) async throws -> SolanaCoherentSnapshot {
    let components =
      (initialNative == nil ? [] : [SolanaSnapshotComponent.native])
      + programs.map(SolanaSnapshotComponent.tokenProgram)
    var activeComponents = Set(components)
    var payloads: [SolanaSnapshotComponent: SolanaSnapshotPayload] = [:]
    var attempts: [SolanaSnapshotComponent: Int] = [:]
    var warnings: [String] = []

    if let initialNative {
      payloads[.native] = .native(initialNative)
      attempts[.native] = 1
    }

    for _ in 0..<Self.maxSolanaSnapshotAttempts {
      try Task.checkCancellation()
      if Self.isCoherentSolanaSnapshot(
        components: components,
        activeComponents: activeComponents,
        payloads: payloads
      ) {
        return Self.coherentSolanaSnapshot(
          components: components,
          activeComponents: activeComponents,
          payloads: payloads,
          warnings: warnings
        )
      }

      let targetSlot = ([minimumSlot] + payloads.values.map(\.contextSlot)).compactMap { $0 }.max()
      let componentsToFetch = components.filter { component in
        guard activeComponents.contains(component),
          attempts[component, default: 0] < Self.maxSolanaSnapshotAttempts
        else { return false }
        guard let payload = payloads[component] else { return true }
        guard let targetSlot else { return false }
        return payload.contextSlot < targetSlot
      }
      guard !componentsToFetch.isEmpty else { break }

      for component in componentsToFetch {
        attempts[component, default: 0] += 1
      }
      let fetched = try await boundedConcurrentMap(
        componentsToFetch,
        maxConcurrent: componentsToFetch.count
      ) { component in
        do {
          let payload: SolanaSnapshotPayload
          switch component {
          case .native:
            payload = .native(
              try await fetchSolanaNativeSnapshot(
                rpc: rpc, owner: owner, minimumSlot: targetSlot))
          case .tokenProgram(let program):
            payload = .tokenProgram(
              try await fetchSolanaProgramSnapshot(
                rpc: rpc, owner: owner, program: program, minimumSlot: targetSlot))
          }
          return SolanaComponentFetch(component: component, payload: payload)
        } catch {
          try throwIfCancellation(error)
          let warning: String
          switch component {
          case .native:
            warning =
              "Native SOL balance could not be aligned to the coherent snapshot and was skipped: \(error.localizedDescription)"
          case .tokenProgram(let program):
            warning =
              "\(Self.solanaProgramLabel(program)) token account scan failed; SPL balances may be incomplete."
          }
          return SolanaComponentFetch(
            component: component,
            payload: nil,
            warning: warning,
            retryableMinimumSlotFailure: Self.isSolanaMinimumContextSlotFailure(error)
          )
        }
      }

      for result in fetched {
        if let payload = result.payload {
          payloads[result.component] = payload
        } else if result.retryableMinimumSlotFailure,
          attempts[result.component, default: 0] < Self.maxSolanaSnapshotAttempts
        {
          // A load-balanced RPC may route this request to a node that has not
          // reached the requested floor yet. Keep the component active (and any
          // earlier, lower-slot payload) so the next bounded convergence round
          // can retry without accepting incoherent data.
          continue
        } else {
          activeComponents.remove(result.component)
          payloads.removeValue(forKey: result.component)
        }
        if let warning = result.warning {
          warnings.append(warning)
        }
      }
    }

    if Self.isCoherentSolanaSnapshot(
      components: components,
      activeComponents: activeComponents,
      payloads: payloads
    ) {
      return Self.coherentSolanaSnapshot(
        components: components,
        activeComponents: activeComponents,
        payloads: payloads,
        warnings: warnings
      )
    }

    let scope = initialNative == nil ? "SPL token balances" : "SOL and SPL balances"
    warnings.append(
      "\(scope) were skipped because the RPC did not return one coherent context slot after \(Self.maxSolanaSnapshotAttempts) bounded snapshot attempts."
    )
    return SolanaCoherentSnapshot(
      native: nil,
      programOutcomes: [],
      warnings: warnings
    )
  }

  private static func isSolanaMinimumContextSlotFailure(_ error: Error) -> Bool {
    let failure = error as NSError
    guard failure.code == -32016 else { return false }
    return failure.domain == "AddressAtlas.Solana"
      || failure.domain == "AddressAtlas.SolanaTokenAccounts"
  }

  private static func isCoherentSolanaSnapshot(
    components: [SolanaSnapshotComponent],
    activeComponents: Set<SolanaSnapshotComponent>,
    payloads: [SolanaSnapshotComponent: SolanaSnapshotPayload]
  ) -> Bool {
    let included = components.filter(activeComponents.contains)
    guard included.allSatisfy({ payloads[$0] != nil }) else { return false }
    return Set(included.compactMap { payloads[$0]?.contextSlot }).count <= 1
  }

  private static func coherentSolanaSnapshot(
    components: [SolanaSnapshotComponent],
    activeComponents: Set<SolanaSnapshotComponent>,
    payloads: [SolanaSnapshotComponent: SolanaSnapshotPayload],
    warnings: [String]
  ) -> SolanaCoherentSnapshot {
    var native: SolanaNativeSnapshot?
    var programOutcomes: [SolanaFetchedProgramOutcome] = []
    for component in components where activeComponents.contains(component) {
      switch payloads[component] {
      case .native(let snapshot): native = snapshot
      case .tokenProgram(let outcome): programOutcomes.append(outcome)
      case nil: continue
      }
    }
    return SolanaCoherentSnapshot(
      native: native,
      programOutcomes: programOutcomes,
      warnings: warnings
    )
  }

  private static func makeSolanaTokenBalanceScan(
    outcomes: [SolanaFetchedProgramOutcome],
    registry: [TokenConfig]
  ) -> SolanaTokenBalanceScan {
    var warnings: [String] = []
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
