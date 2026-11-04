## 2026-11-04 23:10 CET - Claude

- Task: close the leftovers after the redesign merge (phases 1 to 3), and record where the whole redesign stands for the next agent. Done on a worktree branch; not pushed or merged.

### Where the redesign stands

- Data: Cosmos unbonding and Solana native stake accounts (`AssetSource.unbonding`, `TrackedAsset.unlocksAt`), and `PortfolioAnalytics` in AddressAtlasCore (phase 1A, `memory/decisions/2026-11-04-unbonding-source-and-unlock-time.md`).
- Themes: six themes on one shared token engine (Chain colours, Candy brutal, Riso zine, Heatmap, Pixel, Acid). Riso is light only, Acid dark only. Fonts are bundled under `Sources/AddressAtlasMac/Fonts/` (OFL). Pixel's number role is VT323.
- Charts: 14 portfolio views and the coin widgets (state strip, unlock timeline, amount history, change, custody) in `Sources/AddressAtlasMac/Charts/`, compiled for macOS and iOS.
- Mac: seven sections (Portfolio, Assets, History, Wallets, Exchanges, Export, Settings; Cmd-1 to Cmd-7), coin detail over the current section, Tokens as a pane of Wallets, iCloud inside Settings (`MacScreens/`).
- iOS: five tabs (Portfolio, Assets, Sources, History, Settings) on a self-drawn themed tab bar (sidebar on iPad); coin, scan, iCloud and Export are pushed routes. Sources holds wallets, exchanges, manual holdings and custom tokens behind one chip switcher and one "+" menu.
- Copy: plain-language rewrite across the state layer, Core messages, scanner warnings, screens and docs (`memory/decisions/2026-11-04-copy-rules-and-glossary.md`).

### How to switch themes and views

- Theme: Settings > Theme (Mac and iOS); appearance (system, light, dark) next to it. Stored in `UserDefaults` under `display.theme.v1` and `display.appearanceMode.v1`, never in the saved portfolio.
- Portfolio view: the switcher on Portfolio (six chips and a "More" menu on Mac, a scrolling chip row on iPhone); `display.portfolioVisualization.v1` holds it. "Group by" appears only for views with `usesGrouping`. A coin page offers the views with `worksForSingleCoin`; its grouping is `coin.grouping.v1` on iOS.
- Screenshots: Mac with `ATLAS_WRITE_SCREENSHOTS=1 swift test --filter MacScreenRenderTests` (`=all` for every theme) and the chart tests `ChartKitRenderTests`, `ChartRenderTests` (the latter writes the whole matrix into `docs/design/screenshots/phase2/`; keep only the tracked names and run `git clean -f` on the rest). iOS: Debug build, one simulator, `xcrun simctl launch <udid> com.addressatlas.ios -AtlasDemoFixture full -AtlasDemoTab portfolio -AtlasDemoRoute coin:ATOM -display.theme.v1 acid -display.appearanceMode.v1 dark -AtlasDemoScrollY 1400`, then `xcrun simctl io <udid> screenshot`. All launch arguments are listed in `DemoFixture.swift` and `native/AddressAtlasiOS/README.md`. `xcrun simctl ui <udid> content_size accessibility-extra-extra-large` gives the "axxl" pictures.

### What this pass changed

