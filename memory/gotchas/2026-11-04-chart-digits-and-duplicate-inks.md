---
title: Some theme faces and inks make chart figures ambiguous
date: 2026-11-04
status: active
tags: [gotcha, charts, themes, fonts, accessibility]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasThemeRuntime.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/ChartKitTheme.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/HistoryChartSupport.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasThemeCatalog.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasFonts.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Fonts/VT323/OFL.txt, docs/design/screenshots/phase3/pixel-number-font.png]
---

## Gotcha

- Pixelify Sans draws "5" like an "S": "$5,082" reads "$S,082" and "57%" reads
  "S7%" at every size. Silkscreen (the Pixel label face) draws it the same way
  (found 2026-11-04 in the what-changed bar labels, "$59K" read "$S9K"), so it is
  fine for names and words but not for text with digits. Since 2026-11-04 the
  Pixel theme's number role is VT323 (OFL, all ten digits the same
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
- Text that mixes words and digits (counts, dates, axis ticks, "5 holdings") must
  not be set in the label role in Pixel. `AtlasTheme.font(_:_:weight:figuresIn:)`
  and `AtlasThemeTokens.font(...figuresIn:)` move the text to the number face when
  it has a digit and the role's family `drawsFiveLikeS` (Pixelify Sans, Silkscreen);
  the history charts use `HistoryChartStyle.captionFigureFont`, `smallFigureFont`
  and `captionFont(figuresIn:)`, ChartKit uses `chartKitLabelFont(_:weight:figuresIn:)`.
  Money and amounts are always `.number`. After adding a label with a digit, take
  the Pixel picture and look for an "S".
- Slice colours inside one chart come from `chartKitColors(for:)`, which tones the
  later of two identical colours. Do not read `chartKitRGB` per slice in a chart
  that has a legend.
- Do not measure text for a label; use `ViewThatFits` with an empty last option so
  Dynamic Type and a missing font cannot make a label clip.
