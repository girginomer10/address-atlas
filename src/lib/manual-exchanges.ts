import { prisma } from "./db";
import { exchangeProviderLabel } from "./exchanges";
import { containsSensitiveSecret } from "./security";
import { ExchangeProvider, TrackedAsset } from "./types";

const SUPPORTED_PROVIDERS: ExchangeProvider[] = ["binance", "coinbase", "kraken"];
const CUSTOM_PROVIDER = "custom" as const;
const MAX_LABEL_LENGTH = 64;
const MAX_SYMBOL_LENGTH = 16;
const MAX_NAME_LENGTH = 80;
const MAX_VENUE_LENGTH = 64;
const MAX_NOTES_LENGTH = 240;

export type ManualProvider = ExchangeProvider | typeof CUSTOM_PROVIDER;

export interface ManualHoldingRecord {
  id: string;
  label: string;
  provider: ManualProvider;
  providerLabel: string;
  customVenue: string | null;
  symbol: string;
  name: string;
  amount: number;
  priceUsd: number | null;
  valueUsd: number;
  notes: string | null;
  enabled: boolean;
  generatedAt: string;
  createdAt: string;
  updatedAt: string;
}

export interface ManualHoldingCreateInput {
  label?: string;
  provider?: string;
  customVenue?: string | null;
  symbol?: string;
  name?: string;
  amount?: number | string;
  priceUsd?: number | string | null;
  valueUsd?: number | string | null;
  notes?: string | null;
  enabled?: boolean;
  generatedAt?: string;
}

export interface ManualHoldingUpdateInput {
  label?: string;
  provider?: string;
  customVenue?: string | null;
  symbol?: string;
  name?: string;
  amount?: number | string;
  priceUsd?: number | string | null;
  valueUsd?: number | string | null;
  notes?: string | null;
  enabled?: boolean;
  generatedAt?: string;
}

type ManualHoldingRow = {
  id: string;
  label: string;
  provider: string;
  customVenue: string | null;
  symbol: string;
  name: string;
  amount: number;
  priceUsd: number | null;
  valueUsd: number;
  notes: string | null;
  enabled: boolean;
  generatedAt: Date;
  createdAt: Date;
  updatedAt: Date;
};

export function manualProviderOptions() {
  return [
    ...SUPPORTED_PROVIDERS.map((provider) => ({ id: provider, label: exchangeProviderLabel(provider) })),
    { id: CUSTOM_PROVIDER, label: "Custom venue" }
  ];
}

export async function listManualHoldings() {
  const rows = await prisma.manualExchangeHolding.findMany({
    orderBy: [{ enabled: "desc" }, { createdAt: "asc" }]
  });
  return rows.map(serialize);
}

export async function listEnabledManualHoldings() {
  const rows = await prisma.manualExchangeHolding.findMany({
    where: { enabled: true },
    orderBy: [{ createdAt: "asc" }]
  });
  return rows.map(serialize);
}

export async function createManualHolding(input: ManualHoldingCreateInput) {
  const data = validateCreate(input);
  const row = await prisma.manualExchangeHolding.create({ data });
  return serialize(row);
}

export async function updateManualHolding(id: string, input: ManualHoldingUpdateInput) {
  if (!id) throw new Error("Manual holding id is required.");
  const existing = await prisma.manualExchangeHolding.findUnique({ where: { id } });
  if (!existing) throw new Error("Manual holding not found.");

  const data = validateUpdate(existing, input);
  const row = await prisma.manualExchangeHolding.update({ where: { id }, data });
  return serialize(row);
}

export async function deleteManualHolding(id: string) {
  if (!id) throw new Error("Manual holding id is required.");
  await prisma.manualExchangeHolding.delete({ where: { id } });
}

export function manualHoldingToTrackedAsset(holding: ManualHoldingRecord): TrackedAsset {
  const venueLabel = manualVenueLabel(holding);
  const safeAmount = Number.isFinite(holding.amount) ? holding.amount : 0;
  const safePrice = holding.priceUsd && Number.isFinite(holding.priceUsd) ? holding.priceUsd : 0;
  const safeValue = Number.isFinite(holding.valueUsd) ? holding.valueUsd : 0;

  return {
    id: `manual-${holding.id}`,
    address: holding.label,
    chainId: `manual-${holding.provider}`,
    chainName: venueLabel,
    family: "exchange",
    symbol: holding.symbol,
    name: holding.name || holding.symbol,
    amount: safeAmount,
    priceUsd: safePrice,
    valueUsd: safeValue,
    explorerUrl: "",
    source: "exchange",
    status: "ok",
    walletLabel: holding.label,
    exchangeId: holding.id,
    exchangeProvider: holding.provider !== CUSTOM_PROVIDER
      ? (holding.provider as ExchangeProvider)
      : undefined
  };
}

