import { ChainConfig, SplTokenConfig, TokenConfig, Trc20TokenConfig } from "./types";

export const SOLANA_TOKEN_PROGRAM_ID = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
export const SOLANA_TOKEN_2022_PROGRAM_ID = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb";

export const BITCOIN_CHAIN: ChainConfig = {
  id: "bitcoin",
  name: "Bitcoin",
  family: "bitcoin",
  symbol: "BTC",
  coinGeckoId: "bitcoin",
  explorerUrl: "https://blockstream.info/address/",
  decimals: 8
};

export const SOLANA_CHAIN: ChainConfig = {
  id: "solana",
  name: "Solana",
  family: "solana",
  symbol: "SOL",
  coinGeckoId: "solana",
  rpcUrl: "https://api.mainnet-beta.solana.com",
  explorerUrl: "https://solscan.io/account/",
  decimals: 9
};

export const TRON_CHAIN: ChainConfig = {
  id: "tron",
  name: "TRON",
  family: "tron",
  symbol: "TRX",
  coinGeckoId: "tron",
  restUrl: "https://api.trongrid.io",
  explorerUrl: "https://tronscan.org/#/address/",
  decimals: 6
};

export const XRP_CHAIN: ChainConfig = {
  id: "xrp",
  name: "XRP Ledger",
  family: "xrp",
  symbol: "XRP",
  coinGeckoId: "ripple",
  rpcUrl: "https://s1.ripple.com:51234/",
  explorerUrl: "https://xrpscan.com/account/",
  decimals: 6
};

export const EVM_CHAINS: ChainConfig[] = [
  {
    id: "ethereum",
    name: "Ethereum",
    family: "evm",
    symbol: "ETH",
    coinGeckoId: "ethereum",
    rpcUrl: "https://eth.llamarpc.com",
    explorerUrl: "https://etherscan.io/address/",
    decimals: 18
  },
  {
    id: "base",
    name: "Base",
    family: "evm",
    symbol: "ETH",
    coinGeckoId: "ethereum",
    rpcUrl: "https://mainnet.base.org",
    explorerUrl: "https://basescan.org/address/",
    decimals: 18
  },
  {
    id: "arbitrum",
    name: "Arbitrum One",
    family: "evm",
    symbol: "ETH",
    coinGeckoId: "ethereum",
    rpcUrl: "https://arb1.arbitrum.io/rpc",
    explorerUrl: "https://arbiscan.io/address/",
    decimals: 18
  },
  {
    id: "optimism",
    name: "Optimism",
    family: "evm",
    symbol: "ETH",
    coinGeckoId: "ethereum",
    rpcUrl: "https://mainnet.optimism.io",
    explorerUrl: "https://optimistic.etherscan.io/address/",
    decimals: 18
  },
  {
    id: "polygon",
    name: "Polygon PoS",
    family: "evm",
    symbol: "MATIC",
    coinGeckoId: "matic-network",
    rpcUrl: "https://polygon-rpc.com",
    explorerUrl: "https://polygonscan.com/address/",
    decimals: 18
  },
  {
    id: "bsc",
    name: "BNB Chain",
    family: "evm",
    symbol: "BNB",
    coinGeckoId: "binancecoin",
    rpcUrl: "https://bsc-dataseed.binance.org",
    explorerUrl: "https://bscscan.com/address/",
    decimals: 18
  },
  {
    id: "avalanche",
    name: "Avalanche C-Chain",
    family: "evm",
    symbol: "AVAX",
    coinGeckoId: "avalanche-2",
    rpcUrl: "https://api.avax.network/ext/bc/C/rpc",
    explorerUrl: "https://snowtrace.io/address/",
    decimals: 18
  }
];

