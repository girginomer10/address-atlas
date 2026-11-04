# Design references (November 2026 redesign)

Static HTML mockups that define the redesign. Open them in a browser.

- `themes.html`: the six selectable themes (A Chain colours, B Candy brutal, C Riso zine, D Heatmap, E Pixel, F Acid). All six ship as user-selectable themes.
- `views.html`: portfolio and coin visualizations. Every view is independent of the theme and takes a "group by". Ships together with four more views not drawn here: Atlas map (Voronoi), Slope (rank change between two snapshots), Concentration gauge, Calendar heatmap.
- `round-one-rejected.html`: first round (muted, editorial). Rejected as not colourful or crypto-native enough; kept only for the copy before/after rules at the bottom.

Implementation (phase 1): the six themes are in `native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasThemeCatalog.swift` and are chosen under Settings > Theme on Mac and iOS. Screenshots of the result, with synthetic or empty data, are in `screenshots/phase1/`. They show the themes on the screens as they were before phase 3, so the navigation in them is out of date.

Implementation (phase 2, part C1): `MapChartView`, `RingChartView`, `StripChartView`, `GridChartView`, `BubblesChartView`, `RingsInRingsChartView` and `ListChartView` live in `native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/` with their shared `ChartKit*` files. `screenshots/phase2/` holds a review set rendered from a synthetic portfolio; `ATLAS_WRITE_SCREENSHOTS=1 swift test --filter ChartKitRenderTests` rewrites it (`=all` writes every theme, size and grouping).

Implementation (phase 2, history views): `Flow`, `Over time`, `What changed`, `Atlas map`, `Slope`, `Concentration`, `Calendar` and the coin widgets (state strip, unlock timeline, amount history, change, custody) are in `native/AddressAtlasMac/Sources/AddressAtlasMac/Charts/`. A representative set of renders (every view, six themes, full and compact, synthetic data) is in `screenshots/phase2/`; the whole matrix is written by `ATLAS_WRITE_SCREENSHOTS=1 swift test --filter ChartRenderTests` from `native/AddressAtlasMac`.

Implementation (phase 3, Mac screens): the seven Mac sections and the coin detail screen are in `native/AddressAtlasMac/Sources/AddressAtlasMac/MacScreens/`. `screenshots/phase3/mac/` holds 31 review pictures rendered from a synthetic portfolio (the real window, through `NSHostingView`). From `native/AddressAtlasMac`, `ATLAS_WRITE_SCREENSHOTS=1 swift test --filter MacScreenRenderTests` rewrites them; `ATLAS_WRITE_SCREENSHOTS=all` writes every screen in every theme plus the 900-point minimum window. `ATLAS_SCREENSHOT_DIR` changes the output folder and `ATLAS_SCREENSHOT_NAMES` (comma-separated name prefixes) limits which files are written. `screenshots/phase3/pixel-number-font.png` compares Pixelify Sans (draws "5" like "S") with VT323 and Jersey 10, the faces considered for Pixel figures; VT323 was chosen.

Implementation (phase 3, iOS screens): the five iOS tabs (Portfolio, Assets, Sources, History, Settings), the coin detail screen and the themed tab bar are in `native/AddressAtlasiOS/Sources/AddressAtlasiOS/`. `screenshots/phase3/ios/` holds the iPhone review set (all six themes, light and dark where the theme has both, several chart views, coin pages, Assets, Sources, History, a scan, Settings, iCloud, Export, onboarding, unlock states, large text) and a few iPad pictures, named `<screen>-<theme>-<light|dark>[-variant].png`. They are taken in the iOS simulator with the Debug-only demo fixture: build Debug, then launch with `-AtlasDemoFixture full` plus the tab, route and theme arguments listed in `native/AddressAtlasiOS/Sources/AddressAtlasiOS/DemoFixture.swift` and in `native/AddressAtlasiOS/README.md`, and capture with `xcrun simctl io booted screenshot`. The fixture is compiled out of Release builds.

Copy rules: say what a thing is or does, once, in as few words as possible. No slogans, no eyebrow labels, no subtitle under every title, each privacy fact stated once where it matters. Errors say what happened, then what to do.

Data in the mockups is synthetic.