export function manualVenueLabel(holding: Pick<ManualHoldingRecord, "provider" | "customVenue">) {
  if (holding.provider === CUSTOM_PROVIDER) {
    return holding.customVenue?.trim() || "Custom venue";
  }
  return exchangeProviderLabel(holding.provider as ExchangeProvider);
}

function serialize(row: ManualHoldingRow): ManualHoldingRecord {
  const provider = isManualProvider(row.provider) ? row.provider : CUSTOM_PROVIDER;
  return {
    id: row.id,
    label: row.label,
    provider,
    providerLabel: manualVenueLabel({ provider, customVenue: row.customVenue }),
    customVenue: row.customVenue,
    symbol: row.symbol,
    name: row.name,
    amount: row.amount,
    priceUsd: row.priceUsd,
    valueUsd: row.valueUsd,
    notes: row.notes,
    enabled: row.enabled,
    generatedAt: row.generatedAt.toISOString(),
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString()
  };
}

function isManualProvider(value: string): value is ManualProvider {
  return value === CUSTOM_PROVIDER || (SUPPORTED_PROVIDERS as string[]).includes(value);
}

function validateCreate(input: ManualHoldingCreateInput) {
  const provider = parseProvider(input.provider);
  const customVenue = parseCustomVenue(provider, input.customVenue);
  const label = parseLabel(input.label);
  const symbol = parseSymbol(input.symbol);
  const name = parseName(input.name, symbol);
  const amount = parseAmount(input.amount);
  const { priceUsd, valueUsd } = parseValuation(amount, input.priceUsd, input.valueUsd);
  const notes = parseNotes(input.notes);
  const generatedAt = parseGeneratedAt(input.generatedAt);
  assertNoSecret(label, customVenue, name, notes);

  return {
    label,
    provider,
    customVenue,
    symbol,
    name,
    amount,
    priceUsd,
    valueUsd,
    notes,
    enabled: input.enabled === undefined ? true : Boolean(input.enabled),
    generatedAt
  };
}

function validateUpdate(existing: ManualHoldingRow, input: ManualHoldingUpdateInput) {
  const provider = input.provider !== undefined ? parseProvider(input.provider) : (existing.provider as ManualProvider);
  const customVenueRaw =
    input.customVenue !== undefined
      ? input.customVenue
      : existing.customVenue;
  const customVenue = parseCustomVenue(provider, customVenueRaw);
  const label = input.label !== undefined ? parseLabel(input.label) : existing.label;
  const symbol = input.symbol !== undefined ? parseSymbol(input.symbol) : existing.symbol;
  const name = input.name !== undefined ? parseName(input.name, symbol) : existing.name;
  const amount = input.amount !== undefined ? parseAmount(input.amount) : existing.amount;
  const valuation = parseValuationForUpdate(
    amount,
    input.priceUsd,
    input.valueUsd,
    existing.priceUsd,
    existing.valueUsd
  );
  const notes = input.notes !== undefined ? parseNotes(input.notes) : existing.notes;
  const generatedAt = input.generatedAt !== undefined ? parseGeneratedAt(input.generatedAt) : existing.generatedAt;
  const enabled = input.enabled === undefined ? existing.enabled : Boolean(input.enabled);
  assertNoSecret(label, customVenue, name, notes);

  return {
    label,
    provider,
    customVenue,
    symbol,
    name,
    amount,
    priceUsd: valuation.priceUsd,
    valueUsd: valuation.valueUsd,
    notes,
    enabled,
    generatedAt
  };
}

function parseProvider(value: string | undefined): ManualProvider {
  const normalized = (value ?? "").trim().toLowerCase();
  if (!normalized) throw new Error("Provider is required.");
  if (normalized === CUSTOM_PROVIDER) return CUSTOM_PROVIDER;
  if ((SUPPORTED_PROVIDERS as string[]).includes(normalized)) {
    return normalized as ExchangeProvider;
  }
  throw new Error("Provider must be binance, coinbase, kraken, or custom.");
}