export const COSMOS_CHAINS: ChainConfig[] = [
  {
    id: "cosmoshub",
    name: "Cosmos Hub",
    family: "cosmos",
    symbol: "ATOM",
    coinGeckoId: "cosmos",
    restUrl: "https://cosmos-api.polkachu.com",
    fallbackRestUrls: [
      "https://cosmoshub-rest.publicnode.com",
      "https://rest.cosmos.directory/cosmoshub",
      "https://cosmos-lcd.stakely.io"
    ],
    explorerUrl: "https://www.mintscan.io/cosmos/address/",
    decimals: 6,
    nativeDenom: "uatom",
    addressPrefix: "cosmos"
  },
  {
    id: "osmosis",
    name: "Osmosis",
    family: "cosmos",
    symbol: "OSMO",
    coinGeckoId: "osmosis",
    restUrl: "https://lcd.osmosis.zone",
    fallbackRestUrls: [
      "https://osmosis-api.polkachu.com",
      "https://osmosis-rest.publicnode.com"
    ],
    explorerUrl: "https://www.mintscan.io/osmosis/address/",
    decimals: 6,
    nativeDenom: "uosmo",
    addressPrefix: "osmo"
  },
  {
    id: "celestia",
    name: "Celestia",
    family: "cosmos",
    symbol: "TIA",
    coinGeckoId: "celestia",
    restUrl: "https://celestia-api.polkachu.com",
    fallbackRestUrls: [
      "https://public-celestia-lcd.numia.xyz",
      "https://celestia-rest.publicnode.com"
    ],
    explorerUrl: "https://www.mintscan.io/celestia/address/",
    decimals: 6,
    nativeDenom: "utia",
    addressPrefix: "celestia"
  },
  {
    id: "stargaze",
    name: "Stargaze",
    family: "cosmos",
    symbol: "STARS",
    coinGeckoId: "stargaze",
    restUrl: "https://rest.stargaze-apis.com",
    fallbackRestUrls: [
      "https://stargaze-api.polkachu.com",
      "https://stargaze-rest.publicnode.com"
    ],
    explorerUrl: "https://www.mintscan.io/stargaze/address/",
    decimals: 6,
    nativeDenom: "ustars",
    addressPrefix: "stars"
  },
  {
    id: "stride",
    name: "Stride",
    family: "cosmos",
    symbol: "STRD",
    coinGeckoId: "stride",
    restUrl: "https://stride-api.polkachu.com",
    fallbackRestUrls: [
      "https://stride-rest.publicnode.com",
      "https://stride.api.chandrastation.com"
    ],
    explorerUrl: "https://www.mintscan.io/stride/address/",
    decimals: 6,
    nativeDenom: "ustrd",
    addressPrefix: "stride"
  }
];

