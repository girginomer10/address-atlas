---
title: History chart views and coin widgets draw with Canvas from pure models
date: 2026-11-04
status: active
tags: [file-map, redesign, charts, swiftui, accessibility, ios]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/PortfolioChartContract.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/HistoryChartSupport.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/FlowChartView.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/SankeyLayoutEngine.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/AtlasMapChartView.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/PowerDiagramTreemap.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/OverTimeChartView.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/WhatChangedChartView.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/SlopeChartView.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/ConcentrationChartView.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/CalendarChartView.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/CalendarHeatmapModel.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/CoinStateStripView.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/CoinUnlockTimelineView.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/CoinAmountHistoryView.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/CoinChangeView.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/CoinCustodyView.swift, native/AddressAtlasMac/Tests/AddressAtlasMacTests/ChartRenderTests.swift, native/AddressAtlasMac/Tests/AddressAtlasMacTests/ChartTestFixture.swift, docs/design/screenshots/phase2]
---

## Responsibility

Seven portfolio history views and five coin widgets, all `init(input: PortfolioChartInput)` (see `PortfolioChartContract.swift`), compiled for macOS and iOS from `Sources/AddressAtlasMac/Charts/`:

- Portfolio: `FlowChartView`, `OverTimeChartView`, `WhatChangedChartView`, `AtlasMapChartView`, `SlopeChartView`, `ConcentrationChartView`, `CalendarChartView`.
- Coin (take `input.coinKey`, else the largest coin in `input.holdings`): `CoinStateStripView`, `CoinUnlockTimelineView(input:now:)`, `CoinAmountHistoryView`, `CoinChangeView`, `CoinCustodyView`. State strip, timeline and custody also have `init(summary: CoinSummary, ...)`.

Pattern every file follows: a pure model (`*Model.swift`, or an engine such as `SankeyLayoutEngine`, `PowerDiagramTreemap`, `CalendarHeatmapModel`) does the numbers and the words and is unit-tested; the view draws it in a `Canvas` with text measured by `GraphicsContext.historyMeasure/historyFit` (so labels adapt to theme fonts and Dynamic Type and never overlap), reads colours and fonts only from `@Environment(\.atlasTheme)` through `HistoryChartStyle`, and gets hover (Mac) and tap (iOS) from `historyPointer`. Tooltips are drawn inside the canvas (`HistoryTooltip`). VoiceOver: `historyAccessibility(label:)` summary on the container plus one `accessibilityChildren` element per bar, node, cell, row or day, each with a plain-language label and, where selectable, a button action. Charts have no animation, so Reduce Motion needs nothing.

Rules the views share (do not change one without the others):

- Comparability. Any view that subtracts one scan from another first asks `PortfolioAnalytics.runsShareSources`. What changed compares only the latest two scans and says "Your sources changed since the last scan, so this compares different things." Over time and coin amount history cut the chart and draw a dashed rule where sources differ; the calendar hatches such a day and leaves it uncoloured; the slope names the earlier scan as the oldest comparable one from the last 30 days and warns when it cannot.
- Empty is not zero. Calendar days without a scan are outlined, never coloured; fewer than seven scan days gives "Scan on more days to fill the calendar."; unpriced holdings are mentioned, never valued.
- Selection mapping to `PortfolioChartSelection`: coin bars, nodes and rows give `.coin(key)`; wallets and states give `.slice(grouping:key:)`; scans and days give `.run(id)`; "Other" folds are never selectable.
- The calendar builds its own days (`CivilDate`, `CivilDay`) because `CalendarDay` has no public initializer; day arithmetic uses no `Calendar`, so a 23-hour or 25-hour day is one day.
- `HistoryChartSupport.swift` holds the shared pieces (formatting, style, text, tooltip, pointer, layout cache, legend, effects bar, axis math). Every type in these files carries a view-specific or `History` prefix so another chart layer can coexist.

## Coupled files

- `ChartRenderTests.swift` renders every view in all six themes (light and dark where supported) at 640x400 and 320x200 from `ChartTestFixture.swift` (38 synthetic scans over 42 days: a source change on day 20, an unstake on day 27, a coin sold and a coin bought, price moves). A default run renders a small matrix as a smoke test; `ATLAS_WRITE_SCREENSHOTS=1` writes the whole matrix to `docs/design/screenshots/phase2/` (override with `ATLAS_SCREENSHOT_DIR`, limit with `ATLAS_SCREENSHOT_VIEWS=flow,slope`). Changing the fixture changes what the tests assert (calendar skipped days, rank moves, run counts).
- `native/AddressAtlasiOS/AddressAtlasiOS.xcodeproj`: a new file under `Charts/` needs `./native/AddressAtlasiOS/generate-project.sh`.
- `PortfolioAnalytics*.swift` (Core): views must not recompute attribution, ranks, concentration, series or flow; gaps found while building are listed in `docs/handoff/2026-11-04-redesign-phase2c-history-views.md`.
