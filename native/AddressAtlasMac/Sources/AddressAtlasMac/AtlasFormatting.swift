import Foundation

/// Locale-aware formatting shared by the state layer and both apps.
enum AtlasFormatting {
  static var locale: Locale {
    #if DEBUG
      if let override = ProcessInfo.processInfo.environment["ADDRESS_ATLAS_UI_LOCALE"],
        !override.isEmpty
      {
        return Locale(identifier: override)
      }
    #endif
    return .autoupdatingCurrent
  }

  static func dateTime(_ date: Date) -> String {
    date.formatted(
      Date.FormatStyle(date: .abbreviated, time: .shortened)
        .locale(locale)
    )
  }
}
