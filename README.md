<p align="center">
  <img src="docs/assets/github-social-preview.png" alt="Address Atlas: a read-only crypto portfolio for Mac and iPhone. 20 networks, 3 exchanges, 6 themes, 14 views. Six maps of one synthetic portfolio, each in a different theme." width="100%">
</p>

<h1 align="center">Address Atlas</h1>

<p align="center">
  A read-only crypto portfolio for Mac and iPhone. Your data stays on your devices.
</p>

<p align="center">
  <a href="https://github.com/girginomer10/address-atlas/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/girginomer10/address-atlas/ci.yml?branch=main&amp;style=flat-square&amp;label=CI"></a>
  <a href="#get-it-on-testflight"><img alt="TestFlight: in beta review" src="https://img.shields.io/badge/TestFlight-in%20beta%20review-0D96F6?style=flat-square&amp;logo=apple&amp;logoColor=white"></a>
  <img alt="macOS 14 or newer" src="https://img.shields.io/badge/macOS-14%2B-111111?style=flat-square&amp;logo=apple&amp;logoColor=white">
  <img alt="iOS 17 or newer" src="https://img.shields.io/badge/iOS-17%2B-111111?style=flat-square&amp;logo=apple&amp;logoColor=white">
  <img alt="Swift 5.10" src="https://img.shields.io/badge/Swift-5.10-F05138?style=flat-square&amp;logo=swift&amp;logoColor=white">
  <img alt="Wallets are read-only" src="https://img.shields.io/badge/wallets-read--only-C6F432?style=flat-square&amp;labelColor=111111">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-FF9ECF?style=flat-square&amp;labelColor=111111"></a>
</p>

<p align="center">
  <a href="#get-it-on-testflight">Install</a> ·
  <a href="#what-you-get">What you get</a> ·
  <a href="#architecture-at-a-glance">Architecture</a> ·
  <a href="#coverage">Coverage</a> ·
  <a href="#build-from-source">Build from source</a> ·
  <a href="#privacy">Privacy</a> ·
  <a href="#how-it-was-built">How it was built</a>
</p>

<p align="center">
  <img src="docs/assets/hero-themes.gif" alt="The Mac portfolio screen cycling through six themes: Chain colours, Candy brutal, Riso zine, Heatmap, Pixel and Acid. Each frame is the same synthetic portfolio: a total value, the view tabs, and a map of BTC, ETH, SOL and other coins sized by value." width="100%">
  <br>
  <sub>One synthetic portfolio in all six themes. Switch in <b>Settings → Theme</b>.</sub>
</p>

Add public wallet addresses and read-only exchange API keys. Address Atlas reads balances and tokens on 20 networks, plus staking and unbonding on Cosmos chains and Solana and rewards on Cosmos chains. It adds USD prices and shows the result in 14 views and six themes. It never asks for a seed phrase and never needs permission to sign, trade, or withdraw.

