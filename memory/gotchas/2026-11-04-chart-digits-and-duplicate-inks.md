---
title: Some theme faces and inks make chart figures ambiguous
date: 2026-11-04
status: active
tags: [gotcha, charts, themes, fonts, accessibility]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/ChartKitTheme.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasThemeCatalog.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasFonts.swift]
---

## Gotcha

- Pixelify Sans, the Pixel theme's number and display face, draws "5" like an "S":
  "$5,082" reads "$S,082" and "57%" reads "S7%" at every size. Silkscreen (its
  label face) is fine for names.
- The Riso chart palette repeats inks on purpose: Bitcoin and Cosmos are the same
  pink, Ether and USD Coin the same blue, so a legend cannot tell them apart.
- `AtlasFonts.font(...)` with a custom face uses the requested point size, but the
  system fallback ignores it and uses the text style's size, so a measured label
  can differ when the bundled fonts are missing.

## Safe practice

- Chart figures go through `chartKitNumberFont`, `chartKitFigureFont` and
  `chartKitDisplayFont`, which switch to the theme's body face when the number or
  display face is Pixelify Sans. Keep the pixel face for names. If the theme
  catalog changes the Pixel number face, delete the switch.
- Slice colours inside one chart come from `chartKitColors(for:)`, which tones the
  later of two identical colours. Do not read `chartKitRGB` per slice in a chart
  that has a legend.
- Do not measure text for a label; use `ViewThatFits` with an empty last option so
  Dynamic Type and a missing font cannot make a label clip.
