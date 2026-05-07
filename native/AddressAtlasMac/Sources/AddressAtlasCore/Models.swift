import Foundation

public enum ChainFamily: String, Codable, CaseIterable, Sendable {
  case bitcoin
  case cosmos
  case evm
  case solana
  case tron
  case xrp
  case exchange
}

public enum AssetSource: String, Codable, Sendable {
  case native
  case erc20
  case spl
  case trc20
  case issued
  case exchange
  case staked
  case rewards
}

public enum ScanStatus: String, Codable, Sendable {
  case ok
  case empty
  case failed
}

public enum ExchangeProvider: String, Codable, CaseIterable, Sendable {
  case binance
  case coinbase
  case kraken

  public var label: String {
    switch self {
    case .binance: "Binance"
    case .coinbase: "Coinbase"
    case .kraken: "Kraken"
    }
  }
}

public struct WalletRecord: Codable, Identifiable, Hashable, Sendable {
  public var id: UUID
  public var label: String
  public var address: String
  public var chainKind: ChainFamily
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    label: String,
    address: String,
    chainKind: ChainFamily,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.label = label
    self.address = address
    self.chainKind = chainKind
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct Preferences: Codable, Equatable, Sendable {
  public var darkMode: Bool
  public var density: Density
  public var mono: Bool
  public var hideDust: Bool
  public var dustThreshold: Double
  public var autoRefresh: Bool
  public var currency: String

  public enum Density: String, Codable, Sendable {
    case compact
    case comfy
  }

  public init(
    darkMode: Bool = false,
    density: Density = .comfy,
    mono: Bool = false,
    hideDust: Bool = false,
    dustThreshold: Double = 5,
    autoRefresh: Bool = true,
    currency: String = "USD"
  ) {
    self.darkMode = darkMode
    self.density = density
    self.mono = mono
    self.hideDust = hideDust
    self.dustThreshold = dustThreshold
    self.autoRefresh = autoRefresh
    self.currency = currency
  }
}

public struct CustomTokenRecord: Codable, Identifiable, Hashable, Sendable {
  public var id: UUID
  public var chainKind: ChainFamily
  public var chainId: String
  public var address: String
  public var symbol: String
  public var name: String
  public var decimals: Int
  public var coinGeckoId: String?
  public var priceUsd: Double?
  public var enabled: Bool
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    chainKind: ChainFamily,
    chainId: String,
    address: String,
    symbol: String,
    name: String,
    decimals: Int,
    coinGeckoId: String? = nil,
    priceUsd: Double? = nil,
    enabled: Bool = true,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.chainKind = chainKind
    self.chainId = chainId
    self.address = address
    self.symbol = symbol
    self.name = name
    self.decimals = decimals
    self.coinGeckoId = coinGeckoId
    self.priceUsd = priceUsd
    self.enabled = enabled
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct ManualHoldingRecord: Codable, Identifiable, Hashable, Sendable {
  public var id: UUID
  public var label: String
  public var provider: String
  public var customVenue: String?
  public var symbol: String
  public var name: String
  public var amount: Double
  public var priceUsd: Double?
  public var valueUsd: Double
  public var notes: String?
  public var enabled: Bool
  public var generatedAt: Date
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    label: String,
    provider: String,
    customVenue: String? = nil,
    symbol: String,
    name: String,
    amount: Double,
    priceUsd: Double?,
    valueUsd: Double,
    notes: String? = nil,
    enabled: Bool = true,
    generatedAt: Date = Date(),
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.label = label
    self.provider = provider
    self.customVenue = customVenue
    self.symbol = symbol
    self.name = name
    self.amount = amount
    self.priceUsd = priceUsd
    self.valueUsd = valueUsd
    self.notes = notes
    self.enabled = enabled
    self.generatedAt = generatedAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct ExchangeConnectionRecord: Codable, Identifiable, Hashable, Sendable {
  public var id: UUID
  public var provider: ExchangeProvider
  public var label: String
  public var encryptedCredentials: EncryptedVaultEnvelope
  public var status: ScanStatus
  public var lastTestedAt: Date?
  public var lastSyncAt: Date?
  public var lastError: String?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    provider: ExchangeProvider,
    label: String,
    encryptedCredentials: EncryptedVaultEnvelope,
    status: ScanStatus = .empty,
    lastTestedAt: Date? = nil,
    lastSyncAt: Date? = nil,
    lastError: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.provider = provider
    self.label = label
    self.encryptedCredentials = encryptedCredentials
    self.status = status
    self.lastTestedAt = lastTestedAt
    self.lastSyncAt = lastSyncAt
    self.lastError = lastError
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct TrackedAsset: Codable, Identifiable, Hashable, Sendable {
  public var id: String
  public var address: String
  public var chainId: String
  public var chainName: String
  public var family: ChainFamily
  public var symbol: String
  public var name: String
  public var amount: Double
  public var priceUsd: Double
  public var valueUsd: Double
  public var change24h: Double?
  public var explorerUrl: String
  public var source: AssetSource
  public var status: ScanStatus
  public var walletLabel: String?
  public var exchangeId: UUID?
  public var exchangeProvider: ExchangeProvider?

  public init(
    id: String,
    address: String,
    chainId: String,
    chainName: String,
    family: ChainFamily,
    symbol: String,
    name: String,
    amount: Double,
    priceUsd: Double,
    valueUsd: Double,
    change24h: Double? = nil,
    explorerUrl: String = "",
    source: AssetSource,
    status: ScanStatus = .ok,
    walletLabel: String? = nil,
    exchangeId: UUID? = nil,
    exchangeProvider: ExchangeProvider? = nil
  ) {
    self.id = id
    self.address = address
    self.chainId = chainId
    self.chainName = chainName
    self.family = family
    self.symbol = symbol
    self.name = name
    self.amount = amount
    self.priceUsd = priceUsd
    self.valueUsd = valueUsd
    self.change24h = change24h
    self.explorerUrl = explorerUrl
    self.source = source
    self.status = status
    self.walletLabel = walletLabel
    self.exchangeId = exchangeId
    self.exchangeProvider = exchangeProvider
  }
}

public struct ScanRunRecord: Codable, Identifiable, Hashable, Sendable {
  public var id: UUID
  public var generatedAt: Date
  public var totalUsd: Double
  public var inputCount: Int
  public var holdings: [TrackedAsset]
  public var warnings: [String]

  public init(
    id: UUID = UUID(),
    generatedAt: Date = Date(),
    totalUsd: Double,
    inputCount: Int,
    holdings: [TrackedAsset],
    warnings: [String] = []
  ) {
    self.id = id
    self.generatedAt = generatedAt
    self.totalUsd = totalUsd
    self.inputCount = inputCount
    self.holdings = holdings
    self.warnings = warnings
  }
}

public struct SyncState: Codable, Equatable, Sendable {
  public var accountId: String?
  public var latestRemoteVersion: Int
  public var lastSyncedAt: Date?
  public var lastChecksum: String?

  public init(
    accountId: String? = nil,
    latestRemoteVersion: Int = 0,
    lastSyncedAt: Date? = nil,
    lastChecksum: String? = nil
  ) {
    self.accountId = accountId
    self.latestRemoteVersion = latestRemoteVersion
    self.lastSyncedAt = lastSyncedAt
    self.lastChecksum = lastChecksum
  }
}

public struct VaultDocument: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var preferences: Preferences
  public var wallets: [WalletRecord]
  public var customTokens: [CustomTokenRecord]
  public var manualHoldings: [ManualHoldingRecord]
  public var exchangeConnections: [ExchangeConnectionRecord]
  public var scanRuns: [ScanRunRecord]
  public var syncState: SyncState
  public var updatedAt: Date

  public init(
    schemaVersion: Int = 1,
    preferences: Preferences = Preferences(),
    wallets: [WalletRecord] = [],
    customTokens: [CustomTokenRecord] = [],
    manualHoldings: [ManualHoldingRecord] = [],
    exchangeConnections: [ExchangeConnectionRecord] = [],
    scanRuns: [ScanRunRecord] = [],
    syncState: SyncState = SyncState(),
    updatedAt: Date = Date()
  ) {
    self.schemaVersion = schemaVersion
    self.preferences = preferences
    self.wallets = wallets
    self.customTokens = customTokens
    self.manualHoldings = manualHoldings
    self.exchangeConnections = exchangeConnections
    self.scanRuns = scanRuns
    self.syncState = syncState
    self.updatedAt = updatedAt
  }
}
