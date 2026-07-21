import AddressAtlasCore
import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import AddressAtlasMac

final class AtlasDesignSystemTests: XCTestCase {
  @MainActor
  func testLaunchLayoutsProduceOnlyFiniteNonnegativeAppKitGeometry() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultKey = try VaultCrypto().generateVaultKey()
    let store = try EncryptedSQLiteVaultStore(
      path: directory.appending(path: "vault.sqlite"),
      vaultKey: vaultKey
    )
    _ = try store.load()
    let unlockedState = AppState(testStore: store, document: VaultDocument())

    assertValidLayout(
      UnlockView().environmentObject(AppState()),
      size: NSSize(width: 800, height: 560),
      context: "locked launch"
    )
    assertValidLayout(
      MainView().environmentObject(unlockedState),
      size: NSSize(width: 900, height: 600),
      context: "unlocked launch"
    )
  }

  @MainActor
  func testEveryPrimaryProductScreenLaysOutAtMinimumSupportedWindowSize() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultKey = try VaultCrypto().generateVaultKey()
    let store = try EncryptedSQLiteVaultStore(
      path: directory.appending(path: "vault.sqlite"),
      vaultKey: vaultKey
    )
    _ = try store.load()
    let state = AppState(testStore: store, document: VaultDocument())
    let populatedState = AppState(
      testStore: store,
      document: try populatedDocument(vaultKey: vaultKey)
    )
    let screens: [(String, AnyView)] = [
      ("portfolio", AnyView(PortfolioView().environmentObject(state))),
      ("wallets", AnyView(WalletsView().environmentObject(state))),
      ("assets", AnyView(AssetsView().environmentObject(state))),
      ("tokens", AnyView(TokenAllowlistView().environmentObject(state))),
      ("snapshots", AnyView(SnapshotsView().environmentObject(state))),
      ("exchanges", AnyView(ExchangesView().environmentObject(state))),
      ("sync", AnyView(SyncView().environmentObject(state))),
      ("export", AnyView(ExportView().environmentObject(state))),
      ("settings", AnyView(SettingsView().environmentObject(state))),
    ]

    for (name, screen) in screens {
      assertValidLayout(
        screen,
        size: NSSize(width: 900 - 238, height: 600),
        context: name
      )
    }

    let populatedScreens: [(String, AnyView)] = [
      ("portfolio-populated", AnyView(PortfolioView().environmentObject(populatedState))),
      ("wallets-populated", AnyView(WalletsView().environmentObject(populatedState))),
      ("assets-populated", AnyView(AssetsView().environmentObject(populatedState))),
      ("tokens-populated", AnyView(TokenAllowlistView().environmentObject(populatedState))),
      ("snapshots-populated", AnyView(SnapshotsView().environmentObject(populatedState))),
      ("exchanges-populated", AnyView(ExchangesView().environmentObject(populatedState))),
    ]
    for (name, screen) in populatedScreens {
      assertValidLayout(
        screen,
        size: NSSize(width: 900 - 238, height: 600),
        context: name
      )
    }

    guard
      let capturePath = ProcessInfo.processInfo.environment["ADDRESS_ATLAS_UI_CAPTURE_DIR"],
      !capturePath.isEmpty
    else { return }

    let captureDirectory = URL(fileURLWithPath: capturePath, isDirectory: true)
    try FileManager.default.createDirectory(
      at: captureDirectory,
      withIntermediateDirectories: true
    )
    for (name, screen) in screens {
      let data = try XCTUnwrap(
        renderedPNG(
          screen.preferredColorScheme(.dark),
          size: NSSize(width: 1_000, height: 760),
          appearanceName: .darkAqua
        )
      )
      XCTAssertGreaterThan(data.count, 1_024)
      try data.write(to: captureDirectory.appending(path: "\(name).png"), options: .atomic)
    }
    if let compactAssets = populatedScreens.first(where: { $0.0 == "assets-populated" })?.1 {
      let data = try XCTUnwrap(
        renderedPNG(
          compactAssets.preferredColorScheme(.dark),
          size: NSSize(width: 900 - 238, height: 600),
          appearanceName: .darkAqua
        )
      )
      try data.write(
        to: captureDirectory.appending(path: "assets-compact.png"),
        options: .atomic
      )
    }
    for (name, screen) in populatedScreens {
      let data = try XCTUnwrap(
        renderedPNG(
          screen.preferredColorScheme(.dark),
          size: NSSize(width: 1_000, height: 760),
          appearanceName: .darkAqua
        )
      )
      XCTAssertGreaterThan(data.count, 1_024)
      try data.write(to: captureDirectory.appending(path: "\(name).png"), options: .atomic)
    }

    let shellData = try XCTUnwrap(
      renderedPNG(
        MainView()
          .environmentObject(state)
          .preferredColorScheme(.dark),
        size: NSSize(width: 1_200, height: 800),
        appearanceName: .darkAqua
      )
    )
    XCTAssertGreaterThan(shellData.count, 1_024)
    try shellData.write(to: captureDirectory.appending(path: "app-shell.png"), options: .atomic)

    let lightShellData = try XCTUnwrap(
      renderedPNG(
        MainView()
          .environmentObject(state)
          .preferredColorScheme(.light),
        size: NSSize(width: 1_200, height: 800),
        appearanceName: .aqua
      )
    )
    XCTAssertGreaterThan(lightShellData.count, 1_024)
    try lightShellData.write(
      to: captureDirectory.appending(path: "app-shell-light.png"),
      options: .atomic
    )
  }

  @MainActor
  func testAccessibilityAnnouncementsCoalesceDuplicateViewsButAllowFreshEvents() {
    var clock = 10.0
    var announcements: [(message: String, priority: Int)] = []
    let announcer = AtlasAccessibilityAnnouncer(
      duplicateCoalescingInterval: 0.75,
      now: { clock },
      poster: { message, priority in
        announcements.append((message, priority.rawValue))
      }
    )

    announcer.announceVisible("Vault saved.", kind: .notice)
    announcer.announceVisible("Vault saved.", kind: .notice)
    announcer.announceEvent("Vault saved.", kind: .notice)

    XCTAssertEqual(announcements.map(\.message), ["Status: Vault saved."])
    XCTAssertEqual(announcements.map(\.priority), [NSAccessibilityPriorityLevel.medium.rawValue])

    clock += 1
    announcer.announceEvent("Vault saved.", kind: .notice)
    announcer.clear(.notice)
    announcer.announceEvent("Vault saved.", kind: .notice)

    XCTAssertEqual(
      announcements.map(\.message),
      ["Status: Vault saved.", "Status: Vault saved.", "Status: Vault saved."]
    )
  }

  private func populatedDocument(vaultKey: Data) throws -> VaultDocument {
    let connectionID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    let encryptedCredentials = try ExchangeCredentialVault().seal(
      ExchangeCredentials(apiKey: "fixture-key", secret: "fixture-secret"),
      vaultKey: vaultKey,
      connectionId: connectionID
    )
    let ether = TrackedAsset(
      id: "sample-eth",
      address: "0x0000000000000000000000000000000000000001",
      chainId: "ethereum",
      chainName: "Ethereum",
      family: .evm,
      symbol: "ETH",
      name: "Ether",
      amount: 2.5,
      priceUsd: 3_200,
      valueUsd: 8_000,
      source: .native,
      walletLabel: "Main wallet"
    )
    let unpricedToken = TrackedAsset(
      id: "sample-token",
      address: "0x0000000000000000000000000000000000000002",
      chainId: "base",
      chainName: "Base",
      family: .evm,
      symbol: "NEW",
      name: "New Token",
      amount: 42,
      priceUsd: 0,
      valueUsd: 0,
      pricingStatus: .unpriced,
      source: .erc20,
      walletLabel: "Main wallet"
    )
    let scan = ScanRunRecord(
      generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      totalUsd: 8_000,
      inputCount: 2,
      holdings: [ether, unpricedToken],
      warnings: ["A price source was temporarily unavailable for one token."]
    )
    return VaultDocument(
      wallets: [
        WalletRecord(
          label: "Main wallet",
          address: "0x0000000000000000000000000000000000000001",
          chainKind: .evm
        )
      ],
      customTokens: [
        CustomTokenRecord(
          chainKind: .evm,
          chainId: "base",
          address: "0x0000000000000000000000000000000000000002",
          symbol: "NEW",
          name: "New Token",
          decimals: 18
        )
      ],
      manualHoldings: [
        ManualHoldingRecord(
          label: "Cold storage",
          provider: "manual",
          symbol: "BTC",
          name: "Bitcoin",
          amount: 0.25,
          priceUsd: 60_000,
          valueUsd: 15_000
        )
      ],
      exchangeConnections: [
        ExchangeConnectionRecord(
          id: connectionID,
          provider: .binance,
          label: "Binance main",
          encryptedCredentials: encryptedCredentials,
          credentialScopeAssurance: .verifiedReadOnly,
          status: .ok,
          lastSyncAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
      ],
      scanRuns: [scan]
    )
  }

  @MainActor
  func testAccessibilityAnnouncementsClearEmptyStateAndPrioritizeErrors() {
    var announcements: [(message: String, priority: Int)] = []
    let announcer = AtlasAccessibilityAnnouncer(
      now: { 20 },
      poster: { message, priority in
        announcements.append((message, priority.rawValue))
      }
    )

    announcer.announceEvent("  Storage failed.  ", kind: .error)
    announcer.announceEvent("   ", kind: .error)
    announcer.announceVisible("Storage failed.", kind: .error)

    XCTAssertEqual(
      announcements.map(\.message),
      ["Error: Storage failed.", "Error: Storage failed."]
    )
    XCTAssertEqual(
      announcements.map(\.priority),
      [NSAccessibilityPriorityLevel.high.rawValue, NSAccessibilityPriorityLevel.high.rawValue]
    )
  }

  @MainActor
  func testExportPreviewUsesBoundedNavigableRowsInsteadOfOneMonolithicAXValue() {
    let generated = "VOICEOVER_EXPORT_MARKER,{\"wallet\":\"visible\"}"
    let preview = ExportPreview(exportedPreview: generated)
    let model = preview.accessibilityModel

    XCTAssertEqual(preview.displayedText, generated)
    XCTAssertEqual(model.rows.map(\.content), [generated])
    XCTAssertEqual(model.rows.map(\.locationLabel), ["Line 1"])
    XCTAssertEqual(model.rows.map(\.accessibilityIdentifier), ["export-preview-row-1"])
    XCTAssertFalse(model.spokenSummary.contains(generated))
    XCTAssertLessThanOrEqual(
      model.accessibilitySummaryLabel.utf8.count,
      ExportPreviewAccessibilityModel.maximumSummaryByteCount
    )
    XCTAssertLessThanOrEqual(
      ExportPreviewAccessibilityModel.navigationHint.utf8.count,
      ExportPreviewAccessibilityModel.maximumSummaryByteCount
    )
    XCTAssertEqual(ExportPreview.contentAccessibilityIdentifier, "export-preview-content")
  }

  func testExportPreviewAXRowsBoundEveryValueAndPreserveNavigationOrder() {
    let veryLongUnicodeLine = String(repeating: "wallet-😀-", count: 12_000)
    let text = veryLongUnicodeLine + "\n\nfinal,row"
    let model = ExportPreviewAccessibilityModel(text: text)

    XCTAssertGreaterThan(model.rows.count, 3)
    XCTAssertEqual(model.sourceLineCount, 3)
    XCTAssertEqual(model.sourceByteCount, text.utf8.count)
    XCTAssertEqual(model.rows.map(\.id), Array(1...model.rows.count))
    XCTAssertEqual(Set(model.rows.map(\.accessibilityIdentifier)).count, model.rows.count)
    XCTAssertTrue(
      model.rows.allSatisfy {
        $0.accessibilityValue.utf8.count
          <= ExportPreviewAccessibilityModel.maximumNodeValueByteCount
      }
    )
    XCTAssertTrue(
      model.rows.allSatisfy {
        $0.locationLabel.utf8.count
          <= ExportPreviewAccessibilityModel.maximumNodeValueByteCount
      }
    )
    XCTAssertEqual(
      reconstructedPreview(from: model.rows, sourceLineCount: model.sourceLineCount),
      text
    )
    XCTAssertEqual(
      model.rows.first(where: { $0.sourceLine == 2 })?.accessibilityValue,
      "Empty line"
    )
  }

  func testExportPreviewCapsPathologicalAXNodeCountsAndDisclosesOmission() {
    let text = String(repeating: "\n", count: 10_000)
    let model = ExportPreviewAccessibilityModel(text: text)

    XCTAssertEqual(model.rows.count, ExportPreviewAccessibilityModel.maximumNavigableRowCount)
    XCTAssertTrue(model.didOmitContent)
    XCTAssertTrue(model.spokenSummary.contains("Showing the first"))
    XCTAssertTrue(model.spokenSummary.contains("Save the report"))
    XCTAssertLessThanOrEqual(
      model.accessibilitySummaryLabel.utf8.count,
      ExportPreviewAccessibilityModel.maximumSummaryByteCount
    )
  }

  @MainActor
  func testExportPreviewRendersARealNavigableTableWithOneRowPerBoundedNode() {
    let preview = ExportPreview(exportedPreview: "first\nsecond\nthird")
    let hostingView = NSHostingView(rootView: preview)
    hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    hostingView.layoutSubtreeIfNeeded()

    let table: NSTableView? = firstDescendant(of: NSTableView.self, in: hostingView)

    XCTAssertNotNil(table)
    // SwiftUI may back Table with NSTableView or NSOutlineView across macOS
    // releases; both roles retain row and column navigation.
    let role = table?.accessibilityRole()
    XCTAssertTrue(role == .table || role == .outline)
    XCTAssertEqual(table?.numberOfRows, preview.accessibilityModel.rows.count)
    XCTAssertEqual(table?.tableColumns.count, 2)
  }

  func testSecondaryTextMeetsNormalTextContrastOnBothPaperSurfaces() {
    let foreground = AtlasTheme.ink3RGB

    XCTAssertGreaterThanOrEqual(
      contrastRatio(foreground, AtlasTheme.paperRGB),
      4.5
    )
    XCTAssertGreaterThanOrEqual(
      contrastRatio(foreground, AtlasTheme.paper2RGB),
      4.5
    )
  }

  func testWarningTextMeetsNormalTextContrastOnBothPaperSurfaces() {
    XCTAssertGreaterThanOrEqual(
      contrastRatio(AtlasTheme.warningRGB, AtlasTheme.paperRGB),
      4.5
    )
    XCTAssertGreaterThanOrEqual(
      contrastRatio(AtlasTheme.warningRGB, AtlasTheme.paper2RGB),
      4.5
    )
  }

  func testPrimaryActionLabelMeetsNormalTextContrastInEveryAppearance() {
    for appearance in AtlasAppearanceVariant.allCases {
      let palette = AtlasTheme.palette(for: appearance)
      XCTAssertGreaterThanOrEqual(
        contrastRatio(palette.paper, palette.accent),
        4.5,
        "\(appearance) primary action text must remain readable"
      )
    }
  }

  func testMotionTokensDisableAnimationWhenReduceMotionIsEnabled() {
    XCTAssertNil(AtlasMotion.animation(AtlasMotion.standard, reduceMotion: true))
    XCTAssertNotNil(AtlasMotion.animation(AtlasMotion.standard, reduceMotion: false))
  }

  @MainActor
  func testThemeColorsResolveThroughLightAndDarkMacOSAppearances() throws {
    let appearances: [(AtlasAppearanceVariant, NSAppearance.Name)] = [
      (.light, .aqua),
      (.dark, .darkAqua),
    ]

    for (variant, name) in appearances {
      let appearance = try XCTUnwrap(NSAppearance(named: name))
      let expected = AtlasTheme.palette(for: variant).paper
      var resolved: NSColor?

      appearance.performAsCurrentDrawingAppearance {
        resolved = NSColor(AtlasTheme.paper).usingColorSpace(.sRGB)
      }

      let color = try XCTUnwrap(resolved)
      XCTAssertEqual(Double(color.redComponent), expected.red, accuracy: 0.001)
      XCTAssertEqual(Double(color.greenComponent), expected.green, accuracy: 0.001)
      XCTAssertEqual(Double(color.blueComponent), expected.blue, accuracy: 0.001)
    }
  }

  @MainActor
  func testAppearanceResolverPromotesBothSchemesWhenIncreaseContrastIsEnabled() throws {
    let light = try XCTUnwrap(NSAppearance(named: .aqua))
    let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))

    XCTAssertEqual(
      AtlasAppearanceVariant(appearance: light, increaseContrast: true),
      .highContrastLight
    )
    XCTAssertEqual(
      AtlasAppearanceVariant(appearance: dark, increaseContrast: true),
      .highContrastDark
    )
  }

  func testNormalControlBoundariesMeetThreeToOneInEverySupportedAppearance() {
    for appearance in AtlasAppearanceVariant.allCases {
      let palette = AtlasTheme.palette(for: appearance)

      for kind in [AtlasControlKind.textField, .secondaryButton] {
        let tokens = AtlasControlStyleResolver.tokens(
          for: kind,
          appearance: appearance,
          state: AtlasControlVisualState(
            isEnabled: true,
            isPressed: false,
            isFocused: false
          )
        )

        XCTAssertGreaterThanOrEqual(
          contrastRatio(tokens.boundary, tokens.background),
          3,
          "\(appearance) \(kind) boundary must contrast with its fill"
        )
        XCTAssertGreaterThanOrEqual(
          contrastRatio(tokens.boundary, palette.paper2),
          3,
          "\(appearance) \(kind) boundary must contrast with an adjacent secondary surface"
        )
        XCTAssertGreaterThanOrEqual(
          contrastRatio(tokens.foreground, tokens.background),
          4.5,
          "\(appearance) \(kind) text must remain readable"
        )
        XCTAssertGreaterThanOrEqual(tokens.boundaryWidth, 1.5)
        XCTAssertEqual(tokens.focusRingWidth, 0)
      }
    }
  }

  func testFocusedTextFieldsAndSecondaryControlsGainExplicitThreePointFocusRing() {
    for appearance in AtlasAppearanceVariant.allCases {
      let palette = AtlasTheme.palette(for: appearance)

      for kind in [AtlasControlKind.textField, .secondaryButton] {
        let unfocused = AtlasControlStyleResolver.tokens(
          for: kind,
          appearance: appearance,
          state: AtlasControlVisualState(
            isEnabled: true,
            isPressed: false,
            isFocused: false
          )
        )
        let focused = AtlasControlStyleResolver.tokens(
          for: kind,
          appearance: appearance,
          state: AtlasControlVisualState(
            isEnabled: true,
            isPressed: false,
            isFocused: true
          )
        )

        XCTAssertEqual(unfocused.focusRingWidth, 0)
        XCTAssertGreaterThanOrEqual(focused.focusRingWidth, 3)
        XCTAssertGreaterThanOrEqual(focused.focusRingOutset, focused.focusRingWidth)
        XCTAssertGreaterThanOrEqual(
          contrastRatio(focused.focusRing, palette.paper),
          3,
          "\(appearance) \(kind) focus ring must contrast with the primary surface"
        )
        XCTAssertGreaterThanOrEqual(
          contrastRatio(focused.focusRing, palette.paper2),
          3,
          "\(appearance) \(kind) focus ring must contrast with the secondary surface"
        )
      }
    }
  }

  func testExportPreviewIsReadOnlySizedAndDisclosesTruncation() {
    let data = Data("0123456789".utf8)

    let preview = ExportPipeline.preview(for: data, maximumByteCount: 4)

    XCTAssertTrue(preview.hasPrefix("0123"))
    XCTAssertTrue(preview.contains("Preview truncated"))
    XCTAssertTrue(preview.contains("saved export includes all records"))
    XCTAssertEqual(
      ExportPipeline.preview(for: data, maximumByteCount: data.count),
      "0123456789"
    )
  }

  func testExportPipelineWritesTheExactRenderedDataRatherThanPreviewText() throws {
    let destination = FileManager.default.temporaryDirectory
      .appending(path: "AddressAtlasExport-\(UUID().uuidString).csv")
    defer { try? FileManager.default.removeItem(at: destination) }
    let payload = ExportPayload.csv([])
    let expected = try ExportPipeline.data(for: payload)

    let preview = try ExportPipeline.write(payload, to: destination)

    XCTAssertEqual(try Data(contentsOf: destination), expected)
    XCTAssertEqual(preview, String(decoding: expected, as: UTF8.self))
  }

  func testExportFilenamesDescribeRedactedReportsInsteadOfVaultBackups() {
    let csvName = ExportPayload.csv([]).suggestedName
    let jsonName = ExportPayload.json(VaultDocument()).suggestedName

    XCTAssertTrue(csvName.contains("report"))
    XCTAssertTrue(jsonName.contains("report"))
    XCTAssertFalse(jsonName.contains("vault"))
    XCTAssertFalse(jsonName.contains("backup"))
  }

  func testAccessibilityIdentitiesDisambiguateDuplicateVisibleLabels() {
    let firstToken = CustomTokenRecord(
      chainKind: .evm,
      chainId: "ethereum",
      address: "0x0000000000000000000000000000000000000001",
      symbol: "USD",
      name: "Dollar One",
      decimals: 18
    )
    let secondToken = CustomTokenRecord(
      chainKind: .evm,
      chainId: "base",
      address: "0x0000000000000000000000000000000000000002",
      symbol: "USD",
      name: "Dollar Two",
      decimals: 18
    )
    let firstHolding = ManualHoldingRecord(
      id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
      label: "Offline",
      provider: "manual",
      symbol: "BTC",
      name: "Bitcoin",
      amount: 1,
      priceUsd: nil,
      valueUsd: 1
    )
    let secondHolding = ManualHoldingRecord(
      id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
      label: "Offline",
      provider: "manual",
      symbol: "BTC",
      name: "Bitcoin",
      amount: 1,
      priceUsd: nil,
      valueUsd: 1
    )

    XCTAssertNotEqual(
      AtlasAccessibility.tokenIdentity(firstToken),
      AtlasAccessibility.tokenIdentity(secondToken)
    )
    XCTAssertNotEqual(
      AtlasAccessibility.manualHoldingIdentity(firstHolding),
      AtlasAccessibility.manualHoldingIdentity(secondHolding)
    )
  }

  @MainActor
  func testPortfolioRowAccessibilityProvidesColumnMeaningAsOneNavigableRow() {
    let asset = TrackedAsset(
      id: "treasury-eth",
      address: "0x0000000000000000000000000000000000000001",
      chainId: "ethereum",
      chainName: "Ethereum",
      family: .evm,
      symbol: "ETH",
      name: "Ether",
      amount: 1.25,
      priceUsd: 0,
      valueUsd: 0,
      pricingStatus: .unpriced,
      source: .native
    )

    let label = AtlasAccessibility.assetRowIdentity(asset)

    XCTAssertTrue(label.contains("ETH, Ether"))
    XCTAssertTrue(label.contains("Ethereum"))
    XCTAssertTrue(label.contains("source native"))
    XCTAssertTrue(label.contains("amount 1.25"))
    XCTAssertTrue(label.contains("unpriced, USD value unknown"))
    XCTAssertEqual(
      AssetRow.accessibilityIdentifier(for: asset),
      "portfolio-asset-row-treasury-eth"
    )
    XCTAssertLessThan(label.utf8.count, 256)
  }

  private func contrastRatio(
    _ first: AtlasRGB,
    _ second: AtlasRGB
  ) -> Double {
    let lighter = max(relativeLuminance(first), relativeLuminance(second))
    let darker = min(relativeLuminance(first), relativeLuminance(second))
    return (lighter + 0.05) / (darker + 0.05)
  }

  private func relativeLuminance(
    _ color: AtlasRGB
  ) -> Double {
    0.2126 * linearized(color.red)
      + 0.7152 * linearized(color.green)
      + 0.0722 * linearized(color.blue)
  }

  private func linearized(_ component: Double) -> Double {
    component <= 0.04045
      ? component / 12.92
      : pow((component + 0.055) / 1.055, 2.4)
  }

  private func reconstructedPreview(
    from rows: [ExportPreviewRow],
    sourceLineCount: Int
  ) -> String {
    (1...sourceLineCount).map { sourceLine in
      rows
        .filter { $0.sourceLine == sourceLine }
        .sorted { $0.part < $1.part }
        .map(\.content)
        .joined()
    }.joined(separator: "\n")
  }

  @MainActor
  private func firstDescendant<ViewType: NSView>(
    of type: ViewType.Type,
    in root: NSView
  ) -> ViewType? {
    if let match = root as? ViewType { return match }
    for subview in root.subviews {
      if let match = firstDescendant(of: type, in: subview) {
        return match
      }
    }
    return nil
  }

  @MainActor
  private func assertValidLayout<Content: View>(
    _ content: Content,
    size: NSSize,
    context: String
  ) {
    let hostingView = NSHostingView(rootView: content)
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.layoutSubtreeIfNeeded()
    assertValidGeometry(in: hostingView, path: context)
  }

  @MainActor
  private func assertValidGeometry(in view: NSView, path: String) {
    let frame = view.frame
    XCTAssertTrue(frame.origin.x.isFinite, "\(path) has a non-finite x origin")
    XCTAssertTrue(frame.origin.y.isFinite, "\(path) has a non-finite y origin")
    XCTAssertTrue(frame.width.isFinite, "\(path) has a non-finite width")
    XCTAssertTrue(frame.height.isFinite, "\(path) has a non-finite height")
    XCTAssertGreaterThanOrEqual(frame.width, 0, "\(path) has a negative width")
    XCTAssertGreaterThanOrEqual(frame.height, 0, "\(path) has a negative height")
    for (index, subview) in view.subviews.enumerated() {
      assertValidGeometry(
        in: subview,
        path: "\(path)/\(type(of: subview))[\(index)]"
      )
    }
  }

  @MainActor
  private func renderedPNG<Content: View>(
    _ content: Content,
    size: NSSize,
    appearanceName: NSAppearance.Name
  ) -> Data? {
    let hostingView = NSHostingView(rootView: content)
    hostingView.appearance = NSAppearance(named: appearanceName)
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.layoutSubtreeIfNeeded()
    guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
      return nil
    }
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
    return bitmap.representation(using: .png, properties: [:])
  }
}
