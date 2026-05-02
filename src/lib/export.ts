import { ScanResponse, TrackedAsset } from "./types";

export function timestampForFile(value: string) {
  return value.replace(/[:.]/g, "-");
}

export function csvCell(value: string | number | null | undefined) {
  const text = String(value ?? "");
  if (!/[",\n]/.test(text)) return text;
  return `"${text.replace(/"/g, '""')}"`;
}

export function assetsToCsv(assets: TrackedAsset[]) {
  const headers = [
    "source",
    "wallet_or_exchange",
    "address",
    "chain",
    "asset",
    "name",
    "amount",
    "price_usd",
    "value_usd",
    "change_24h",
    "explorer_url"
  ];
  const rows = assets.map((asset) => [
    asset.source,
    asset.walletLabel || asset.exchangeProvider || "",
    asset.address,
    asset.chainName,
    asset.symbol,
    asset.name,
    asset.amount,
    asset.priceUsd,
    asset.valueUsd,
    asset.change24h ?? "",
    asset.explorerUrl
  ]);

  return [headers, ...rows]
    .map((row) => row.map((value) => csvCell(value)).join(","))
    .join("\n");
}

export function scanToJson(scan: ScanResponse) {
  return JSON.stringify(scan, null, 2);
}
