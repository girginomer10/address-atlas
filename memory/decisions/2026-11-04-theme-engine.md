---
title: Six selectable themes run on one shared token engine
date: 2026-11-04
status: active
tags: [decision, native, swiftui, design-system, themes, fonts, accessibility]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasThemeModel.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasThemeCatalog.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasThemeRuntime.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasDisplayPreferences.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasFonts.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasThemePicker.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasDesignSystem.swift, native/AddressAtlasMac/Tests/AddressAtlasMacTests/AtlasThemeTests.swift, native/AddressAtlasMac/build-mac-app.sh, native/AddressAtlasiOS/project.yml, docs/design/themes.html]
---

## Context

The November 2026 redesign (`docs/design/`) replaced the single restrained
palette with six user-selectable themes: Chain colours, Candy brutal, Riso zine,
Heatmap, Pixel and Acid. Phase 1 is the engine and its plumbing; screens are
redesigned later.

## Decision

- One engine for both platforms, in the shared Mac sources that the iOS target
  compiles. `AtlasThemeID` (persisted raw strings), per-theme `AtlasPalette`
  (light and dark; HC variants are derived by `AtlasPalette.highContrast`),
  `AtlasShape`, `AtlasTypography`, `AtlasChartPalette`. Data lives in
  `AtlasThemeCatalog.swift`; riso is light only, acid dark only (their single
  palette answers every appearance, and `forcedColorScheme` forces the window).
- The old static API (`AtlasTheme.paper/ink/accent/...`, `AtlasRadius`) is kept
  but now resolves from the selected theme. `AtlasThemeRuntime` is a hand-made
  `Observable` (lock-protected), so any `body` that reads a token re-renders on
  a theme change: no relaunch, no `.id` rebuild, view state survives. New views
  read `@Environment(\.atlasTheme)` (`AtlasThemeTokens`) for palette, chart
  colours, shape and fonts.
- `accent` is also used as text and icon colour, so every theme's accent meets
  4.5:1 on canvas and surface and `onAccent` meets it on the accent; `selection`
  / `onSelection` colour the selected nav item, chip or segment.
- Display preferences (`AtlasDisplayPreferences`) live in UserDefaults, never in
  the vault: `display.theme.v1`, `display.appearanceMode.v1`,
  `display.portfolioVisualization.v1`, `display.portfolioGrouping.v1` (raw string
  until the grouping enum exists in AddressAtlasCore).
- Fonts are bundled OFL files under `Sources/AddressAtlasMac/Fonts/<Family>/`
  with each OFL.txt. Mac: SwiftPM resource (`.copy("Fonts")`), copied by
  `build-mac-app.sh` into `Contents/Resources/AddressAtlasMac_AddressAtlasMac.bundle`.
  iOS: a folder-reference resource in `project.yml` (Fonts excluded from the
  shared source glob). `AtlasFonts` registers them with CoreText at first use
  and never touches `Bundle.module` inside a packaged `.app` (it traps if the
  bundle is missing). Missing fonts fall back to system fonts.

## Supersedes

The 2026-07-21 design-system decision's single navy/blue palette, rounded system
type and soft-border-only surfaces are superseded by the themes. Its rules on
calm literal copy, Reduce Motion, minimum widths, saved-state-first layouts and
synthetic fixtures still apply.

## Consequences

- Add colours through `AtlasPalette` roles in the catalog, never as literals in
  screens. A new palette must pass the contrast tests for all four variants.
- Adding a file under `Sources/AddressAtlasMac` needs `./generate-project.sh`.
- Screens still use system `.font(.callout)` etc. in places; only the shared
  primitives, page headers and a few iOS pieces use themed fonts. Migrating
  screens to `AtlasTheme.font(...)`/chart tokens is the next phase. (Done for
  the Mac in phase 3, see `2026-11-04-mac-navigation-and-screens.md`; the Mac
  screens also avoid the shared pill button styles, see the pill gotcha note.)
- Hard-edged themes draw offset shadows behind cards; do not clip a card's
  parent tightly or the shadow is cut.
