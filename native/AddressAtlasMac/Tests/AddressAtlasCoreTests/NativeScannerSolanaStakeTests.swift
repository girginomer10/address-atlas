import Foundation
import XCTest

@testable import AddressAtlasCore

private let walletAddress = "11111111111111111111111111111111"
private let otherAuthority = "Vote111111111111111111111111111111111111111"
private let stakeProgram = "Stake11111111111111111111111111111111111111"
private let neverDeactivated = "18446744073709551615"

// Public sysvar and program ids stand in for stake-account public keys.
private let stakeA = "SysvarC1ock11111111111111111111111111111111"
private let stakeB = "SysvarRent111111111111111111111111111111111"
private let stakeC = "SysvarS1otHashes111111111111111111111111111"
private let stakeD = "SysvarStakeHistory1111111111111111111111111"
private let stakeE = "Config1111111111111111111111111111111111111"

private func stakeAccountObject(
  pubkey: String,
  lamports: UInt64,
  staker: String = walletAddress,
  withdrawer: String = walletAddress,
  type: String = "delegated",
  activationEpoch: String? = "650",
  deactivationEpoch: String? = neverDeactivated,
  program: String = stakeProgram
) -> [String: Any] {
  var info: [String: Any] = [
    "meta": [
      "authorized": ["staker": staker, "withdrawer": withdrawer],
      "lockup": ["custodian": walletAddress, "epoch": 0, "unixTimestamp": 0],
      "rentExemptReserve": "2282880",
    ]
  ]
  if type == "delegated" {
    var delegation: [String: Any] = [
      "stake": String(lamports - 2_282_880),
      "voter": otherAuthority,
      "warmupCooldownRate": 0.25,
    ]
    if let activationEpoch { delegation["activationEpoch"] = activationEpoch }
    if let deactivationEpoch { delegation["deactivationEpoch"] = deactivationEpoch }
    info["stake"] = ["creditsObserved": 1, "delegation": delegation]
  }
  return [
    "pubkey": pubkey,
    "account": [
      "owner": program,
      "lamports": lamports,
      "executable": false,
      "data": ["parsed": ["type": type, "info": info], "program": "stake", "space": 200],
    ],
  ]
}

/// One stake account as JSON text, so stubs can capture it in `@Sendable`
/// closures (a `[String: Any]` dictionary is not `Sendable`).
private struct StakeFixture: Sendable {
  var json: String
}

private func stakeAccountJSON(
  pubkey: String,
  lamports: UInt64,
  staker: String = walletAddress,
  withdrawer: String = walletAddress,
  type: String = "delegated",
  activationEpoch: String? = "650",
  deactivationEpoch: String? = neverDeactivated,
  program: String = stakeProgram
) -> StakeFixture {
  let object = stakeAccountObject(
    pubkey: pubkey, lamports: lamports, staker: staker, withdrawer: withdrawer, type: type,
    activationEpoch: activationEpoch, deactivationEpoch: deactivationEpoch, program: program)
  let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  return StakeFixture(json: String(decoding: data, as: UTF8.self))
}

private func decodeStakeAccounts(_ accounts: [[String: Any]]) throws -> [SolanaStakeAccount] {
  try JSONDecoder().decode(
    [SolanaStakeAccount].self, from: try JSONSerialization.data(withJSONObject: accounts))
}

private func solanaMethod(_ request: URLRequest) -> String? {
  guard let data = request.httpBody,
    let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else { return nil }
  return body["method"] as? String
}

private func solanaParams(_ request: URLRequest) -> [Any] {
  guard let data = request.httpBody,
    let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else { return [] }
  return body["params"] as? [Any] ?? []
}

private func solanaMinimumSlot(_ request: URLRequest) -> UInt64? {
  (solanaParams(request).last as? [String: Any])?["minContextSlot"].flatMap {
    ($0 as? NSNumber)?.uint64Value
  }
}

/// The authority a stake lookup filtered on: 12 is the staker, 44 the withdrawer.
private func stakeFilterOffset(_ request: URLRequest) -> Int? {
  guard let config = solanaParams(request).last as? [String: Any],
    let filters = config["filters"] as? [[String: Any]],
    let memcmp = filters.compactMap({ $0["memcmp"] as? [String: Any] }).first
  else { return nil }
  return (memcmp["offset"] as? NSNumber)?.intValue
}

