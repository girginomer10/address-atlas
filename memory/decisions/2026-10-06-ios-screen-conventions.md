---
title: iOS screens are list-first with sheets, toasts, and a first-run walkthrough
date: 2026-10-06
status: active
tags: [decision, ios, swiftui, ux, onboarding, design-system]
related_files: [native/AddressAtlasiOS/Sources/AddressAtlasiOS/IOSComponents.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/RootView.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/MainShell.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/OnboardingScreen.swift, docs/IOS-POLISH-2026-10-06.md, native/AddressAtlasiOS/Sources/AddressAtlasiOS/IOSTheme.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/SourcesScreen.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/AtlasSection.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/DemoFixture.swift]
---

## Context

A simulator walkthrough found the iOS app read as unfinished: paragraph
subtitles and always-open callouts on every page, creation forms above saved
items, no first run, status lines at the top of pages far from the action.

## Decision

- Shared iOS-only primitives live in `IOSComponents.swift`; screens compose
  them instead of re-creating local variants.
- Transient `state.notice` / `state.error` render in `IOSStatusToast` (mounted
  in `RootView`, above the tab bar; top-pinned outside the shell). Notices
  auto-dismiss; errors stay until tapped or navigation clears them. Forms in
  sheets show `IOSInlineError` next to the confirm button and clear
  `state.error` on open, edit, and dismiss. `IOSPage` only shows persistent
  guidance.
- Saved content first; creation goes through a toolbar "+" and empty-state
  button opening an `IOSFormSheet`. Destructive actions confirm.
- Cross-screen "open the add sheet" goes through `IOSNavigationModel`
  (`open(_:then:)` + `consume(_:)`); shells react to `openRequest`, so reopening
  the same section still works.
- The walkthrough shows only while `onboarding.completed.v1` is false and the
  vault has no sources; restored vaults skip it.
- Mechanism and privacy explanations live in `LearnMoreDisclosure`; each
  privacy promise is said once per screen. Page subtitles are absent or short.
- An opaque `IOSPrivacyCover` covers the app whenever the scene is not active;
  revealed secrets and recovery codes also reset on leaving `.active`.

## Consequences

- New iOS screens follow these patterns; adding a shared iOS file still
  requires `./generate-project.sh` and committing the project.
- Manual holdings and custom tokens are edited in place (see the update
  below); detail sheets offer edit, include/pause, and remove.

## Update 2026-10-07 (second QA pass)

- The privacy cover lives in its own `UIWindow` above `.alert` (`IOSPrivacyShield`),
  because a SwiftUI overlay in `RootView` sits under presented sheets.
- Never present a sheet from inside a sheet for a form: SwiftUI hit-testing of
  fields in the stacked sheet was unreliable. Edit forms are pushed inside the
  detail sheet's `NavigationStack` (`TokensFormContainer(embedded:)`).
- On iOS `AtlasTextFieldStyle` focuses the field when its padded area is
  tapped; the padding sits outside the UIKit text view.
- Toast tones: success, warning, neutral (cancelled / already running), error,
  from `AppState.noticeTone` (2026-11-04; earlier they were guessed from the
  wording). Silent preference toggles show no toast; routine saves post no notice,
  so the toast names them from the document.
- Portfolio/Assets hide holdings whose source was removed or paused since the
  latest run and show a "Sources changed" banner; change-since-previous is only
  shown when both runs read the same sources (`AppStateScanning` helpers).
- Wallet names come from `AppState.walletDisplayNames` / `walletDisplayName(for:)`
  on every screen, search, warning, and export.
- Exchange credentials are format-checked before saving and can be replaced in
  place (`replaceExchangeCredentials`); manual holdings and custom tokens are
  edited with `updateManualHolding` / `updateCustomToken`.

## Update 2026-11-04 (phase 3 redesign: five tabs, themed screens)

- Information architecture: Portfolio, Assets, Sources, History, Settings
  (`AtlasSection`). The nine sections, the "More" list and the "Private by
  design" row are gone. Wallets, exchanges, manual holdings and custom tokens
  are one Sources tab (`SourcesScreen`: chip switcher, one "+" menu); iCloud
  and Export are pushed from Settings; a coin and a saved scan are pushed
  routes. Assets lists coins (`CoinSummary`), not holdings; the holding detail
  sheet is reached from a coin's page.
- Navigation: `IOSNavigationModel` no longer has `openRequest`; it owns
  `selectedSection` and one route stack per section (`paths`, `IOSRoute`), so a
  chart tap, a toast or another tab can open a coin (`openCoin`), narrow Assets
  (`openAssets(filter:)`) or open a scan (`openSnapshot`). `pendingAction` and
  `consume(_:)` still carry "open this add sheet"; `SourcesScreen` follows the
  action to the list that owns the sheet.
- Chrome: the shell draws the tab bar (`IOSTabBar`) and screens set an inline
  themed title (`iosTitle`), because the system tab bar and large titles take
  no theme font or shape and do not follow a live theme change. Cards, chips,
  notices and empty states come from `IOSTheme.swift` and read the theme
  tokens; do not reintroduce system `.insetGrouped` look-alikes or
  `.font(.callout)` (use `AtlasTheme.font(role, style)`).
- Copy: no subtitles, eyebrows or slogans; privacy is explained once, in
  Settings; the walkthrough is one page; warnings sit next to the data they
  affect. Code must not match AppState notice or status wording at all: use
  `noticeTone`, `iCloudStatusKind` and `RecoveryKitRestoreOutcome` (see
  `2026-11-04-typed-state-signals.md`). The toast names an ordinary save from the
  document (`IOSSaveSummary`) because AppState posts no notice for it.
- Screenshots and review use the Debug-only `-AtlasDemoFixture` (see
  `DemoFixture.swift` and `docs/handoff/2026-11-04-redesign-phase3e-ios-screens.md`);
  after a change, grep a Release binary for `AtlasDemo`/`DemoFixture`.
