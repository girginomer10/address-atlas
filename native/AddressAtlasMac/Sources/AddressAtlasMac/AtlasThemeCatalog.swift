import SwiftUI

/// The six theme definitions. Values follow `docs/design/themes.html` and
/// `docs/design/views.html`; the variants the mockups do not draw (Chain
/// colours dark, Candy dark, Heatmap light, Pixel dark) keep each theme's
/// character: same accents and pastel blocks, re-grounded on a light or dark
/// canvas. Every palette is contrast-checked by `AtlasDesignSystemTests`.
enum AtlasThemeCatalog {
  static func definition(for id: AtlasThemeID) -> AtlasThemeDefinition {
    guard let definition = definitions[id] else {
      preconditionFailure("No definition for \(id)")
    }
    return definition
  }

  private static let definitions: [AtlasThemeID: AtlasThemeDefinition] = [
    .chainColors: chainColors,
    .candy: candy,
    .riso: riso,
    .heatmap: heatmap,
    .pixel: pixel,
    .acid: acid,
  ]

  // MARK: A. Chain colours

  private static let chainColors = AtlasThemeDefinition(
    id: .chainColors,
    light: AtlasPalette(
      canvas: 0xF6F7FB, surface: 0xFFFFFF, surfaceMuted: 0xE6EAF1,
      ink: 0x12141A, ink2: 0x3E4452, ink3: 0x5B6070,
      rule: 0xB8BFCC, ruleSoft: 0xD9DDE7, outline: 0xD9DDE7,
      controlBoundary: 0x5E6676, focusRing: 0x3B5BDB,
      accent: 0x12141A, onAccent: 0xFFFFFF,
      selection: 0xE6EAF1, onSelection: 0x12141A,
      accentSoft: 0xE8EAF2, gainSoft: 0xE3F8EA, warningSoft: 0xFFF4E0, lossSoft: 0xFDE9EA,
      gain: 0x0F7A3A, loss: 0xC0262F, warning: 0x8A5300,
      shadow: 0x12141A, onPastel: 0x12141A
    ),
    dark: AtlasPalette(
      canvas: 0x0E1014, surface: 0x161A1F, surfaceMuted: 0x212630,
      ink: 0xF2F4F8, ink2: 0xC9CED8, ink3: 0xAEB5C4,
      rule: 0x4F5766, ruleSoft: 0x2B313C, outline: 0x2B313C,
      controlBoundary: 0x757F94, focusRing: 0x6E9BFF,
      accent: 0xF4F5F9, onAccent: 0x12141A,
      selection: 0x2A303C, onSelection: 0xF2F4F8,
      accentSoft: 0x1F2330, gainSoft: 0x12301F, warningSoft: 0x3A2A10, lossSoft: 0x3A1A1E,
      gain: 0x4DD189, loss: 0xFF6E78, warning: 0xF8AB40,
      shadow: 0x000000, onPastel: 0x12141A
    ),
    shape: AtlasShape(
      radiusSmall: 10, radiusControl: 14, radiusCard: 20, radiusLarge: 24,
      cardBorderWidth: 1, controlBorderWidth: 1.5,
      cardShadowOffset: nil, controlShadowOffset: nil,
      usesSoftShadow: true, pillControls: true, cardFill: .plain, canvasGradient: true
    ),
    typography: AtlasTypography(
      display: AtlasFontSpec(family: .plusJakartaSans, weight: .heavy, tracking: -0.03),
      number: AtlasFontSpec(family: .plusJakartaSans, weight: .bold, tracking: -0.01),
      body: AtlasFontSpec(family: .plusJakartaSans, weight: .medium),
      label: AtlasFontSpec(family: .plusJakartaSans, weight: .semibold),
      mono: AtlasFontSpec(family: .geistMono, weight: .regular)
    ),
    lightChart: chainColorsChart(dark: false),
    darkChart: chainColorsChart(dark: true)
  )

