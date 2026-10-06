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
