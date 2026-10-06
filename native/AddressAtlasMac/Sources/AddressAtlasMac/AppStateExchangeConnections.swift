import AddressAtlasCore
import CryptoKit
import Foundation

/// The credential field a local format problem belongs to, so a form can show
/// the message under the field that needs fixing.
enum ExchangeCredentialInputField: Equatable, Sendable {
  case apiKey
  case secret
}

/// A credential that can't work, found locally before anything is encrypted
/// or sent to the exchange.
struct ExchangeCredentialFormatIssue: Equatable, Sendable {
  var field: ExchangeCredentialInputField
  var message: String
}

extension AppState {
  /// Input the request signer is certain to reject (`ExchangeRequestSigner`):
  /// a Coinbase key name outside `organizations/…/apiKeys/…`, a Coinbase
  /// secret that is not a P-256 PEM key after the same escaped-newline
  /// unescaping, or a Kraken secret that is not standard Base64. Such a
  /// credential would only fail at the first scan, so it is refused up front.
  nonisolated static func exchangeCredentialSigningIssue(
    provider: ExchangeProvider,
    credentials: ExchangeCredentials
  ) -> ExchangeCredentialFormatIssue? {
    switch provider {
    case .binance:
      return nil
    case .coinbase:
      let keyName = credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      guard keyName.hasPrefix("organizations/"), keyName.contains("/apiKeys/") else {
        return ExchangeCredentialFormatIssue(
          field: .apiKey,
          message: "Enter the CDP key name. It starts with organizations/ and contains /apiKeys/."
        )
      }
      let pem = credentials.secret
        .replacingOccurrences(of: "\\n", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard (try? P256.Signing.PrivateKey(pemRepresentation: pem)) != nil else {
        return ExchangeCredentialFormatIssue(
          field: .secret,
          message:
            "Paste the whole ES256 private key, from -----BEGIN EC PRIVATE KEY----- to the END line."
        )
      }
      return nil
    case .kraken:
      let secret = credentials.secret.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let decoded = Data(base64Encoded: secret), !decoded.isEmpty else {
        return ExchangeCredentialFormatIssue(
          field: .secret,
          message: "Paste the private key exactly as Kraken shows it."
        )
      }
      return nil
    }
  }

  /// Stricter form-level check run before a connect or a key replacement: the
  /// signer rules above plus the shapes each exchange actually issues, so a
  /// truncated paste, a swapped field, or another exchange's key is named
  /// under the right field instead of failing at the first scan.
  nonisolated static func exchangeCredentialFormatIssue(
    provider: ExchangeProvider,
    credentials: ExchangeCredentials
  ) -> ExchangeCredentialFormatIssue? {
    let apiKey = credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let secret = credentials.secret.trimmingCharacters(in: .whitespacesAndNewlines)
    if apiKey.contains("-----BEGIN") {
      return ExchangeCredentialFormatIssue(
        field: .apiKey,
        message: "That's a private key. Paste it in the private key field instead."
      )
    }
    if provider != .coinbase, apiKey.hasPrefix("organizations/") {
      return ExchangeCredentialFormatIssue(
        field: .apiKey,
        message:
          "That looks like a Coinbase key. Choose Coinbase, or paste a \(provider.label) key."
      )
    }
    if provider != .coinbase, secret.contains("-----BEGIN") {
      return ExchangeCredentialFormatIssue(
        field: .secret,
        message: provider == .binance
          ? "Use a system-generated Binance key. Ed25519 and RSA keys aren't supported."
          : "That looks like a Coinbase key. Choose Coinbase, or paste a \(provider.label) key."
      )
    }
    if provider != .coinbase, apiKey.contains(where: \.isWhitespace) {
      return ExchangeCredentialFormatIssue(
        field: .apiKey, message: "Remove spaces or line breaks from the API key.")
    }
    if provider != .coinbase, secret.contains(where: \.isWhitespace) {
      return ExchangeCredentialFormatIssue(
        field: .secret, message: "Remove spaces or line breaks from the key.")
    }
    switch provider {
    case .binance:
      guard isASCIIAlphanumeric(apiKey), (32...128).contains(apiKey.count) else {
        return ExchangeCredentialFormatIssue(
          field: .apiKey,
          message:
            "A Binance API key is a long string of letters and numbers. Check that the whole key was pasted."
        )
      }
      guard isASCIIAlphanumeric(secret), (32...128).contains(secret.count) else {
        return ExchangeCredentialFormatIssue(
          field: .secret,
          message:
            "A Binance secret key is a long string of letters and numbers. Check that the whole key was pasted."
        )
      }
      return nil
    case .coinbase:
      return exchangeCredentialSigningIssue(provider: provider, credentials: credentials)
    case .kraken:
      let base64Alphabet = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
      guard apiKey.count >= 32, apiKey.unicodeScalars.allSatisfy(base64Alphabet.contains) else {
        return ExchangeCredentialFormatIssue(
          field: .apiKey,
          message:
            "A Kraken API key is a long string of letters, numbers, + and /. Check that the whole key was pasted."
        )
      }
      if let issue = exchangeCredentialSigningIssue(provider: provider, credentials: credentials) {
        return issue
      }
      guard let decoded = Data(base64Encoded: secret), decoded.count >= 32 else {
        return ExchangeCredentialFormatIssue(
          field: .secret,
          message: "That private key is too short. Check that the whole key was pasted."
        )
      }
      return nil
    }
  }

  /// A Coinbase PEM key pasted into a one-line field arrives with its line
  /// breaks turned into spaces, or escaped as a backslash-n sequence. Rebuilds
  /// the standard 64-column PEM so the signer can parse it; anything else is
  /// returned trimmed and otherwise unchanged.
  nonisolated static func normalizedCoinbasePrivateKey(_ raw: String) -> String {
    let unescaped = raw.replacingOccurrences(of: "\\n", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let beginMarker = unescaped.range(of: "-----BEGIN "),
      let beginClose = unescaped.range(
        of: "-----", range: beginMarker.upperBound..<unescaped.endIndex),
      let endMarker = unescaped.range(
        of: "-----END ", range: beginClose.upperBound..<unescaped.endIndex),
      let endClose = unescaped.range(
        of: "-----", range: endMarker.upperBound..<unescaped.endIndex)
    else { return unescaped }
    let label = unescaped[beginMarker.upperBound..<beginClose.lowerBound]
    let endLabel = unescaped[endMarker.upperBound..<endClose.lowerBound]
    let body = unescaped[beginClose.upperBound..<endMarker.lowerBound].filter {
      !$0.isWhitespace
    }
    guard !label.isEmpty, label == endLabel, !body.isEmpty else { return unescaped }
    var lines: [String] = []
    var index = body.startIndex
    while index < body.endIndex {
      let next = body.index(index, offsetBy: 64, limitedBy: body.endIndex) ?? body.endIndex
      lines.append(String(body[index..<next]))
      index = next
    }
    return "-----BEGIN \(label)-----\n\(lines.joined(separator: "\n"))\n-----END \(label)-----"
  }

  private nonisolated static func isASCIIAlphanumeric(_ value: String) -> Bool {
    !value.isEmpty
      && value.unicodeScalars.allSatisfy {
        ("0"..."9").contains($0) || ("A"..."Z").contains($0) || ("a"..."z").contains($0)
      }
  }
}

@MainActor
extension AppState {
  @discardableResult
  func saveExchangeConnection(
    provider: ExchangeProvider,
    label: String,
    credentials: ExchangeCredentials
  ) async -> Bool {
    guard canMutateVault() else { return false }
    guard document.exchangeConnections.count < Self.maximumExchangeConnections else {
      error = "A vault can contain at most \(Self.maximumExchangeConnections) exchange connections."
      return false
    }
    guard let vaultKey else {
      error = "Vault must be unlocked before saving exchange credentials."
      return false
    }
    let normalizedCredentials = ExchangeCredentials(
      apiKey: credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
      secret: credentials.secret.trimmingCharacters(in: .whitespacesAndNewlines),
      passphrase: credentials.passphrase?.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    let passphraseIsValid = normalizedCredentials.passphrase.map {
      !$0.isEmpty && $0.utf8.count <= 4_096
    } ?? true
    guard !normalizedCredentials.apiKey.isEmpty,
      !normalizedCredentials.secret.isEmpty,
      normalizedCredentials.apiKey.utf8.count <= 4_096,
      normalizedCredentials.secret.utf8.count <= 32_768,
      passphraseIsValid
    else {
      error = "API key and secret are required and must be within supported size limits."
      return false
    }
    if let issue = Self.exchangeCredentialSigningIssue(
      provider: provider, credentials: normalizedCredentials)
    {
      error = issue.message
      return false
    }
    let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard VaultTextLimits.contains(
      normalizedLabel,
      maximumCharacters: VaultTextLimits.exchangeLabelCharacters,
      maximumUTF8Bytes: VaultTextLimits.exchangeLabelUTF8Bytes
    ) else {
      error = "Exchange labels must be 80 characters or fewer."
      return false
    }
    guard !isValidatingExchangeCredentials else {
      notice = "An exchange credential check is already running."
      return false
    }
    isValidatingExchangeCredentials = true
    defer { isValidatingExchangeCredentials = false }
    let connectionId = UUID()
    do {
      let credentialVault = ExchangeCredentialVault(crypto: crypto)
      if try AppState.hasDuplicateExchangeAPIKey(
        provider: provider,
        apiKey: normalizedCredentials.apiKey,
        connections: document.exchangeConnections,
        vaultKey: vaultKey,
        crypto: crypto
      ) {
        error = "That \(provider.label) API key is already saved."
        return false
      }
      let scope = try await NativeExchangeBalanceClient(
        http: httpClient,
        endpointConfig: endpointConfig
      ).validateCredentialScope(
        provider: provider,
        credentials: normalizedCredentials
      )
      let krakenDeviceIdentifier: String?
      if provider == .kraken {
        guard
          let normalizedIdentifier = KrakenDeviceIdentity.normalizedIdentifier(
            try self.krakenDeviceIdentifier()
          )
        else {
          error = "Kraken's protected device identity is invalid. No credentials were saved."
          return false
        }
        krakenDeviceIdentifier = normalizedIdentifier
      } else {
        krakenDeviceIdentifier = nil
      }
      let encrypted = try credentialVault.seal(
        normalizedCredentials,
        vaultKey: vaultKey,
        connectionId: connectionId
      )
      let saved = await mutateDocument { document in
        let scopeAssurance: ExchangeCredentialScopeAssurance =
          switch scope {
          case .verifiedReadOnly: .verifiedReadOnly
          case .manualVerificationRequired: .manualVerificationRequired
          }
        document.exchangeConnections.append(
          ExchangeConnectionRecord(
            id: connectionId,
            provider: provider,
            label: normalizedLabel.isEmpty ? provider.label : normalizedLabel,
            encryptedCredentials: encrypted,
            krakenDeviceIdentifier: krakenDeviceIdentifier,
            credentialScopeAssurance: scopeAssurance
          )
        )
      }
      if saved,
        case .manualVerificationRequired(_, let guidance) = scope
      {
        notice = "Saved encrypted. \(guidance)"
      }
      return saved
    } catch {
      presentUserFacingError(error)
      return false
    }
  }

  /// Replaces the API key and secret of a saved connection in place, keeping
  /// its id, name, and creation date. The new credential passes the same
  /// checks as a new connection (size limits, signer format, duplicate key,
  /// provider scope check, Kraken device identity) before anything changes.
  /// A Kraken connection is re-bound to this device, since the new key was
  /// entered here. The old encrypted credential can survive in the rollback
  /// point and the last remote copy, so this commits like a removal: the
  /// rollback point is consumed in the same transaction and remote cleanup is
  /// flagged when a remote snapshot may still hold the old key.
  @discardableResult
  func replaceExchangeCredentials(id: UUID, credentials: ExchangeCredentials) async -> Bool {
    guard canMutateVault() else { return false }
    guard let existing = document.exchangeConnections.first(where: { $0.id == id }) else {
      error = "That exchange connection is no longer saved."
      return false
    }
    guard let vaultKey else {
      error = "Vault must be unlocked before saving exchange credentials."
      return false
    }
    let provider = existing.provider
    let normalizedCredentials = ExchangeCredentials(
      apiKey: credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
      secret: credentials.secret.trimmingCharacters(in: .whitespacesAndNewlines),
      passphrase: credentials.passphrase?.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    let passphraseIsValid = normalizedCredentials.passphrase.map {
      !$0.isEmpty && $0.utf8.count <= 4_096
    } ?? true
    guard !normalizedCredentials.apiKey.isEmpty,
      !normalizedCredentials.secret.isEmpty,
      normalizedCredentials.apiKey.utf8.count <= 4_096,
      normalizedCredentials.secret.utf8.count <= 32_768,
      passphraseIsValid
    else {
      error = "API key and secret are required and must be within supported size limits."
      return false
    }
    if let issue = Self.exchangeCredentialSigningIssue(
      provider: provider, credentials: normalizedCredentials)
    {
      error = issue.message
      return false
    }
    guard !isValidatingExchangeCredentials else {
      notice = "An exchange credential check is already running."
      return false
    }
    isValidatingExchangeCredentials = true
    defer { isValidatingExchangeCredentials = false }
    do {
      if try AppState.hasDuplicateExchangeAPIKey(
        provider: provider,
        apiKey: normalizedCredentials.apiKey,
        connections: document.exchangeConnections.filter { $0.id != id },
        vaultKey: vaultKey,
        crypto: crypto
      ) {
        error = "That \(provider.label) API key is already saved in another connection."
        return false
      }
      let scope = try await NativeExchangeBalanceClient(
        http: httpClient,
        endpointConfig: endpointConfig
      ).validateCredentialScope(
        provider: provider,
        credentials: normalizedCredentials
      )
      let krakenDeviceIdentifier: String?
      if provider == .kraken {
        guard
          let normalizedIdentifier = KrakenDeviceIdentity.normalizedIdentifier(
            try self.krakenDeviceIdentifier()
          )
        else {
          error = "Kraken's protected device identity is invalid. The saved keys were not changed."
          return false
        }
        krakenDeviceIdentifier = normalizedIdentifier
      } else {
        krakenDeviceIdentifier = nil
      }
      let encrypted = try ExchangeCredentialVault(crypto: crypto).seal(
        normalizedCredentials,
        vaultKey: vaultKey,
        connectionId: id
      )
      var candidate = document
      guard let index = candidate.exchangeConnections.firstIndex(where: { $0.id == id }) else {
        error = "That exchange connection was removed while its keys were being checked."
        return false
      }
      let now = Date()
      candidate.exchangeConnections[index].encryptedCredentials = encrypted
      candidate.exchangeConnections[index].krakenDeviceIdentifier = krakenDeviceIdentifier
      let scopeAssurance: ExchangeCredentialScopeAssurance =
        switch scope {
        case .verifiedReadOnly: .verifiedReadOnly
        case .manualVerificationRequired: .manualVerificationRequired
        }
      candidate.exchangeConnections[index].credentialScopeAssurance = scopeAssurance
      candidate.exchangeConnections[index].status = .empty
      candidate.exchangeConnections[index].lastError = nil
      candidate.exchangeConnections[index].lastTestedAt = nil
      candidate.exchangeConnections[index].lastSyncAt = nil
      candidate.exchangeConnections[index].updatedAt = now
      candidate.syncState.pendingExchangeCredentialCleanup =
        candidate.syncState.accountId != nil
        && (candidate.syncState.latestRemoteVersion > 0
          || candidate.syncState.remoteOutcomeUncertain)
      guard await saveAndDiscardRollbackCheckpoint(candidate) else { return false }
      var message = "\(provider.label) keys replaced."
      if case .manualVerificationRequired = scope {
        message += " \(provider.label) can't confirm the new key is read-only, so check its permissions."
      }
      if candidate.iCloudState != nil {
        message += " Save to iCloud to replace the old encrypted keys there too."
      }
      notice = message
      error = ""
      return true
    } catch {
      presentUserFacingError(error)
      return false
    }
  }

  /// Renames a saved connection. A blank name falls back to the provider name,
  /// as when connecting.
  @discardableResult
  func renameExchangeConnection(id: UUID, label: String) async -> Bool {
    guard canMutateVault() else { return false }
    guard let index = document.exchangeConnections.firstIndex(where: { $0.id == id }) else {
      error = "That exchange connection is no longer saved."
      return false
    }
    let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard VaultTextLimits.contains(
      normalizedLabel,
      maximumCharacters: VaultTextLimits.exchangeLabelCharacters,
      maximumUTF8Bytes: VaultTextLimits.exchangeLabelUTF8Bytes
    ) else {
      error = "Exchange labels must be 80 characters or fewer."
      return false
    }
    let resolved =
      normalizedLabel.isEmpty ? document.exchangeConnections[index].provider.label : normalizedLabel
    guard document.exchangeConnections[index].label != resolved else { return true }
    return await mutateDocument { document in
      document.exchangeConnections[index].label = resolved
      document.exchangeConnections[index].updatedAt = Date()
    }
  }

  func removeExchangeConnection(id: UUID) async {
    guard canMutateVault() else { return }
    guard document.exchangeConnections.contains(where: { $0.id == id }) else { return }
    var candidate = document
    candidate.exchangeConnections.removeAll { $0.id == id }
    candidate.syncState.pendingExchangeCredentialCleanup =
      candidate.syncState.accountId != nil
      && (candidate.syncState.latestRemoteVersion > 0
        || candidate.syncState.remoteOutcomeUncertain)

    // A rollback checkpoint can contain the credential being removed. Commit
    // the primary deletion and consume that checkpoint in one transaction so
    // Restore can never resurrect a credential the UI said was removed.
    guard await saveAndDiscardRollbackCheckpoint(candidate) else { return }
    notice = candidate.syncState.pendingExchangeCredentialCleanup
      ? "Exchange credentials were removed from this \(PlatformCopy.deviceNoun), including its earlier local copy. Your last uploaded encrypted copy may still contain them until you save a new one."
      : "Exchange credentials were removed from this \(PlatformCopy.deviceNoun), including its earlier local copy."
    if candidate.iCloudState != nil {
      notice += " Save the updated portfolio to iCloud or delete its iCloud copy to remove the old encrypted credentials there too."
    }
  }

}
