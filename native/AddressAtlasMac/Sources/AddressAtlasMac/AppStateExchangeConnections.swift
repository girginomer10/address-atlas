import AddressAtlasCore
import Foundation

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
      ? "Exchange credentials were removed from this Mac and any local rollback point. The last remote snapshot may still contain them; upload the replacement vault to complete remote cleanup."
      : "Exchange credentials were removed from this Mac and any local rollback point."
  }

}
