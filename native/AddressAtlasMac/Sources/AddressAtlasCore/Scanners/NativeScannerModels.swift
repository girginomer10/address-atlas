import Foundation

public struct TokenRegistries: Sendable {
  public var evm: [String: [TokenConfig]]
  public var spl: [String: [TokenConfig]]
  public var trc20: [String: [TokenConfig]]
  public var warnings: [String]

  public init(
    evm: [String: [TokenConfig]],
    spl: [String: [TokenConfig]],
    trc20: [String: [TokenConfig]],
    warnings: [String] = []
  ) {
    self.evm = evm
    self.spl = spl
    self.trc20 = trc20
    self.warnings = warnings
  }
}

struct NativeScanResult: Sendable {
  var assets: [TrackedAsset] = []
  var warnings: [String] = []
}

struct ChainScanJob: Sendable {
  var index: Int
  var address: String
  var chain: ChainConfig
}

struct ChainScanOutcome: Sendable {
  var index: Int
  var chainName: String
  var addressHint: String
  var result: NativeScanResult
}

struct TokenScanOutcome: Sendable {
  var asset: TrackedAsset?
  var failedSymbol: String?
}

struct SolanaProgramOutcome: Sendable {
  var accounts: [ParsedSplAccount] = []
  var warnings: [String] = []
  var invalidMints: [String] = []
  var unidentifiedInvalidAccountCount = 0
}

struct SolanaAccountParseResult {
  var accounts: [ParsedSplAccount] = []
  var invalidMints: [String] = []
  var unidentifiedInvalidAccountCount = 0
}

struct TronTokenBalanceParseResult {
  var balances: [(token: TokenConfig, amount: Double)] = []
  var invalidSymbols: [String] = []
  var warnings: [String] = []
}

enum CosmosScanPart: Sendable {
  case liquid
  case delegations
  case rewards
  case unbonding

  var failureWarning: String {
    switch self {
    case .liquid:
      "Couldn't read the available balance, so it's missing from this scan. Staked, unbonding and reward balances may still be included. Scan again later."
    case .delegations: "Couldn't read delegations, so staked balance may be missing from this scan. Scan again later."
    case .rewards: "Couldn't read rewards, so claimable rewards may be missing from this scan. Scan again later."
    case .unbonding: "Couldn't read unbonding delegations, so unbonding balance may be missing from this scan. Scan again later."
    }
  }
}

struct SolanaTokenBalanceScan: Sendable {
  var balances: [(token: TokenConfig, amount: Double)] = []
  var warnings: [String] = []
}

struct XrpTrustLineScan: Sendable {
  var lines: [XrpTrustLine] = []
  var warnings: [String] = []
}

struct CosmosBalanceScan: Sendable {
  var balances: [CosmosBalance] = []
  var warnings: [String] = []
  var height: Int64?
}

struct CosmosDelegationScan: Sendable {
  var delegations: [CosmosDelegation] = []
  var warnings: [String] = []
}

struct CosmosUnbondingScan: Sendable {
  var unbondingDelegations: [CosmosUnbondingDelegation] = []
  var warnings: [String] = []
}

/// Unbonding entries that share one completion time, folded into a single
/// amount. `unlocksAt` is nil for entries whose completion time is missing or
/// unusable; their funds still count.
public struct CosmosUnbondingBucket: Equatable, Sendable {
  public var unlocksAt: Date?
  public var amount: Double
}

public struct CosmosUnbondingParse: Equatable, Sendable {
  public var buckets: [CosmosUnbondingBucket]
  public var warnings: [String]
}

public struct ParsedSplAccount: Equatable, Sendable {
  public var accountPublicKey: String
  public var mint: String
  public var rawAmount: Double
  public var decimals: Int
}

public struct SolanaTokenAccountsResponse: Decodable, Sendable {
  public var jsonrpc: String?
  public var id: Int?
  public var result: Result?
  public var error: JSONRPCError?

  public struct Result: Decodable, Sendable {
    public var context: Context?
    public var value: [SolanaTokenAccount]
  }

  public struct Context: Decodable, Sendable {
    public var slot: UInt64?
  }
}

