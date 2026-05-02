import { detectChainsForAddress } from "./chain-registry";
import { containsSensitiveSecret } from "./security";

export function detectAddressKind(address: string) {
  const chains = detectChainsForAddress(address);
  const first = chains[0];
  if (!first) return "unknown";
  if (first.family === "evm") return "evm";
  return first.family;
}

export function isSupportedPublicAddress(address: string) {
  return detectChainsForAddress(address).length > 0;
}

export function supportedPublicAddresses(addresses: string[]) {
  return addresses.filter(isSupportedPublicAddress);
}

export function unsupportedPublicAddresses(addresses: string[]) {
  return addresses.filter((address) => !isSupportedPublicAddress(address));
}

export function defaultWalletLabel(address: string) {
  const kind = detectAddressKind(address);
  if (kind === "bitcoin") return "Bitcoin wallet";
  if (kind === "evm") return "EVM wallet";
  if (kind === "cosmos") return "Cosmos wallet";
  if (kind === "solana") return "Solana wallet";
  return "Watched wallet";
}

export function assertSafePublicAddresses(addresses: string[]) {
  const unsafe = addresses.find((address) => containsSensitiveSecret(address));
  if (unsafe) {
    throw new Error("Private keys, seed phrases, and mnemonic-looking text are not accepted.");
  }
}

export function shortAddress(address: string, head = 8, tail = 6) {
  if (address.length <= head + tail + 1) return address;
  return `${address.slice(0, head)}...${address.slice(-tail)}`;
}