  private static func chainColorsChart(dark: Bool) -> AtlasChartPalette {
    // A few brand colours are near-black and vanish on a dark canvas.
    let atom: AtlasRGB = dark ? 0x8E94C4 : 0x2E3148
    let xrp: AtlasRGB = dark ? 0xA0A8B8 : 0x23292F
    let ada: AtlasRGB = dark ? 0x5C86E8 : 0x0033AD
    let osmo: AtlasRGB = dark ? 0x9B4FE0 : 0x750BBB
    return AtlasChartPalette(
      assets: [
        "BTC": 0xF7931A, "ETH": 0x627EEA, "SOL": 0x9945FF, "ATOM": atom, "USDC": 0x2775CA,
        "USDT": 0x26A17B, "DAI": 0xF5AC37, "BNB": 0xF3BA2F, "XRP": xrp, "TRX": 0xEB0029,
        "POL": 0x8247E5, "AVAX": 0xE84142, "LINK": 0x2A5ADA, "ARB": 0x28A0F0, "OP": 0xFF0420,
        "DOGE": 0xC2A633, "ADA": ada, "DOT": 0xE6007A, "UNI": 0xFF007A, "AAVE": 0xB6509E,
        "OSMO": osmo, "TIA": 0x7B2BF9, "LDO": 0x00A3FF, "SHIB": 0xFFA409, "PYUSD": 0x0070E0,
      ],
      networks: [
        "bitcoin": 0xF7931A, "ethereum": 0x627EEA, "base": 0x0052FF, "solana": 0x9945FF,
        "tron": 0xEB0029, "xrp": xrp, "xrpledger": xrp, "arbitrum": 0x28A0F0,
        "arbitrumone": 0x28A0F0, "optimism": 0xFF0420, "polygon": 0x8247E5,
        "polygonpos": 0x8247E5, "bsc": 0xF3BA2F, "bnbchain": 0xF3BA2F, "avalanche": 0xE84142,
        "avalanchecchain": 0xE84142, "gnosis": 0x3E6957, "linea": 0x61DFFF, "mantle": 0x65B3AE,
        "scroll": 0xEBC28E, "zksyncera": 0x8C8DFC, "cosmoshub": atom, "cosmos": atom,
        "osmosis": osmo, "celestia": 0x7B2BF9, "stride": 0xE91E63, "kraken": 0x5741D9,
      ],
      categorical: [
        0x627EEA, 0xF7931A, 0x9945FF, 0x2FB67C, 0xE8589C, 0x28A0F0, 0xF3BA2F, 0xE84142,
        0x00A3FF, 0x8A90A2,
      ],
      states: [
        .liquid: 0x2FB67C, .staked: 0x4C7DF0, .unbonding: 0xF5A623, .rewards: 0xE8589C,
        .onExchange: 0x8E7CF0,
      ],
      kinds: [
        .native: 0xF7931A, .stablecoin: 0x2775CA, .token: 0x9945FF, .exchange: 0x26A17B,
        .manual: 0x8A90A2,
      ],
      pastels: [],
      blendsWithMultiply: false
    )
  }

  // MARK: B. Candy brutal

