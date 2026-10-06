# iOS polish pass — simulator walkthrough findings

Date: 6 October 2026. Reviewer: Claude, driving a fresh iPhone 17 Pro simulator
(iOS 26.5) with `axe` taps, typing, and accessibility dumps on build `0.2.0 (92)`,
source `c2fc14c`. Test data: public, well-known addresses only
(`0xd8dA…6045`, `1A1zP1…DivfNa`, the `…dEaD` burn address). No exchange account
was connected.

Owner request: the app feels unfinished — too much text, no onboarding, design
and UX need a finishing pass, in the same spirit as the Pact simulator review.
This pass complements `docs/NATIVE-UI-REVIEW-2026-10-06.md` (F01–F11, U01–U06).

## Global findings

| ID | Finding | Direction |
| --- | --- | --- |
| G1 | No first-run experience. A new install lands on a Portfolio of zeros; the empty state tells the user to go elsewhere but has no button. | Walkthrough for vaults without sources; empty states with direct actions. |
| G2 | Text everywhere. Every page has a paragraph subtitle, every card a title + subtitle, plus always-open callouts. "Private keys never enter the app" appears three times on Wallets alone. iCloud and Export are walls of text. | Remove or shorten page subtitles; move mechanism/privacy copy into collapsed "How this works" disclosures; say each privacy promise once. |
| G3 | Forms before content. Wallets, Exchanges, and Tokens open with a long creation form; saved items sit below it (violates the 2026-07-21 design decision). | List first; add through a toolbar "+" sheet. |
| G4 | Assets have letter-in-a-blue-circle avatars only; every row looks the same. | Deterministic colored monograms (`TokenMonogram`). |
| G5 | Status messages are rendered at the top of the page, far from the action, and push content down; success and warning share the green style ("Snapshot saved with 1 warning"). | Floating toast for notices/errors; inline errors inside forms. |
| G6 | Mixed number formatting: `%99,3` next to a hard-coded `<0.1%`. | Locale-aware floor (`AtlasPercent`). |
| G7 | App switcher shows balances and revealed keys (F01). | Opaque privacy cover when the scene is not active. |

## Screen findings

- **Portfolio:** four large metric tiles for counts (0/0/0/0 on first run); a big "Refresh portfolio" card with four trust bullets on every visit; no indication of change since the previous snapshot; allocation lists the same asset per chain and the "Other" row leads nowhere.
- **Wallets:** wallet name shown as an always-editable text field holding a truncated address; stale red error stays after the input becomes valid (U02); invalid input still reads "1 address detected"; delete has no confirmation from the row.
- **Assets:** search and two toggles occupy the first screen; native assets repeat the network (`ETH Base … [Base]`); monospaced amounts look like code; rows open nothing (U05); AX5 overflow (F02).
- **Exchanges:** the "create a restricted key" guidance comes after the form; key reveal state survives backgrounding.
- **Tokens:** empty custom-token card and the whole contract form come before manual holdings (U04); errors at the top of the page (F04); field labels (F05); no keyboard Done (U01).
- **Snapshots:** date column squeezed to three lines by the amount (F03); no change vs previous snapshot; no detail.
- **iCloud:** three dense paragraphs before and after the actions; Kraken caveat always open.
- **Export:** long always-open explanation; preview text in monospaced code style.
- **Settings:** legal/support links as six full-width outlined buttons; recovery code selectable text bypasses the protected copy path (F08).
- **More:** privacy card narrower than the list.

## Foundation added before screen work

`native/AddressAtlasiOS/Sources/AddressAtlasiOS/IOSComponents.swift`:
`IOSNavigationModel` / `IOSPendingAction` (cross-screen "open the add sheet"),
`IOSOnboarding.completedKey`, `TokenMonogram`, `AtlasPercent`, `IOSFormSheet`,
`IOSInlineError`, `LearnMoreDisclosure`, `IOSFactRow`, `atlasKeyboardDoneButton()`,
`IOSPersistentStatus`, `IOSStatusToast`, `IOSPrivacyCover`. `RootView` gates the
walkthrough (`OnboardingScreen`) on "not completed and no sources", overlays the
toast and the privacy cover; `TabShell`/`SplitShell` follow the navigation model.
