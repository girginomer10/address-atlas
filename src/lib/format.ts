export function formatUnits(value: bigint, decimals: number): number {
  if (value === 0n) return 0;

  const divisor = 10n ** BigInt(decimals);
  const whole = value / divisor;
  const fraction = value % divisor;
  const fractionText = fraction
    .toString()
    .padStart(decimals, "0")
    .replace(/0+$/, "")
    .slice(0, 12);

  return Number(`${whole.toString()}${fractionText ? `.${fractionText}` : ""}`);
}

export function hexToBigInt(hex: string | null | undefined): bigint {
  if (!hex || hex === "0x") return 0n;
  return BigInt(hex);
}

export function toUsd(value: number): string {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: 2,
    maximumFractionDigits: value >= 1 ? 2 : 6
  }).format(value);
}

export function shortAddress(address: string): string {
  if (address.length <= 14) return address;
  return `${address.slice(0, 6)}...${address.slice(-6)}`;
}

export function percent(value: number | undefined): string {
  if (typeof value !== "number" || Number.isNaN(value)) return "0.00%";
  const sign = value > 0 ? "+" : "";
  return `${sign}${value.toFixed(2)}%`;
}
