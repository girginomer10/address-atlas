// Debug-only demo data for simulator screenshots and manual review.
//
// The whole file is inside `#if DEBUG`, so a Release build contains none of
// it (no symbol, no launch-argument parsing, no fixture strings). The
// fixture never touches the person's vault: `AppState` is created with a
// throw-away directory under `NSTemporaryDirectory()` and an in-memory key,
// the synthetic document is then placed into memory only, and the network
// client always fails, so a scan cannot reach any provider.
//
// Launch arguments (all optional):
//   -AtlasDemoFixture full|empty      boot on the synthetic vault, or an empty one
//   -AtlasDemoTab portfolio|assets|sources|history|settings
//   -AtlasDemoRoute coin:ATOM|snapshot:latest|iCloud|export   push onto that tab
//   -AtlasDemoSegment wallets|exchanges|holdings|tokens        Sources list
//   -AtlasDemoAction addWallet|connectExchange|addManualHolding|addCustomToken
//   -AtlasDemoSliceFilter network:ethereum|state:staked        Assets filter
//   -AtlasDemoUnlock error|damaged|quarantine   with -AtlasDemoFixture empty: show the unlock screen in that state
//   -AtlasDemoScrollY 700             scroll the page by that many points (iOS 18+ simulators)
// Theme and appearance use the normal preference keys, for example
// `-display.theme.v1 candy -display.appearanceMode.v1 dark`.
#if DEBUG
  import AddressAtlasCore
  import Foundation
  import SwiftUI

  enum DemoFixture {
    enum Mode: String {
      case full
      case empty
    }

    static var mode: Mode? {
      guard let raw = UserDefaults.standard.string(forKey: "AtlasDemoFixture") else { return nil }
      switch raw.lowercased() {
      case "empty": return .empty
      case "full", "1", "yes", "true": return .full
      default: return nil
      }
    }

    static var isEnabled: Bool { mode != nil }

    private static func argument(_ key: String) -> String? {
      UserDefaults.standard.string(forKey: key)
    }

    // MARK: State

    /// Offline, throw-away `AppState`: temporary directory, in-memory key.
    @MainActor
    static func makeState() -> AppState {
      let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appending(path: "AddressAtlasDemo-\(UUID().uuidString)", directoryHint: .isDirectory)
      return AppState(
        httpClient: OfflineHTTPClient(),
        keyStore: DemoKeyStore(),
        appSupportDirectoryOverride: directory
      )
    }

    /// Replaces the (empty, temporary) vault's document with the synthetic
    /// portfolio. In memory only.
    @MainActor
    static func seed(_ state: AppState) {
      guard state.isUnlocked, let mode, mode == .full else { return }
      state.document = document(now: Date())
      state.notice = ""
      state.error = ""
    }

    private struct OfflineHTTPClient: HTTPClient {
      func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
      }
    }

    private final class DemoKeyStore: VaultKeyStore, @unchecked Sendable {
      private let lock = NSLock()
      private var key: Data?

      func loadVaultKey() throws -> Data? { lock.withLock { key } }
      func saveVaultKey(_ key: Data) throws { lock.withLock { self.key = key } }
      func saveVaultKeyIfAbsent(_ key: Data) throws -> Data {
        lock.withLock {
          if let existing = self.key { return existing }
          self.key = key
          return key
        }
      }
      func deleteVaultKey() throws { lock.withLock { key = nil } }
    }

    // MARK: Launch navigation

    @MainActor
    static func applyLaunchNavigation(_ navigation: IOSNavigationModel, state: AppState) {
      if let tab = argument("AtlasDemoTab"), let section = AtlasSection(rawValue: tab) {
        navigation.selectedSection = section
      }
      if let route = argument("AtlasDemoRoute") {
        let parts = route.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "coin":
          if parts.count == 2 {
            navigation.paths[navigation.selectedSection] = [
              .coin(CoinIdentity.key(forSymbol: parts[1]))
            ]
          }
        case "snapshot":
          if let id = state.latestScan?.id {
            navigation.paths[navigation.selectedSection] = [.snapshot(id)]
          }
        case "iCloud": navigation.paths[navigation.selectedSection] = [.iCloud]
        case "export": navigation.paths[navigation.selectedSection] = [.export]
        default: break
        }
      }
      if let filter = argument("AtlasDemoSliceFilter") {
        let parts = filter.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2, let grouping = PortfolioGrouping(rawValue: parts[0]) {
          navigation.assetsFilter = IOSAssetsFilter(
            grouping: grouping, key: parts[1], label: parts[1].capitalized)
        }
      }
      if let action = argument("AtlasDemoAction") {
        switch action {
        case "addWallet": navigation.pendingAction = .addWallet
        case "connectExchange": navigation.pendingAction = .connectExchange
        case "addManualHolding": navigation.pendingAction = .addManualHolding
        case "addCustomToken": navigation.pendingAction = .addCustomToken
        default: break
        }
      }
    }

    static var unlockPreviewMode: String? {
      UserDefaults.standard.string(forKey: "AtlasDemoUnlock")
    }

    static var scrollY: CGFloat {
      CGFloat(UserDefaults.standard.double(forKey: "AtlasDemoScrollY"))
    }

    static var sourcesSegment: SourcesSegment? {
      argument("AtlasDemoSegment").flatMap(SourcesSegment.init(rawValue:))
    }

    // MARK: Synthetic portfolio

    static let bitcoinAddress = "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
    static let evmAddress = "0x0000000000000000000000000000000000000001"
    static let savingsAddress = "0x0000000000000000000000000000000000000002"
    static let solanaAddress = "11111111111111111111111111111111"
    static let cosmosAddress = "cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22"
    static let krakenID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
    static let ledgerID = UUID(uuidString: "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee")!

    private static let dayCount = 42
    private static let sourceChangeDay = 20
    private static let unstakeDay = 27
    private static let skippedDays: Set<Int> = [3, 6, 12, 17, 24, 25, 33, 38]

    /// Days with a scan, oldest first (day index, hour of the scan).
    private static var schedule: [(day: Int, hour: Int)] {
      var result: [(Int, Int)] = []
      for day in 0..<dayCount where !skippedDays.contains(day) {
        result.append((day, 0))
        if day % 10 == 0 && day > 0 { result.append((day, 10)) }
      }
      return result
    }

    private static func price(_ symbol: String, day: Int) -> Double {
      let d = Double(day)
      switch symbol {
      case "BTC": return 66_000 * (1 + 0.030 * d / 41) + 900 * sin(d * 0.45)
      case "ETH": return 3_050 * (1 + 0.050 * d / 41) + 70 * sin(d * 0.9 + 1)
      case "SOL": return 138 * (1 - 0.040 * d / 41) + 6 * sin(d * 0.6 - 2.3)
      case "ATOM": return 6.5 * (1 + 0.040 * d / 41) + 0.25 * sin(d * 0.7 + 3)
      case "LINK": return 15.2 * (1 + 0.300 * d / 41) + 0.5 * sin(d * 0.8)
      case "ARB": return 0.82 * (1 - 0.050 * d / 41) + 0.03 * sin(d * 1.1)
      case "DOGE": return 0.16 * (1 + d / 41) + 0.012 * sin(d * 0.5 + 1.74)
      case "UNI": return 7.5 + 0.4 * sin(d * 0.3)
      case "OP": return 1.9 + 0.1 * sin(d * 0.4)
      default: return 1
      }
    }

    private static func wallet(
      _ symbol: String, amount: Double, day: Int, source: AssetSource = .native,
      family: ChainFamily, chainId: String, chainName: String, address: String, label: String,
      unlocksAt: Date? = nil, priced: Bool = true
    ) -> TrackedAsset {
      let unit = priced ? price(symbol, day: day) : 0
      let explorer =
        ChainRegistry.allChains.first(where: { $0.id == chainId })?.explorerURL(for: address)
        .absoluteString ?? ""
      return TrackedAsset(
        id: "\(address)-\(chainId)-\(symbol)-\(source.rawValue)", address: address,
        chainId: chainId, chainName: chainName, family: family, symbol: symbol,
        name: symbol == "ETH" || symbol == "BTC" || symbol == "SOL" || symbol == "ATOM"
          ? "\(chainName)" : symbol,
        amount: amount, priceUsd: unit, valueUsd: unit * amount,
        pricingStatus: priced ? .priced : .unpriced, change24h: priced ? change(symbol, day) : nil,
        explorerUrl: explorer, source: source, walletLabel: label, unlocksAt: unlocksAt)
    }

    private static func change(_ symbol: String, _ day: Int) -> Double {
      let today = price(symbol, day: day)
      let before = price(symbol, day: max(0, day - 1))
      guard before > 0 else { return 0 }
      return (today - before) / before * 100
    }

    private static func kraken(_ symbol: String, amount: Double, day: Int) -> TrackedAsset {
      let unit = price(symbol, day: day)
      return TrackedAsset(
        id: "\(krakenID.uuidString)-kraken-\(symbol)", address: "Kraken", chainId: "kraken",
        chainName: "Kraken", family: .exchange, symbol: symbol, name: symbol, amount: amount,
        priceUsd: unit, valueUsd: unit * amount, pricingStatus: .priced,
        change24h: change(symbol, day), source: .exchange, walletLabel: "Kraken",
        exchangeId: krakenID, exchangeProvider: .kraken)
    }

    private static func ledger() -> TrackedAsset {
      let unit = price("BTC", day: dayCount - 1)
      return TrackedAsset(
        id: "manual-\(ledgerID.uuidString)", address: "Ledger", chainId: "manual-hardware",
        chainName: "Ledger Nano", family: .exchange, symbol: "BTC", name: "Bitcoin",
        amount: 0.1, priceUsd: unit, valueUsd: unit * 0.1, pricingStatus: .priced,
        source: .exchange)
    }

    private static func holdings(day: Int, unlockDate: Date) -> [TrackedAsset] {
      let unstaked = day >= unstakeDay
      let baseEth = day >= dayCount - 1 ? 1.0094 : 1.0
      var holdings: [TrackedAsset] = [
        wallet(
          "BTC", amount: 0.362, day: day, family: .bitcoin, chainId: "bitcoin",
          chainName: "Bitcoin", address: bitcoinAddress, label: "Cold storage"),
        kraken("BTC", amount: 0.05, day: day),
        ledger(),
        wallet(
          "ETH", amount: 2.6, day: day, family: .evm, chainId: "ethereum",
          chainName: "Ethereum", address: evmAddress, label: "Main"),
        wallet(
          "ETH", amount: baseEth, day: day, family: .evm, chainId: "base", chainName: "Base",
          address: evmAddress, label: "Main"),
        kraken("ETH", amount: 0.5, day: day),
        wallet(
          "LINK", amount: 110, day: day, source: .erc20, family: .evm, chainId: "ethereum",
          chainName: "Ethereum", address: evmAddress, label: "Main"),
        wallet(
          "ARB", amount: 900, day: day, source: .erc20, family: .evm, chainId: "arbitrum",
          chainName: "Arbitrum One", address: evmAddress, label: "Main"),
        wallet(
          "SOL", amount: 12.5, day: day, family: .solana, chainId: "solana",
          chainName: "Solana", address: solanaAddress, label: "Phantom"),
        wallet(
          "SOL", amount: 26, day: day, source: .staked, family: .solana, chainId: "solana",
          chainName: "Solana", address: solanaAddress, label: "Phantom"),
        wallet(
          "ATOM", amount: 4.2, day: day, family: .cosmos, chainId: "cosmoshub",
          chainName: "Cosmos Hub", address: cosmosAddress, label: "Keplr"),
        wallet(
          "ATOM", amount: unstaked ? 280 : 304.79, day: day, source: .staked, family: .cosmos,
          chainId: "cosmoshub", chainName: "Cosmos Hub", address: cosmosAddress, label: "Keplr"),
        wallet(
          "ATOM", amount: min(0.2 + 0.025 * Double(day), 1.21), day: day, source: .rewards,
          family: .cosmos, chainId: "cosmoshub", chainName: "Cosmos Hub",
          address: cosmosAddress, label: "Keplr"),
        kraken("USDC", amount: 920.05, day: day),
        kraken("DOGE", amount: 2_400, day: day),
      ]
      if (8...33).contains(day) {
        holdings.append(
          wallet(
            "UNI", amount: 80, day: day, source: .erc20, family: .evm, chainId: "ethereum",
            chainName: "Ethereum", address: evmAddress, label: "Main"))
      }
      if day >= 31 {
        holdings.append(
          wallet(
            "OP", amount: 600, day: day, source: .erc20, family: .evm, chainId: "optimism",
            chainName: "Optimism", address: evmAddress, label: "Main"))
      }
      if unstaked {
        holdings.append(
          wallet(
            "ATOM", amount: 24.79, day: day, source: .unbonding, family: .cosmos,
            chainId: "cosmoshub", chainName: "Cosmos Hub", address: cosmosAddress,
            label: "Keplr", unlocksAt: unlockDate))
      }
      if day >= sourceChangeDay {
        holdings.append(
          wallet(
            "ETH", amount: 1.5, day: day, family: .evm, chainId: "ethereum",
            chainName: "Ethereum", address: savingsAddress, label: "Savings"))
        holdings.append(
          wallet(
            "USDC", amount: 500, day: day, source: .erc20, family: .evm, chainId: "ethereum",
            chainName: "Ethereum", address: savingsAddress, label: "Savings"))
        holdings.append(
          wallet(
            "MEME", amount: 1_000_000, day: day, source: .erc20, family: .evm,
            chainId: "base", chainName: "Base", address: savingsAddress, label: "Savings",
            priced: false))
      }
      return holdings
    }

    @MainActor
    static func document(now: Date) -> VaultDocument {
      // The last scan ran three hours ago; the others follow the schedule.
      let lastScan = now.addingTimeInterval(-3 * 3_600)
      let lastIndex = Double(dayCount - 1)
      func date(day: Int, hour: Int) -> Date {
        let whole = lastScan.addingTimeInterval(-(lastIndex - Double(day)) * 86_400)
        return Date(timeIntervalSince1970: (whole.timeIntervalSince1970 + Double(hour) * 3_600).rounded())
      }
      // The unbonding ATOM becomes spendable 12 days from now.
      let unlockDate = Date(
        timeIntervalSince1970: (now.timeIntervalSince1970 + 12 * 86_400).rounded())

      let entries = schedule.suffix(AppState.maximumStoredScanRuns)
      var runs: [ScanRunRecord] = []
      for entry in entries {
        let items = holdings(day: entry.day, unlockDate: unlockDate)
        // A scan before the second wallet existed cannot hold it.
        let walletCount = entry.day >= sourceChangeDay ? 5 : 4
        runs.append(
          ScanRunRecord(
            id: UUID(
              uuidString: String(format: "00000000-0000-4000-8000-%012d", entry.day * 100 + entry.hour))!,
            generatedAt: date(day: entry.day, hour: entry.hour),
            totalUsd: items.filter { $0.pricingStatus == .priced }.map(\.valueUsd).reduce(0, +),
            inputCount: walletCount,
            holdings: items,
            warnings: entry.day >= sourceChangeDay && entry.day == dayCount - 1
              ? ["MEME on Base has no price, so it is left out of the total."] : []))
      }

      let firstDate = runs.first?.generatedAt ?? now
      let created = firstDate.addingTimeInterval(-86_400)
      let wallets = [
        WalletRecord(
          label: "Cold storage", address: bitcoinAddress, chainKind: .bitcoin,
          createdAt: created, updatedAt: created),
        WalletRecord(
          label: "Main", address: evmAddress, chainKind: .evm, createdAt: created,
          updatedAt: created),
        WalletRecord(
          label: "Savings", address: savingsAddress, chainKind: .evm,
          createdAt: date(day: sourceChangeDay, hour: 0).addingTimeInterval(-3_600),
          updatedAt: created),
        WalletRecord(
          label: "Phantom", address: solanaAddress, chainKind: .solana, createdAt: created,
          updatedAt: created),
        WalletRecord(
          label: "Keplr", address: cosmosAddress, chainKind: .cosmos, createdAt: created,
          updatedAt: created),
      ]
      let envelope = EncryptedVaultEnvelope(
        keyId: "demo", nonce: "demo", ciphertext: "demo", checksum: "demo", createdAt: created)
      let exchanges = [
        ExchangeConnectionRecord(
          id: krakenID, provider: .kraken, label: "Kraken", encryptedCredentials: envelope,
          credentialScopeAssurance: .verifiedReadOnly, status: .ok,
          lastTestedAt: lastScan, lastSyncAt: lastScan, createdAt: created, updatedAt: created)
      ]
      let manual = [
        ManualHoldingRecord(
          id: ledgerID, label: "Ledger", provider: "hardware", customVenue: "Ledger Nano",
          symbol: "BTC", name: "Bitcoin", amount: 0.1,
          priceUsd: price("BTC", day: dayCount - 1),
          valueUsd: price("BTC", day: dayCount - 1) * 0.1, generatedAt: created,
          createdAt: created, updatedAt: created)
      ]
      return VaultDocument(
        preferences: Preferences(hideDust: true, dustThreshold: 5, autoRefresh: true),
        wallets: wallets,
        manualHoldings: manual,
        exchangeConnections: exchanges,
        scanRuns: runs,
        updatedAt: now)
    }
  }

  /// Scrolls a page to the offset of `-AtlasDemoScrollY` so a screenshot can
  /// show content below the first screen. Debug builds on iOS 18+ only.
  struct DemoScrollModifier: ViewModifier {
    func body(content: Content) -> some View {
      if #available(iOS 18.0, *), DemoFixture.scrollY > 0 {
        Scrolled(content: content)
      } else {
        content
      }
    }

    @available(iOS 18.0, *)
    private struct Scrolled<Content: View>: View {
      @State private var position = ScrollPosition(y: DemoFixture.scrollY)
      var content: Content

      var body: some View {
        content.scrollPosition($position)
      }
    }
  }

  /// The unlock screen with the shared state set into one of its recovery
  /// states, for screenshots only.
  struct DemoUnlockPreview: View {
    @EnvironmentObject private var state: AppState
    var mode: String

    var body: some View {
      UnlockScreen()
        .task {
          switch mode {
          case "error":
            state.error = "The encryption key for this device isn't available in Keychain."
          case "damaged":
            state.damagedVaultRecoveryAvailability = .validatedRollbackCheckpoint
            state.error = "Your saved portfolio on this device is damaged, but an earlier copy was checked and is intact."
          case "quarantine":
            state.damagedVaultRecoveryAvailability = .quarantineOnly
            state.error = "Your saved portfolio on this device is damaged and no earlier copy is available."
          default: break
          }
        }
    }
  }
#endif