private func rpcResult(_ request: URLRequest, id: Int, result: String) -> (Data, HTTPURLResponse) {
  scannerResponse(request, "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":\(result)}")
}

private func stakeAccountsResult(
  _ request: URLRequest,
  accounts: [StakeFixture],
  slot: UInt64
) -> (Data, HTTPURLResponse) {
  let id = stakeFilterOffset(request) == 12 ? 4 : 5
  let value = "[" + accounts.map(\.json).joined(separator: ",") + "]"
  return rpcResult(request, id: id, result: "{\"context\":{\"slot\":\(slot)},\"value\":\(value)}")
}

/// A Solana wallet with 2 SOL liquid, no tokens, and the given stake accounts.
private struct SolanaStakeStub {
  var stakerAccounts: [StakeFixture] = []
  var withdrawerAccounts: [StakeFixture] = []
  var epoch: UInt64 = 700
  /// Replaces the answer to a stake lookup (by authority offset) entirely.
  var stakeOverride: (@Sendable (URLRequest, Int) throws -> (Data, HTTPURLResponse))?
  var epochOverride: (@Sendable (URLRequest) throws -> (Data, HTTPURLResponse))?

  func client(requests: ScannerRequestLog) -> ScannerHTTPStub {
    let staker = stakerAccounts
    let withdrawer = withdrawerAccounts
    let epoch = epoch
    let stakeOverride = stakeOverride
    let epochOverride = epochOverride
    return ScannerHTTPStub(automaticallyServesEmptySolanaStakeAccounts: false) { request in
      requests.append(request)
      let minimumSlot = solanaMinimumSlot(request)
      switch solanaMethod(request) {
      case "getBalance":
        return rpcResult(
          request, id: 1,
          result: "{\"context\":{\"slot\":\(minimumSlot ?? 123)},\"value\":2000000000}")
      case "getTokenAccountsByOwner":
        return rpcResult(
          request, id: 2, result: "{\"context\":{\"slot\":\(minimumSlot ?? 123)},\"value\":[]}")
      case "getProgramAccounts":
        let offset = stakeFilterOffset(request) ?? -1
        if let stakeOverride { return try stakeOverride(request, offset) }
        return stakeAccountsResult(
          request, accounts: offset == 12 ? staker : withdrawer, slot: minimumSlot ?? 123)
      case "getEpochInfo":
        if let epochOverride { return try epochOverride(request) }
        return rpcResult(
          request, id: 6,
          result: "{\"absoluteSlot\":\(minimumSlot ?? 123),\"epoch\":\(epoch),\"slotIndex\":10,\"slotsInEpoch\":432000}"
        )
      default:
        XCTFail("Unexpected Solana method: \(solanaMethod(request) ?? "nil")")
        return scannerResponse(request, "{}")
      }
    }
  }
}

private func solanaScanner(http: ScannerHTTPStub) -> NativeScanner {
  NativeScanner(
    http: JSONHTTPClient(http: http),
    priceProvider: ScannerStaticPriceProvider(
      values: ["solana": PricePoint(usd: 10), "usd-coin": PricePoint(usd: 1)])
  )
}

final class NativeScannerSolanaStakeTests: XCTestCase {
  // MARK: Classification

  private func account(
    activation: UInt64? = nil, deactivation: UInt64? = nil, lamports: UInt64 = 1
  ) -> NativeScanner.SolanaParsedStakeAccount {
    NativeScanner.SolanaParsedStakeAccount(
      publicKey: stakeA, lamports: lamports, staker: walletAddress, withdrawer: walletAddress,
      activationEpoch: activation, deactivationEpoch: deactivation)
  }