  private static let candy = AtlasThemeDefinition(
    id: .candy,
    light: AtlasPalette(
      canvas: 0xFFF7EA, surface: 0xFFFFFF, surfaceMuted: 0xFBEBD2,
      ink: 0x111111, ink2: 0x2B2B2B, ink3: 0x4F4F4F,
      rule: 0x111111, ruleSoft: 0xD8C9AE, outline: 0x111111,
      controlBoundary: 0x111111, focusRing: 0x4B2FE0,
      accent: 0x111111, onAccent: 0xFFFFFF,
      selection: 0xC6F432, onSelection: 0x111111,
      accentSoft: 0xFFD1E8, gainSoft: 0xD5F5C4, warningSoft: 0xFFD27A, lossSoft: 0xFFC9C9,
      gain: 0x0A6B35, loss: 0xB3141E, warning: 0x8A4B00,
      shadow: 0x111111, onPastel: 0x111111
    ),
    dark: AtlasPalette(
      canvas: 0x14110E, surface: 0x1F1B17, surfaceMuted: 0x2A2520,
      ink: 0xFFF7EA, ink2: 0xE8DFCF, ink3: 0xC4B9A6,
      rule: 0x5A5047, ruleSoft: 0x3A332C, outline: 0xFFF7EA,
      controlBoundary: 0xFFF7EA, focusRing: 0x8FD3FF,
      accent: 0xC6F432, onAccent: 0x111111,
      selection: 0xFF9ECF, onSelection: 0x111111,
      accentSoft: 0x2D3A12, gainSoft: 0x14301F, warningSoft: 0x3A2C0E, lossSoft: 0x3D1B1B,
      gain: 0x7BE0A0, loss: 0xFF8A8A, warning: 0xFFC857,
      shadow: 0xFF9ECF, onPastel: 0x111111
    ),
    shape: AtlasShape(
      radiusSmall: 10, radiusControl: 12, radiusCard: 18, radiusLarge: 24,
      cardBorderWidth: 2.5, controlBorderWidth: 2.5,
      cardShadowOffset: CGSize(width: 5, height: 5),
      controlShadowOffset: CGSize(width: 3, height: 3),
      usesSoftShadow: false, pillControls: false, cardFill: .pastel, canvasGradient: false
    ),
    typography: AtlasTypography(
      display: AtlasFontSpec(family: .bricolageGrotesque, weight: .heavy, tracking: -0.04),
      number: AtlasFontSpec(family: .bricolageGrotesque, weight: .heavy, tracking: -0.02),
      body: AtlasFontSpec(family: .bricolageGrotesque, weight: .medium),
      label: AtlasFontSpec(family: .bricolageGrotesque, weight: .semibold),
      mono: AtlasFontSpec(family: .spaceMono, weight: .regular)
    ),
    lightChart: candyChart,
    darkChart: candyChart
  )

  private static let candyChart = AtlasChartPalette(
    assets: [
      "BTC": 0xFFD27A, "ETH": 0xC9D2FF, "SOL": 0xE3C8FF, "ATOM": 0xD5F5C4, "USDC": 0xBFE6FF,
      "USDT": 0xB5F0D2, "DAI": 0xFFE9A0, "BNB": 0xFFEA70, "XRP": 0xE0E0E0, "TRX": 0xFFB3B3,
      "POL": 0xD9C6FF, "AVAX": 0xFFB8B8, "LINK": 0xB8CCFF, "ARB": 0xA8DCFF, "OP": 0xFFB0B0,
    ],
    networks: [
      "bitcoin": 0xFFD27A, "ethereum": 0xC9D2FF, "base": 0x9BB4FF, "solana": 0xE3C8FF,
      "cosmoshub": 0xD5F5C4, "cosmos": 0xD5F5C4, "kraken": 0xC9B8FF,
    ],
    categorical: [
      0xFF9ECF, 0xC6F432, 0x8FD3FF, 0xFFD27A, 0xC9B8FF, 0x8FE3A8, 0xFFB38A, 0xF59BF0,
      0x9BE8E0, 0xFFEA70,
    ],
    states: [
      .liquid: 0x8FE3A8, .staked: 0x8FD3FF, .unbonding: 0xFFD27A, .rewards: 0xFF9ECF,
      .onExchange: 0xC9B8FF,
    ],
    kinds: [
      .native: 0xFFD27A, .stablecoin: 0x8FD3FF, .token: 0xE3C8FF, .exchange: 0xC6F432,
      .manual: 0xFFB38A,
    ],
    pastels: [0xFF9ECF, 0xC6F432, 0x8FD3FF, 0xFFD27A],
    blendsWithMultiply: false
  )

  // MARK: C. Riso zine (light only)

