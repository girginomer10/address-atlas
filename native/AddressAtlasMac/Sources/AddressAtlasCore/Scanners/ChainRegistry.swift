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
      TokenConfig(symbol: "WETH", name: "Wrapped Ether", address: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", decimals: 18, coinGeckoId: "weth"),
      TokenConfig(symbol: "WBTC", name: "Wrapped Bitcoin", address: "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599", decimals: 8, coinGeckoId: "wrapped-bitcoin"),
      TokenConfig(symbol: "LINK", name: "Chainlink", address: "0x514910771AF9Ca656af840dff83E8264EcF986CA", decimals: 18, coinGeckoId: "chainlink"),
      TokenConfig(symbol: "UNI", name: "Uniswap", address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984", decimals: 18, coinGeckoId: "uniswap"),
      TokenConfig(symbol: "AAVE", name: "Aave", address: "0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9", decimals: 18, coinGeckoId: "aave"),
      TokenConfig(symbol: "SHIB", name: "Shiba Inu", address: "0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE", decimals: 18, coinGeckoId: "shiba-inu"),
      TokenConfig(symbol: "PEPE", name: "Pepe", address: "0x6982508145454Ce325dDbE47a25d4ec3d2311933", decimals: 18, coinGeckoId: "pepe"),
      TokenConfig(symbol: "LDO", name: "Lido DAO", address: "0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32", decimals: 18, coinGeckoId: "lido-dao"),
      TokenConfig(symbol: "stETH", name: "Lido Staked Ether", address: "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84", decimals: 18, coinGeckoId: "staked-ether"),
      TokenConfig(symbol: "PYUSD", name: "PayPal USD", address: "0x6c3ea9036406852006290770BEdFcAbA0e23A0e8", decimals: 6, coinGeckoId: "paypal-usd")
    ],
    "base": [
      TokenConfig(symbol: "USDC", name: "USD Coin", address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", decimals: 6, coinGeckoId: "usd-coin"),
      TokenConfig(symbol: "USDT", name: "Tether", address: "0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2", decimals: 6, coinGeckoId: "tether"),
      TokenConfig(symbol: "WETH", name: "Wrapped Ether", address: "0x4200000000000000000000000000000000000006", decimals: 18, coinGeckoId: "weth"),
      TokenConfig(symbol: "cbBTC", name: "Coinbase Wrapped BTC", address: "0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf", decimals: 8, coinGeckoId: "coinbase-wrapped-btc"),
      TokenConfig(symbol: "DAI", name: "Dai", address: "0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb", decimals: 18, coinGeckoId: "dai"),
      TokenConfig(symbol: "AERO", name: "Aerodrome Finance", address: "0x940181a94A35A4569E4529A3CDfB74e38FD98631", decimals: 18, coinGeckoId: "aerodrome-finance")
    ],
    "arbitrum": [
      TokenConfig(symbol: "USDC", name: "USD Coin", address: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", decimals: 6, coinGeckoId: "usd-coin"),
      TokenConfig(symbol: "USDT", name: "Tether", address: "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9", decimals: 6, coinGeckoId: "tether"),
      TokenConfig(symbol: "USDC.e", name: "Bridged USDC", address: "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8", decimals: 6, coinGeckoId: "usd-coin"),
      TokenConfig(symbol: "WETH", name: "Wrapped Ether", address: "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1", decimals: 18, coinGeckoId: "weth"),
      TokenConfig(symbol: "WBTC", name: "Wrapped Bitcoin", address: "0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f", decimals: 8, coinGeckoId: "wrapped-bitcoin"),
      TokenConfig(symbol: "DAI", name: "Dai", address: "0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1", decimals: 18, coinGeckoId: "dai"),
      TokenConfig(symbol: "ARB", name: "Arbitrum", address: "0x912CE59144191C1204E64559FE8253a0e49E6548", decimals: 18, coinGeckoId: "arbitrum"),
      TokenConfig(symbol: "LINK", name: "Chainlink", address: "0xf97f4df75117a78c1A5a0DBb814Af92458539FB4", decimals: 18, coinGeckoId: "chainlink")
    ],
    "optimism": [
      TokenConfig(symbol: "USDC", name: "USD Coin", address: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85", decimals: 6, coinGeckoId: "usd-coin"),
      TokenConfig(symbol: "USDT", name: "Tether", address: "0x94b008aD8e3F875fCcb024E2A1dC0C9573EcC1d9", decimals: 6, coinGeckoId: "tether"),
      TokenConfig(symbol: "WETH", name: "Wrapped Ether", address: "0x4200000000000000000000000000000000000006", decimals: 18, coinGeckoId: "weth"),
      TokenConfig(symbol: "WBTC", name: "Wrapped Bitcoin", address: "0x68f180fcCe6836688e9084f035309E29Bf0A2095", decimals: 8, coinGeckoId: "wrapped-bitcoin"),
      TokenConfig(symbol: "DAI", name: "Dai", address: "0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1", decimals: 18, coinGeckoId: "dai"),
      TokenConfig(symbol: "OP", name: "Optimism", address: "0x4200000000000000000000000000000000000042", decimals: 18, coinGeckoId: "optimism"),
      TokenConfig(symbol: "LINK", name: "Chainlink", address: "0x350a791Bfc2C21F9Ed5d10980Dad2e2638ffa7f6", decimals: 18, coinGeckoId: "chainlink")
    ],
    "polygon": [
      TokenConfig(symbol: "USDC.e", name: "Bridged USDC", address: "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174", decimals: 6, coinGeckoId: "usd-coin"),
      TokenConfig(symbol: "USDT", name: "Tether", address: "0xc2132D05D31c914a87C6611C10748AEb04B58e8F", decimals: 6, coinGeckoId: "tether"),
      TokenConfig(symbol: "WETH", name: "Wrapped Ether", address: "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619", decimals: 18, coinGeckoId: "weth"),
      TokenConfig(symbol: "WBTC", name: "Wrapped Bitcoin", address: "0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6", decimals: 8, coinGeckoId: "wrapped-bitcoin"),
      TokenConfig(symbol: "DAI", name: "Dai", address: "0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063", decimals: 18, coinGeckoId: "dai"),
      TokenConfig(symbol: "LINK", name: "Chainlink", address: "0x53e0bca35eC356BD5ddDFebbd1Fc0fD03FaBad39", decimals: 18, coinGeckoId: "chainlink"),
      TokenConfig(symbol: "AAVE", name: "Aave", address: "0xD6DF932A45C0f255f85145f286eA0b292B21C90B", decimals: 18, coinGeckoId: "aave")
    ],
    "bsc": [
      TokenConfig(symbol: "USDT", name: "Tether", address: "0x55d398326f99059fF775485246999027B3197955", decimals: 18, coinGeckoId: "tether"),
      TokenConfig(symbol: "USDC", name: "USD Coin", address: "0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d", decimals: 18, coinGeckoId: "usd-coin"),
      TokenConfig(symbol: "WBNB", name: "Wrapped BNB", address: "0xBB4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c", decimals: 18, coinGeckoId: "binancecoin"),
      TokenConfig(symbol: "BTCB", name: "Bitcoin BEP2", address: "0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c", decimals: 18, coinGeckoId: "bitcoin"),
      TokenConfig(symbol: "ETH", name: "Ethereum Token", address: "0x2170Ed0880ac9A755fd29B2688956BD959F933F8", decimals: 18, coinGeckoId: "ethereum"),
      TokenConfig(symbol: "DAI", name: "Dai", address: "0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3", decimals: 18, coinGeckoId: "dai"),
      TokenConfig(symbol: "CAKE", name: "PancakeSwap", address: "0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82", decimals: 18, coinGeckoId: "pancakeswap-token")
    ],
    "avalanche": [
      TokenConfig(symbol: "USDC", name: "USD Coin", address: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E", decimals: 6, coinGeckoId: "usd-coin"),
      TokenConfig(symbol: "USDT.e", name: "Tether", address: "0xc7198437980c041c805A1EDcbA50c1Ce5db95118", decimals: 6, coinGeckoId: "tether"),
      TokenConfig(symbol: "WAVAX", name: "Wrapped AVAX", address: "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7", decimals: 18, coinGeckoId: "avalanche-2"),
      TokenConfig(symbol: "WETH.e", name: "Wrapped Ether", address: "0x49D5c2BdFfac6CE2BFdB6640F4F80f226bc10bAB", decimals: 18, coinGeckoId: "ethereum"),
      TokenConfig(symbol: "BTC.b", name: "Bitcoin Avalanche Bridged", address: "0x152b9d0FdC40C096757F570A51E494bd4b943E50", decimals: 8, coinGeckoId: "bitcoin-avalanche-bridged-btc-b"),
      TokenConfig(symbol: "DAI.e", name: "Dai", address: "0xd586E7F844cEa2F87f50152665BCbc2C279D8d70", decimals: 18, coinGeckoId: "dai"),
      TokenConfig(symbol: "LINK.e", name: "Chainlink", address: "0x5947BB275c521040051D82396192181b413227A3", decimals: 18, coinGeckoId: "chainlink")
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
        address: "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB",
        decimals: 6,
        coinGeckoId: "tether"
      ),
      TokenConfig(
        symbol: "WBTC",
        name: "Wrapped Bitcoin",
        address: "9n4nbM75f5Ui33ZbPYXn59EwSgE8CGsHtAeTH5YFeJ9E",
        decimals: 6,
        coinGeckoId: "wrapped-bitcoin"
      ),
      TokenConfig(
        symbol: "JitoSOL",
        name: "Jito Staked SOL",
        address: "J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn",
        decimals: 9,
        coinGeckoId: "jito-staked-sol"
      ),
      TokenConfig(
        symbol: "BONK",
        name: "Bonk",
        address: "DezXAZ8z7PnrnRJjz3JpPZsM1pPB263KGg1W53WZyQb",
        decimals: 5,
        coinGeckoId: "bonk"
      ),
      TokenConfig(
        symbol: "WIF",
        name: "dogwifhat",
        address: "EKpQGSJtjMFqKZ9KQanSqYXRcF8fBopzLau9bQn8HnK8",
        decimals: 6,
        coinGeckoId: "dogwifcoin"
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

  public static let commonTrc20Tokens: [String: [TokenConfig]] = [
    "tron": [
      TokenConfig(
        symbol: "USDT",
        name: "Tether",
        address: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
        decimals: 6,
        coinGeckoId: "tether"
      )
    ]
  ]

  public static var allChains: [ChainConfig] {
    [bitcoin, solana, tron, xrp] + evmChains + cosmosChains
  }
}