  func testStakeStateFollowsTheDelegationEpochsAgainstTheCurrentEpoch() {
    let never = UInt64.max
    let cases: [(NativeScanner.SolanaParsedStakeAccount, UInt64, NativeScanner.SolanaStakeState)] = [
      // Initialized, never delegated.
      (account(), 700, .inactive),
      // Delegated this epoch: still warming up.
      (account(activation: 700, deactivation: never), 700, .activating),
      (account(activation: 699, deactivation: never), 700, .active),
      (account(activation: 100, deactivation: never), 700, .active),
      // Bootstrap stake uses the max epoch as its activation.
      (account(activation: never, deactivation: never), 700, .active),
      // Deactivation requested this epoch: still cooling down.
      (account(activation: 600, deactivation: 700), 700, .deactivating),
      // Deactivated in an earlier epoch: finished.
      (account(activation: 600, deactivation: 699), 700, .inactive),
      (account(activation: 600, deactivation: 1), 700, .inactive),
      // Activated and deactivated within one epoch.
      (account(activation: 700, deactivation: 700), 700, .deactivating),
      (account(activation: 700, deactivation: 700), 701, .inactive),
    ]
    for (stake, epoch, expected) in cases {
      XCTAssertEqual(
        NativeScanner.solanaStakeState(stake, currentEpoch: epoch), expected,
        "activation \(String(describing: stake.activationEpoch)), deactivation \(String(describing: stake.deactivationEpoch)), epoch \(epoch)"
      )
    }
  }

  // MARK: Parsing

  func testParserReadsDelegatedAndInitializedAccountsForTheRequestedAuthority() throws {
    let accounts = try decodeStakeAccounts([
      stakeAccountObject(pubkey: stakeA, lamports: 1_502_282_880),
      stakeAccountObject(
        pubkey: stakeB, lamports: 5_000_000, type: "initialized", activationEpoch: nil,
        deactivationEpoch: nil),
      stakeAccountObject(
        pubkey: stakeC, lamports: 3_000_000_000, activationEpoch: "600", deactivationEpoch: "700"),
    ])

    let parsed = NativeScanner.parseSolanaStakeAccounts(
      accounts, owner: walletAddress, authority: .withdrawer)

    XCTAssertEqual(parsed.invalidAccountCount, 0)
    XCTAssertEqual(
      parsed.accounts,
      [
        NativeScanner.SolanaParsedStakeAccount(
          publicKey: stakeA, lamports: 1_502_282_880, staker: walletAddress,
          withdrawer: walletAddress, activationEpoch: 650, deactivationEpoch: UInt64.max),
        NativeScanner.SolanaParsedStakeAccount(
          publicKey: stakeB, lamports: 5_000_000, staker: walletAddress,
          withdrawer: walletAddress, activationEpoch: nil, deactivationEpoch: nil),
        NativeScanner.SolanaParsedStakeAccount(
          publicKey: stakeC, lamports: 3_000_000_000, staker: walletAddress,
          withdrawer: walletAddress, activationEpoch: 600, deactivationEpoch: 700),
      ])
  }

  func testParserCountsEveryAccountItCannotTrustInsteadOfUsingIt() throws {
    var numericEpochs = stakeAccountObject(pubkey: stakeD, lamports: 10_000_000)
    // A JSON integer epoch is accepted; the sentinel does not fit a double, so
    // a provider can only send it as text.
    var account = numericEpochs["account"] as! [String: Any]
    var data = account["data"] as! [String: Any]
    var parsedJSON = data["parsed"] as! [String: Any]
    var info = parsedJSON["info"] as! [String: Any]
    var stake = info["stake"] as! [String: Any]
    var delegation = stake["delegation"] as! [String: Any]
    delegation["activationEpoch"] = 650
    delegation["deactivationEpoch"] = 700
    stake["delegation"] = delegation
    info["stake"] = stake
    parsedJSON["info"] = info
    data["parsed"] = parsedJSON
    account["data"] = data
    numericEpochs["account"] = account

    let accounts = try decodeStakeAccounts([
      numericEpochs,
      // Wrong owner program.
      stakeAccountObject(pubkey: stakeA, lamports: 1_000_000_000, program: otherAuthority),
      // Response does not match the lookup: the withdrawer is someone else.
      stakeAccountObject(pubkey: stakeB, lamports: 1_000_000_000, withdrawer: otherAuthority),
      // Unusable layouts.
      stakeAccountObject(pubkey: stakeC, lamports: 1_000_000_000, type: "uninitialized"),
      stakeAccountObject(
        pubkey: stakeE, lamports: 1_000_000_000, activationEpoch: nil, deactivationEpoch: nil),
      stakeAccountObject(
        pubkey: stakeE, lamports: 1_000_000_000, activationEpoch: "-1"),
      stakeAccountObject(pubkey: "not-a-key", lamports: 1_000_000_000),
      ["pubkey": stakeA, "account": ["owner": stakeProgram]],
      ["pubkey": 7],
    ])

    let parsed = NativeScanner.parseSolanaStakeAccounts(
      accounts, owner: walletAddress, authority: .withdrawer)

    XCTAssertEqual(parsed.accounts.map(\.publicKey), [stakeD])
    XCTAssertEqual(parsed.accounts.first?.activationEpoch, 650)
    XCTAssertEqual(parsed.accounts.first?.deactivationEpoch, 700)
    XCTAssertEqual(parsed.invalidAccountCount, 8)
  }

