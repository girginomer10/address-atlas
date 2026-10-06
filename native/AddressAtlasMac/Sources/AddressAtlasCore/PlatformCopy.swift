import Foundation

/// Device nouns for user-facing copy that is shared between the macOS and iOS
/// apps. The macOS wording is unchanged so existing string assertions and
/// screenshots stay stable; iOS builds substitute a neutral device noun.
public enum PlatformCopy {
  /// "Mac" on macOS, "device" on iOS. Use inside sentences such as
  /// "created only for this \(PlatformCopy.deviceNoun)".
  public static let deviceNoun: String = {
    #if os(macOS)
      return "Mac"
    #else
      return "device"
    #endif
  }()

  /// Possessive form for phrases such as "Correct the Mac's date and time".
  public static var deviceNounPossessive: String { "\(deviceNoun)'s" }

  // iCloud copy can move between a Mac, iPhone, and iPad, so copy about the
  // other end of a transfer says "device" on every platform instead of using
  // this noun.

  /// Where the user signs in to iCloud on this platform.
  public static let iCloudSettingsLocation: String = {
    #if os(macOS)
      return "System Settings"
    #else
      return "Settings"
    #endif
  }()

  /// The storefront that distributes this platform's build.
  public static let appStoreName: String = {
    #if os(macOS)
      return "Mac App Store"
    #else
      return "App Store"
    #endif
  }()
}