1. iOS `TokensScreen` copy (Holdings and Tokens lists, empty states, footers, add and detail sheets, dialogs, notices) follows the copy rules: "In your total", "1 of 100 holdings", "Count in your total", "You've reached the limit of 100 holdings. Remove one to add another.", and so on. Behaviour and limits are unchanged.
2. Typed signals replace wording checks (`memory/decisions/2026-11-04-typed-state-signals.md`): `AppState.noticeTone` and `postNotice(_:tone:)`, `iCloudStatusKind`, and `restoreRecoveryKit` returning `RecoveryKitRestoreOutcome`. The checks for "Saved locally.", "receipt failed" and the "restored" substring are gone. Found on the way: since 2026-10-07 AppState posts no notice for an ordinary save, so the toast's save summary ("Wallet added.", "Name saved.") and the "Scan" offer after the first source never appeared; the toast now builds them from the document when the notice is empty.
3. Pixel digits: Silkscreen (Pixel's label face) also draws a five like an S, not only Pixelify Sans. Money and amounts use the number role everywhere (iOS Tokens, holding detail header); text that mixes words and digits goes through `AtlasTheme.font(_:_:weight:figuresIn:)`, `HistoryChartStyle.captionFigureFont` / `smallFigureFont` / `captionFont(figuresIn:)` and `chartKitLabelFont(_:weight:figuresIn:)`. Axis ticks, dates, tooltips and waterfall labels in the history charts moved to the number face.
4. Acid state colours: lime, cyan, orange, pink, violet (was lime, near-white, grey, olive, dark olive). Grey stays for "sources changed".
5. `BrandLockup`, `SidebarTrustLine` and `PrivacyCard` removed from `AtlasDesignSystem.swift` (unused).
6. The Mac render fixtures now use the scanner's wording for the unpriced-token warning ("MEME on Ethereum has no USD price, so it's left out of the total.").
7. Docs: `native/AddressAtlasiOS/README.md`, `native/AddressAtlasMac/README.md`, `docs/DEVELOPMENT.md`, `docs/design/README.md` updated, `docs/IOS-POLISH-2026-10-06.md` marked historical, `docs/RELEASE_CHECKLIST.md` iCloud path fixed, root `README.md` shows three iPhone pictures.
8. Pictures replaced: iOS `portfolio-pixel-light`, `portfolio-pixel-light-list`, `coin-ETH-pixel-light-holdings`, `icloud-pixel-light`, `dynamic-type-axxl-sources-pixel-light`, `coin-ATOM-acid-dark-history`, `ipad-coin-ATOM-acid-dark`, `sources-holdings-heatmap-dark` (new Tokens copy); the 16 Mac pictures in `phase3/mac/` that show the warning, Pixel figures or Acid states; four in `phase2/` (`calendar-pixel-light-compact`, `what-changed-pixel-light-compact`, `concentration-acid-dark-compact`, `flow-acid-dark-full`).

### Verified

- From `native/AddressAtlasMac`: `swift test` 856 tests, 5 skipped, only the 3 known environment failures (KeychainVaultKeyStoreTests x2, KrakenNonceProcessTests x1). `-Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`: same, no warnings. `--sanitize=thread`: 856 tests, 6 skipped, no sanitizer reports, only the 2 Keychain tests failed. `swift build --configuration release --product AddressAtlasMac`, `./build-mac-app.sh` (universal, signed, VT323 in the bundle), `Tests/build-mac-app-version-tests.sh` (163 checks), `Tests/notarize-mac-app-tests.sh` (11 passed), `Tests/mas-release-contract-tests.sh`: pass.
- From the repo root: `./native/AddressAtlasiOS/generate-project.sh` leaves the project unchanged; `build-ios-app.sh --simulator --unsigned` (Debug) and `--configuration Release --unsigned`: BUILD SUCCEEDED. A Release build has no `AtlasDemo`, `DemoFixture`, `DemoKeyStore`, `DemoScrollModifier` or `DemoUnlockPreview` in `strings -a` or `nm` (the Debug dylib has 28 matches, so the check is not vacuous). `npm test` (592 passed, 58 skipped: the PostgreSQL integration tests), `npm run typecheck`, `npm run build`, `npm audit` (0 vulnerabilities), `scripts/check-secret-artifacts.py` (708 files), `scripts/check-secret-artifacts-tests.sh` (22/22). Note: `src/lib/sync/deployment.test.ts` has 5 second timeouts and failed 1 to 6 tests while another job pushed the machine load average to about 250; it passes in a normal run and with `--testTimeout=120000` (59/59).
- Looked at every replaced picture. The Pixel pictures now show clean fives in VT323 (totals, rows, custody, chart axes, waterfall labels); the Acid coin pages show five separable state colours.

### Not exercised

- Live window interaction on the Mac (hover, focus order, menu commands, the six themes switching under a real vault) and any tap on iOS: sheets, add forms, confirmation dialogs, the toast (including the save summary and the first-scan offer restored here), the recovery kit restore flows and the iCloud card were reviewed by reading code and building, not by tapping. VoiceOver, Reduce Motion, physical devices, real iCloud and real exchange keys were not driven.
- Live Solana `getProgramAccounts` for stake accounts and Cosmos unbonding delegations against real nodes (fixtures only; see `memory/api-notes/2026-11-04-solana-stake-accounts-getprogramaccounts.md`).
- The iPad picture and the status bar of the iPad shot show the host's Turkish date, as the earlier one did.

### Next

- Old words remain in iOS strings outside the Tokens pass: `UnlockScreen` ("vault", "damaged vault") and `ICloudScreen` ("rollback copy", "keep the local vault", the legacy migration card) do not follow the glossary (backup copy / earlier copy, saved portfolio). The unlock pictures would need re-taking with them.
- `MacButtons.swift` can drop its own button and badge styles now that `AtlasChrome` draws capsules (check in a live window first). `MacSliceFilter.key` repeats a private Core rule. A default portfolio view per theme (Heatmap map, Acid over time, as in `themes.html`) needs a change in `AtlasDisplayPreferences`.
- Coinbase and Kraken keys are not checked for read-only scope by the app (only Binance), so the README and review notes say "read-only API keys" without claiming enforcement.
- Memory: added `memory/decisions/2026-11-04-typed-state-signals.md`; updated the chart digits gotcha, the theme engine decision, the iOS screen conventions, the copy glossary and the iOS file map. `npm run memory:sync` and `npm run memory:doctor` were run.
