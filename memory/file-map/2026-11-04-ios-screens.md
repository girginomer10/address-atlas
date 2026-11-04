---
title: iOS screens, shell and demo fixture after the phase 3 redesign
date: 2026-11-04
status: active
tags: [file-map, ios, swiftui, redesign, themes]
related_files: [native/AddressAtlasiOS/Sources/AddressAtlasiOS/AtlasSection.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/MainShell.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/IOSTheme.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/IOSComponents.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/IOSCoinViews.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/PortfolioScreen.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/CoinDetailScreen.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/AssetsScreen.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/HistoryScreen.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/SourcesScreen.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/DemoFixture.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/PortfolioVisualizationView.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AppStateCharts.swift]
---

## Responsibility

`native/AddressAtlasiOS/Sources/AddressAtlasiOS/` holds the iOS-only screens;
the state layer, charts, theme engine and Core come from the shared Mac
sources (the Mac-only `MacScreens/` and window views are excluded in
`project.yml`).

- `AtlasSection`, `MainShell`: five sections, the themed tab bar (iPhone) or
  sidebar (iPad), one `NavigationStack` per section driven by
  `IOSNavigationModel.paths`; `IOSRouteDestination` maps `IOSRoute` to screens.
- `IOSTheme.swift`: title, card, chip, notice, empty state, tab bar, the hero
  style (`IOSHeroStyle`: the theme's pastel in Candy and Heatmap, a plain
  surface elsewhere). `IOSCoinViews.swift`: coin rows, `IOSChartCard` (frames a
  chart by proportion; ring, grid and rings-in-rings use `.compact` density so
  their legends fit a phone), `AppState.iosChartInput` (applies edited wallet
  names), `handleChartSelection`, number formatting.
- `PortfolioScreen`, `CoinDetailScreen`, `AssetsScreen`, `HistoryScreen`
  (with `SnapshotDetailScreen`), `SourcesScreen` (hosts `WalletsScreen`,
  `ExchangesScreen`, `TokensScreen(list:)`), `SettingsScreen` (hosts the
  pushed `ICloudScreen` and `ExportScreen`), `OnboardingScreen`,
  `UnlockScreen`. `HoldingViews.swift`: holding row and detail sheet.
- `DemoFixture.swift`: Debug-only synthetic vault and launch arguments (all of
  it inside `#if DEBUG`).

## Rules that are easy to break

- Charts take the space they are offered: give them a frame (`IOSChartCard`)
  and never put one in an unbounded `ScrollView` without it.
- Totals use the theme's number face; text uses `AtlasTheme.font(...)`, never
  `.font(.callout)`. Hard-edged themes draw offset shadows right and below, so
  cards need that room in their parents (no tight clipping, `iosListRow` insets).
- Coin detail defaults to grouping by state when the coin is in more than one
  state, else by network; the choice is stored per device (`coin.grouping.v1`).
- React to `AppState.noticeTone`, `iCloudStatusKind` and the `RecoveryKitRestoreOutcome`
  that `restoreRecoveryKit` returns, never to notice or status wording; an ordinary
  save posts no notice, so `IOSStatusToast` names it from the document
  (`IOSSaveSummary`). See `memory/decisions/2026-11-04-typed-state-signals.md`.
- Text with digits in the Pixel theme goes through `AtlasTheme.font(_:_:weight:figuresIn:)`
  or the `.number` role (Pixelify Sans and Silkscreen draw a five like an S).
- New files in this folder need `./native/AddressAtlasiOS/generate-project.sh`.
- A Release build must contain no demo code: after touching debug paths, run
  `strings -a "Address Atlas" | grep -E "AtlasDemo|DemoFixture"` on the Release
  binary (expect nothing).

## Coupled files

- `Charts/PortfolioVisualizationView.swift` and `AppStateCharts.swift`: the
  14 views and their `usesGrouping`, `usesHistory`, `worksForSingleCoin` rules.
- `AtlasThemeCatalog.swift`: chart and pastel colours the hero and rows read.
- `docs/design/screenshots/phase3/ios/`: the review set rendered with the demo
  fixture (see the phase 3E handoff for the launch arguments).