  func testAccountsAppearingInBothLookupsMergeSilentlyAndConflictsAreDropped() {
    let shared = account(activation: 650, deactivation: UInt64.max, lamports: 100)
    var other = account(activation: 650, deactivation: UInt64.max, lamports: 200)
    other.publicKey = stakeB
    var conflicting = other
    conflicting.lamports = 999
    var third = shared
    third.publicKey = stakeC

    let merged = NativeScanner.mergeSolanaStakeAccounts(
      [shared, other, third, shared, conflicting, third])

    XCTAssertEqual(merged.accounts.map(\.publicKey), [stakeA, stakeC])
    XCTAssertEqual(
      merged.warnings,
      ["Solana returned conflicting data for one stake account; every version was skipped."])
    XCTAssertTrue(NativeScanner.mergeSolanaStakeAccounts([shared, shared]).warnings.isEmpty)
  }

  // MARK: Summary

  func testSummaryCountsOnlyWithdrawableAccountsAndSplitsByState() {
    var active = account(activation: 650, deactivation: UInt64.max, lamports: 1_500_000_000)
    active.publicKey = stakeA
    var cooling = account(activation: 600, deactivation: 700, lamports: 500_000_000)
    cooling.publicKey = stakeB
    var finished = account(activation: 600, deactivation: 699, lamports: 250_000_000)
    finished.publicKey = stakeC
    var managedForSomeoneElse = account(
      activation: 650, deactivation: UInt64.max, lamports: 9_000_000_000)
    managedForSomeoneElse.publicKey = stakeD
    managedForSomeoneElse.withdrawer = otherAuthority
    var unrelated = account(activation: 650, deactivation: UInt64.max, lamports: 42)
    unrelated.publicKey = stakeE
    unrelated.staker = otherAuthority
    unrelated.withdrawer = otherAuthority

    let summary = NativeScanner.summarizeSolanaStake(
      [active, cooling, finished, managedForSomeoneElse, unrelated],
      owner: walletAddress, currentEpoch: 700)

    XCTAssertEqual(summary.stakedLamports, 1_750_000_000)
    XCTAssertEqual(summary.unbondingLamports, 500_000_000)
    XCTAssertEqual(
      summary.warnings,
      [
        "One Solana stake account is managed by this address but can only be withdrawn by another; it wasn't counted.",
        "One Solana stake account has finished deactivating but hasn't been withdrawn; its SOL is counted as staked until it is.",
      ])
  }

  func testWithoutAnEpochEveryOwnedAccountIsStakedAndTheWarningSaysWhy() {
    var cooling = account(activation: 600, deactivation: 700, lamports: 500_000_000)
    cooling.publicKey = stakeB
    let summary = NativeScanner.summarizeSolanaStake(
      [account(activation: 650, deactivation: UInt64.max, lamports: 1_000_000_000), cooling],
      owner: walletAddress, currentEpoch: nil)

    XCTAssertEqual(summary.stakedLamports, 1_500_000_000)
    XCTAssertEqual(summary.unbondingLamports, 0)
    XCTAssertEqual(
      summary.warnings,
      [
        "Solana's current epoch couldn't be read, so every stake account is counted as staked; some may be unbonding or inactive."
      ])
  }

  func testSummaryNeverWrapsOnLamportOverflow() {
    var first = account(activation: 650, deactivation: UInt64.max, lamports: UInt64.max)
    first.publicKey = stakeA
    var second = account(activation: 650, deactivation: UInt64.max, lamports: 5)
    second.publicKey = stakeB

    let summary = NativeScanner.summarizeSolanaStake(
      [first, second], owner: walletAddress, currentEpoch: 700)

    XCTAssertEqual(summary.stakedLamports, UInt64.max)
    XCTAssertEqual(
      summary.warnings,
      ["Solana stake balances exceeded the supported numeric range; the remainder was skipped."])
  }

  // MARK: Scanning