export const ERC20_TOKENS_BY_CHAIN: Record<string, TokenConfig[]> = {
  ethereum: [
    {
      symbol: "USDC",
      name: "USD Coin",
      address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      decimals: 6,
      coinGeckoId: "usd-coin"
    },
    {
      symbol: "USDT",
      name: "Tether",
      address: "0xdAC17F958D2ee523a2206206994597C13D831ec7",
      decimals: 6,
      coinGeckoId: "tether"
    },
    {
      symbol: "DAI",
      name: "Dai",
      address: "0x6B175474E89094C44Da98b954EedeAC495271d0F",
      decimals: 18,
      coinGeckoId: "dai"
    },
    {
      symbol: "WETH",
      name: "Wrapped Ether",
      address: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
      decimals: 18,
      coinGeckoId: "weth"
    },
    {
      symbol: "WBTC",
      name: "Wrapped Bitcoin",
      address: "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",
      decimals: 8,
      coinGeckoId: "wrapped-bitcoin"
    },
    {
      symbol: "LINK",
      name: "Chainlink",
      address: "0x514910771AF9Ca656af840dff83E8264EcF986CA",
      decimals: 18,
      coinGeckoId: "chainlink"
    },
    {
      symbol: "UNI",
      name: "Uniswap",
      address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
      decimals: 18,
      coinGeckoId: "uniswap"
    },
    {
      symbol: "AAVE",
      name: "Aave",
      address: "0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9",
      decimals: 18,
      coinGeckoId: "aave"
    },
    {
      symbol: "SHIB",
      name: "Shiba Inu",
      address: "0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE",
      decimals: 18,
      coinGeckoId: "shiba-inu"
    },
    {
      symbol: "PEPE",
      name: "Pepe",
      address: "0x6982508145454Ce325dDbE47a25d4ec3d2311933",
      decimals: 18,
      coinGeckoId: "pepe"
    },
    {
      symbol: "LDO",
      name: "Lido DAO",
      address: "0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32",
      decimals: 18,
      coinGeckoId: "lido-dao"
    },
    {
      symbol: "stETH",
      name: "Lido Staked Ether",
      address: "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84",
      decimals: 18,
      coinGeckoId: "staked-ether"
    },
    {
      symbol: "PYUSD",
      name: "PayPal USD",
      address: "0x6c3ea9036406852006290770BEdFcAbA0e23A0e8",
      decimals: 6,
      coinGeckoId: "paypal-usd"
    }
  ],
  base: [
    {
      symbol: "USDC",
      name: "USD Coin",
      address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
      decimals: 6,
      coinGeckoId: "usd-coin"
    },
    {
      symbol: "USDT",
      name: "Tether",
      address: "0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2",
      decimals: 6,
      coinGeckoId: "tether"
    },
    {
      symbol: "WETH",
      name: "Wrapped Ether",
      address: "0x4200000000000000000000000000000000000006",
      decimals: 18,
      coinGeckoId: "weth"
    },
    {
      symbol: "cbBTC",
      name: "Coinbase Wrapped BTC",
      address: "0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf",
      decimals: 8,
      coinGeckoId: "coinbase-wrapped-btc"
    },
    {
      symbol: "DAI",
      name: "Dai",
      address: "0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb",
      decimals: 18,
      coinGeckoId: "dai"
    },
    {
      symbol: "AERO",
      name: "Aerodrome Finance",
      address: "0x940181a94A35A4569E4529A3CDfB74e38FD98631",
      decimals: 18,
      coinGeckoId: "aerodrome-finance"
    }
  ],
  arbitrum: [
    {
      symbol: "USDC",
      name: "USD Coin",
      address: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
      decimals: 6,
      coinGeckoId: "usd-coin"
    },
    {
      symbol: "USDT",
      name: "Tether",
      address: "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9",
      decimals: 6,
      coinGeckoId: "tether"
    },
    {
      symbol: "USDC.e",
      name: "Bridged USDC",
      address: "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8",
      decimals: 6,
      coinGeckoId: "usd-coin"
    },
    {
      symbol: "WETH",
      name: "Wrapped Ether",
      address: "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1",
      decimals: 18,
      coinGeckoId: "weth"
    },
    {
      symbol: "WBTC",
      name: "Wrapped Bitcoin",
      address: "0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f",
      decimals: 8,
      coinGeckoId: "wrapped-bitcoin"
    },
    {
      symbol: "DAI",
      name: "Dai",
      address: "0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1",
      decimals: 18,
      coinGeckoId: "dai"
    },
    {
      symbol: "ARB",
      name: "Arbitrum",
      address: "0x912CE59144191C1204E64559FE8253a0e49E6548",
      decimals: 18,
      coinGeckoId: "arbitrum"
    },
    {
      symbol: "LINK",
      name: "Chainlink",
      address: "0xf97f4df75117a78c1A5a0DBb814Af92458539FB4",
      decimals: 18,
      coinGeckoId: "chainlink"
    }
  ],
  optimism: [
    {
      symbol: "USDC",
      name: "USD Coin",
      address: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85",
      decimals: 6,
      coinGeckoId: "usd-coin"
    },
    {
      symbol: "USDT",
      name: "Tether",
      address: "0x94b008aD8e3F875fCcb024E2A1dC0C9573EcC1d9",
      decimals: 6,
      coinGeckoId: "tether"
    },
    {
      symbol: "WETH",
      name: "Wrapped Ether",
      address: "0x4200000000000000000000000000000000000006",
      decimals: 18,
      coinGeckoId: "weth"
    },
    {
      symbol: "WBTC",
      name: "Wrapped Bitcoin",
      address: "0x68f180fcCe6836688e9084f035309E29Bf0A2095",
      decimals: 8,
      coinGeckoId: "wrapped-bitcoin"
    },
    {
      symbol: "DAI",
      name: "Dai",
      address: "0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1",
      decimals: 18,
      coinGeckoId: "dai"
    },
    {
      symbol: "OP",
      name: "Optimism",
      address: "0x4200000000000000000000000000000000000042",
      decimals: 18,
      coinGeckoId: "optimism"
    },
    {
      symbol: "LINK",
      name: "Chainlink",
      address: "0x350a791Bfc2C21F9Ed5d10980Dad2e2638ffa7f6",
      decimals: 18,
      coinGeckoId: "chainlink"
    }
  ],
  polygon: [
    {
      symbol: "USDC.e",
      name: "Bridged USDC",
      address: "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174",
      decimals: 6,
      coinGeckoId: "usd-coin"
    },
    {
      symbol: "USDT",
      name: "Tether",
      address: "0xc2132D05D31c914a87C6611C10748AEb04B58e8F",
      decimals: 6,
      coinGeckoId: "tether"
    },
    {
      symbol: "WETH",
      name: "Wrapped Ether",
      address: "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619",
      decimals: 18,
      coinGeckoId: "weth"
    },
    {
      symbol: "WBTC",
      name: "Wrapped Bitcoin",
      address: "0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6",
      decimals: 8,
      coinGeckoId: "wrapped-bitcoin"
    },
    {
      symbol: "DAI",
      name: "Dai",
      address: "0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063",
      decimals: 18,
      coinGeckoId: "dai"
    },
    {
      symbol: "LINK",
      name: "Chainlink",
      address: "0x53e0bca35eC356BD5ddDFebbd1Fc0fD03FaBad39",
      decimals: 18,
      coinGeckoId: "chainlink"
    },
    {
      symbol: "AAVE",
      name: "Aave",
      address: "0xD6DF932A45C0f255f85145f286eA0b292B21C90B",
      decimals: 18,
      coinGeckoId: "aave"
    }
  ],
  bsc: [
    {
      symbol: "USDT",
      name: "Tether",
      address: "0x55d398326f99059fF775485246999027B3197955",
      decimals: 18,
      coinGeckoId: "tether"
    },
    {
      symbol: "USDC",
      name: "USD Coin",
      address: "0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d",
      decimals: 18,
      coinGeckoId: "usd-coin"
    },
    {
      symbol: "WBNB",
      name: "Wrapped BNB",
      address: "0xBB4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
      decimals: 18,
      coinGeckoId: "binancecoin"
    },
    {
      symbol: "BTCB",
      name: "Bitcoin BEP2",
      address: "0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c",
      decimals: 18,
      coinGeckoId: "bitcoin"
    },
    {
      symbol: "ETH",
      name: "Ethereum Token",
      address: "0x2170Ed0880ac9A755fd29B2688956BD959F933F8",
      decimals: 18,
      coinGeckoId: "ethereum"
    },
    {
      symbol: "DAI",
      name: "Dai",
      address: "0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3",
      decimals: 18,
      coinGeckoId: "dai"
    },
    {
      symbol: "CAKE",
      name: "PancakeSwap",
      address: "0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82",
      decimals: 18,
      coinGeckoId: "pancakeswap-token"
    }
  ],
  avalanche: [
    {
      symbol: "USDC",
      name: "USD Coin",
      address: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E",
      decimals: 6,
      coinGeckoId: "usd-coin"
    },
    {
      symbol: "USDT.e",
      name: "Tether",
      address: "0xc7198437980c041c805A1EDcbA50c1Ce5db95118",
      decimals: 6,
      coinGeckoId: "tether"
    },
    {
      symbol: "WAVAX",
      name: "Wrapped AVAX",
      address: "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7",
      decimals: 18,
      coinGeckoId: "avalanche-2"
    },
    {
      symbol: "WETH.e",
      name: "Wrapped Ether",
      address: "0x49D5c2BdFfac6CE2BFdB6640F4F80f226bc10bAB",
      decimals: 18,
      coinGeckoId: "ethereum"
    },
    {
      symbol: "BTC.b",
      name: "Bitcoin Avalanche Bridged",
      address: "0x152b9d0FdC40C096757F570A51E494bd4b943E50",
      decimals: 8,
      coinGeckoId: "bitcoin-avalanche-bridged-btc-b"
    },
    {
      symbol: "DAI.e",
      name: "Dai",
      address: "0xd586E7F844cEa2F87f50152665BCbc2C279D8d70",
      decimals: 18,
      coinGeckoId: "dai"
    },
    {
      symbol: "LINK.e",
      name: "Chainlink",
      address: "0x5947BB275c521040051D82396192181b413227A3",
      decimals: 18,
      coinGeckoId: "chainlink"
    }
  ]
};

