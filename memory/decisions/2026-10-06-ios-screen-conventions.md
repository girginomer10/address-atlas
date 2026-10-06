---
title: iOS screens are list-first with sheets, toasts, and a first-run walkthrough
date: 2026-10-06
status: active
tags: [decision, ios, swiftui, ux, onboarding, design-system]
related_files: [native/AddressAtlasiOS/Sources/AddressAtlasiOS/IOSComponents.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/RootView.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/MainShell.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/OnboardingScreen.swift, docs/IOS-POLISH-2026-10-06.md]
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
- Manual holdings and custom tokens have no update API in `AppState`; detail
  sheets offer include/pause and remove only.

## Update 2026-10-07 (second QA pass)

- The privacy cover lives in its own `UIWindow` above `.alert` (`IOSPrivacyShield`),
  because a SwiftUI overlay in `RootView` sits under presented sheets.
- Never present a sheet from inside a sheet for a form: SwiftUI hit-testing of
  fields in the stacked sheet was unreliable. Edit forms are pushed inside the
  detail sheet's `NavigationStack` (`TokensFormContainer(embedded:)`).
- On iOS `AtlasTextFieldStyle` focuses the field when its padded area is
  tapped; the padding sits outside the UIKit text view.
- Toast tones: success, warning (text mentions a warning), neutral
  (cancelled/already running), error. Silent preference toggles show no toast;
  routine saves no longer produce "Saved locally.".
- Portfolio/Assets hide holdings whose source was removed or paused since the
  latest run and show a "Sources changed" banner; change-since-previous is only
  shown when both runs read the same sources (`AppStateScanning` helpers).
- Wallet names come from `AppState.walletDisplayNames` / `walletDisplayName(for:)`
  on every screen, search, warning, and export.
- Exchange credentials are format-checked before saving and can be replaced in
  place (`replaceExchangeCredentials`); manual holdings and custom tokens are
  edited with `updateManualHolding` / `updateCustomToken`.