  func testScanReadsStakeAccountsByStakerAndWithdrawerAndSplitsStakedFromUnbonding() async throws {
    let active = stakeAccountJSON(pubkey: stakeA, lamports: 1_502_282_880)
    let cooling = stakeAccountJSON(
      pubkey: stakeB, lamports: 500_000_000, staker: otherAuthority, activationEpoch: "600",
      deactivationEpoch: "700")
    let finished = stakeAccountJSON(
      pubkey: stakeC, lamports: 250_000_000, activationEpoch: "600", deactivationEpoch: "699")
    let managedForSomeoneElse = stakeAccountJSON(
      pubkey: stakeD, lamports: 9_000_000_000, withdrawer: otherAuthority)
    let requests = ScannerRequestLog()
    let stub = SolanaStakeStub(
      stakerAccounts: [active, finished, managedForSomeoneElse],
      withdrawerAccounts: [active, cooling, finished])

    let result = try await solanaScanner(http: stub.client(requests: requests))
      .scan(addresses: walletAddress)

    let native = try XCTUnwrap(result.holdings.first { $0.source == .native })
    XCTAssertEqual(native.amount, 2)
    let staked = try XCTUnwrap(result.holdings.first { $0.source == .staked })
    XCTAssertEqual(staked.amount, 1.75228288, accuracy: 1e-12)
    XCTAssertEqual(staked.id, "\(walletAddress)-solana-SOL-staked")
    XCTAssertEqual(staked.name, "Solana Staked")
    XCTAssertEqual(staked.family, .solana)
    XCTAssertEqual(staked.valueUsd, staked.amount * 10, accuracy: 1e-9)
    XCTAssertNil(staked.unlocksAt)
    let unbonding = try XCTUnwrap(result.holdings.first { $0.source == .unbonding })
    XCTAssertEqual(unbonding.amount, 0.5)
    XCTAssertEqual(unbonding.id, "\(walletAddress)-solana-SOL-unbonding")
    XCTAssertEqual(unbonding.name, "Solana Unbonding")
    // Solana publishes no completion time, so none is invented.
    XCTAssertNil(unbonding.unlocksAt)
    XCTAssertEqual(result.holdings.count, 3)
    XCTAssertNoThrow(try VaultDocumentSemanticValidator.validateAssets(result.holdings))

    XCTAssertEqual(
      Set(result.warnings),
      [
        "Solana · \(String(walletAddress.prefix(6)))...\(String(walletAddress.suffix(4))): One Solana stake account is managed by this address but can only be withdrawn by another; it wasn't counted.",
        "Solana · \(String(walletAddress.prefix(6)))...\(String(walletAddress.suffix(4))): One Solana stake account has finished deactivating but hasn't been withdrawn; its SOL is counted as staked until it is.",
      ])

    // Both lookups hit the Stake program with a size filter and a memcmp on
    // the wallet at the staker (12) and withdrawer (44) offsets, with context.
    let lookups = requests.snapshot().filter { solanaMethod($0) == "getProgramAccounts" }
    XCTAssertEqual(lookups.count, 2)
    XCTAssertEqual(Set(lookups.compactMap(stakeFilterOffset)), [12, 44])
    for lookup in lookups {
      XCTAssertEqual(solanaParams(lookup).first as? String, stakeProgram)
      let config = try XCTUnwrap(solanaParams(lookup).last as? [String: Any])
      XCTAssertEqual(config["encoding"] as? String, "jsonParsed")
      XCTAssertEqual(config["commitment"] as? String, "confirmed")
      XCTAssertEqual(config["withContext"] as? Bool, true)
      XCTAssertEqual(config["minContextSlot"] as? Int, 123)
      let filters = try XCTUnwrap(config["filters"] as? [[String: Any]])
      XCTAssertEqual(filters.count, 2)
      XCTAssertEqual(filters[0]["dataSize"] as? Int, 200)
      let memcmp = try XCTUnwrap(filters[1]["memcmp"] as? [String: Any])
      XCTAssertEqual(memcmp["bytes"] as? String, walletAddress)
    }
    // One epoch lookup, bound to the snapshot slot.
    let epochRequests = requests.snapshot().filter { solanaMethod($0) == "getEpochInfo" }
    XCTAssertEqual(epochRequests.count, 1)
    XCTAssertEqual(solanaMinimumSlot(epochRequests[0]), 123)
  }

