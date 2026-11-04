---
title: The Mac app has seven sections and a coin detail screen, all drawn from theme tokens
date: 2026-11-04
status: active
tags: [decision, native, mac, swiftui, navigation, redesign, themes, copy]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasMac/AppShellViews.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AddressAtlasApp.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/MacScreens/MacNavigation.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/MacScreens/PortfolioScreen.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/MacScreens/CoinDetailScreen.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/MacScreens/AssetsScreen.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/MacScreens/HistoryScreen.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/PortfolioViews.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/ExchangeSyncViews.swift, native/AddressAtlasiOS/project.yml, docs/design/screenshots/phase3/mac]
---

## Context

Phase 3 of the November 2026 redesign rebuilt the Mac screens on the theme
engine and the chart views. The old shell had nine sections (Portfolio, Wallets,
Assets, Tokens, Snapshots, Exchanges, iCloud, Export, Settings), eyebrow labels,
a subtitle under every title, a "Private by design" sidebar card and marketing
copy on the unlock screen.

## Decision

- Navigation: Portfolio, Assets, History, Wallets, Exchanges, Export, Settings
  (`MainView.Section`, in that order, ⌘1 to ⌘7). Custom tokens and manual
  holdings are the "Tokens" pane of Wallets (`MacWalletsPane`); iCloud is a
  section of Settings (`SyncView`); Snapshots became History (an over-time chart
  plus the snapshot list, and a snapshot's holdings when one is picked).
- Coin detail is not a section. `MacNavigationModel.openCoin(_:)` shows it on top
  of the current section, keeps that section selected, and `closeCoin()` (Esc, or
  the back button) returns. `MacNavigationModel` is the one place that knows where
  the window is; the sidebar, the screens and the menu commands (`AtlasCommands`:
  ⌘N add wallet, ⌘F find asset, ⌘R scan, ⌘1 to ⌘7) all drive it. Commands that
  need a screen ready (focus the address field or the search field) leave a
  `PendingAction` that the screen consumes when it appears.
- Chart selections route through `MacNavigationModel.handle(_:)`: `.coin` opens
  the coin, `.slice` limits Assets (`MacSliceFilter`), `.run` opens that snapshot
  in History. On a coin detail screen a `.slice` limits that coin's holdings
  rows instead.
- Portfolio: total in the theme display face, change since the previous scan only
  when `PortfolioAnalytics.runsShareSources` says both scans read the same sources
  (and nothing was removed since), otherwise "Sources changed since the last
  scan"; a view switcher over all 14 `PortfolioVisualization` cases (six chips and
  a "More" menu, persisted in `AtlasDisplayPreferences`), "Group by" only for the
  views whose `usesGrouping` is true; the chart; the eight largest coins. A
  holding without a price is explained in one sentence under the total
  ("MEME on Ethereum has no price, so it's left out of the total.").
- The headline total counts every priced holding of a source that is still saved;
  hiding small balances only changes lists and charts, never the total.
- Copy: no eyebrows, no page subtitles, buttons verb-first in one to three words,
  empty states invite ("Add a wallet address or an exchange to see what you
  hold."), and each privacy fact is stated once, in Settings > Privacy (what stays
  on the Mac, what goes to providers, what is never asked for). The one place that
  keeps its own line is where the fact matters: "Keys are encrypted on this Mac
  before they're saved." next to the exchange key fields.
- Mac-only view files live in `Sources/AddressAtlasMac/MacScreens/` and
  `project.yml` excludes that folder (and the seven older Mac-only files) from the
  iOS target. Adding a Mac-only file under `MacScreens/` needs no project change.
- Safety behaviours are unchanged: confirmations before removing a wallet, token,
  holding, connection or snapshot and before restoring or deleting iCloud data,
  provider permission guidance and read-only checks on exchange keys, the
  disclosure that guards the full identifying exports, vault edit gating
  (`vaultEditsDisabled`), recovery kit export and restore, damaged-vault recovery.

## Supersedes

The Mac parts of `2026-07-21-native-product-design-system.md` that describe the
old shell: nine numbered sections, the sidebar privacy card, the status-and-guide
layout of Exchanges. Its rules (saved items before creation forms, Reduce Motion,
minimum widths, synthetic fixtures) still apply. The note in
`2026-11-04-theme-engine.md` that screens still use system fonts is done for the
Mac; the iOS screens are a separate piece of work.

## Consequences

- A new Mac screen is a `MacPage` (title, optional trailing control, pinned status
  line, scroll area) with `Surface` cards, `MacRowList` rows, and the `Mac*` button
  and chip styles; colours, fonts and shape come from `AtlasTheme` and
  `@Environment(\.atlasTheme)`, never from literals.
- Screens that navigate need `MacNavigationModel` and `AtlasDisplayPreferences` as
  environment objects (`MainView` supplies both). `SettingsView` needs neither
  navigation nor the model, because the macOS Settings scene hosts it too.
- Review pictures come from `MacScreenRenderTests` (`ATLAS_WRITE_SCREENSHOTS=1` for
  the committed set in `docs/design/screenshots/phase3/mac/`, `=all` for every
  screen in every theme and at the 900-point minimum width).
