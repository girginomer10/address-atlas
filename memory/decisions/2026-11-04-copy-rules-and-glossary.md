---
title: User-facing copy rules and preferred terms
date: 2026-11-04
status: active
tags: [decision, copy, documentation, errors, glossary]
related_files: [docs/design/README.md, docs/design/round-one-rejected.html, native/AddressAtlasMac/Sources/AddressAtlasMac/UserFacingErrors.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/ExportPipeline.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/PlatformCopy.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/HTTPClient.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/UnlockScreen.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/ICloudScreen.swift, README.md, PRIVACY.md, app-store/metadata/en-US.md]
---

## Context

The first redesign round was rejected for tone as well as colour. App text,
scanner warnings, errors, the README and the store listing mixed marketing lines
("sees what others miss", "Private by design") with internal terms (vault,
endpoint policy, rollback checkpoint, crash-durable). Phase 3 part F rewrote the
shared copy once so the Mac screens, the iOS screens and the docs agree.

## Decision

Rules (also in `docs/design/README.md`):

- English, plain, short. Say what a thing is or does once. No slogans, no
  eyebrow labels, no subtitle under every title, no "successfully", no
  "please", no "!" in system copy.
- Errors say what happened, then what to do, in one or two short sentences.
  Scanner warnings name the coin, network or provider and the consequence:
  "Kraken didn't respond, so its balances are missing from this scan. Scan again
  later." / "NEW on Base has no USD price, so it's left out of the total."
- Notices are past tense and terse: "Scan finished with 2 warnings", "Wallet
  added", "iCloud copy deleted".
- Keep meaning and safety exact. Never weaken a warning about identifying
  exports, API keys or data loss, and never claim more privacy than the code
  provides (providers see scanned addresses; share-safer exports are not
  anonymous).
- State each privacy fact once, where it matters.

Preferred terms (user-facing text only; type, file and column names keep their
old words):

| Say | Not |
| --- | --- |
| your portfolio, saved portfolio, saved data | vault |
| backup copy (saved before an iCloud restore; "earlier copy" when you restore it) | rollback checkpoint, rollback point, rollback copy |
| server settings, built-in server settings | endpoint config, endpoint policy, bundled endpoints |
| saved, couldn't confirm it was saved | durable, crash-durable, persistence |
| set aside, "Set aside and start fresh" | quarantined, "start clean" |
| earlier copy (the button and dialog that restore it), "Restore earlier copy" | previous copy, previous local copy, restore point |
| damaged data, damaged files, "Your saved portfolio is damaged" | damaged vault, local vault needs attention |
| stop the upload to the old sync server ("Stop the upload…") | finish migration, keep local vault and migrate |
| keys (in lists of what diagnostics leave out), API keys | credentials |
| wallet name (also in export warnings) | wallet label, labels |
| "saved before keys were tied to one device" | predates device binding, legacy Kraken key |
| API key (exchange keys) | credentials, secret material |
| name (wallet name, exchange name) | label |
| sync connection | account binding |
| scan, snapshot (a saved scan), source (wallet or exchange), recovery kit, passkey, sync account, watch-only | (kept as they are) |
| unbonding ("Unbonding: 24.79 ATOM, free on 16 Nov") | |
| stake account (staked, in cooldown, ready to withdraw) | |

No code depends on the wording of notices or iCloud statuses any more: the iOS
screens read `AppState.noticeTone`, `iCloudStatusKind` and the
`RecoveryKitRestoreOutcome` returned by `restoreRecoveryKit` (see
`2026-11-04-typed-state-signals.md`). Scan warnings still use the "<network> · <short address>: <text>"
and "<exchange>: <text>" shapes that `ScanWarningCopy` rewrites.

## Consequences

- New text goes through the same rules; check the table before adding a word
  like "vault" or "endpoint" to a message.
- Core's `ProviderErrorSanitizer.description(of:)` turns a `URLError` into
  advice for scan warnings; raw framework text is never shown.
- Bundled chain and token names, saved asset names ("<chain> Staked",
  "Unbonding", "Rewards"), export column names and diagnostics keys are data, not
  copy, and stay as they are.
- The legacy sync-server messages (`AppStateAccountLifecycle`, `AppStateVaultSync`)
  follow the table but no screen reaches them while `legacyServerSyncEnabled` is
  false.