  private static let riso = AtlasThemeDefinition(
    id: .riso,
    light: AtlasPalette(
      canvas: 0xF3EDE2, surface: 0xFBF7EE, surfaceMuted: 0xE9E1D2,
      ink: 0x1B2A6B, ink2: 0x33417F, ink3: 0x4B5790,
      rule: 0x1B2A6B, ruleSoft: 0xBDB9C4, outline: 0x1B2A6B,
      controlBoundary: 0x1B2A6B, focusRing: 0x00589E,
      accent: 0x00589E, onAccent: 0xFFFFFF,
      selection: 0xFF4FA3, onSelection: 0x15205C,
      accentSoft: 0xD6E7F5, gainSoft: 0xD4EEDD, warningSoft: 0xFFF2A8, lossSoft: 0xFFD3E6,
      gain: 0x00693E, loss: 0xB0125A, warning: 0x8A4B00,
      shadow: 0x1B2A6B, onPastel: 0x15205C
    ),
    dark: nil,
    shape: AtlasShape(
      radiusSmall: 3, radiusControl: 4, radiusCard: 6, radiusLarge: 8,
      cardBorderWidth: 1.5, controlBorderWidth: 1.5,
      cardShadowOffset: nil, controlShadowOffset: nil,
      usesSoftShadow: false, pillControls: false, cardFill: .plain, canvasGradient: false
    ),
    typography: AtlasTypography(
      display: AtlasFontSpec(family: .spaceGrotesk, weight: .bold, tracking: -0.03),
      number: AtlasFontSpec(family: .spaceGrotesk, weight: .bold, tracking: -0.01),
      body: AtlasFontSpec(family: .spaceGrotesk, weight: .regular),
      label: AtlasFontSpec(family: .spaceMono, weight: .regular),
      mono: AtlasFontSpec(family: .spaceMono, weight: .regular)
    ),
    lightChart: risoChart,
    darkChart: risoChart
  )

  private static let risoChart = AtlasChartPalette(
    assets: [
      "BTC": 0xFF4FA3, "ETH": 0x0078BF, "SOL": 0xFFE800, "ATOM": 0xFF4FA3, "USDC": 0x0078BF,
      "USDT": 0x00A95C, "DAI": 0xFF6C2F, "BNB": 0xFFE800, "XRP": 0x765BA7, "TRX": 0xFF6C2F,
      "POL": 0x765BA7, "AVAX": 0xFF4FA3, "LINK": 0x0078BF, "ARB": 0x00838A, "OP": 0xFF6C2F,
    ],
    networks: [
      "bitcoin": 0xFF4FA3, "ethereum": 0x0078BF, "base": 0x00838A, "solana": 0xFFE800,
      "cosmoshub": 0xFF4FA3, "cosmos": 0xFF4FA3, "kraken": 0x765BA7,
    ],
    categorical: [
      0xFF4FA3, 0x0078BF, 0xFFE800, 0xFF6C2F, 0x00A95C, 0x765BA7, 0x00838A, 0x82D8D5,
      0xB0125A,
    ],
    states: [
      .liquid: 0x00A95C, .staked: 0x0078BF, .unbonding: 0xFFE800, .rewards: 0xFF4FA3,
      .onExchange: 0x765BA7,
    ],
    kinds: [
      .native: 0xFF4FA3, .stablecoin: 0x0078BF, .token: 0xFFE800, .exchange: 0x765BA7,
      .manual: 0xFF6C2F,
    ],
    pastels: [0xFF4FA3, 0x0078BF, 0xFFE800],
    blendsWithMultiply: true
  )

  // MARK: D. Heatmap

