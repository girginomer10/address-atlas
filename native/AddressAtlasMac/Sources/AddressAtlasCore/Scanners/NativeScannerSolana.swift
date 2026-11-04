import Foundation

extension NativeScanner {
  private static let solanaTokenPrograms = [
    "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
    "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb",
  ]
  private static let maxSolanaSnapshotAttempts = 3
  private static let solanaStakeProgram = "Stake11111111111111111111111111111111111111"
  /// Every stake account is exactly 200 bytes. Filtering by size lets the RPC
  /// skip the memcmp scan over unrelated accounts.
  private static let solanaStakeAccountSize: UInt64 = 200
  private static let solanaStakeNotDeactivating = UInt64.max

  /// Which authority field of a stake account the memcmp filter matches. The
  /// Stake program lays an account out as: 4-byte state tag, 8-byte rent
  /// reserve, then the staker pubkey at byte 12 and the withdrawer at byte 44.
  enum SolanaStakeAuthority: Sendable {
    case staker
    case withdrawer

    var memcmpOffset: UInt64 {
      switch self {
      case .staker: 12
      case .withdrawer: 44
      }
    }

    var requestID: Int {
      switch self {
      case .staker: 4
      case .withdrawer: 5
      }
    }
  }

  /// Warning for the one failure that matters to the balance: the lookup of
  /// accounts the address can withdraw. Public RPC providers commonly reject
  /// or rate-limit `getProgramAccounts`, so say so instead of implying the
  /// address has no stake.
  static let solanaStakeUnavailableWarning =
    "Couldn't read this wallet's Solana stake accounts, so staked SOL and SOL in cooldown may be missing from this scan. Some public servers reject or limit this request."

  /// How a stake account is counted. Everything is a function of the account's
  /// delegation epochs and the current epoch; see `solanaStakeState`.
  enum SolanaStakeState: Equatable, Sendable {
    case activating
    case active
    case deactivating
    /// Never delegated, or fully cooled down and still sitting in the account.
    case inactive
  }

  struct SolanaParsedStakeAccount: Equatable, Sendable {
    var publicKey: String
    var lamports: UInt64
    var staker: String
    var withdrawer: String
    /// Both nil for an initialized account that was never delegated.
    var activationEpoch: UInt64?
    var deactivationEpoch: UInt64?
  }

  struct SolanaStakeSummary: Equatable, Sendable {
    /// Active, activating, and inactive-but-unwithdrawn lamports.
    var stakedLamports: UInt64 = 0
    /// Lamports of accounts that are deactivating.
    var unbondingLamports: UInt64 = 0
    var warnings: [String] = []
  }