export const SPL_TOKENS_BY_CHAIN: Record<string, SplTokenConfig[]> = {
  solana: [
    {
      symbol: "USDC",
      name: "USD Coin",
      mint: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
      decimals: 6,
      coinGeckoId: "usd-coin"
    },
    {
      symbol: "USDT",
      name: "Tether",
      mint: "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB",
      decimals: 6,
      coinGeckoId: "tether"
    },
    {
      symbol: "WBTC",
      name: "Wrapped Bitcoin",
      mint: "9n4nbM75f5Ui33ZbPYXn59EwSgE8CGsHtAeTH5YFeJ9E",
      decimals: 6,
      coinGeckoId: "wrapped-bitcoin"
    },
    {
      symbol: "JitoSOL",
      name: "Jito Staked SOL",
      mint: "J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn",
      decimals: 9,
      coinGeckoId: "jito-staked-sol"
    },
    {
      symbol: "BONK",
      name: "Bonk",
      mint: "DezXAZ8z7PnrnRJjz3JpPZsM1pPB263KGg1W53WZyQb",
      decimals: 5,
      coinGeckoId: "bonk"
    },
    {
      symbol: "WIF",
      name: "dogwifhat",
      mint: "EKpQGSJtjMFqKZ9KQanSqYXRcF8fBopzLau9bQn8HnK8",
      decimals: 6,
      coinGeckoId: "dogwifcoin"
    },
    {
      symbol: "JUP",
      name: "Jupiter",
      mint: "JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN",
      decimals: 6,
      coinGeckoId: "jupiter-exchange-solana"
    }
  ]
};