function parseCustomVenue(provider: ManualProvider, value: string | null | undefined) {
  if (provider !== CUSTOM_PROVIDER) return null;
  const trimmed = (value ?? "").toString().trim();
  if (!trimmed) throw new Error("Custom venue name is required for custom provider.");
  if (trimmed.length > MAX_VENUE_LENGTH) {
    throw new Error(`Custom venue name must be ${MAX_VENUE_LENGTH} characters or fewer.`);
  }
  return trimmed;
}

function parseLabel(value: string | undefined) {
  const trimmed = (value ?? "").trim();
  if (!trimmed) throw new Error("Label is required.");
  if (trimmed.length > MAX_LABEL_LENGTH) {
    throw new Error(`Label must be ${MAX_LABEL_LENGTH} characters or fewer.`);
  }
  return trimmed;
}

function parseSymbol(value: string | undefined) {
  const trimmed = (value ?? "").trim().toUpperCase();
  if (!trimmed) throw new Error("Symbol is required.");
  if (trimmed.length > MAX_SYMBOL_LENGTH) {
    throw new Error(`Symbol must be ${MAX_SYMBOL_LENGTH} characters or fewer.`);
  }
  if (!/^[A-Z0-9._-]{1,16}$/.test(trimmed)) {
    throw new Error("Symbol may only contain letters, digits, dot, dash, or underscore.");
  }
  return trimmed;
}

function parseName(value: string | undefined, fallbackSymbol: string) {
  const trimmed = (value ?? "").trim();
  const final = trimmed || fallbackSymbol;
  if (final.length > MAX_NAME_LENGTH) {
    throw new Error(`Name must be ${MAX_NAME_LENGTH} characters or fewer.`);
  }
  return final;
}

function parseAmount(value: number | string | undefined) {
  const numeric = typeof value === "string" ? Number(value) : value;
  if (!Number.isFinite(numeric ?? NaN) || (numeric as number) < 0) {
    throw new Error("Amount must be a non-negative number.");
  }
  return numeric as number;
}

function parseValuation(
  amount: number,
  priceUsdInput: number | string | null | undefined,
  valueUsdInput: number | string | null | undefined
) {
  const priceUsd = parseOptionalNonNegative(priceUsdInput);
  const valueUsd = parseOptionalNonNegative(valueUsdInput);

  if (valueUsd !== null) {
    return {
      priceUsd: priceUsd ?? (amount > 0 ? valueUsd / amount : null),
      valueUsd
    };
  }

  if (priceUsd !== null) {
    return {
      priceUsd,
      valueUsd: amount * priceUsd
    };
  }

  throw new Error("Either price (USD) or total value (USD) is required.");
}

function parseValuationForUpdate(
  amount: number,
  priceInput: number | string | null | undefined,
  valueInput: number | string | null | undefined,
  existingPrice: number | null,
  existingValue: number
) {
  const hasPrice = priceInput !== undefined;
  const hasValue = valueInput !== undefined;

  if (!hasPrice && !hasValue) {
    if (existingPrice !== null && amount > 0) {
      return { priceUsd: existingPrice, valueUsd: amount * existingPrice };
    }
    return { priceUsd: existingPrice, valueUsd: existingValue };
  }

  return parseValuation(
    amount,
    hasPrice ? priceInput : existingPrice,
    hasValue ? valueInput : null
  );
}

function parseOptionalNonNegative(value: number | string | null | undefined) {
  if (value === undefined || value === null || value === "") return null;
  const numeric = typeof value === "string" ? Number(value) : value;
  if (!Number.isFinite(numeric)) {
    throw new Error("Numeric values must be finite.");
  }
  if (numeric < 0) {
    throw new Error("Numeric values must be non-negative.");
  }
  return numeric;
}

function parseNotes(value: string | null | undefined) {
  if (value === null || value === undefined) return null;
  const trimmed = String(value).trim();
  if (!trimmed) return null;
  if (trimmed.length > MAX_NOTES_LENGTH) {
    throw new Error(`Notes must be ${MAX_NOTES_LENGTH} characters or fewer.`);
  }
  return trimmed;
}

function parseGeneratedAt(value: string | undefined) {
  if (!value) return new Date();
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    throw new Error("generatedAt must be a valid ISO date string.");
  }
  return parsed;
}

function assertNoSecret(...values: (string | null)[]) {
  for (const value of values) {
    if (value && containsSensitiveSecret(value)) {
      throw new Error("Manual entries must not contain seed phrases, private keys, or other secrets.");
    }
  }
}