  func testWalletWithoutStakeAccountsAsksNoEpochAndWarnsNothing() async throws {
    let requests = ScannerRequestLog()

    let result = try await solanaScanner(
      http: SolanaStakeStub().client(requests: requests)
    ).scan(addresses: walletAddress)

    XCTAssertEqual(result.holdings.map(\.source), [.native])
    XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
    XCTAssertFalse(requests.snapshot().contains { solanaMethod($0) == "getEpochInfo" })
  }

  func testAnAccountOnlyReturnedByTheStakerLookupIsNotCountedAsTheWalletsMoney() async throws {
    let managed = stakeAccountJSON(
      pubkey: stakeA, lamports: 9_000_000_000, withdrawer: otherAuthority)
    let requests = ScannerRequestLog()

    let result = try await solanaScanner(
      http: SolanaStakeStub(stakerAccounts: [managed]).client(requests: requests)
    ).scan(addresses: walletAddress)

    XCTAssertEqual(result.holdings.map(\.source), [.native])
    XCTAssertTrue(result.warnings.contains { $0.contains("can only be withdrawn by another") })
    // Nothing the wallet owns, so no epoch is needed.
    XCTAssertFalse(requests.snapshot().contains { solanaMethod($0) == "getEpochInfo" })
  }

  func testARejectedStakeLookupIsOneClearWarningAndTheRestOfTheScanIsIntact() async throws {
    let rejections: [(String, @Sendable (URLRequest, Int) throws -> (Data, HTTPURLResponse))] = [
      (
        "JSON-RPC rejection",
        { request, offset in
          scannerResponse(
            request,
            "{\"jsonrpc\":\"2.0\",\"id\":\(offset == 12 ? 4 : 5),\"error\":{\"code\":-32010,\"message\":\"excluded from account secondary indexes; this RPC method is unavailable for key Stake11111111111111111111111111111111111111\"}}"
          )
        }
      ),
      ("rate limit", { request, _ in scannerResponse(request, "{}", statusCode: 429) }),
      ("forbidden", { request, _ in scannerResponse(request, "{}", statusCode: 403) }),
      ("timeout", { _, _ in throw URLError(.timedOut) }),
    ]
    for (name, rejection) in rejections {
      var stub = SolanaStakeStub()
      stub.stakeOverride = rejection

      let result = try await solanaScanner(http: stub.client(requests: ScannerRequestLog()))
        .scan(addresses: walletAddress)

      XCTAssertEqual(result.holdings.map(\.source), [.native], name)
      XCTAssertEqual(result.holdings.first?.amount, 2, name)
      let stakeWarnings = result.warnings.filter { $0.contains("stake accounts couldn't be read") }
      XCTAssertEqual(stakeWarnings.count, 1, "\(name): \(result.warnings)")
      XCTAssertTrue(
        stakeWarnings[0].hasSuffix(NativeScanner.solanaStakeUnavailableWarning), name)
      XCTAssertTrue(stakeWarnings[0].contains("reject or rate-limit"), name)
      XCTAssertEqual(result.warnings.count, 1, "\(name): \(result.warnings)")
    }
  }

  func testLosingOnlyTheStakerLookupKeepsTheWithdrawableStakeAndStaysQuiet() async throws {
    let active = stakeAccountJSON(pubkey: stakeA, lamports: 1_000_000_000)
    var stub = SolanaStakeStub(withdrawerAccounts: [active])
    stub.stakeOverride = { request, offset in
      if offset == 12 { return scannerResponse(request, "{}", statusCode: 429) }
      return stakeAccountsResult(request, accounts: [active], slot: solanaMinimumSlot(request) ?? 123)
    }

    let result = try await solanaScanner(http: stub.client(requests: ScannerRequestLog()))
      .scan(addresses: walletAddress)

    XCTAssertEqual(result.holdings.first { $0.source == .staked }?.amount, 1)
    XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
  }

  func testLosingTheWithdrawerLookupWarnsEvenIfTheStakerLookupWorked() async throws {
    let active = stakeAccountJSON(pubkey: stakeA, lamports: 1_000_000_000)
    var stub = SolanaStakeStub(stakerAccounts: [active])
    stub.stakeOverride = { request, offset in
      if offset == 44 { return scannerResponse(request, "{}", statusCode: 429) }
      return stakeAccountsResult(request, accounts: [active], slot: solanaMinimumSlot(request) ?? 123)
    }

    let result = try await solanaScanner(http: stub.client(requests: ScannerRequestLog()))
      .scan(addresses: walletAddress)

    XCTAssertFalse(result.holdings.contains { $0.source == .staked })
    XCTAssertTrue(
      result.warnings.contains { $0.contains(NativeScanner.solanaStakeUnavailableWarning) })
  }