export const TRC20_TOKENS_BY_CHAIN: Record<string, Trc20TokenConfig[]> = {
  tron: [
    {
      symbol: "USDT",
      name: "Tether",
      address: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
      decimals: 6,
      coinGeckoId: "tether"
    }
  ]
};

export const SUPPORTED_CHAINS: ChainConfig[] = [
  BITCOIN_CHAIN,
  SOLANA_CHAIN,
  TRON_CHAIN,
  XRP_CHAIN,
  ...EVM_CHAINS,
  ...COSMOS_CHAINS
];

export function detectChainsForAddress(address: string): ChainConfig[] {
  const trimmed = address.trim();

  if (/^0x[a-fA-F0-9]{40}$/.test(trimmed)) {
    return EVM_CHAINS;
  }

  if (/^(bc1|[13])[a-zA-HJ-NP-Z0-9]{25,90}$/i.test(trimmed)) {
    return [BITCOIN_CHAIN];
  }

  if (/^T[1-9A-HJ-NP-Za-km-z]{33}$/.test(trimmed)) {
    return [TRON_CHAIN];
  }

  if (/^r[1-9A-HJ-NP-Za-km-z]{24,34}$/.test(trimmed)) {
    return [XRP_CHAIN];
  }

  const cosmosMatch = trimmed.match(/^([a-z][a-z0-9]{1,20})1[023456789acdefghjklmnpqrstuvwxyz]{20,}$/i);
  if (cosmosMatch) {
    const prefix = cosmosMatch[1].toLowerCase();
    return COSMOS_CHAINS.filter((chain) => chain.addressPrefix === prefix);
  }

  if (/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(trimmed)) {
    return [SOLANA_CHAIN];
  }

  return [];
}

export function getAllCoinGeckoIds(): string[] {
  const ids = new Set<string>();
  SUPPORTED_CHAINS.forEach((chain) => ids.add(chain.coinGeckoId));
  Object.values(ERC20_TOKENS_BY_CHAIN).forEach((tokens) => {
    tokens.forEach((token) => {
      if (token.coinGeckoId) ids.add(token.coinGeckoId);
    });
  });
  Object.values(SPL_TOKENS_BY_CHAIN).forEach((tokens) => {
    tokens.forEach((token) => {
      if (token.coinGeckoId) ids.add(token.coinGeckoId);
    });
  });
  Object.values(TRC20_TOKENS_BY_CHAIN).forEach((tokens) => {
    tokens.forEach((token) => {
      if (token.coinGeckoId) ids.add(token.coinGeckoId);
    });
  });
  return Array.from(ids);
}