Balances are read directly from public chain, price, and exchange providers, so those providers see the addresses you scan. See [Privacy](#privacy).

> [!IMPORTANT]
> Address Atlas is a preview. There is no signed and notarized direct download and no App Store release; the TestFlight builds are in Apple's beta review (see below), and you can build it from source. The [November 5 release checkpoint](app-store/README.md#release-checkpoint--november-5-2026) records what was built and submitted. Treat results as a view of your holdings, not as accounting records or financial advice. Physical-device acceptance and Mac-to-iPhone iCloud restore are not verified.

## Get it on TestFlight

<p align="center">
  <a href="https://testflight.apple.com/join/yGnNKV1a"><img alt="Join the Mac beta on TestFlight" src="https://img.shields.io/badge/TestFlight-Mac-0D96F6?style=for-the-badge&amp;logo=apple&amp;logoColor=white"></a>
  &nbsp;&nbsp;
  <a href="https://testflight.apple.com/join/9ZJwBjGr"><img alt="Join the iPhone and iPad beta on TestFlight" src="https://img.shields.io/badge/TestFlight-iPhone%20%26%20iPad-0D96F6?style=for-the-badge&amp;logo=apple&amp;logoColor=white"></a>
</p>

| | Mac | iPhone and iPad |
| --- | --- | --- |
| Needs | macOS 14 or newer | iOS 17 or newer |
| Build | 0.2.0 (175) | 0.2.0 (175) |
| Status | In Apple's TestFlight beta review, submitted 2026-11-05 | In Apple's TestFlight beta review, submitted 2026-11-05 |
| Public link | [testflight.apple.com/join/yGnNKV1a](https://testflight.apple.com/join/yGnNKV1a) | [testflight.apple.com/join/9ZJwBjGr](https://testflight.apple.com/join/9ZJwBjGr) |

The links start working once Apple approves the build. Until then they are live but offer nothing to install. Not yet verified: a tester joining through either link, and an install on a physical device. Build IDs and the full list of what is and is not verified are in the [release checkpoint](app-store/README.md#release-checkpoint--november-5-2026).

Prefer to build it yourself? See [Build from source](#build-from-source). The first run takes a public Bitcoin address and needs no account or API key.

## What you get

### Six themes

<table>
  <tr>
    <td width="33%" valign="top">
      <img src="docs/assets/themes/chain-colours.png" alt="Portfolio on Mac in the Chain colours theme: a white interface and a map with BTC orange, ETH indigo and SOL purple" width="100%"><br>
      <b>Chain colours</b><br>
      Every coin and network keeps its own colour on a quiet white interface. Light and dark.
    </td>
    <td width="33%" valign="top">
      <img src="docs/assets/themes/candy-brutal.png" alt="Portfolio on Mac in the Candy brutal theme: a pink total card, pastel map blocks, thick black outlines and hard offset shadows" width="100%"><br>
      <b>Candy brutal</b><br>
      Pink, lime and sky blue, thick black outlines, hard offset shadows. Light and dark.
    </td>
    <td width="33%" valign="top">
      <img src="docs/assets/themes/riso-zine.png" alt="Portfolio on Mac in the Riso zine theme: warm paper, a hot pink BTC block, blue ETH and a yellow SOL block" width="100%"><br>
      <b>Riso zine</b><br>
      Fluorescent pink, federal blue and yellow, overprinted on warm paper. Light only.
    </td>
  </tr>
  <tr>
    <td width="33%" valign="top">
      <img src="docs/assets/themes/heatmap.png" alt="Portfolio on Mac in the Heatmap theme, dark: bright map blocks on a dark frame" width="100%"><br>
      <b>Heatmap</b><br>
      Block size is value, block colour is the coin. Dark frame, bright blocks. Light and dark.
    </td>
    <td width="33%" valign="top">
      <img src="docs/assets/themes/pixel.png" alt="Portfolio on Mac in the Pixel theme: pixel type for figures, a yellow total card, primary-colour blocks and hard square shadows" width="100%"><br>
      <b>Pixel</b><br>
      Pixel type for figures and labels, primary-colour blocks, hard square shadows. Light and dark.
    </td>
    <td width="33%" valign="top">
      <img src="docs/assets/themes/acid.png" alt="Portfolio on Mac in the Acid theme: near-black with one electric lime accent" width="100%"><br>
      <b>Acid</b><br>
      Near-black with one electric lime. Chain colours appear only on token marks. Dark only.
    </td>
  </tr>
</table>

Choose a theme in **Settings → Theme**; the app restyles without a relaunch. Previews are in [`docs/design/themes.html`](docs/design/themes.html).

<p align="center">
  <img src="docs/assets/iphone-themes.png" alt="Six iPhone screens of one synthetic portfolio, one per theme: Chain colours, Candy brutal, Riso zine, Heatmap, Pixel and Acid. Each shows the total value, a scan warning, the view switcher and the start of a map." width="100%">
  <br>
  <sub>The same six themes on iPhone.</sub>
</p>

### 14 views

<p align="center">
  <img src="docs/assets/views-14.png" alt="A gallery of the 14 views, rendered from a synthetic portfolio in several themes: Map, Ring, Strip, Grid, Bubbles, Rings in rings, List, Flow, Atlas map, Over time, What changed, Slope, Concentration and Calendar. A last tile lists the group-by choices: Asset, Network, Wallet or exchange, State, Type." width="100%">
</p>

Every view works with every theme. Most take a **group by** choice: Asset, Network, Wallet or exchange, State, or Type. State is liquid, staked, unbonding, rewards, or on an exchange.

<details>
<summary>What each of the 14 views shows</summary>

| View | Shows |
| --- | --- |
| Map | Treemap. Each block's area is its share of the portfolio. |
| Ring | Donut with the total in the middle and a legend. |
| Strip | One bar split by share. |
| Grid | 100 squares, one per percent. |
| Bubbles | Circles sized by value. |
| Rings in rings | Two rings. The outer ring splits each inner slice by a second grouping. |
| List | One row per slice, largest first, with share and value. Coins without a price come last. |
| Flow | Wallets and exchanges on the left, coins in the middle, states on the right. |
| Atlas map | Voronoi map. Each cell's area is its value. |
| Over time | Value across your saved scans, stacked by group. |
| What changed | The change between the latest two scans, split into price moves and coins arriving or leaving. |
| Slope | Each coin's rank in an earlier scan and now. |
| Concentration | How much sits in the largest group, and how many equal-sized holdings the portfolio behaves like. |
| Calendar | One square per day, green or red by that day's change. Days without a scan stay empty. |

The history views (Over time, What changed, Slope, Calendar) need saved scans. When two scans read different wallets or exchanges, these views cut the chart, mark the break, or say the comparison is not like for like.

</details>

### Coin widgets

<table>
  <tr>
    <td valign="top">
      Open a coin to see:
      <ul>
        <li><b>State strip</b>: how much is liquid, staked, unbonding, rewards, or on an exchange.</li>
        <li><b>Unlock timeline</b>: when unbonding amounts become spendable.</li>
        <li><b>Change</b>: why the coin's value moved since the last comparable scan, price or coins.</li>
        <li><b>Custody</b>: how much you hold yourself and how much sits on exchanges.</li>
        <li><b>Amount history</b>: the coin amount, not the dollar value, across saved scans.</li>
      </ul>
      The picture shows ATOM on Mac: 24.79 ATOM unbonding until Nov 16, with the other four widgets under it.
    </td>
    <td width="44%" valign="top">
      <img src="docs/assets/coin-widgets.png" alt="ATOM detail on Mac in the Candy brutal theme: a state strip with liquid, staked, unbonding and rewards, an unlock timeline for 24.79 ATOM free on Nov 16, a map grouped by state, a change card (+$55.10 since Nov 3), a custody card (100% self-custody) and the ATOM amount over time" width="100%">
    </td>
  </tr>
</table>

### Also included

USD pricing, BTC-relative fiat conversion, snapshots, dust filtering, CSV and JSON export, and a recovery kit for restoring on a new device. If a provider fails, the scan keeps what it read and shows a warning. It does not report a partial result as complete.

The review set of screenshots (Mac, iPhone and iPad, all six themes) is in [`docs/design/screenshots`](docs/design/screenshots). All of it is rendered from a synthetic portfolio.

## Architecture at a glance

```mermaid
flowchart LR
  subgraph providers["Providers, read only"]
    chain["Chain RPC and REST<br/>20 networks"]
    ex["Exchanges<br/>Binance, Coinbase, Kraken<br/>read-only API keys"]
    cg["CoinGecko<br/>USD prices"]
  end
  subgraph core["AddressAtlasCore"]
    scan["Scanners and price client<br/>balances, staking, unbonding, rewards"]
  end
  appstate["Shared state layer<br/>scan orchestration, snapshots, export"]
  subgraph store["Encrypted local store"]
    db[("SQLite<br/>one AES-256-GCM document")]
    kc["Keychain<br/>this-device-only key"]
  end
  subgraph apps["SwiftUI apps"]
    mac["Mac"]
    ios["iPhone and iPad"]
    theme["Theme engine<br/>6 themes, 14 views, coin widgets"]
  end
  icloud[("iCloud private database<br/>encrypted copy")]

  chain --> scan
  ex --> scan
  cg --> scan
  scan --> appstate
  appstate <--> db
  kc -.->|"unlocks"| db
  appstate --> mac
  appstate --> ios
  mac --- theme
  ios --- theme
  appstate <-.->|"manual save and restore"| icloud
```

- **No Address Atlas server.** The apps talk to the providers directly and to iCloud only if you save a copy. Providers see the addresses you scan; see [Privacy](#privacy).
- **One shared core.** The Mac package holds `AddressAtlasCore` (model, scanners, encryption, recovery, export, iCloud client), the shared state layer, the theme engine and the charts. The iOS app compiles the same sources and adds its own screens.
- **One encrypted document.** The whole portfolio is saved as one AES-256-GCM document in a local SQLite database. Keys for separate purposes are derived from one random portfolio key, which the Keychain keeps on this device only.
- **Manual iCloud copy.** Save and restore are explicit. Nothing merges in the background.

Architecture rules and the full verification gate are in [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md).

## Coverage

20 networks, from the native [chain registry](native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/ChainRegistry.swift).

| Source | What is read |
| --- | --- |
| **EVM:** Ethereum, Base, Arbitrum One, Optimism, Polygon PoS, BNB Chain, Avalanche C-Chain, Gnosis Chain, Linea, Mantle, Scroll, ZKsync Era | Native balance and registered ERC-20 tokens |
| **Bitcoin** | Native balance |
| **Solana** | SOL, registered SPL tokens, and stake accounts |
| **TRON** | TRX and registered TRC20 tokens |
| **XRP Ledger** | XRP and positive issued-currency trustlines |
| **Cosmos:** Cosmos Hub, Osmosis, Celestia, Stride | Liquid, delegated (staked), unbonding, and claimable reward balances in the chain's own coin |
| **Exchanges:** Binance, Coinbase Advanced Trade, Kraken | Account balances only, through read-only API keys |

You can add custom ERC-20, SPL, and TRC20 tokens. Up to 100 enabled custom tokens are scanned.

<details>
<summary>How unbonding and stake accounts are read</summary>

- **Cosmos:** unbonding delegations are read with their completion time. Each distinct completion time becomes its own holding, so a holding's unlock date is exact for its whole amount. Past 20 distinct times, the later ones are combined under the earliest of their dates, with a warning. An entry without a usable completion time is counted without a date, with a warning.
- **Solana:** stake accounts are read with `getProgramAccounts` and classified by the current epoch. Active and activating stake counts as staked. Stake that is cooling down counts as unbonding, with no unlock date because Solana does not publish one. Stake that has finished cooling down but is not withdrawn yet counts as staked, with a warning. Only accounts your address can withdraw are counted.
- Many free Solana RPC endpoints reject `getProgramAccounts`. The scan then warns that staked and unbonding SOL may be missing and still returns your SOL balance and tokens.

</details>

## Build from source

### Try it with a public wallet

You need macOS 14 or newer, full Xcode installed and opened once, and an internet connection. No account, exchange API key, Node.js, Docker, or iCloud setup is needed.

1. Run `xcodebuild -version`. If it reports Command Line Tools, select Xcode in **Xcode → Settings → Locations → Command Line Tools** and try again.
2. Build and open the app:

   ```bash
   git clone https://github.com/girginomer10/address-atlas.git
   cd address-atlas/native/AddressAtlasMac
   ./check-toolchain.sh
   ./build-mac-app.sh
   open "dist/Address Atlas.app"
   ```

3. Open **Wallets**, paste this public Bitcoin address, and choose **Add wallet**:

   ```text
   1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa
   ```

4. Open **Portfolio** and choose **Scan**. When it finishes, open **Assets** and search for **BTC**. You should see a Bitcoin holding. Balances and prices change with live provider data. If a provider is unavailable, the app shows a warning; scan again later.
5. Close and reopen the app. The wallet and snapshot should still be there. You can remove the wallet in **Wallets** and the snapshot in **History**.

This is a local build with an ad-hoc signature. For iPhone, see [iPhone and iPad](#iphone-and-ipad).

### Mac

You need macOS 14 or newer and a Swift 5.10 toolchain. XCTest needs full Xcode.

```bash
cd native/AddressAtlasMac
./check-toolchain.sh
swift run AddressAtlasMac
```

To build a universal app bundle:

```bash
./build-mac-app.sh
open "dist/Address Atlas.app"
```

Local builds use the hardened runtime and an ad-hoc signature. They are not for distribution. The [Mac app guide](native/AddressAtlasMac/README.md) covers signing, storage, and packaging.

### iPhone and iPad

You need full Xcode selected with `xcode-select` and an iOS 17 or newer simulator. Command Line Tools cannot build iOS apps. CI uses Xcode 26.5. The Xcode project is committed, so `xcodegen` is only needed after editing `native/AddressAtlasiOS/project.yml`.

Open the project, select the **AddressAtlasiOS** scheme and an iPhone simulator, and run:

```bash
open native/AddressAtlasiOS/AddressAtlasiOS.xcodeproj
```

Add the example address above from the first screen or from **Sources** (the **+** button), open **Portfolio**, and tap **Scan**. Wallets and scans work without iCloud.

From Terminal, boot a simulator first, then:

```bash
./native/AddressAtlasiOS/build-ios-app.sh --simulator --install-booted
```

This builds, installs, and launches on the booted simulator with the ad-hoc signature that local Keychain access needs. `--unsigned` only checks that the code compiles; an unsigned build cannot unlock the local portfolio. The `npm run native:ios:*` scripts do the same for contributors. Node.js is not needed for either app.

The iOS App Store Connect record exists, and build 0.2.0 (175) was submitted to TestFlight Beta App Review on 2026-11-05; the evidence is in the [November 5 release checkpoint](app-store/README.md#release-checkpoint--november-5-2026). Physical-device acceptance is not verified. The [iOS app guide](native/AddressAtlasiOS/README.md) covers versioning, signing, and entitlements.

### Test

The full local gate is in [Development Notes](docs/DEVELOPMENT.md). Run the part that matches your change:

```bash
# Native Mac app (needs full Xcode)
cd native/AddressAtlasMac
swift test

# Native iOS app (needs full Xcode; compile only, no signing identity)
cd "$(git rev-parse --show-toplevel)"
npm run native:ios:build:unsigned

# Web and sync service
npm test
npm run typecheck
npm run build
```

GitHub Actions also checks repository hygiene, dependency security, server behavior, native tests, the iOS simulator build and bundle, production operations, and release rules.

## Privacy

Address Atlas is not anonymous. Reading a public blockchain means asking a provider about an address.

| Who | What they get |
| --- | --- |
| Your device (Mac, iPhone, or iPad) | Your portfolio, saved as one AES-256-GCM encrypted document in a local SQLite database |
| Device Keychain | The random encryption key, stored so that it stays on this device |
| Chain RPC and REST providers | The public addresses and requests needed to scan |
| Exchanges | Signed, read-only balance requests, sent directly from the app |
| CoinGecko | Asset and fiat-rate lookups. No exchange API keys and no portfolio data. |
| iCloud (CloudKit) | If you save a copy: an encrypted copy of the portfolio in your private database. A second key travels through iCloud Keychain. |

There is no Address Atlas account and no Address Atlas backup server. iCloud transfers are manual: you save and restore, and nothing merges in the background.

Share-safer CSV and JSON exports leave out addresses, labels, exact balances, and history, and group the rest into ranges. They show less but are not anonymous. Full exports include all of it, behind a warning. Neither kind is a portfolio backup.

Full details are in [PRIVACY.md](PRIVACY.md). Report vulnerabilities privately; see [.github/SECURITY.md](.github/SECURITY.md).

## Project layout

- [`native/AddressAtlasMac`](native/AddressAtlasMac) is the macOS app. It also holds `AddressAtlasCore` (portfolio model, scanners, encryption, recovery, export, iCloud client) and the shared state layer, design system, themes, and charts.
- [`native/AddressAtlasiOS`](native/AddressAtlasiOS) is the iPhone and iPad app. It compiles `AddressAtlasCore` and the shared sources from the Mac package and adds its own screens. See the [iOS app guide](native/AddressAtlasiOS/README.md).
- [`docs/design`](docs/design) holds the theme and view references and the review screenshots. [`docs/assets`](docs/assets) holds the images on this page and the script that composes them from those screenshots.
- The root Next.js service and [`server/sync`](server/sync) are older sync code. The apps no longer use them. See [Legacy sync service](#legacy-sync-service).
- [`docs/ICLOUD.md`](docs/ICLOUD.md): iCloud setup, the private record schema, and the two-device release test. Real iCloud transfer needs an Apple-signed build with iCloud enabled.
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md): architecture rules and the full verification gate.
- [`docs/OPERATIONS.md`](docs/OPERATIONS.md) and [`docs/RELEASE_CHECKLIST.md`](docs/RELEASE_CHECKLIST.md): operations and signed releases.
- [`docs/handoff`](docs/handoff) and [`memory`](memory): the dated session log and the curated decision notes.

## Legacy sync service

The apps no longer connect to the root Next.js service or [`server/sync`](server/sync). It is a self-hostable service for passkey sync accounts and encrypted portfolio snapshots, kept for reference and for older data.

<details>
<summary>Run it locally</summary>

You need Node.js `>=22.17 <23`, npm `>=10.9.2 <11`, and Docker with Compose:

```bash
cd "$(git rev-parse --show-toplevel)"
npm ci
install -m 0600 .env.example .env
node -e '
  const fs = require("node:fs"), crypto = require("node:crypto"), path = ".env";
  const source = fs.readFileSync(path, "utf8");
  fs.writeFileSync(path, source.replace(
    "replace-with-a-long-random-secret",
    crypto.randomBytes(32).toString("base64url"),
  ));
'
npm run sync:db:up
npm run dev
```

This creates `.env` with owner-only permissions and replaces the session-secret placeholder, which the service rejects. Do not reuse published placeholders or commit `.env`. Deploy, backup, restore, and monitoring steps are in the [sync service guide](server/sync/README.md).

</details>

## How it was built

Ömer Girgin designed Address Atlas and directed the work. He chose the product boundary (read-only, no seed phrases, no signing, local-first), the privacy model, and the direction of the six-theme redesign, and he reviewed every change. AI coding agents wrote much of the code, in separate sessions. Each session has a dated entry in [`docs/handoff`](docs/handoff) that says which agent did what; both tools touched both apps at different times.

| Agent | Main work |
| --- | --- |
| OpenAI Codex (GPT-5.6) | The first native Mac app, the sync service, threat modeling of the read-only and encryption boundaries, hardening and adversarial review, and the first App Store Connect and TestFlight setup. |
| Anthropic Claude (Claude Code) | Review audits and fixes, the start of the iPhone and iPad app and its October polish passes, and the November redesign: the theme engine, the 14 views, the coin widgets, Cosmos unbonding and Solana stake scanning, and the plain-language copy. The November redesign and the November 5 TestFlight build were done with Claude Opus 5.5 directing Claude Sonnet 5.5 agents. |

Neither tool is part of the app. Address Atlas has no AI runtime dependency and does not send portfolio data to an AI provider. A human reviewed every suggested change, and the repository tests (more than 850 XCTest cases in the native packages, plus the legacy service's tests) and CI run on all of it, whichever agent wrote it.

## Contributing

Start with [CONTRIBUTING.md](CONTRIBUTING.md), then open a focused issue or pull request. The boundary does not change: no custody, no seed phrases, no signing, no trading, no withdrawal permissions.

Do not report security issues in public issues. Use [GitHub private vulnerability reporting](https://github.com/girginomer10/address-atlas/security/advisories/new). For help, see [SUPPORT.md](SUPPORT.md).

## License

[MIT](LICENSE). The native apps bundle fonts under the SIL Open Font License; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
