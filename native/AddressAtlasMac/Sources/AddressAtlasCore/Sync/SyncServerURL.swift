import Foundation

public enum SyncServerURL {
  /// Returns one canonical origin (scheme, host and non-default port only).
  /// Sync endpoints are fixed by the client, so paths, credentials, queries and
  /// fragments are never meaningful server settings.
  public static func validatedOrigin(_ raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          var components = URLComponents(string: trimmed),
          let scheme = components.scheme?.lowercased(),
          let host = components.host?.lowercased(), !host.isEmpty,
          components.user == nil,
          components.password == nil,
          components.query == nil,
          components.fragment == nil,
          components.path.isEmpty || components.path == "/"
    else { return nil }

    if scheme != "https" {
      guard scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(host) else {
        return nil
      }
    }

    components.scheme = scheme
    components.host = host
    components.path = ""
    components.query = nil
    components.fragment = nil
    if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
      components.port = nil
    }
    guard let url = components.url, url.host != nil else { return nil }
    return url
  }
}