/// `getProgramAccounts` (jsonParsed, `withContext: true`) on the Stake program.
/// Decoding follows `SolanaTokenAccount`: a wrongly typed field becomes nil
/// so one malformed account is counted and reported instead of discarding the
/// whole page.
public struct SolanaStakeAccountsResponse: Decodable, Sendable {
  public var jsonrpc: String?
  public var id: Int?
  public var result: Result?
  public var error: JSONRPCError?

  public struct Result: Decodable, Sendable {
    public var context: SolanaTokenAccountsResponse.Context?
    public var value: [SolanaStakeAccount]
  }
}

public struct SolanaStakeAccount: Decodable, Sendable {
  public var pubkey: String?
  public var account: Account?

  private enum CodingKeys: String, CodingKey {
    case pubkey
    case account
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    pubkey = try? container.decode(String.self, forKey: .pubkey)
    account = try? container.decode(Account.self, forKey: .account)
  }

  public struct Account: Decodable, Sendable {
    public var owner: String?
    public var lamports: UInt64?
    public var data: AccountData?

    private enum CodingKeys: String, CodingKey {
      case owner
      case lamports
      case data
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      owner = try? container.decode(String.self, forKey: .owner)
      lamports = try? container.decode(UInt64.self, forKey: .lamports)
      data = try? container.decode(AccountData.self, forKey: .data)
    }
  }

  public struct AccountData: Decodable, Sendable {
    public var parsed: Parsed?

    private enum CodingKeys: String, CodingKey {
      case parsed
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      parsed = try? container.decode(Parsed.self, forKey: .parsed)
    }
  }

  public struct Parsed: Decodable, Sendable {
    /// `delegated` or `initialized` for the accounts this scan can use.
    public var type: String?
    public var info: Info?

    private enum CodingKeys: String, CodingKey {
      case type
      case info
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      type = try? container.decode(String.self, forKey: .type)
      info = try? container.decode(Info.self, forKey: .info)
    }
  }

  public struct Info: Decodable, Sendable {
    public var meta: Meta?
    public var stake: Stake?

    private enum CodingKeys: String, CodingKey {
      case meta
      case stake
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      meta = try? container.decode(Meta.self, forKey: .meta)
      stake = try? container.decode(Stake.self, forKey: .stake)
    }
  }

  public struct Meta: Decodable, Sendable {
    public var staker: String?
    public var withdrawer: String?

    private enum CodingKeys: String, CodingKey {
      case authorized
    }

    private enum AuthorizedKeys: String, CodingKey {
      case staker
      case withdrawer
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let authorized = try? container.nestedContainer(
        keyedBy: AuthorizedKeys.self, forKey: .authorized)
      staker = try? authorized?.decode(String.self, forKey: .staker)
      withdrawer = try? authorized?.decode(String.self, forKey: .withdrawer)
    }
  }

  public struct Stake: Decodable, Sendable {
    public var activationEpoch: UInt64?
    public var deactivationEpoch: UInt64?

    private enum CodingKeys: String, CodingKey {
      case delegation
    }

    private enum DelegationKeys: String, CodingKey {
      case activationEpoch
      case deactivationEpoch
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let delegation = try? container.nestedContainer(
        keyedBy: DelegationKeys.self, forKey: .delegation)
      activationEpoch = delegation.flatMap { Self.epoch(in: $0, forKey: .activationEpoch) }
      deactivationEpoch = delegation.flatMap { Self.epoch(in: $0, forKey: .deactivationEpoch) }
    }

    /// Epochs are u64 and the RPC spells them as decimal strings (the
    /// "never" sentinel is u64::MAX, which no JSON double can hold). A plain
    /// JSON integer is accepted too; anything else is nil.
    private static func epoch(
      in container: KeyedDecodingContainer<DelegationKeys>,
      forKey key: DelegationKeys
    ) -> UInt64? {
      if let text = try? container.decode(String.self, forKey: key) {
        let bytes = text.utf8
        guard !bytes.isEmpty, bytes.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return UInt64(text)
      }
      return try? container.decode(UInt64.self, forKey: key)
    }
  }
}

public struct SolanaEpochInfoResponse: Decodable, Sendable {
  public var jsonrpc: String?
  public var id: Int?
  public var result: Result?
  public var error: JSONRPCError?

  public struct Result: Decodable, Sendable {
    public var epoch: UInt64?
    public var absoluteSlot: UInt64?
  }
}

