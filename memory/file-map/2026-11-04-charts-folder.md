---
title: The Charts folder holds the redesign chart views and their shared ChartKit
date: 2026-11-04
status: active
tags: [file-map, charts, redesign, swiftui, ios]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/PortfolioChartContract.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/ChartKitLayout.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/ChartKitModel.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/ChartKitFormat.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/ChartKitTheme.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/ChartKitShapes.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/ChartKitComponents.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/ChartKitLabels.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/MapChartView.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/RingChartView.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/StripChartView.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/GridChartView.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/BubblesChartView.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/RingsInRingsChartView.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/ListChartView.swift, native/AddressAtlasMac/Tests/AddressAtlasMacTests/ChartKitLayoutTests.swift, native/AddressAtlasMac/Tests/AddressAtlasMacTests/ChartKitDataTests.swift, native/AddressAtlasMac/Tests/AddressAtlasMacTests/ChartKitRenderTests.swift, docs/design/screenshots/phase2]
---

## Responsibility

`Sources/AddressAtlasMac/Charts/` is shared by Mac and iOS (the iOS target
compiles the whole folder), so nothing in it may use AppKit or UIKit. Every view
is `struct <Name>: View { init(input: PortfolioChartInput) }` (the contract is in
`PortfolioChartContract.swift`); numbers come from `PortfolioAnalytics`, colours,
fonts and shape from `@Environment(\.atlasTheme)`.

Part C1 views: `MapChartView` (squarified treemap, nested by network in `.full`
density when every part can carry its name), `RingChartView`, `StripChartView`,
`GridChartView` (100-cell waffle, largest remainder), `BubblesChartView`
(deterministic circle packing), `RingsInRingsChartView` (sunburst),
`ListChartView`. Other views in the folder come from the part-C2 work.

ChartKit (all type names start with `ChartKit`, so a file-private helper in a
sibling view cannot collide with them):

- `ChartKitLayout.swift`: pure geometry (`ChartKitTreemap`, `ChartKitWaffle`,
  `ChartKitBubblePacking`, `ChartKitSunburst`, `ChartKitStrip`,
  `ChartKitLabelBudget`). No SwiftUI; unit-tested for areas, sums, overlaps and
  angles.
- `ChartKitModel.swift`: `ChartKitData` turns a `PortfolioChartInput` into
  `ChartKitSlice`s (from `PortfolioAnalytics.breakdown`), with colour key,
  selection, VoiceOver wording, folding into "Other", and the optional second
  level (`Nesting`).
- `ChartKitFormat.swift`: every number and sentence (locale from
  `AtlasFormatting.locale`, USD only today, "No priced holdings yet", the
  unpriced note).
- `ChartKitTheme.swift`: slice colours (`chartKitRGB`, `chartKitColors(for:)`),
  readable ink, fonts, `ChartKitBlockStyle` (radius, outline, hard shadow,
  overprint from the tokens, never from a theme id), `ChartKitBlock`.
- `ChartKitShapes.swift`: `ChartKitDonutSegment`, `ChartKitMark`.
- `ChartKitComponents.swift`: `ChartKitFrame` (empty state, unpriced note,
  VoiceOver summary), interaction (`chartKitTarget`, hover through
  `onContinuousHover`, tap through `onTapGesture`), `ChartKitLegend`,
  `ChartKitGraphicLayout`, `ChartKitRingCenter`.
- `ChartKitLabels.swift`: `ChartKitNameAndShare` and `ChartKitBlockLabel`, the
  text tiers drawn inside a block.

## Rules that are easy to break

- Labels are chosen by `ViewThatFits` (so Dynamic Type on iOS is measured, not
  guessed) and end in an empty view: a label is shown whole or not at all.
  `ChartKitLabelBudget` only estimates which slices need a legend entry instead.
- Within one chart no two slices share a colour: `chartKitColors(for:)` tones the
  later of two alike (Riso reuses an ink on purpose). Ring, waffle and sunburst
  legends depend on it.
- Figures use the theme's body face when the number or display face is Pixelify
  Sans (its five looks like an S); see the gotcha note on digits.
- A view must stay deterministic: no randomness, no `Date()`, no dictionary
  iteration order in layout.
- Adding a file under `Charts/` needs `./native/AddressAtlasiOS/generate-project.sh`.

## Coupled files

- `native/AddressAtlasMac/Sources/AddressAtlasCore/PortfolioAnalytics.swift`: the
  slices and their rules (priced versus unpriced, coin identity). The views must
  not recompute them.
- `native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasThemeModel.swift` and
  `AtlasThemeCatalog.swift`: tokens and chart palettes the views read.
- `native/AddressAtlasMac/Tests/AddressAtlasMacTests/ChartKitRenderTests.swift`:
  renders every view in every theme with `ImageRenderer`; with
  `ATLAS_WRITE_SCREENSHOTS=1` it writes the review set to
  `docs/design/screenshots/phase2/` (`=all` for every combination, optionally to
  `ATLAS_SCREENSHOT_DIR`).
