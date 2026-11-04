---
title: Pill outlines grow bars in AppKit renders and macOS menus ignore custom labels
date: 2026-11-04
status: active
tags: [gotcha, swiftui, macos, themes, rendering]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasMac/MacScreens/MacButtons.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/MacScreens/MacPrimitives.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasThemeRuntime.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasDesignSystem.swift]
---

## Gotcha

- In themes with pill controls (Chain colours, Heatmap) `atlasChrome` draws a
  control as `RoundedRectangle(cornerRadius: 999 or half the height, style:
  .continuous)`. Through AppKit (`NSHostingView`, which the screenshot harness
  uses) that outline grows a straight bar outside each end. `.circular`
  corners and `Capsule(style: .circular)` do not. Clamping the radius does not
  help: 14, 15 and 16 points on a 32-point chip all show it. It is in
  `AtlasPrimaryButtonStyle`, `AtlasSecondaryButtonStyle` and `Badge`, so iOS
  shows the same shapes.
- A macOS `Menu` turns its label into a menu title and image: custom chrome
  (padding, outline, fill) and the order of an icon and a text are lost, and
  the chevron appears before the text.
- `ImageRenderer` cannot draw a `ScrollView`, `Menu`, `Picker` or `Table`;
  `NSHostingView.cacheDisplay` can, and also draws the `Canvas` charts. An
  AppKit `Table` still shows no rows in an offscreen render.

## Fixed in the shared chrome

`AtlasChrome` and the two button styles now draw outlines with `AtlasOutline`
(`AtlasThemeRuntime.swift`): a circular-corner capsule when the radius reaches
half the shorter side (pill controls pass 999), a continuous rounded rectangle
otherwise. A render of `AtlasPrimaryButtonStyle`, `AtlasSecondaryButtonStyle` and
`Badge` through `NSHostingView` in Chain colours shows no bars. The Mac-only
styles in `MacButtons.swift` can be removed once a live window confirms it; the
`Menu` label limit below still applies.

## Safe practice

- Mac screens use `MacPrimaryButtonStyle`, `MacSecondaryButtonStyle`,
  `MacBadge` and `macChrome(isPill:)` (a capsule with circular corners for pills).
  Do not add `atlasChrome` with a pill radius in a Mac screen.
- Build a menu-shaped chip as `Menu { ... } label: { ... }.menuStyle(.button)`
  with `.buttonStyle(MacChipButtonStyle(selected:))`, never with the chrome inside
  the label.
- Fixing `AtlasChrome` (draw the outline as a capsule when the radius reaches half
  the height) would fix the shared styles for both apps; it belongs with the theme
  engine files, not in a screen.
