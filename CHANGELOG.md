# Changelog

All notable changes to Address Atlas are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Address Atlas has no public release yet. The entries below are TestFlight builds of version 0.2.0 for macOS and for iPhone and iPad. A build number is the repository's commit count at the commit it was built from, and both platforms use the same number. The app-store [release checkpoints](app-store/README.md#release-checkpoint--november-5-2026) record the App Store Connect state of each build.

## [Unreleased]

### Changed

- Dependabot now ignores semver-major version updates for the legacy sync service (npm and Docker), which stays on Node 22. Minor and patch updates and GitHub Actions updates are unchanged.
- The security policy, bug report template, and contributing guide describe the Mac and iOS apps and the TestFlight builds.

## [0.2.0 (175)] - 2026-11-05

Built from commit [`394e8e7`](https://github.com/girginomer10/address-atlas/commit/394e8e7b1ab1513bc8f4216cda54806f85fbfcf3). Uploaded to TestFlight for macOS and iOS and submitted to Beta App Review on 2026-11-05. Release notes: [0.2.0-beta.175](https://github.com/girginomer10/address-atlas/releases/tag/0.2.0-beta.175).

### Added

- Six themes: Chain colours, Candy brutal, Riso zine, Heatmap, Pixel, and Acid. Choose one in Settings on Mac and iOS. Riso zine is light only and Acid is dark only. The other four follow light and dark mode. Eight open-licence font families ship with the app.
- 14 portfolio views, each usable with every theme: Map (treemap), Ring, Strip, Grid, Bubbles, Rings in rings, List, Flow, Atlas map, Over time, What changed, Slope, Concentration, and Calendar. Most views group by asset, network, wallet or exchange, state, or type.
- Coin widgets on each coin page: state strip, unlock timeline, amount history, change, and custody.
- Cosmos unbonding. Unbonding delegations are read with their completion time, and each distinct completion time becomes its own holding with an exact unlock date. Past 20 distinct times, the later ones are combined under the earliest date, with a warning.
- Solana stake accounts. They are read with `getProgramAccounts` and split into staked and unbonding by the current epoch. Many free Solana RPC endpoints reject that call; the scan then warns that staked and unbonding SOL may be missing and still returns the balance and tokens.
- A price-versus-amount split of change between two scans. What changed and the coin page show how much of a move came from price and how much from coins arriving or leaving. When two scans read different wallets or exchanges, the history views mark the break or say the comparison is not like for like.
- An `unlocks_at` column in the full CSV export and an `unlocksAt` field in the full JSON export. Share-safer exports only gain the `unbonding` state.
- Editing of manual holdings and custom tokens on Mac and iOS, and one readable name per wallet everywhere.
- An address column and fixed decimals in exports, and a confirmation before a full export.
- A first-run walkthrough on iOS and a first-scan offer after the first source is added.

### Changed

- The Mac app has seven sections: Portfolio, Assets, History, Wallets, Exchanges, Export, and Settings. The iOS app has five tabs: Portfolio, Assets, Sources, History, and Settings, with a sidebar on iPad.
- Plain-language copy across both apps, the scanner warnings, the error messages, and the documentation. Internal terms such as vault and rollback checkpoint are gone from user-facing text.
- On iOS, the app switcher shows a privacy cover, including over open sheets, so a revealed recovery code or API key does not stay visible there.
- Next.js, Vitest, and Vite dependency updates for the legacy sync service.

### Fixed

- The iOS iCloud check now reads the entitlements from the code signature. Before, it could not find them in TestFlight and App Store installs, so iCloud save and restore could not start. Checked against the signed build 91 executable only; not verified on a physical device.
- A normal zero-balance XRP trust line no longer produces a scan warning.
- The app now refuses a custom token that duplicates a built-in token, whose custom settings the scanner would have ignored.
- CI: the power diagram timing checks are skipped under Thread Sanitizer, where they ran past their time budget. CI on main had been failing because of this since 2026-11-04.

### Not verified

- Beta App Review has not accepted the build, and no tester has joined through a public link yet.
- Installation on a physical iPhone, iPad, or Mac from TestFlight.
- Restoring an iCloud copy made on a Mac onto an iPhone.
- Cosmos unbonding and Solana stake accounts against live nodes. They are tested with fixtures.
- Real exchange API keys, VoiceOver, and the Mac app in a live window.

## [0.2.0 (91)] - 2026-10-06

Built from commit [`4782ce5`](https://github.com/girginomer10/address-atlas/commit/4782ce544e9fbca69f255bb3312e8c392ddbfb01). Uploaded to TestFlight for macOS and iOS and available to the owner through Internal Testing only. External testing was not requested.

### Added

- The first iPhone and iPad build (`com.addressatlas.ios`). It compiles the Mac package's shared core and state layer and adds its own screens. The iOS TestFlight upload was the first for this app.
- On Mac, optional private iCloud copies in place of the earlier hosted sync account. You save and restore a copy by hand from the iCloud screen. The portfolio is encrypted before it leaves the device, and a second key travels through iCloud Keychain. The apps no longer connect to the sync service.
- A sandboxed Mac App Store build of the Mac app. A first Mac build, 0.2.0 (82), was accepted by App Store Connect on 2026-09-07.

### Known problems in this build

- The iOS app switcher can show a revealed API key.
- Large text overflows the Assets screen on iOS.
- On iOS, iCloud save and restore cannot start in TestFlight installs because the app does not detect its iCloud entitlement. Fixed in 175.
- The full list is in the [native usage review](docs/NATIVE-UI-REVIEW-2026-10-06.md) and the [iOS polish pass](docs/IOS-POLISH-2026-10-06.md).

[Unreleased]: https://github.com/girginomer10/address-atlas/compare/0.2.0-beta.175...HEAD
[0.2.0 (175)]: https://github.com/girginomer10/address-atlas/releases/tag/0.2.0-beta.175
[0.2.0 (91)]: https://github.com/girginomer10/address-atlas/commit/4782ce544e9fbca69f255bb3312e8c392ddbfb01