  private struct SolanaFetchedStakeOutcome: Sendable {
    var contextSlot: UInt64
    var authority: SolanaStakeAuthority
    var accounts: [SolanaParsedStakeAccount] = []
    var invalidAccountCount = 0
  }

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
    case stakeAccounts(SolanaStakeAuthority)
  }

  private enum SolanaSnapshotPayload: Sendable {
    case native(SolanaNativeSnapshot)
    case tokenProgram(SolanaFetchedProgramOutcome)
    case stakeAccounts(SolanaFetchedStakeOutcome)

    var contextSlot: UInt64 {
      switch self {
      case .native(let snapshot): snapshot.contextSlot
      case .tokenProgram(let outcome): outcome.contextSlot
      case .stakeAccounts(let outcome): outcome.contextSlot
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
    var stakeOutcomes: [SolanaFetchedStakeOutcome] = []
    /// The one slot every included component was read at.
    var contextSlot: UInt64?
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
        domain: "Solana", message: "Couldn't confirm the Solana network, so balances are missing from this scan. Check the server settings in Settings.")
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
      warnings.append("SOL balance is missing from this scan: \(ProviderErrorSanitizer.description(of: error))")
      // Token and stake-account reads still need one agreed slot to be
      // trustworthy, so fall back to a validated confirmed slot.
      do {
        snapshotFloor = try await fetchSolanaConfirmedSlot(rpc: rpc)
      } catch {
        try throwIfCancellation(error)
        warnings.append(
          tokens.isEmpty
            ? "Stake account balances are missing from this scan because the server didn't return consistent data: \(ProviderErrorSanitizer.description(of: error))"
            : "Token and stake account balances are missing from this scan because the server didn't return consistent data: \(ProviderErrorSanitizer.description(of: error))"
        )
      }
    }

    guard initialNative != nil || snapshotFloor != nil else {
      return NativeScanResult(warnings: warnings)
    }

    let snapshot = try await fetchCoherentSolanaSnapshot(
      rpc: rpc,
      owner: address,
      programs: tokens.isEmpty ? [] : Self.solanaTokenPrograms,
      stakeAuthorities: [.staker, .withdrawer],
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

    let stake = try await solanaStakeResult(
      snapshot: snapshot,
      rpc: rpc,
      owner: address,
      chain: chain,
      prices: prices
    )
    assets.append(contentsOf: stake.assets)
    warnings.append(contentsOf: stake.warnings)

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
        domain: "Solana", message: "The server's reply to the network check didn't match the request, so balances are missing from this scan. Scan again later.")
    }
    if let error = response.error {
      throw Self.rpcError(
        domain: "Solana", error: error, fallback: "The network check failed, so balances are missing from this scan. Scan again later.")
    }
    guard response.result == expectedGenesisHash else {
      throw Self.messageError(
        domain: "Solana", message: "The server isn't on the Solana network, so balances are missing from this scan. Check the server settings in Settings.")
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
        domain: "Solana", message: "The server sent a balance Address Atlas couldn't read."
      )
    }
    guard response.jsonrpc == "2.0", response.id == 1 else {
      throw Self.messageError(
        domain: "Solana", message: "The server's reply didn't match the request."
      )
    }
    if let error = response.error {
      throw Self.rpcError(
        domain: "Solana", error: error, fallback: "The balance request failed.")
    }
    guard let nativeBalance = response.result,
      let contextSlot = nativeBalance.context?.slot
    else {
      throw Self.messageError(
        domain: "Solana", message: "The server's reply was empty.")
    }
    if let minimumSlot, contextSlot < minimumSlot {
      throw Self.messageError(
        domain: "Solana",
        message: "The server's reply was older than the rest of this scan's data."
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
        domain: "Solana", message: "The server's reply didn't match the request.")
    }
    if let error = response.error {
      throw Self.rpcError(
        domain: "Solana", error: error, fallback: "Couldn't read the latest block from the server.")
    }
    guard let slot = response.result else {
      throw Self.messageError(
        domain: "Solana", message: "The server's reply was empty.")
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

  /// One `getProgramAccounts` page of stake accounts whose staker or
  /// withdrawer is `owner`. `withContext` returns the slot the node answered
  /// at, so stake accounts take part in the same coherent-snapshot rule as the
  /// native balance and token accounts: moving SOL into a stake account between
  /// two reads can then never be counted twice or not at all.
  private func fetchSolanaStakeSnapshot(
    rpc: URL,
    owner: String,
    authority: SolanaStakeAuthority,
    minimumSlot: UInt64?
  ) async throws -> SolanaFetchedStakeOutcome {
    var requestConfig: [String: RPCValue] = [
      "encoding": .string("jsonParsed"),
      "commitment": .string("confirmed"),
      "withContext": .bool(true),
      "filters": .array([
        .object(["dataSize": .unsignedInteger(Self.solanaStakeAccountSize)]),
        .object([
          "memcmp": .object([
            "offset": .unsignedInteger(authority.memcmpOffset),
            "bytes": .string(owner),
          ])
        ]),
      ]),
    ]
    if let minimumSlot {
      requestConfig["minContextSlot"] = .unsignedInteger(minimumSlot)
    }
    let response = try await http.post(
      rpc,
      body: JSONRPCRequest(
        id: authority.requestID,
        method: "getProgramAccounts",
        params: [.string(Self.solanaStakeProgram), .object(requestConfig)]
      ),
      as: SolanaStakeAccountsResponse.self
    )
    guard response.jsonrpc == "2.0", response.id == authority.requestID else {
      throw Self.messageError(
        domain: "SolanaStake", message: "Stake account lookup returned a mismatched response.")
    }
    if let error = response.error {
      throw Self.rpcError(
        domain: "SolanaStake", error: error, fallback: "Stake account lookup failed.")
    }
    guard let result = response.result, let contextSlot = result.context?.slot else {
      throw Self.messageError(
        domain: "SolanaStake", message: "Stake account lookup returned an empty result.")
    }
    if let minimumSlot, contextSlot < minimumSlot {
      throw Self.messageError(
        domain: "SolanaStake",
        message: "Stake account lookup returned data older than the bound snapshot slot.")
    }
    let parsed = Self.parseSolanaStakeAccounts(result.value, owner: owner, authority: authority)
    return SolanaFetchedStakeOutcome(
      contextSlot: contextSlot,
      authority: authority,
      accounts: parsed.accounts,
      invalidAccountCount: parsed.invalidAccountCount
    )
  }

  /// The epoch decides whether delegated stake is still earning, cooling
  /// down, or finished cooling down. `minContextSlot` keeps the answer from
  /// predating the snapshot the accounts were read at.
  private func fetchSolanaCurrentEpoch(rpc: URL, minimumSlot: UInt64?) async throws -> UInt64 {
    var requestConfig: [String: RPCValue] = ["commitment": .string("confirmed")]
    if let minimumSlot {
      requestConfig["minContextSlot"] = .unsignedInteger(minimumSlot)
    }
    let response = try await http.post(
      rpc,
      body: JSONRPCRequest(id: 6, method: "getEpochInfo", params: [.object(requestConfig)]),
      as: SolanaEpochInfoResponse.self
    )
    guard response.jsonrpc == "2.0", response.id == 6 else {
      throw Self.messageError(
        domain: "SolanaStake", message: "Epoch lookup returned a mismatched response.")
    }
    if let error = response.error {
      throw Self.rpcError(domain: "SolanaStake", error: error, fallback: "Epoch lookup failed.")
    }
    guard let epoch = response.result?.epoch else {
      throw Self.messageError(
        domain: "SolanaStake", message: "Epoch lookup returned an empty result.")
    }
    return epoch
  }

  /// Turns the coherent snapshot's stake outcomes into holdings.
  ///
  /// Counting rules:
  /// - Only accounts the address can *withdraw* are its funds. Accounts where
  ///   it is merely the staker (a delegation manager acting for someone else)
  ///   are never counted; they are reported in one warning.
  /// - An account's whole lamport balance is counted, rent reserve and
  ///   compounded rewards included, because that is what a withdrawal pays out.
  /// - If the epoch cannot be read, every account is counted as staked with a
  ///   warning: the total stays right and only the state label is uncertain.
  private func solanaStakeResult(
    snapshot: SolanaCoherentSnapshot,
    rpc: URL,
    owner: String,
    chain: ChainConfig,
    prices: [String: PricePoint]
  ) async throws -> NativeScanResult {
    // No withdrawer outcome means the lookup failed or the snapshot never
    // converged; either way a warning has already been recorded.
    guard snapshot.stakeOutcomes.contains(where: { $0.authority == .withdrawer }) else {
      return NativeScanResult()
    }
    var warnings: [String] = []
    let invalidCount = snapshot.stakeOutcomes.reduce(0) { $0 + $1.invalidAccountCount }
    if invalidCount > 0 {
      warnings.append(
        "Some Solana stake accounts had data Address Atlas couldn't read, so staked balances may be incomplete.")
    }
    let merged = Self.mergeSolanaStakeAccounts(snapshot.stakeOutcomes.flatMap(\.accounts))
    warnings.append(contentsOf: merged.warnings)
    guard !merged.accounts.isEmpty else {
      return NativeScanResult(warnings: warnings)
    }

    var currentEpoch: UInt64?
    if merged.accounts.contains(where: { $0.withdrawer == owner }) {
      do {
        currentEpoch = try await fetchSolanaCurrentEpoch(
          rpc: rpc, minimumSlot: snapshot.contextSlot)
      } catch {
        try throwIfCancellation(error)
      }
    }
    let summary = Self.summarizeSolanaStake(
      merged.accounts, owner: owner, currentEpoch: currentEpoch)
    warnings.append(contentsOf: summary.warnings)

    let scale = pow(10, Double(chain.decimals))
    var assets = assetIfPositive(
      amount: Double(summary.stakedLamports) / scale,
      address: owner,
      chain: chain,
      prices: prices,
      name: "\(chain.name) Staked",
      source: .staked
    )
    assets += assetIfPositive(
      amount: Double(summary.unbondingLamports) / scale,
      address: owner,
      chain: chain,
      prices: prices,
      name: "\(chain.name) Unbonding",
      source: .unbonding
    )
    return NativeScanResult(assets: assets, warnings: warnings)
  }

  private func fetchCoherentSolanaSnapshot(
    rpc: URL,
    owner: String,
    programs: [String],
    stakeAuthorities: [SolanaStakeAuthority] = [],
    minimumSlot: UInt64?,
    initialNative: SolanaNativeSnapshot?
  ) async throws -> SolanaCoherentSnapshot {
    let components =
      (initialNative == nil ? [] : [SolanaSnapshotComponent.native])
      + programs.map(SolanaSnapshotComponent.tokenProgram)
      + stakeAuthorities.map(SolanaSnapshotComponent.stakeAccounts)
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
          case .stakeAccounts(let authority):
            payload = .stakeAccounts(
              try await fetchSolanaStakeSnapshot(
                rpc: rpc, owner: owner, authority: authority, minimumSlot: targetSlot))
          }
          return SolanaComponentFetch(component: component, payload: payload)
        } catch {
          try throwIfCancellation(error)
          let warning: String?
          switch component {
          case .native:
            warning =
              "SOL balance is missing from this scan because it didn't line up with the rest of the data: \(ProviderErrorSanitizer.description(of: error))"
          case .tokenProgram(let program):
            warning =
              "Couldn't read \(Self.solanaProgramLabel(program)) balances, so some tokens may be missing from this scan. Scan again later."
          case .stakeAccounts(.withdrawer):
            // The withdrawer lookup is the one that finds the address's own
            // stake. Losing the staker lookup only loses an informational
            // count, so it does not warn a second time.
            warning = Self.solanaStakeUnavailableWarning
          case .stakeAccounts(.staker):
            warning = nil
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

    var scopeParts: [String] = []
    if initialNative != nil { scopeParts.append("SOL") }
    if !stakeAuthorities.isEmpty { scopeParts.append("stake account") }
    scopeParts.append("token")
    let scope: String
    if scopeParts.count == 1 {
      scope = "Token balances"
    } else if scopeParts.count == 2 {
      scope = "\(scopeParts[0]) and \(scopeParts[1]) balances"
    } else {
      scope = "\(scopeParts.dropLast().joined(separator: ", ")) and \(scopeParts[scopeParts.count - 1]) balances"
    }
    warnings.append(
      "\(scope) are missing from this scan because the server didn't return consistent data after \(Self.maxSolanaSnapshotAttempts) tries. Scan again later."
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
      || failure.domain == "AddressAtlas.SolanaStake"
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
    var stakeOutcomes: [SolanaFetchedStakeOutcome] = []
    for component in components where activeComponents.contains(component) {
      switch payloads[component] {
      case .native(let snapshot): native = snapshot
      case .tokenProgram(let outcome): programOutcomes.append(outcome)
      case .stakeAccounts(let outcome): stakeOutcomes.append(outcome)
      case nil: continue
      }
    }
    return SolanaCoherentSnapshot(
      native: native,
      programOutcomes: programOutcomes,
      stakeOutcomes: stakeOutcomes,
      // Coherent means every included payload shares this one slot.
      contextSlot: components.compactMap { payloads[$0]?.contextSlot }.first,
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
        "Address Atlas couldn't read the Solana balance data for \(Self.formattedSymbols(malformedSymbols)), so those balances may be missing from this scan."
      )
    }
    if outcomes.reduce(0, { $0 + $1.invalidAccountCount }) > 0 {
      warnings.append(
        "Some Solana token accounts had data Address Atlas couldn't read, so token balances may be incomplete.")
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
          "\(token.symbol) has \(decimals) decimals on Solana, not the \(token.decimals) Address Atlas expected. The balance uses \(decimals)."
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
        "Solana reported different decimals for \(Self.formattedSymbols(inconsistentDecimalsSymbols)), so those tokens are left out of this scan."
      )
    }
    if !overflowedSymbols.isEmpty {
      warnings.append(
        "The balances of \(Self.formattedSymbols(overflowedSymbols)) are larger than Address Atlas can add up, so those tokens are left out of this scan."
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
          ? "One Solana token account was left out because another record used the same address with invalid data."
          : "\(malformedDuplicatePublicKeys.count) Solana token accounts were left out because other records used the same addresses with invalid data."
      )
    }
    if identicalDuplicateAccountCount > 0 {
      warnings.append(
        identicalDuplicateAccountCount == 1
          ? "Solana listed the same token account twice. It was counted once."
          : "Solana listed \(identicalDuplicateAccountCount) token accounts more than once. Each was counted once."
      )
    }
    if !conflictingAccountPublicKeys.isEmpty {
      warnings.append(
        conflictingAccountPublicKeys.count == 1
          ? "Solana sent conflicting data for one token account, so it's left out of this scan. Scan again later."
          : "Solana sent conflicting data for \(conflictingAccountPublicKeys.count) token accounts, so they're left out of this scan. Scan again later."
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

  /// Validates every returned stake account against what was asked for: the
  /// Stake program owns it, it has a usable parsed layout, and the requested
  /// authority field really is `owner`. Anything else is counted and reported,
  /// never silently used.
  static func parseSolanaStakeAccounts(
    _ accounts: [SolanaStakeAccount],
    owner: String,
    authority: SolanaStakeAuthority
  ) -> (accounts: [SolanaParsedStakeAccount], invalidAccountCount: Int) {
    var parsedAccounts: [SolanaParsedStakeAccount] = []
    var invalidAccountCount = 0
    for account in accounts {
      guard
        let publicKey = account.pubkey.flatMap({
          AddressDetection.canonicalAddress($0, family: .solana)
        }),
        let rpcAccount = account.account,
        rpcAccount.owner == solanaStakeProgram,
        let lamports = rpcAccount.lamports,
        let parsed = rpcAccount.data?.parsed,
        let info = parsed.info,
        let staker = info.meta?.staker.flatMap({
          AddressDetection.canonicalAddress($0, family: .solana)
        }),
        let withdrawer = info.meta?.withdrawer.flatMap({
          AddressDetection.canonicalAddress($0, family: .solana)
        }),
        (authority == .staker ? staker : withdrawer) == owner
      else {
        invalidAccountCount += 1
        continue
      }
      var activationEpoch: UInt64?
      var deactivationEpoch: UInt64?
      switch parsed.type {
      case "delegated":
        guard let activation = info.stake?.activationEpoch,
          let deactivation = info.stake?.deactivationEpoch
        else {
          invalidAccountCount += 1
          continue
        }
        activationEpoch = activation
        deactivationEpoch = deactivation
      case "initialized":
        break
      default:
        invalidAccountCount += 1
        continue
      }
      parsedAccounts.append(
        SolanaParsedStakeAccount(
          publicKey: publicKey,
          lamports: lamports,
          staker: staker,
          withdrawer: withdrawer,
          activationEpoch: activationEpoch,
          deactivationEpoch: deactivationEpoch
        ))
    }
    return (parsedAccounts, invalidAccountCount)
  }

  /// Unions the staker-filtered and withdrawer-filtered results by public key.
  /// An account that names the same address in both roles (the usual case)
  /// legitimately appears in both, so identical repeats are silent. Differing
  /// records for one key cannot both be right and are dropped with a warning.
  static func mergeSolanaStakeAccounts(
    _ accounts: [SolanaParsedStakeAccount]
  ) -> (accounts: [SolanaParsedStakeAccount], warnings: [String]) {
    var byPublicKey: [String: SolanaParsedStakeAccount] = [:]
    var conflicting = Set<String>()
    for account in accounts {
      guard !conflicting.contains(account.publicKey) else { continue }
      if let existing = byPublicKey[account.publicKey] {
        if existing != account {
          byPublicKey.removeValue(forKey: account.publicKey)
          conflicting.insert(account.publicKey)
        }
      } else {
        byPublicKey[account.publicKey] = account
      }
    }
    var warnings: [String] = []
    if !conflicting.isEmpty {
      warnings.append(
        conflicting.count == 1
          ? "Solana sent conflicting data for one stake account, so it's left out of this scan. Scan again later."
          : "Solana sent conflicting data for \(conflicting.count) stake accounts, so they're left out of this scan. Scan again later."
      )
    }
    return (byPublicKey.keys.sorted().compactMap { byPublicKey[$0] }, warnings)
  }

  /// Where a stake account is in its life, from its delegation epochs alone.
  ///
  /// - never delegated, or deactivated in an earlier epoch: `inactive`
  /// - deactivation requested this epoch (or later): `deactivating`
  /// - delegated in an earlier epoch and not deactivated: `active`
  /// - delegated this epoch: `activating`
  ///
  /// Cooldown is capped network-wide per epoch, so in a rare busy epoch a
  /// deactivated account can still be partly cooling down after the epoch
  /// ends; it is then labelled inactive slightly early. The balance counted is
  /// the same either way.
  static func solanaStakeState(
    _ account: SolanaParsedStakeAccount,
    currentEpoch: UInt64
  ) -> SolanaStakeState {
    guard let activation = account.activationEpoch,
      let deactivation = account.deactivationEpoch
    else { return .inactive }
    if deactivation == solanaStakeNotDeactivating {
      // Bootstrap stake carries the max epoch as its activation: always active.
      if activation == UInt64.max { return .active }
      return currentEpoch > activation ? .active : .activating
    }
    return currentEpoch <= deactivation ? .deactivating : .inactive
  }

  /// Splits the address's stake accounts into the two holdings it reports.
  ///
  /// - Only accounts the address can withdraw are counted (see
  ///   `solanaStakeResult`).
  /// - Active and activating accounts are `staked`.
  /// - Deactivating accounts are `unbonding`. Solana publishes no completion
  ///   timestamp (cooldown ends at an epoch boundary that depends on
  ///   network-wide limits), so no unlock time is attached rather than a guess.
  /// - Inactive accounts (cooled down, SOL still inside the stake account until
  ///   the owner withdraws) are counted as `staked` and a warning says so.
  ///   They are the owner's money and must be in the total; the other states
  ///   fit worse (`liquid` would imply it is spendable, which it is not until
  ///   a withdraw transaction, and the native holding is a different balance).
  /// - With no epoch, every owned account is `staked`, with a warning.
  static func summarizeSolanaStake(
    _ accounts: [SolanaParsedStakeAccount],
    owner: String,
    currentEpoch: UInt64?
  ) -> SolanaStakeSummary {
    var summary = SolanaStakeSummary()
    var inactiveCount = 0
    var notOwnedCount = 0
    var ownedCount = 0
    var overflowed = false
    for account in accounts.sorted(by: { $0.publicKey < $1.publicKey }) {
      guard account.withdrawer == owner else {
        if account.staker == owner { notOwnedCount += 1 }
        continue
      }
      ownedCount += 1
      let state = currentEpoch.map { solanaStakeState(account, currentEpoch: $0) }
      if state == .deactivating {
        let sum = summary.unbondingLamports.addingReportingOverflow(account.lamports)
        if sum.overflow { overflowed = true } else { summary.unbondingLamports = sum.partialValue }
      } else {
        if state == .inactive { inactiveCount += 1 }
        let sum = summary.stakedLamports.addingReportingOverflow(account.lamports)
        if sum.overflow { overflowed = true } else { summary.stakedLamports = sum.partialValue }
      }
    }
    if notOwnedCount > 0 {
      summary.warnings.append(
        notOwnedCount == 1
          ? "One Solana stake account is managed by this address, but only another address can withdraw it. It isn't counted."
          : "\(notOwnedCount) Solana stake accounts are managed by this address, but only another address can withdraw them. They aren't counted."
      )
    }
    if inactiveCount > 0 {
      summary.warnings.append(
        inactiveCount == 1
          ? "One Solana stake account has finished its cooldown and is ready to withdraw. Its SOL is counted as staked until you withdraw it."
          : "\(inactiveCount) Solana stake accounts have finished their cooldown and are ready to withdraw. Their SOL is counted as staked until you withdraw it."
      )
    }
    if currentEpoch == nil, ownedCount > 0 {
      summary.warnings.append(
        "Solana's current epoch couldn't be read, so every stake account is counted as staked. Some may be in cooldown or ready to withdraw."
      )
    }
    if overflowed {
      summary.warnings.append(
        "Solana stake balances are larger than Address Atlas can add up, so the rest are left out of this scan.")
    }
    return summary
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
