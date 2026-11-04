# Design references (November 2026 redesign)

Static HTML mockups that define the redesign. Open them in a browser.

- `themes.html`: the six selectable themes (A Chain colours, B Candy brutal, C Riso zine, D Heatmap, E Pixel, F Acid). All six ship as user-selectable themes.
- `views.html`: portfolio and coin visualizations. Every view is independent of the theme and takes a "group by". Ships together with four more views not drawn here: Atlas map (Voronoi), Slope (rank change between two snapshots), Concentration gauge, Calendar heatmap.
- `round-one-rejected.html`: first round (muted, editorial). Rejected as not colourful or crypto-native enough; kept only for the copy before/after rules at the bottom.

Implementation (phase 1): the six themes are in `native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasThemeCatalog.swift` and are chosen under Settings > Theme on Mac and iOS. Screenshots of the result, with synthetic or empty data, are in `screenshots/phase1/`.

Copy rules: say what a thing is or does, once, in as few words as possible. No slogans, no eyebrow labels, no subtitle under every title, each privacy fact stated once where it matters. Errors say what happened, then what to do.

Data in the mockups is synthetic.