  private static let heatmap = AtlasThemeDefinition(
    id: .heatmap,
    light: AtlasPalette(
      canvas: 0xF4F5F8, surface: 0xFFFFFF, surfaceMuted: 0xE7E9EF,
      ink: 0x0D0E12, ink2: 0x3B3F4B, ink3: 0x5A6070,
      rule: 0xC9CCD6, ruleSoft: 0xE0E2E9, outline: 0xE0E2E9,
      controlBoundary: 0x6A7084, focusRing: 0x3D54D6,
      accent: 0x0D0E12, onAccent: 0xFFFFFF,
      selection: 0xE7E9EF, onSelection: 0x0D0E12,
      accentSoft: 0xE3E6F5, gainSoft: 0xDDF3E6, warningSoft: 0xFFF0D1, lossSoft: 0xFBE1E1,
      gain: 0x0E7A3E, loss: 0xC22A2A, warning: 0x8A5A00,
      shadow: 0x0D0E12, onPastel: 0x111111
    ),
    dark: AtlasPalette(
      canvas: 0x0D0E12, surface: 0x15171D, surfaceMuted: 0x1B1D24,
      ink: 0xEEF0F6, ink2: 0xB6BAC6, ink3: 0x8B90A0,
      rule: 0x3A3E4A, ruleSoft: 0x23262F, outline: 0x23262F,
      controlBoundary: 0x6B7184, focusRing: 0x8FA2FF,
      accent: 0xEEF0F6, onAccent: 0x0D0E12,
      selection: 0x262A35, onSelection: 0xFFFFFF,
      accentSoft: 0x1D2030, gainSoft: 0x14281D, warningSoft: 0x2E2410, lossSoft: 0x341A1C,
      gain: 0x4ADE80, loss: 0xFF6B6B, warning: 0xFFCC66,
      shadow: 0x000000, onPastel: 0x111111
    ),
    shape: AtlasShape(
      radiusSmall: 8, radiusControl: 10, radiusCard: 16, radiusLarge: 20,
      cardBorderWidth: 1, controlBorderWidth: 1.5,
      cardShadowOffset: nil, controlShadowOffset: nil,
      usesSoftShadow: false, pillControls: true, cardFill: .plain, canvasGradient: false
    ),
    typography: AtlasTypography(
      display: AtlasFontSpec(family: .geist, weight: .semibold, tracking: -0.02),
      number: AtlasFontSpec(family: .geist, weight: .medium, tracking: -0.01),
      body: AtlasFontSpec(family: .geist, weight: .regular),
      label: AtlasFontSpec(family: .geist, weight: .medium),
      mono: AtlasFontSpec(family: .geistMono, weight: .regular)
    ),
    lightChart: heatmapChart,
    darkChart: heatmapChart
  )

  /// Pastel blocks from `views.html`; they carry dark ink in both appearances.
  private static let heatmapChart = AtlasChartPalette(
    assets: [
      "BTC": 0xFFAB4A, "ETH": 0x8FA2FF, "SOL": 0xC49BFF, "ATOM": 0x7EE0B5, "USDC": 0x7CC4FF,
      "USDT": 0x7EE0B5, "DAI": 0xFFCC66, "BNB": 0xFFCC66, "XRP": 0xB6BAC6, "TRX": 0xFF9E9E,
      "POL": 0xB9A6FF, "AVAX": 0xFF9E9E, "LINK": 0x8FA2FF, "ARB": 0x7CC4FF, "OP": 0xFF9E9E,
    ],
    networks: [
      "bitcoin": 0xFFAB4A, "ethereum": 0x8FA2FF, "base": 0x5B7CFF, "solana": 0xC49BFF,
      "cosmoshub": 0x7EE0B5, "cosmos": 0x7EE0B5, "kraken": 0xB9A6FF,
    ],
    categorical: [
      0xFFAB4A, 0x8FA2FF, 0xC49BFF, 0x7EE0B5, 0x7CC4FF, 0xF28CC0, 0xFFCC66, 0x8FD3A8,
      0xB9A6FF, 0x5B7CFF,
    ],
    states: [
      .liquid: 0x8FD3A8, .staked: 0x5AA9FF, .unbonding: 0xFFCC66, .rewards: 0xFF9ECF,
      .onExchange: 0xB9A6FF,
    ],
    kinds: [
      .native: 0xFFAB4A, .stablecoin: 0x7CC4FF, .token: 0xC49BFF, .exchange: 0xF28CC0,
      .manual: 0x8B90A0,
    ],
    pastels: [0xFFAB4A, 0x8FA2FF, 0xC49BFF, 0x7EE0B5, 0x7CC4FF],
    blendsWithMultiply: false
  )

  // MARK: E. Pixel

