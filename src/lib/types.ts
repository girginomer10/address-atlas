export type ChainFamily = "bitcoin" | "cosmos" | "evm" | "solana";

export type ScanStatus = "ok" | "empty" | "failed";

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
  source: "native" | "erc20";
  status: ScanStatus;
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
  inputCount: number;
  addresses: AddressScan[];
  assets: TrackedAsset[];
  summary: ScanSummary;
  warnings: string[];
}
