---
title: Screens read typed state signals, not the wording of notices and statuses
date: 2026-11-04
status: active
tags: [decision, appstate, ios, notices, icloud, recovery-kit, toast]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasMac/AppState.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AppStateICloud.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AppStateVaultSync.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AppStateScanning.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/IOSComponents.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/SettingsScreen.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/UnlockScreen.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/ICloudScreen.swift]
---

## Context

The iOS screens decided what to do from the wording of `AppState.notice` and
`AppState.iCloudStatus`: the toast tone came from the substrings "warning",
"cancelled" and "already running"; a recovery kit restore was recognised by
"restored"; the iCloud card by "Needs attention" and "not recorded" /
"receipt failed"; and the toast named a save only when the notice started with
"Saved locally.". The state layer stopped posting "Saved locally." on
2026-10-07 (an ordinary save leaves `notice` empty), so the save toast and the
"Scan" offer after the first source had silently stopped working, and the copy
rewrite of 2026-11-04 made the other checks one reword away from breaking too.

## Decision

- `AppState.noticeTone` (`NoticeTone`: `.success`, `.neutral`, `.warning`) is
  posted with the notice by `postNotice(_:tone:)`. Assigning `notice` directly
  resets it to `.success`. Cancellations, "already running" refusals (scan, sync,
  exchange key check, unlock) and `presentUserFacingError`'s cancellation notice
  are `.neutral`; "Scan finished with N warnings" is `.warning`. The iOS toast
  maps it with `IOSToastTone.init(_ NoticeTone)`.
- `AppState.iCloudStatusKind` (`ICloudStatusKind`) is the state; `iCloudStatus`
  is its text and is now read-only. Screens compare the kind.
- `restoreRecoveryKit(from:recoveryCode:)` returns `RecoveryKitRestoreOutcome`
  (`.restored`, `.restoredWithFollowUp` for an interrupted upload or a read-only
  portfolio, `.notRestored`); it is `@discardableResult`, so the Mac views are
  unchanged.
- The iOS toast names an ordinary save from the document itself
  (`IOSSaveFingerprint` / `IOSSaveSummary`: "Wallet added.", "Name saved.", the
  first-scan offer) when `notice` is empty, or empty but for the sentence about
  pruned snapshots. A notice a screen or AppState posts wins over the summary.

## Consequences

- New code that needs to react to an outcome adds a typed signal next to the
  producer; do not match notice or status wording in a view. The glossary note
  lists no wording that code depends on any more.
- Tests still compare `notice` text where they assert behaviour; changing a
  notice string is a copy change only.
- Not exercised in a live run: the toast, the restore flows and the iCloud card
  were checked by building and by reading the code; the simulator cannot be
  tapped from the shell.