  private static let pixel = AtlasThemeDefinition(
    id: .pixel,
    light: AtlasPalette(
      canvas: 0xFDFCF6, surface: 0xFFFFFF, surfaceMuted: 0xF1EEDD,
      ink: 0x1A1A1A, ink2: 0x333333, ink3: 0x4D4D4D,
      rule: 0x1A1A1A, ruleSoft: 0xCFCAB3, outline: 0x1A1A1A,
      controlBoundary: 0x1A1A1A, focusRing: 0x2F4DF0,
      accent: 0x2F4DF0, onAccent: 0xFFFFFF,
      selection: 0x3B5BFF, onSelection: 0xFFFFFF,
      accentSoft: 0xD8DEFF, gainSoft: 0xC8F3DE, warningSoft: 0xFFE9A8, lossSoft: 0xFFC9D8,
      gain: 0x0A6B35, loss: 0xB3141E, warning: 0x8A4B00,
      shadow: 0x1A1A1A, onPastel: 0x1A1A1A
    ),
    dark: AtlasPalette(
      canvas: 0x15141B, surface: 0x1F1E27, surfaceMuted: 0x2A2933,
      ink: 0xF5F3E8, ink2: 0xD6D3C4, ink3: 0xB2AE9C,
      rule: 0xF5F3E8, ruleSoft: 0x3A3846, outline: 0xF5F3E8,
      controlBoundary: 0xF5F3E8, focusRing: 0x7FE7FF,
      accent: 0xFFD23F, onAccent: 0x1A1A1A,
      selection: 0x3B5BFF, onSelection: 0xFFFFFF,
      accentSoft: 0x2B2A12, gainSoft: 0x12301F, warningSoft: 0x3A2A10, lossSoft: 0x3D1B24,
      gain: 0x4BE08F, loss: 0xFF7A8A, warning: 0xFFB84D,
      shadow: 0x3B5BFF, onPastel: 0x1A1A1A
    ),
    shape: AtlasShape(
      radiusSmall: 0, radiusControl: 0, radiusCard: 0, radiusLarge: 0,
      cardBorderWidth: 3, controlBorderWidth: 3,
      cardShadowOffset: CGSize(width: 6, height: 6),
      controlShadowOffset: CGSize(width: 4, height: 4),
      usesSoftShadow: false, pillControls: false, cardFill: .pastel, canvasGradient: false
    ),
    typography: AtlasTypography(
      display: AtlasFontSpec(family: .pixelifySans, weight: .semibold),
      number: AtlasFontSpec(family: .vt323, weight: .regular),
      body: AtlasFontSpec(family: .geist, weight: .regular),
      label: AtlasFontSpec(family: .silkscreen, weight: .regular),
      mono: AtlasFontSpec(family: .geistMono, weight: .regular)
    ),
    lightChart: pixelChart,
    darkChart: pixelChart
  )

  private static let pixelChart = AtlasChartPalette(
    assets: [
      "BTC": 0xFF9A1F, "ETH": 0x3B5BFF, "SOL": 0xA259FF, "ATOM": 0x19C37D, "USDC": 0x38B6FF,
      "USDT": 0x19C37D, "DAI": 0xFFD23F, "BNB": 0xFFD23F, "XRP": 0x38B6FF, "TRX": 0xFF5D8F,
      "POL": 0xA259FF, "AVAX": 0xFF5D8F, "LINK": 0x3B5BFF, "ARB": 0x38B6FF, "OP": 0xFF5D8F,
    ],
    networks: [
      "bitcoin": 0xFF9A1F, "ethereum": 0x3B5BFF, "base": 0x38B6FF, "solana": 0xA259FF,
      "cosmoshub": 0x19C37D, "cosmos": 0x19C37D, "kraken": 0xFF5D8F,
    ],
    categorical: [
      0xFF9A1F, 0x3B5BFF, 0xA259FF, 0x19C37D, 0x38B6FF, 0xFFD23F, 0xFF5D8F, 0x8BD450,
      0x00BFA6,
    ],
    states: [
      .liquid: 0x19C37D, .staked: 0x3B5BFF, .unbonding: 0xFFD23F, .rewards: 0xFF5D8F,
      .onExchange: 0xA259FF,
    ],
    kinds: [
      .native: 0xFF9A1F, .stablecoin: 0x38B6FF, .token: 0xA259FF, .exchange: 0xFF5D8F,
      .manual: 0xFFD23F,
    ],
    pastels: [0xFFD23F, 0xFF5D8F, 0x38B6FF, 0x19C37D],
    blendsWithMultiply: false
  )

