export type ChainFamily = "bitcoin" | "cosmos" | "evm" | "solana" | "exchange";

export type ScanStatus = "ok" | "empty" | "failed";
export type AssetSource = "native" | "erc20" | "spl" | "exchange" | "staked" | "rewards";
export type ExchangeProvider = "binance" | "coinbase" | "kraken";

export interface PricePoint {
  usd: number;
  usd_24h_change?: number;
}

export interface ChainConfig {
  id: string;
  name: string;
  family: ChainFamily;
  symbol: string;
  coinGeckoId: string;
  explorerUrl: string;
  decimals: number;
  rpcUrl?: string;
  restUrl?: string;
  fallbackRestUrls?: string[];
  nativeDenom?: string;
  addressPrefix?: string;
}

export interface TokenConfig {
  symbol: string;
  name: string;
  address: `0x${string}`;
  decimals: number;
  coinGeckoId: string;
}

export interface SplTokenConfig {
  symbol: string;
  name: string;
  mint: string;
  decimals: number;
  coinGeckoId: string;
}

export interface TrackedAsset {
  id: string;
  address: string;
  chainId: string;
  chainName: string;
  family: ChainFamily;
  symbol: string;
  name: string;
  amount: number;
  priceUsd: number;
  valueUsd: number;
  change24h?: number;
  explorerUrl: string;
  source: AssetSource;
  status: ScanStatus;
  walletLabel?: string;
  exchangeId?: string;
  exchangeProvider?: ExchangeProvider;
}

export interface AddressScan {
  address: string;
  detectedChains: string[];
  assets: TrackedAsset[];
  warnings: string[];
  errors: string[];
}

export interface ScanSummary {
  totalUsd: number;
  addressCount: number;
  chainCount: number;
  assetCount: number;
}

export interface ScanResponse {
  generatedAt: string;
  scanRunId?: string;
  inputCount: number;
  addresses: AddressScan[];
  assets: TrackedAsset[];
  summary: ScanSummary;
  warnings: string[];
  sources?: ScanSource[];
  exchangeSnapshots?: ExchangeSnapshot[];
}

export interface ScanSource {
  id: string;
  label: string;
  kind: "onchain" | "exchange";
  status: ScanStatus;
  message?: string;
}

export interface ExchangeSnapshot {
  id?: string;
  connectionId: string;
  provider: ExchangeProvider;
  label: string;
  generatedAt: string;
  totalUsd: number;
  status: ScanStatus;
  holdings: TrackedAsset[];
  error?: string;
}

export interface ExchangeCredentialInput {
  provider: ExchangeProvider;
  label: string;
  apiKey: string;
  secret: string;
  passphrase?: string;
  vaultPassphrase?: string;
}

export interface NormalizedHolding {
  symbol: string;
  name: string;
  amount: number;
  priceUsd: number;
  valueUsd: number;
  change24h?: number;
}
