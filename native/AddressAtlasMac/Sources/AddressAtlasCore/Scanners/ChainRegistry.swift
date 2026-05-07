import Foundation

public struct ChainConfig: Codable, Hashable, Sendable {
  public var id: String
  public var name: String
  public var family: ChainFamily
  public var symbol: String
  public var coinGeckoId: String
  public var decimals: Int
  public var rpcUrl: URL?
  public var restUrl: URL?
  public var explorerUrl: URL
  public var nativeDenom: String?
  public var addressPrefix: String?

  public init(
    id: String,
    name: String,
    family: ChainFamily,
    symbol: String,
    coinGeckoId: String,
    decimals: Int,
    rpcUrl: URL? = nil,
    restUrl: URL? = nil,
    explorerUrl: URL,
    nativeDenom: String? = nil,
    addressPrefix: String? = nil
  ) {
    self.id = id
    self.name = name
    self.family = family
    self.symbol = symbol
    self.coinGeckoId = coinGeckoId
    self.decimals = decimals
    self.rpcUrl = rpcUrl
    self.restUrl = restUrl
    self.explorerUrl = explorerUrl
    self.nativeDenom = nativeDenom
    self.addressPrefix = addressPrefix
  }
}

public struct TokenConfig: Codable, Hashable, Sendable {
  public var symbol: String
  public var name: String
  public var address: String
  public var decimals: Int
  public var coinGeckoId: String?
  public var priceUsd: Double?

  public init(symbol: String, name: String, address: String, decimals: Int, coinGeckoId: String? = nil, priceUsd: Double? = nil) {
    self.symbol = symbol
    self.name = name
    self.address = address
    self.decimals = decimals
    self.coinGeckoId = coinGeckoId
    self.priceUsd = priceUsd
  }
}

public enum ChainRegistry {
  public static let bitcoin = ChainConfig(
    id: "bitcoin",
    name: "Bitcoin",
    family: .bitcoin,
    symbol: "BTC",
    coinGeckoId: "bitcoin",
    decimals: 8,
    restUrl: URL(string: "https://blockstream.info/api"),
    explorerUrl: URL(string: "https://blockstream.info/address/")!
  )

  public static let solana = ChainConfig(
    id: "solana",
    name: "Solana",
    family: .solana,
    symbol: "SOL",
    coinGeckoId: "solana",
    decimals: 9,
    rpcUrl: URL(string: "https://api.mainnet-beta.solana.com"),
    explorerUrl: URL(string: "https://solscan.io/account/")!
  )

  public static let tron = ChainConfig(
    id: "tron",
    name: "TRON",
    family: .tron,
    symbol: "TRX",
    coinGeckoId: "tron",
    decimals: 6,
    restUrl: URL(string: "https://api.trongrid.io"),
    explorerUrl: URL(string: "https://tronscan.org/#/address/")!
  )

  public static let xrp = ChainConfig(
    id: "xrp",
    name: "XRP Ledger",
    family: .xrp,
    symbol: "XRP",
    coinGeckoId: "ripple",
    decimals: 6,
    rpcUrl: URL(string: "https://s1.ripple.com:51234/"),
    explorerUrl: URL(string: "https://xrpscan.com/account/")!
  )

  public static let evmChains: [ChainConfig] = [
    ChainConfig(id: "ethereum", name: "Ethereum", family: .evm, symbol: "ETH", coinGeckoId: "ethereum", decimals: 18, rpcUrl: URL(string: "https://eth.llamarpc.com"), explorerUrl: URL(string: "https://etherscan.io/address/")!),
    ChainConfig(id: "base", name: "Base", family: .evm, symbol: "ETH", coinGeckoId: "ethereum", decimals: 18, rpcUrl: URL(string: "https://mainnet.base.org"), explorerUrl: URL(string: "https://basescan.org/address/")!),
    ChainConfig(id: "arbitrum", name: "Arbitrum One", family: .evm, symbol: "ETH", coinGeckoId: "ethereum", decimals: 18, rpcUrl: URL(string: "https://arb1.arbitrum.io/rpc"), explorerUrl: URL(string: "https://arbiscan.io/address/")!),
    ChainConfig(id: "optimism", name: "Optimism", family: .evm, symbol: "ETH", coinGeckoId: "ethereum", decimals: 18, rpcUrl: URL(string: "https://mainnet.optimism.io"), explorerUrl: URL(string: "https://optimistic.etherscan.io/address/")!),
    ChainConfig(id: "polygon", name: "Polygon PoS", family: .evm, symbol: "MATIC", coinGeckoId: "matic-network", decimals: 18, rpcUrl: URL(string: "https://polygon-rpc.com"), explorerUrl: URL(string: "https://polygonscan.com/address/")!),
    ChainConfig(id: "bsc", name: "BNB Chain", family: .evm, symbol: "BNB", coinGeckoId: "binancecoin", decimals: 18, rpcUrl: URL(string: "https://bsc-dataseed.binance.org"), explorerUrl: URL(string: "https://bscscan.com/address/")!),
    ChainConfig(id: "avalanche", name: "Avalanche C-Chain", family: .evm, symbol: "AVAX", coinGeckoId: "avalanche-2", decimals: 18, rpcUrl: URL(string: "https://api.avax.network/ext/bc/C/rpc"), explorerUrl: URL(string: "https://snowtrace.io/address/")!)
  ]