public struct JSONRPCError: Decodable, Sendable {
  public var code: Int?
  public var message: String?
}

struct EvmTokenBatchResponse: Decodable, Sendable {
  var jsonrpc: String?
  var id: Int
  var result: String?
  var error: JSONRPCError?

  init(
    jsonrpc: String? = "2.0",
    id: Int,
    result: String?,
    error: JSONRPCError?
  ) {
    self.jsonrpc = jsonrpc
    self.id = id
    self.result = result
    self.error = error
  }
}

public struct SolanaTokenAccount: Decodable, Sendable {
  public var pubkey: String?
  public var account: Account?

  private enum CodingKeys: String, CodingKey {
    case pubkey
    case account
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    pubkey = try? container.decode(String.self, forKey: .pubkey)
    account = try? container.decode(Account.self, forKey: .account)
  }

  public struct Account: Decodable, Sendable {
    public var owner: String?
    public var data: AccountData?

    private enum CodingKeys: String, CodingKey {
      case owner
      case data
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      owner = try? container.decode(String.self, forKey: .owner)
      data = try? container.decode(AccountData.self, forKey: .data)
    }
  }

  public struct AccountData: Decodable, Sendable {
    public var parsed: Parsed?

    private enum CodingKeys: String, CodingKey {
      case parsed
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      parsed = try? container.decode(Parsed.self, forKey: .parsed)
    }
  }

  public struct Parsed: Decodable, Sendable {
    public var type: String?
    public var info: Info?

    private enum CodingKeys: String, CodingKey {
      case type
      case info
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      type = try? container.decode(String.self, forKey: .type)
      info = try? container.decode(Info.self, forKey: .info)
    }
  }

  public struct Info: Decodable, Sendable {
    public var mint: String?
    public var owner: String?
    public var tokenAmount: TokenAmount?

    private enum CodingKeys: String, CodingKey {
      case mint
      case owner
      case tokenAmount
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      mint = try? container.decode(String.self, forKey: .mint)
      owner = try? container.decode(String.self, forKey: .owner)
      tokenAmount = try? container.decode(TokenAmount.self, forKey: .tokenAmount)
    }
  }

  public struct TokenAmount: Decodable, Sendable {
    public var amount: String?
    public var decimals: Int?

    private enum CodingKeys: String, CodingKey {
      case amount
      case decimals
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      amount = try? container.decode(String.self, forKey: .amount)
      decimals = try? container.decode(Int.self, forKey: .decimals)
    }
  }
}

public struct CosmosBankResponse: Decodable, Sendable {
  public var balances: [CosmosBalance]?
  public var pagination: CosmosPageResponse?
}

public struct CosmosDelegationResponse: Decodable, Sendable {
  public var delegationResponses: [CosmosDelegation]?
  public var pagination: CosmosPageResponse?

  enum CodingKeys: String, CodingKey {
    case delegationResponses = "delegation_responses"
    case pagination
  }
}

/// `/cosmos/staking/v1beta1/delegators/{address}/unbonding_delegations`.
public struct CosmosUnbondingResponse: Decodable, Sendable {
  public var unbondingResponses: [CosmosUnbondingDelegation]?
  public var pagination: CosmosPageResponse?

  enum CodingKeys: String, CodingKey {
    case unbondingResponses = "unbonding_responses"
    case pagination
  }

  public init(
    unbondingResponses: [CosmosUnbondingDelegation]?,
    pagination: CosmosPageResponse? = nil
  ) {
    self.unbondingResponses = unbondingResponses
    self.pagination = pagination
  }
}

/// All unbonding entries one delegator has with one validator.
public struct CosmosUnbondingDelegation: Decodable, Equatable, Sendable {
  public var delegatorAddress: String?
  public var validatorAddress: String?
  public var entries: [Entry]?

  enum CodingKeys: String, CodingKey {
    case delegatorAddress = "delegator_address"
    case validatorAddress = "validator_address"
    case entries
  }

  public struct Entry: Decodable, Equatable, Sendable {
    public var creationHeight: String?
    /// RFC 3339 UTC, up to nanosecond precision.
    public var completionTime: String?
    public var initialBalance: String?
    /// What the entry will pay out: `initial_balance` less any slashing.
    public var balance: String?
    public var unbondingId: String?