  func testAMinimumContextSlotFailureOnTheStakeLookupIsRetriedWithoutAWarning() async throws {
    let active = stakeAccountJSON(pubkey: stakeA, lamports: 1_000_000_000)
    let attempts = ScannerRequestLog()
    var stub = SolanaStakeStub()
    stub.stakeOverride = { request, offset in
      if offset == 44, attempts.append(request) == 1 {
        return scannerResponse(
          request,
          "{\"jsonrpc\":\"2.0\",\"id\":5,\"error\":{\"code\":-32016,\"message\":\"Minimum context slot has not been reached\"}}"
        )
      }
      return stakeAccountsResult(
        request, accounts: offset == 44 ? [active] : [], slot: solanaMinimumSlot(request) ?? 123)
    }

    let result = try await solanaScanner(http: stub.client(requests: ScannerRequestLog()))
      .scan(addresses: walletAddress)

    XCTAssertEqual(result.holdings.first { $0.source == .staked }?.amount, 1)
    XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
    XCTAssertEqual(attempts.snapshot().count, 2)
  }

  func testStakeLookupsJoinTheCoherentSnapshotAndForceLaggingReadsToCatchUp() async throws {
    let active = stakeAccountJSON(pubkey: stakeA, lamports: 1_000_000_000)
    let requests = ScannerRequestLog()
    var stub = SolanaStakeStub()
    // The node answering the withdrawer lookup is two slots ahead.
    stub.stakeOverride = { request, offset in
      let minimum = solanaMinimumSlot(request) ?? 123
      return stakeAccountsResult(
        request, accounts: offset == 44 ? [active] : [], slot: max(minimum, 125))
    }

    let result = try await solanaScanner(http: stub.client(requests: requests))
      .scan(addresses: walletAddress)

    XCTAssertEqual(result.holdings.first { $0.source == .native }?.amount, 2)
    XCTAssertEqual(result.holdings.first { $0.source == .staked }?.amount, 1)
    XCTAssertFalse(result.warnings.contains { $0.contains("consistent snapshot") })
    // The native balance was re-read at the slot the stake lookup reached.
    let balanceSlots = requests.snapshot()
      .filter { solanaMethod($0) == "getBalance" }.map { solanaMinimumSlot($0) }
    XCTAssertEqual(balanceSlots, [nil, 125])
    // And the epoch lookup is bound to that agreed slot.
    let epoch = try XCTUnwrap(requests.snapshot().first { solanaMethod($0) == "getEpochInfo" })
    XCTAssertEqual(solanaMinimumSlot(epoch), 125)
  }

  func testAStakeLookupThatNeverReachesTheAgreedSlotFailsTheWholeSnapshotClosed() async throws {
    let requests = ScannerRequestLog()
    // Every read lands further ahead than the slot it was told to reach, each
    // by a different amount, so the three of them can never agree.
    let http = ScannerHTTPStub(automaticallyServesEmptySolanaStakeAccounts: false) { request in
      requests.append(request)
      let minimum = solanaMinimumSlot(request)
      switch solanaMethod(request) {
      case "getBalance":
        return rpcResult(
          request, id: 1,
          result: "{\"context\":{\"slot\":\(minimum.map { $0 + 1 } ?? 100)},\"value\":1000000000}")
      case "getTokenAccountsByOwner":
        return rpcResult(
          request, id: 2, result: "{\"context\":{\"slot\":\((minimum ?? 100) + 2)},\"value\":[]}")
      case "getProgramAccounts":
        return stakeAccountsResult(request, accounts: [], slot: (minimum ?? 100) + 4)
      default:
        XCTFail("Unexpected Solana method: \(solanaMethod(request) ?? "nil")")
        return scannerResponse(request, "{}")
      }
    }

    let result = try await solanaScanner(http: http).scan(addresses: walletAddress)

    XCTAssertTrue(result.holdings.isEmpty)
    // Bounded: no epoch lookup, and no endless re-reading.
    XCTAssertFalse(requests.snapshot().contains { solanaMethod($0) == "getEpochInfo" })
    XCTAssertLessThanOrEqual(requests.snapshot().count, 20)
    XCTAssertTrue(
      result.warnings.contains {
        $0.contains(
          "SOL, stake-account, and Solana token balances were skipped because the network didn't return a consistent snapshot after 3 tries."
        )
      }, "\(result.warnings)")
  }