  public static let cosmosChains: [ChainConfig] = [
    ChainConfig(id: "cosmoshub", name: "Cosmos Hub", family: .cosmos, symbol: "ATOM", coinGeckoId: "cosmos", decimals: 6, restUrl: URL(string: "https://cosmos-api.polkachu.com"), explorerUrl: URL(string: "https://www.mintscan.io/cosmos/address/")!, nativeDenom: "uatom", addressPrefix: "cosmos"),
    ChainConfig(id: "osmosis", name: "Osmosis", family: .cosmos, symbol: "OSMO", coinGeckoId: "osmosis", decimals: 6, restUrl: URL(string: "https://lcd.osmosis.zone"), explorerUrl: URL(string: "https://www.mintscan.io/osmosis/address/")!, nativeDenom: "uosmo", addressPrefix: "osmo"),
    ChainConfig(id: "celestia", name: "Celestia", family: .cosmos, symbol: "TIA", coinGeckoId: "celestia", decimals: 6, restUrl: URL(string: "https://celestia-api.polkachu.com"), explorerUrl: URL(string: "https://www.mintscan.io/celestia/address/")!, nativeDenom: "utia", addressPrefix: "celestia"),
    ChainConfig(id: "stargaze", name: "Stargaze", family: .cosmos, symbol: "STARS", coinGeckoId: "stargaze", decimals: 6, restUrl: URL(string: "https://rest.stargaze-apis.com"), explorerUrl: URL(string: "https://www.mintscan.io/stargaze/address/")!, nativeDenom: "ustars", addressPrefix: "stars"),
    ChainConfig(id: "stride", name: "Stride", family: .cosmos, symbol: "STRD", coinGeckoId: "stride", decimals: 6, restUrl: URL(string: "https://stride-api.polkachu.com"), explorerUrl: URL(string: "https://www.mintscan.io/stride/address/")!, nativeDenom: "ustrd", addressPrefix: "stride")
  ]

  public static let commonErc20Tokens: [String: [TokenConfig]] = [
    "ethereum": [
      TokenConfig(symbol: "USDC", name: "USD Coin", address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", decimals: 6, coinGeckoId: "usd-coin"),
      TokenConfig(symbol: "USDT", name: "Tether", address: "0xdAC17F958D2ee523a2206206994597C13D831ec7", decimals: 6, coinGeckoId: "tether"),
      TokenConfig(symbol: "DAI", name: "Dai", address: "0x6B175474E89094C44Da98b954EedeAC495271d0F", decimals: 18, coinGeckoId: "dai"),
      TokenConfig(symbol: "WETH", name: "Wrapped Ether", address: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", decimals: 18, coinGeckoId: "weth")
    ],
    "base": [
      TokenConfig(symbol: "USDC", name: "USD Coin", address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", decimals: 6, coinGeckoId: "usd-coin")
    ],
    "polygon": [
      TokenConfig(symbol: "USDC", name: "USD Coin", address: "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174", decimals: 6, coinGeckoId: "usd-coin"),
      TokenConfig(symbol: "USDT", name: "Tether", address: "0xc2132D05D31c914a87C6611C10748AEb04B58e8F", decimals: 6, coinGeckoId: "tether")
    ]
  ]

  public static let commonSplTokens: [String: [TokenConfig]] = [
    "solana": [
      TokenConfig(
        symbol: "USDC",
        name: "USD Coin",
        address: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
        decimals: 6,
        coinGeckoId: "usd-coin"
      ),
      TokenConfig(
        symbol: "USDT",
        name: "Tether",
        address: "Es9vMFrzaCERmJfrF4H2FYD4KCoNkYgkNaQx4nFqL1dT",
        decimals: 6,
        coinGeckoId: "tether"
      ),
      TokenConfig(
        symbol: "BONK",
        name: "Bonk",
        address: "DezXAZ8z7PnrnRJjz3sqfB8mVD5JYhwpGfT7TVKPa6i",
        decimals: 5,
        coinGeckoId: "bonk"
      ),
      TokenConfig(
        symbol: "JUP",
        name: "Jupiter",
        address: "JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN",
        decimals: 6,
        coinGeckoId: "jupiter-exchange-solana"
      )
    ]
  ]

  public static var allChains: [ChainConfig] {
    [bitcoin, solana, tron, xrp] + evmChains + cosmosChains
  }
}
