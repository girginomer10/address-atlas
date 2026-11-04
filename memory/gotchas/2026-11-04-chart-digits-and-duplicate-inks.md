---
title: Some theme faces and inks make chart figures ambiguous
date: 2026-11-04
status: active
tags: [gotcha, charts, themes, fonts, accessibility]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/ChartKitTheme.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/HistoryChartSupport.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasThemeCatalog.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasFonts.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Fonts/VT323/OFL.txt, docs/design/screenshots/phase3/pixel-number-font.png]
---

## Gotcha

- Pixelify Sans draws "5" like an "S": "$5,082" reads "$S,082" and "57%" reads
  "S7%" at every size. Silkscreen (the Pixel label face) is fine for names. Since
  2026-11-04 the Pixel theme's number role is VT323 (OFL, all ten digits the same
  width, covers the minus sign and dashes); Pixelify Sans stays on display text
  (names, titles). Jersey 10 was the other candidate: bolder, but its "1" is
  narrow, so columns of figures do not line up. Micro 5 reads "5" as "S" too.
  `docs/design/screenshots/phase3/pixel-number-font.png` has the comparison.
- VT323 is drawn small on its em square, so `AtlasFontFamily.opticalScale` scales
  it by 1.15.
- The Riso chart palette repeats inks on purpose: Bitcoin and Cosmos are the same
  pink, Ether and USD Coin the same blue, so a legend cannot tell them apart.
- `AtlasFonts.font(...)` with a custom face uses the requested point size, but the
  system fallback ignores it and uses the text style's size, so a measured label
  can differ when the bundled fonts are missing.

## Safe practice

- Chart figures go through `chartKitNumberFont`, `chartKitFigureFont` and
  `chartKitDisplayFont`. Where the display face is Pixelify Sans,
  `chartKitDisplayFont` and the history charts' `displayFont` use the number
  face, so big figures stay readable. The Mac screens' totals use
  `chartKitDisplayFont`. A figure set directly in the `.display` role anywhere
  else would still draw Pixelify Sans: use the `.number` role for figures and keep
  the pixel display face for names and titles.
- Slice colours inside one chart come from `chartKitColors(for:)`, which tones the
  later of two identical colours. Do not read `chartKitRGB` per slice in a chart
  that has a legend.
- Do not measure text for a label; use `ViewThatFits` with an empty last option so
  Dynamic Type and a missing font cannot make a label clip.