    enum CodingKeys: String, CodingKey {
      case creationHeight = "creation_height"
      case completionTime = "completion_time"
      case initialBalance = "initial_balance"
      case balance
      case unbondingId = "unbonding_id"
    }

    /// A wrongly typed field becomes nil instead of failing the whole page, so
    /// the parser can report exactly one unusable entry and keep the rest.
    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      creationHeight = try? container.decode(String.self, forKey: .creationHeight)
      completionTime = try? container.decode(String.self, forKey: .completionTime)
      initialBalance = try? container.decode(String.self, forKey: .initialBalance)
      balance = try? container.decode(String.self, forKey: .balance)
      unbondingId = try? container.decode(String.self, forKey: .unbondingId)
    }

    public init(
      creationHeight: String? = nil,
      completionTime: String? = nil,
      initialBalance: String? = nil,
      balance: String? = nil,
      unbondingId: String? = nil
    ) {
      self.creationHeight = creationHeight
      self.completionTime = completionTime
      self.initialBalance = initialBalance
      self.balance = balance
      self.unbondingId = unbondingId
    }
  }

  public init(
    delegatorAddress: String?,
    validatorAddress: String?,
    entries: [Entry]?
  ) {
    self.delegatorAddress = delegatorAddress
    self.validatorAddress = validatorAddress
    self.entries = entries
  }
}

public struct CosmosPageResponse: Decodable, Sendable {
  public var nextKey: String?

  enum CodingKeys: String, CodingKey {
    case nextKey = "next_key"
  }
}

public struct CosmosRewardsResponse: Decodable, Sendable {
  public var total: [CosmosBalance]?
}

public struct CosmosDelegation: Decodable, Equatable, Sendable {
  public var delegation: DelegationIdentity?
  public var balance: CosmosBalance?

  public struct DelegationIdentity: Decodable, Equatable, Sendable {
    public var delegatorAddress: String?
    public var validatorAddress: String?

    enum CodingKeys: String, CodingKey {
      case delegatorAddress = "delegator_address"
      case validatorAddress = "validator_address"
    }
  }
}

public struct CosmosBalance: Decodable, Equatable, Sendable {
  public var denom: String
  public var amount: String
}

public struct TronAccountResponse: Decodable, Sendable {
  public var success: Bool?
  public var data: [Account]?

  public struct Account: Decodable, Sendable {
    public var address: String?
    public var balance: Double?
    public var trc20: [[String: String]]?
  }
}

public struct XrpAccountLinesResponse: Decodable, Sendable {
  public var result: Result?

  public struct Result: Decodable, Sendable {
    public var status: String?
    public var error: String?
    public var errorMessage: String?
    public var account: String?
    public var ledgerHash: String?
    public var ledgerIndex: Int?
    public var validated: Bool?
    public var lines: [XrpTrustLine]?
    public var marker: JSONValue?

    enum CodingKeys: String, CodingKey {
      case status
      case error
      case errorMessage = "error_message"
      case account
      case ledgerHash = "ledger_hash"
      case ledgerIndex = "ledger_index"
      case validated
      case lines
      case marker
    }
  }
}

public struct XrpTrustLine: Decodable, Sendable {
  public var account: String
  public var balance: String
  public var currency: String
}

struct XRPRequest: Encodable {
  var method: String
  var params: [[String: XRPValue]]
}

enum XRPValue: Encodable {
  case string(String)
  case number(Int)
  case json(JSONValue)

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .json(let value):
      try container.encode(value)
    }
  }
}

public indirect enum JSONValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Unsupported JSON value.")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  func stableKey() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return Base64URL.encode(try encoder.encode(self))
  }
}

struct JSONRPCRequest: Encodable {
  var jsonrpc = "2.0"
  var id = 1
  var method: String
  var params: [RPCValue]

  init(id: Int = 1, method: String, params: [RPCValue]) {
    self.id = id
    self.method = method
    self.params = params
  }
}

enum RPCValue: Encodable {
  case string(String)
  case number(Double)
  case unsignedInteger(UInt64)
  case bool(Bool)
  case object([String: RPCValue])
  case array([RPCValue])

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value):
      try container.encode(value)
    case .bool(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .unsignedInteger(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    }
  }
}