  func testAnUnreadableEpochCountsEverythingAsStakedWithAWarning() async throws {
    let cooling = stakeAccountJSON(
      pubkey: stakeB, lamports: 500_000_000, activationEpoch: "600", deactivationEpoch: "700")
    var stub = SolanaStakeStub(withdrawerAccounts: [cooling])
    stub.epochOverride = { request in scannerResponse(request, "{}", statusCode: 503) }

    let result = try await solanaScanner(http: stub.client(requests: ScannerRequestLog()))
      .scan(addresses: walletAddress)

    XCTAssertEqual(result.holdings.first { $0.source == .staked }?.amount, 0.5)
    XCTAssertFalse(result.holdings.contains { $0.source == .unbonding })
    XCTAssertTrue(result.warnings.contains { $0.contains("current epoch couldn't be read") })
  }

  func testInvalidStakeAccountDataIsReportedNotSilentlyDropped() async throws {
    let good = stakeAccountJSON(pubkey: stakeA, lamports: 1_000_000_000)
    let bad = stakeAccountJSON(pubkey: stakeB, lamports: 1_000_000_000, type: "uninitialized")
    let result = try await solanaScanner(
      http: SolanaStakeStub(withdrawerAccounts: [good, bad]).client(requests: ScannerRequestLog())
    ).scan(addresses: walletAddress)

    XCTAssertEqual(result.holdings.first { $0.source == .staked }?.amount, 1)
    XCTAssertTrue(
      result.warnings.contains { $0.contains("stake accounts returned invalid data") })
  }

  func testStakeLookupsThatDisagreeAboutOneAccountDropItWithAWarning() async throws {
    let asStaker = stakeAccountJSON(pubkey: stakeA, lamports: 1_000_000_000)
    let asWithdrawer = stakeAccountJSON(pubkey: stakeA, lamports: 7_000_000_000)
    let result = try await solanaScanner(
      http: SolanaStakeStub(stakerAccounts: [asStaker], withdrawerAccounts: [asWithdrawer])
        .client(requests: ScannerRequestLog())
    ).scan(addresses: walletAddress)

    XCTAssertFalse(result.holdings.contains { $0.source == .staked })
    XCTAssertTrue(
      result.warnings.contains { $0.contains("conflicting data for one stake account") })
  }

  func testAFailedNativeReadStillScansStakeAtAValidatedFallbackSlot() async throws {
    let active = stakeAccountJSON(pubkey: stakeA, lamports: 1_000_000_000)
    let withdrawerAccounts = [active]
    let http = ScannerHTTPStub(automaticallyServesEmptySolanaStakeAccounts: false) { request in
      switch solanaMethod(request) {
      case "getBalance":
        return scannerResponse(
          request,
          #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"node is behind"}}"#)
      case "getSlot":
        return rpcResult(request, id: 3, result: "123")
      case "getTokenAccountsByOwner":
        return rpcResult(
          request, id: 2,
          result: "{\"context\":{\"slot\":\(solanaMinimumSlot(request) ?? 123)},\"value\":[]}")
      case "getProgramAccounts":
        return stakeAccountsResult(
          request,
          accounts: stakeFilterOffset(request) == 44 ? withdrawerAccounts : [],
          slot: solanaMinimumSlot(request) ?? 123)
      case "getEpochInfo":
        return rpcResult(request, id: 6, result: "{\"epoch\":700}")
      default:
        XCTFail("Unexpected Solana method: \(solanaMethod(request) ?? "nil")")
        return scannerResponse(request, "{}")
      }
    }

    let result = try await solanaScanner(http: http).scan(addresses: walletAddress)

    XCTAssertFalse(result.holdings.contains { $0.source == .native })
    XCTAssertEqual(result.holdings.first { $0.source == .staked }?.amount, 1)
    XCTAssertTrue(result.warnings.contains { $0.contains("node is behind") })
  }
}
