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
}

enum CosmosScanPart: Sendable {
  case liquid
  case delegations
  case rewards

  var failureWarning: String {
    switch self {
    case .liquid:
      "Liquid balance could not be read; staked and reward balances may still be available."
    case .delegations: "Delegations could not be read; staked balance may be missing."
    case .rewards: "Rewards could not be read; claimable rewards may be missing."
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
}

struct CosmosDelegationScan: Sendable {
  var delegations: [CosmosDelegation] = []
  var warnings: [String] = []
}

public struct ParsedSplAccount: Equatable, Sendable {
  public var mint: String
  public var rawAmount: Double
  public var decimals: Int
}

public struct SolanaTokenAccountsResponse: Decodable, Sendable {
  public var result: Result?
  public var error: JSONRPCError?

  public struct Result: Decodable, Sendable {
    public var value: [SolanaTokenAccount]
  }
}

public struct JSONRPCError: Decodable, Sendable {
  public var code: Int?
  public var message: String?
}

struct EvmTokenBatchResponse: Decodable, Sendable {
  var id: Int
  var result: String?
  var error: JSONRPCError?
}

public struct SolanaTokenAccount: Decodable, Sendable {
  public var account: Account

  public struct Account: Decodable, Sendable {
    public var data: AccountData
  }

  public struct AccountData: Decodable, Sendable {
    public var parsed: Parsed?
  }

  public struct Parsed: Decodable, Sendable {
    public var info: Info
  }

  public struct Info: Decodable, Sendable {
    public var mint: String
    public var tokenAmount: TokenAmount
  }

  public struct TokenAmount: Decodable, Sendable {
    public var amount: String
    public var decimals: Int
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

public struct CosmosPageResponse: Decodable, Sendable {
  public var nextKey: String?

  enum CodingKeys: String, CodingKey {
    case nextKey = "next_key"
  }
}

public struct CosmosRewardsResponse: Decodable, Sendable {
  public var total: [CosmosBalance]?
}

public struct CosmosDelegation: Decodable, Sendable {
  public var balance: CosmosBalance?
}

public struct CosmosBalance: Decodable, Sendable {
  public var denom: String
  public var amount: String
}

public struct TronAccountResponse: Decodable, Sendable {
  public var data: [Account]?

  public struct Account: Decodable, Sendable {
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
    public var lines: [XrpTrustLine]?
    public var marker: JSONValue?

    enum CodingKeys: String, CodingKey {
      case status
      case error
      case errorMessage = "error_message"
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
  case object([String: RPCValue])
  case array([RPCValue])

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    }
  }
}
