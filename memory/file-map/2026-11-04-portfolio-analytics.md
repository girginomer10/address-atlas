---
title: Portfolio analytics live in AddressAtlasCore and feed every redesign view
date: 2026-11-04
status: active
tags: [file-map, analytics, redesign, core]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasCore/PortfolioAnalytics.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/PortfolioAnalyticsHistory.swift, native/AddressAtlasMac/Tests/AddressAtlasCoreTests/PortfolioAnalyticsTests.swift, native/AddressAtlasMac/Tests/AddressAtlasCoreTests/PortfolioAnalyticsHistoryTests.swift, native/AddressAtlasMac/Tests/AddressAtlasCoreTests/PortfolioAnalyticsTestSupport.swift, docs/design/views.html]
---

## Responsibility

`PortfolioAnalytics.swift` and `PortfolioAnalyticsHistory.swift` (AddressAtlasCore, so macOS and iOS share them) own every number the redesign's portfolio and coin visualizations draw. Pure `Sendable` value types over `[TrackedAsset]` and `[ScanRunRecord]`; no preferences, clock, locale, network, or vault access. The overview comment at the top of `PortfolioAnalytics.swift` is the API reference and defines coin identity, state, kind, grouping, the priced/unpriced rule, and the attribution formulas.

- `PortfolioAnalytics.breakdown(_:by:then:)`, `coinSummaries`, `coinSummary`, `flowGraph`, `concentration` work on one set of holdings; `attribution`, `rankChanges`, `runTotals`, `coinSeries`, `stackedSeries`, `dailySeries` work on scans.
- Rules that views must not reimplement: unpriced holdings (`pricingStatus != .priced`) never enter value or share math and come back separately; coin identity is the upper-cased symbol with bridged stablecoins folded (`USDC.e` to `USDC`) and wrapped assets kept apart; the dust filter is applied by the caller through `PortfolioHoldingFilter`; attribution splits a coin into price effect `old amount * (new price - old price)`, amount effect `(new amount - old amount) * new price`, and a valuation gap when a coin lost or gained its price; `sourcesDiffer` flags scans that did not read the same wallets, exchanges, and manual holdings.
- Determinism is part of the contract: sums add smallest first and every list ends in an id tie-break, so shuffled input gives identical output (a test shuffles 20 times).

## Coupled files

- `native/AddressAtlasMac/Sources/AddressAtlasMac/AppStateScanning.swift`: `scanSourceKey` and `scanRunsShareSources` are the app's own copy of the source-identity and "same sources" logic; `PortfolioAnalytics.sourceKey(for:)` and `runsShareSources(_:_:context:)` repeat it in Core (the context comes from `ScanSourceContext(document:)`). Keep the two in step, or point the app at the Core version.
- `native/AddressAtlasMac/Sources/AddressAtlasCore/Models.swift`: a new `AssetSource` case needs a `HoldingState` mapping and a `HoldingKind` case in analytics.
- `docs/design/views.html`: the visualizations the API was shaped to feed.
