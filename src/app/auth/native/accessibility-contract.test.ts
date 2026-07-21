import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const styles = readFileSync(new URL("../../globals.css", import.meta.url), "utf8");

type OKLCH = { lightness: number; chroma: number; hue: number };

function themeBlock(selector: ":root" | "dark"): string {
  const pattern = selector === ":root"
    ? /:root\s*\{([^}]*)\}/
    : /\[data-theme="dark"\]\s*\{([^}]*)\}/;
  const match = styles.match(pattern);
  if (!match?.[1]) throw new Error(`Missing ${selector} theme block.`);
  return match[1];
}

function token(block: string, name: string): OKLCH {
  const pattern = new RegExp(
    `--${name}:\\s*oklch\\((\\d+(?:\\.\\d+)?)%\\s+(\\d+(?:\\.\\d+)?)\\s+(\\d+(?:\\.\\d+)?)\\)`
  );
  const match = block.match(pattern);
  if (!match) throw new Error(`Missing literal OKLCH token --${name}.`);
  return {
    lightness: Number(match[1]) / 100,
    chroma: Number(match[2]),
    hue: Number(match[3])
  };
}

function relativeLuminance(color: OKLCH): number {
  const radians = color.hue * Math.PI / 180;
  const a = color.chroma * Math.cos(radians);
  const b = color.chroma * Math.sin(radians);
  const lPrime = color.lightness + 0.3963377774 * a + 0.2158037573 * b;
  const mPrime = color.lightness - 0.1055613458 * a - 0.0638541728 * b;
  const sPrime = color.lightness - 0.0894841775 * a - 1.291485548 * b;
  const l = lPrime ** 3;
  const m = mPrime ** 3;
  const s = sPrime ** 3;
  const clamp = (value: number) => Math.max(0, Math.min(1, value));
  const red = clamp(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s);
  const green = clamp(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s);
  const blue = clamp(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s);
  return 0.2126 * red + 0.7152 * green + 0.0722 * blue;
}

function contrastRatio(foreground: OKLCH, background: OKLCH): number {
  const foregroundLuminance = relativeLuminance(foreground);
  const backgroundLuminance = relativeLuminance(background);
  const lighter = Math.max(foregroundLuminance, backgroundLuminance);
  const darker = Math.min(foregroundLuminance, backgroundLuminance);
  return (lighter + 0.05) / (darker + 0.05);
}

describe("native passkey page accessibility tokens", () => {
  it.each([
    ["light", themeBlock(":root")],
    ["dark", themeBlock("dark")]
  ])("keeps small text and control boundaries perceivable in %s mode", (_name, block) => {
    const smallText = token(block, "ink-3");
    const controlBorder = token(block, "control-border");
    const focusRing = token(block, "focus-ring");

    for (const backgroundName of ["paper", "paper-2"]) {
      const background = token(block, backgroundName);
      expect(contrastRatio(smallText, background)).toBeGreaterThanOrEqual(4.5);
      expect(contrastRatio(controlBorder, background)).toBeGreaterThanOrEqual(3);
      expect(contrastRatio(focusRing, background)).toBeGreaterThanOrEqual(3);
    }
  });

  it("pins normal, keyboard-focus, and disabled input states", () => {
    expect(styles).toMatch(/\.aa-auth-panel input\s*\{[^}]*border:\s*1px solid var\(--control-border\)/s);
    expect(styles).toMatch(/\.aa-auth-panel input:focus-visible,[^}]*outline:\s*3px solid var\(--focus-ring\)/s);
    expect(styles).toMatch(/\.aa-auth-panel input:disabled\s*\{[^}]*border-color:\s*var\(--control-border\)[^}]*opacity:\s*1/s);
  });
});
