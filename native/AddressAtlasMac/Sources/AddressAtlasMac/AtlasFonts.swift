import CoreText
import Foundation
import SwiftUI

/// The bundled open-source (SIL OFL) font families the themes draw from.
///
/// Files live in `Fonts/<Family>/` next to each family's `OFL.txt`. They are
/// registered for the process at runtime with CoreText, so the same code serves
/// the SwiftPM Mac app (resource bundle) and the xcodegen iOS app (folder
/// resource in the main bundle). A missing family degrades to a system font.
enum AtlasFontFamily: String, CaseIterable, Sendable {
  case plusJakartaSans
  case bricolageGrotesque
  case spaceGrotesk
  case spaceMono
  case geist
  case geistMono
  case pixelifySans
  case silkscreen
  case vt323

  /// CoreText family name, as used by `Font.custom`.
  var familyName: String {
    switch self {
    case .plusJakartaSans: "Plus Jakarta Sans"
    case .bricolageGrotesque: "Bricolage Grotesque"
    case .spaceGrotesk: "Space Grotesk"
    case .spaceMono: "Space Mono"
    case .geist: "Geist"
    case .geistMono: "Geist Mono"
    case .pixelifySans: "Pixelify Sans"
    case .silkscreen: "Silkscreen"
    case .vt323: "VT323"
    }
  }

  /// Folder under `Fonts/` holding the family's files and licence.
  var directoryName: String {
    switch self {
    case .plusJakartaSans: "PlusJakartaSans"
    case .bricolageGrotesque: "BricolageGrotesque"
    case .spaceGrotesk: "SpaceGrotesk"
    case .spaceMono: "SpaceMono"
    case .geist: "Geist"
    case .geistMono: "GeistMono"
    case .pixelifySans: "PixelifySans"
    case .silkscreen: "Silkscreen"
    case .vt323: "VT323"
    }
  }

  /// Font files expected inside `directoryName`.
  var fileNames: [String] {
    switch self {
    case .plusJakartaSans: ["PlusJakartaSans-Variable.ttf"]
    case .bricolageGrotesque: ["BricolageGrotesque-Variable.ttf"]
    case .spaceGrotesk: ["SpaceGrotesk-Variable.ttf"]
    case .spaceMono: ["SpaceMono-Regular.ttf", "SpaceMono-Bold.ttf"]
    case .geist: ["Geist-Variable.ttf"]
    case .geistMono: ["GeistMono-Variable.ttf"]
    case .pixelifySans: ["PixelifySans-Variable.ttf"]
    case .silkscreen: ["Silkscreen-Regular.ttf", "Silkscreen-Bold.ttf"]
    case .vt323: ["VT323-Regular.ttf"]
    }
  }

  /// Factor applied to a requested point size so faces look as big as their
  /// neighbours. VT323 is drawn small on its em square.
  var opticalScale: CGFloat {
    switch self {
    case .vt323: 1.15
    default: 1
    }
  }

  /// The five is drawn like an S, so a figure set in this face is misread
  /// ("$5,082" reads "$S,082"). Figures use the number face instead.
  var drawsFiveLikeS: Bool {
    switch self {
    case .pixelifySans, .silkscreen: true
    default: false
    }
  }

  /// System design used when the bundled files cannot be loaded.
  var fallbackDesign: Font.Design {
    switch self {
    case .spaceMono, .geistMono, .silkscreen, .pixelifySans, .vt323: .monospaced
    case .plusJakartaSans, .bricolageGrotesque: .rounded
    case .spaceGrotesk, .geist: .default
    }
  }
}

/// Result of registering the bundled fonts.
struct AtlasFontRegistrationReport: Equatable, Sendable {
  /// Families whose CoreText family name resolves after registration.
  var availableFamilies: Set<AtlasFontFamily>
  /// Folder the font files were read from, when one was found.
  var fontDirectory: URL?

  var missingFamilies: [AtlasFontFamily] {
    AtlasFontFamily.allCases.filter { !availableFamilies.contains($0) }
  }
}

enum AtlasFonts {
  /// Name of the resource folder (SwiftPM `.copy("Fonts")`, iOS folder reference).
  static let resourceDirectoryName = "Fonts"
  /// SwiftPM names the resource bundle `<package>_<target>`.
  static let packageResourceBundleName = "AddressAtlasMac_AddressAtlasMac.bundle"

  private static let registration = AtlasFontRegistration()

  /// Registers every bundled font for this process. Safe to call repeatedly
  /// and from any thread; the work happens once.
  @discardableResult
  static func registerAll() -> AtlasFontRegistrationReport {
    registration.report
  }

  static func isAvailable(_ family: AtlasFontFamily) -> Bool {
    registerAll().availableFamilies.contains(family)
  }

  /// Candidate `Fonts` directories, most specific first:
  /// 1. a packaged Mac app: `Contents/Resources/<package bundle>/Fonts`;
  /// 2. the iOS app (or a flat Mac layout): `<main bundle resources>/Fonts`;
  /// 3. SwiftPM development runs and tests, through `Bundle.module`. A
  ///    packaged `.app` never reaches this, because `Bundle.module` traps when
  ///    its resource bundle is missing.
  static func candidateFontDirectories() -> [URL] {
    var directories: [URL] = []
    let main = Bundle.main
    if let resources = main.resourceURL {
      let packageBundleURL = resources.appendingPathComponent(
        packageResourceBundleName, isDirectory: true)
      let packageRoot = Bundle(url: packageBundleURL)?.resourceURL ?? packageBundleURL
      directories.append(
        packageRoot.appendingPathComponent(resourceDirectoryName, isDirectory: true))
      directories.append(
        resources.appendingPathComponent(resourceDirectoryName, isDirectory: true))
    }
    #if SWIFT_PACKAGE
      if main.bundleURL.pathExtension != "app" {
        let moduleRoot = Bundle.module.resourceURL ?? Bundle.module.bundleURL
        directories.append(
          moduleRoot.appendingPathComponent(resourceDirectoryName, isDirectory: true))
      }
    #endif
    return directories
  }

  /// Every font file below `directory`.
  static func fontFiles(in directory: URL) -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }
    var files: [URL] = []
    for case let url as URL in enumerator {
      let ext = url.pathExtension.lowercased()
      if ext == "ttf" || ext == "otf" { files.append(url) }
    }
    return files.sorted { $0.path < $1.path }
  }

  fileprivate static func availableFamilyNames() -> Set<String> {
    Set((CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? [])
  }
}

/// Performs the one-time registration. `Sendable` because the stored report is
/// immutable after `init`.
private final class AtlasFontRegistration: Sendable {
  let report: AtlasFontRegistrationReport

  init() {
    let directory = AtlasFonts.candidateFontDirectories().first {
      !AtlasFonts.fontFiles(in: $0).isEmpty
    }
    if let directory {
      let urls = AtlasFonts.fontFiles(in: directory) as CFArray
      // The handler keeps going past per-file errors such as "already
      // registered" (a host may have loaded the same file); the family check
      // below is the authority on whether the fonts are usable.
      CTFontManagerRegisterFontURLs(urls, .process, true) { _, _ in true }
    }
    let names = AtlasFonts.availableFamilyNames()
    report = AtlasFontRegistrationReport(
      availableFamilies: Set(AtlasFontFamily.allCases.filter { names.contains($0.familyName) }),
      fontDirectory: directory
    )
  }
}