  // MARK: F. Acid (dark only)

  private static let acid = AtlasThemeDefinition(
    id: .acid,
    light: nil,
    dark: AtlasPalette(
      canvas: 0x0A0B0A, surface: 0x121412, surfaceMuted: 0x1A1D1A,
      ink: 0xE8EBE6, ink2: 0xB8BEB3, ink3: 0x8F968C,
      rule: 0x2A2E2A, ruleSoft: 0x1C1F1C, outline: 0x2A2E2A,
      controlBoundary: 0x6C7269, focusRing: 0xC8FF4D,
      accent: 0xC8FF4D, onAccent: 0x0A0B0A,
      selection: 0xC8FF4D, onSelection: 0x0A0B0A,
      accentSoft: 0x1E2A0B, gainSoft: 0x1B2A0B, warningSoft: 0x2E2410, lossSoft: 0x341A1C,
      gain: 0xC8FF4D, loss: 0xFF6B6B, warning: 0xFFC24D,
      shadow: 0x000000, onPastel: 0x0A0B0A
    ),
    shape: AtlasShape(
      radiusSmall: 4, radiusControl: 6, radiusCard: 8, radiusLarge: 10,
      cardBorderWidth: 1, controlBorderWidth: 1.5,
      cardShadowOffset: nil, controlShadowOffset: nil,
      usesSoftShadow: false, pillControls: false, cardFill: .plain, canvasGradient: false
    ),
    typography: AtlasTypography(
      display: AtlasFontSpec(family: .geistMono, weight: .medium, tracking: -0.03),
      number: AtlasFontSpec(family: .geistMono, weight: .medium),
      body: AtlasFontSpec(family: .geist, weight: .regular),
      label: AtlasFontSpec(family: .geistMono, weight: .regular),
      mono: AtlasFontSpec(family: .geistMono, weight: .regular)
    ),
    lightChart: acidChart,
    darkChart: acidChart
  )

  /// Lime leads every series; the real chain colours stay on token marks.
  private static let acidChart = AtlasChartPalette(
    assets: [
      "BTC": 0xF7931A, "ETH": 0x627EEA, "SOL": 0x9945FF, "ATOM": 0x8E94C4, "USDC": 0x2775CA,
      "USDT": 0x26A17B, "DAI": 0xF5AC37, "BNB": 0xF3BA2F, "XRP": 0xA0A8B8, "TRX": 0xEB0029,
      "POL": 0x8247E5, "AVAX": 0xE84142, "LINK": 0x2A5ADA, "ARB": 0x28A0F0, "OP": 0xFF0420,
    ],
    networks: [
      "bitcoin": 0xF7931A, "ethereum": 0x627EEA, "base": 0x0052FF, "solana": 0x9945FF,
      "cosmoshub": 0x8E94C4, "cosmos": 0x8E94C4, "kraken": 0x5741D9,
    ],
    categorical: [
      0xC8FF4D, 0xE8EBE6, 0x8FB83A, 0x8F968C, 0x5C7A24, 0xB8BEB3, 0x6C7269, 0xA8E02A,
    ],
    states: [
      .liquid: 0xC8FF4D, .staked: 0xE8EBE6, .unbonding: 0x8F968C, .rewards: 0x8FB83A,
      .onExchange: 0x5C7A24,
    ],
    kinds: [
      .native: 0xC8FF4D, .stablecoin: 0xE8EBE6, .token: 0x8FB83A, .exchange: 0x8F968C,
      .manual: 0x5C7A24,
    ],
    pastels: [],
    blendsWithMultiply: false
  )
}
