import { describe, expect, it } from "vitest";
import { detectAddressKind } from "./address-utils";
import { parseAddressInput } from "./scanner";

describe("address parsing", () => {
  it("deduplicates pasted addresses and detects supported families", () => {
    const parsed = parseAddressInput([
      "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
      "0xd8da6bf26964af9d7eed9e03e53415d37aa96045",
      "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh",
      "cosmos1p8s5k7eyed68x2qplfw0e5a8svjqx39g7yr82m"
    ]);

    expect(parsed).toHaveLength(3);
    expect(detectAddressKind(parsed[0])).toBe("evm");
    expect(detectAddressKind(parsed[1])).toBe("bitcoin");
    expect(detectAddressKind(parsed[2])).toBe("cosmos");
  });
});
