import { ChainConfig, TokenConfig } from "./types";

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
    }
  ],
  base: [
    {
      symbol: "USDC",
      name: "USD Coin",
      address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
      decimals: 6,
      coinGeckoId: "usd-coin"
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
    }
  ]
};

export const SUPPORTED_CHAINS: ChainConfig[] = [
  BITCOIN_CHAIN,
  SOLANA_CHAIN,
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
    tokens.forEach((token) => ids.add(token.coinGeckoId));
  });
  return Array.from(ids);
}
