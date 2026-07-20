import Darwin
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
          let rawHost = components.host?.lowercased(),
          let host = normalizedHost(rawHost), !host.isEmpty,
          components.port.map({ (1...65_535).contains($0) }) ?? true,
          components.user == nil,
          components.password == nil,
          components.query == nil,
          components.fragment == nil,
          components.path.isEmpty || components.path == "/"
    else { return nil }

    // The native sync account flow always authenticates with WebAuthn. An IP
    // literal cannot be a WebAuthn relying-party ID, even when transported over
    // HTTPS, so such an origin can never produce a usable native session.
    guard !isIPLiteral(host) else { return nil }

    if scheme != "https" {
      // WebAuthn permits an insecure development origin only for the exact
      // localhost hostname. Loopback IP literals cannot be relying-party IDs,
      // so accepting them here would advertise a sync server that the native
      // passkey flow can never authenticate against.
      guard scheme == "http", host == "localhost" else {
        return nil
      }
    }

    components.scheme = scheme
    // Foundation exposes bracketed IPv6 literals as "[::1]" and also requires
    // the brackets when assigning URLComponents.host. Keep the parsed spelling
    // for reconstruction while using the normalized host for policy checks.
    components.host = rawHost
    components.path = ""
    components.query = nil
    components.fragment = nil
    if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
      components.port = nil
    }
    guard let url = components.url,
          let canonicalHost = url.host?.lowercased(),
          isWebAuthnDomainHost(canonicalHost)
    else { return nil }
    return url
  }

  private static func normalizedHost(_ host: String) -> String? {
    if host.hasPrefix("[") || host.hasSuffix("]") {
      guard host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 else { return nil }
      return String(host.dropFirst().dropLast())
    }
    return host
  }

  private static func isIPLiteral(_ host: String) -> Bool {
    // IPv6 always contains a colon; this also fails closed for scoped literals
    // whose interface suffix is not meaningful to a WebAuthn RP ID.
    if host.contains(":") { return true }

    // inet_aton recognizes both canonical dotted IPv4 and the legacy numeric
    // spellings that URL implementations may reinterpret as IPv4. Rejecting all
    // of them prevents Swift and the browser from disagreeing about the origin.
    var address = in_addr()
    return host.withCString { inet_aton($0, &address) == 1 }
  }

  private static func isWebAuthnDomainHost(_ host: String) -> Bool {
    if host == "localhost" { return true }
    guard host.count <= 253, host.contains("."), !host.hasSuffix(".") else {
      return false
    }
    return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
      guard (1...63).contains(label.count),
            let first = label.utf8.first,
            let last = label.utf8.last,
            isASCIILetterOrDigit(first),
            isASCIILetterOrDigit(last)
      else { return false }
      return label.utf8.allSatisfy { isASCIILetterOrDigit($0) || $0 == 45 }
    }
  }

  private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
  }
}
