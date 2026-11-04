---
title: Mac-only screens live in MacScreens and seven older view files
date: 2026-11-04
status: active
tags: [file-map, mac, swiftui, redesign]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasMac/MacScreens/MacNavigation.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/MacScreens/MacPrimitives.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/MacScreens/MacButtons.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/MacScreens/MacPortfolioModel.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/MacScreens/MacCoinList.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/MacScreens/PortfolioScreen.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/MacScreens/CoinDetailScreen.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/MacScreens/AssetsScreen.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/MacScreens/HistoryScreen.swift, native/AddressAtlasMac/Tests/AddressAtlasMacTests/MacScreenRenderTests.swift, native/AddressAtlasiOS/project.yml]
---

## Responsibility

Everything the iOS target must not compile. `project.yml` excludes
`MacScreens/` and `AddressAtlasApp.swift`, `AppShellViews.swift`,
`PortfolioViews.swift`, `PortfolioComponents.swift`, `ExchangeSyncViews.swift`,
`ICloudSyncView.swift`, `PrivacySafeDiagnosticsView.swift` from the shared
glob. Nothing in a shared file may name a type from these files.

- `MacNavigation.swift`: `MacNavigationModel` (section, open coin, Assets slice
  filter, selected snapshot, Wallets pane, pending focus actions), `MacSliceFilter`
  (the key Core gives a breakdown slice, repeated here because Core's
  `descriptor(of:in:)` is not public; a render test compares them),
  `MacScanAction` (Scan button and ⌘R share admission).
- `MacPrimitives.swift`: `MacPage`, headings, `MacFigure` (themed number face),
  `CoinMark`, chips, `MacViewSwitcher`, `MacGroupingMenu`, `MacRowButton`,
  `MacRowList`, `MacNote`, `MacEmptyState`, `MacScanButton`, `MacFormat`.
- `MacButtons.swift`: pill-safe button styles, badge and chrome (see the gotcha
  note on pill outlines).
- `MacPortfolioModel.swift`: `MacPortfolioSnapshot` (headline total, change line,
  unpriced and drift sentences, dust), `MacCoinRow` (one coin of a list).
- `PortfolioScreen.swift` (Portfolio, hero, scan warnings, selection routing),
  `CoinDetailScreen.swift`, `AssetsScreen.swift`, `HistoryScreen.swift`.
- Older files, rewritten: `PortfolioViews.swift` (Wallets, Tokens pane, edit
  sheets), `PortfolioComponents.swift` (holding rows), `ExchangeSyncViews.swift`
  (Exchanges, Export, Settings, privacy section), `ICloudSyncView.swift`
  (`SyncView`, now a Settings section), `AddressAtlasApp.swift` (app, commands,
  unlock screen), `AppShellViews.swift` (`MainView`, sidebar).

## Coupled files

- `Charts/PortfolioVisualizationView.swift`, `Charts/Coin*View.swift` and
  `AppStateCharts.swift` supply the charts and their input; screens only size them.
- `MacScreenRenderTests.swift` renders the unlocked window through
  `NSHostingView` from a synthetic vault built on `ChartFixture`.
