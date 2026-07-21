import AddressAtlasCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExchangesView: View {
  @EnvironmentObject private var state: AppState
  @State private var provider: ExchangeProvider = .binance
  @State private var label = ""
  @State private var apiKey = ""
  @State private var secret = ""

  private var hasRequiredCredentialInput: Bool {
    !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    Page(
      eyebrow: "Read-only API connectors",
      title: "Exchanges",
      subtitle: "API credentials are encrypted with a dedicated vault subkey before storage.",
      statTitle: "Connections",
      statValue: "\(state.document.exchangeConnections.count)"
    ) {
      Surface {
        VStack(alignment: .leading, spacing: 14) {
          SectionHeader(title: "Save encrypted credentials", meta: "Balance/read permissions only")
          AdaptiveStack {
            Picker("Provider", selection: $provider) {
              ForEach(ExchangeProvider.allCases, id: \.self) { provider in
                Text(provider.label).tag(provider)
              }
            }
            .frame(width: 170)
            TextField("Label", text: $label)
              .textFieldStyle(AtlasTextFieldStyle())
          }
          AdaptiveStack {
            SecureField("API key", text: $apiKey)
              .textFieldStyle(AtlasTextFieldStyle())
            SecureField("Secret", text: $secret)
              .textFieldStyle(AtlasTextFieldStyle())
            Button("Save encrypted") {
              Task {
                if await state.saveExchangeConnection(
                  provider: provider,
                  label: label,
                  credentials: ExchangeCredentials(
                    apiKey: apiKey,
                    secret: secret,
                    passphrase: nil
                  )
                ) {
                  label = ""
                  apiKey = ""
                  secret = ""
                }
              }
            }
            .buttonStyle(AtlasPrimaryButtonStyle())
            .disabled(!hasRequiredCredentialInput)
          }
          Text(
            {
              switch provider {
              case .coinbase:
                return
                  "Coinbase uses a CDP API key name and ES256 private key. Scope cannot be verified automatically; confirm view/read-only access. Escaped \\n line breaks are accepted."
              case .kraken:
                return
                  "Kraken scope cannot be verified automatically. Enable only Query Funds, use a different key for every Mac, and keep trading/withdrawals disabled."
              case .binance:
                return
                  "Binance permissions are checked before saving; any trading, transfer, margin, futures, options, or withdrawal capability is refused."
              }
            }()
          )
          .font(.callout)
          .foregroundStyle(AtlasTheme.ink3)
        }
      }
      .disabled(state.vaultEditsDisabled)

      AdaptiveStack(horizontalSpacing: 12) {
        Button {
          if state.scanning {
            state.cancelScan()
          } else {
            state.startScan()
          }
        } label: {
          if state.scanning {
            Label("Cancel scan", systemImage: "xmark.circle")
          } else {
            Label("Scan all sources", systemImage: "arrow.clockwise")
          }
        }
        .buttonStyle(AtlasPrimaryButtonStyle())
        .disabled(
          !state.scanning
            && (state.syncing || state.syncPersistencePending || !state.hasScanSources))
        Text("\(state.document.exchangeConnections.count) encrypted connections")
          .font(.caption.monospaced())
          .foregroundStyle(AtlasTheme.ink3)
      }

      SectionHeader(
        title: "Saved connections", meta: "\(state.document.exchangeConnections.count) records")
      Surface(padding: 0) {
        if state.document.exchangeConnections.isEmpty {
          EmptyState(
            title: "No exchange connections", systemImage: "building.columns",
            copy: "Add read-only API credentials to scan exchange balances."
          )
          .padding(28)
        } else {
          VStack(spacing: 0) {
            ForEach(state.document.exchangeConnections) { connection in
              ExchangeRow(connection: connection)
              if connection.id != state.document.exchangeConnections.last?.id {
                Divider().overlay(AtlasTheme.ruleSoft)
              }
            }
          }
        }
      }
    }
  }
}

struct ExchangeRow: View {
  @EnvironmentObject private var state: AppState
  @State private var confirmingRemoval = false
  var connection: ExchangeConnectionRecord

  private var hasInvalidKrakenBinding: Bool {
    connection.provider == .kraken
      && connection.krakenDeviceIdentifier.flatMap(KrakenDeviceIdentity.normalizedIdentifier) == nil
  }

  var body: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text(connection.label)
          .font(.body.weight(.semibold))
        Text(
          connection.lastError?.isEmpty == false
            ? connection.lastError ?? ""
            : hasInvalidKrakenBinding
              ? "Legacy Kraken key: remove it and add a new per-device read-only key before scanning."
              : connection.provider.label
        )
        .font(.callout)
        .foregroundStyle(
          connection.lastError?.isEmpty == false
            || hasInvalidKrakenBinding
            ? AtlasTheme.loss
            : AtlasTheme.ink3
        )
        .lineLimit(2)
      }
      Spacer()
      Badge(
        connection.credentialScopeAssurance == .verifiedReadOnly
          ? "SCOPE LAST VERIFIED"
          : "SCOPE UNVERIFIED",
        color: connection.credentialScopeAssurance == .verifiedReadOnly
          ? AtlasTheme.gain
          : AtlasTheme.loss
      )
      Badge(
        connection.status.rawValue.uppercased(),
        color: connection.status == .failed ? AtlasTheme.loss : AtlasTheme.gain)
      if let lastSync = connection.lastSyncAt {
        Text(lastSync, style: .relative)
          .font(.caption.monospaced())
          .foregroundStyle(AtlasTheme.ink3)
      }
      Button(role: .destructive) {
        confirmingRemoval = true
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(IconButtonStyle())
      .accessibilityLabel(
        "Remove exchange connection \(AtlasAccessibility.exchangeIdentity(connection))"
      )
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 10)
    .frame(minHeight: 64)
    .confirmationDialog(
      "Remove \(AtlasAccessibility.exchangeIdentity(connection))?",
      isPresented: $confirmingRemoval,
      titleVisibility: .visible
    ) {
      Button("Remove connection", role: .destructive) {
        Task { await state.removeExchangeConnection(id: connection.id) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The encrypted API credentials for this connection will be removed from the vault.")
    }
    .disabled(state.vaultEditsDisabled)
  }
}

struct SyncView: View {
  @EnvironmentObject private var state: AppState
  @State private var serverURL = ""
  @State private var confirmingDiscardDownload = false
  @State private var confirmingSessionRevocation = false
  @State private var confirmingAccountDeletion = false
  @State private var confirmingStopUploadRecovery = false
  @State private var pendingDownloadServerURL: URL?
  @State private var pendingRevocationServerURL: URL?
  @State private var pendingDeletionServerURL: URL?

  private var hasValidServerInput: Bool {
    AppState.validatedSyncURL(serverURL) != nil
  }

  private var hasActiveSyncSession: Bool {
    boundActionServerURL != nil
      && state.document.syncState.accountId != nil
      && !state.document.syncState.sessionToken.isEmpty
  }

  private var persistedServerURL: URL? {
    AppState.validatedSyncURL(state.document.syncState.serverURL)
  }

  private var boundActionServerURL: URL? {
    guard
      AppState.syncServerDraftMatchesPersisted(
        serverURL,
        persisted: state.document.syncState.serverURL
      )
    else { return nil }
    return AppState.validatedSyncURL(serverURL)
  }

  private var persistedServerOrigin: String {
    persistedServerURL?.absoluteString ?? "not connected"
  }

  var body: some View {
    Page(
      eyebrow: "Zero knowledge sync",
      title: "Encrypted Sync",
      subtitle:
        "Only opaque encrypted vault snapshots are uploaded. The server never receives decryptable key material.",
      statTitle: "Remote version",
      statValue: "\(state.document.syncState.latestRemoteVersion)"
    ) {
      Surface {
        VStack(alignment: .leading, spacing: 14) {
          SectionHeader(title: "Passkey account", meta: "Authentication only")
          TextField("Sync server URL", text: $serverURL)
            .textFieldStyle(AtlasTextFieldStyle())
            .disabled(
              state.syncing || state.scanning || state.syncPersistencePending
                || state.hasPendingAccountDeletion
            )
          if hasValidServerInput, persistedServerURL != nil, boundActionServerURL == nil {
            Text(
              "This session remains bound to \(persistedServerOrigin). Save the edited server or restore that origin before using existing-session controls."
            )
            .font(.callout)
            .foregroundStyle(AtlasTheme.loss)
          }
          AdaptiveStack {
            Button("Create passkey account") {
              Task {
                await state.createPasskeyAccount(serverURL: serverURL)
                serverURL = state.document.syncState.serverURL
              }
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            .disabled(
              state.syncing || state.scanning || state.syncPersistencePending
                || state.hasPendingAccountDeletion || !hasValidServerInput
            )
            Button("Sign in with passkey") {
              Task {
                await state.signInWithPasskey(serverURL: serverURL)
                serverURL = state.document.syncState.serverURL
              }
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            .disabled(
              state.syncing || state.scanning
                || (state.syncPersistencePending && state.pendingVaultUpload == nil)
                || state.hasPendingAccountDeletion || !hasValidServerInput
            )
            Button("Save server") {
              Task {
                if await state.saveSyncSettings(serverURL: serverURL) {
                  serverURL = state.document.syncState.serverURL
                  await state.refreshEndpointConfig()
                }
              }
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            .disabled(
              state.syncing || state.scanning || state.syncPersistencePending
                || state.hasPendingAccountDeletion || !hasValidServerInput
            )
            Button("Refresh endpoints") {
              Task {
                await state.refreshEndpointConfig()
              }
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            .disabled(
              state.syncing || state.scanning || boundActionServerURL == nil
            )
          }
          AdaptiveStack {
            Button {
              guard let target = boundActionServerURL else { return }
              Task { await state.uploadEncryptedVault(expectedServerURL: target) }
            } label: {
              if state.syncing {
                ProgressView()
              } else {
                Label("Upload encrypted vault", systemImage: "arrow.up.doc")
              }
            }
            .buttonStyle(AtlasPrimaryButtonStyle())
            .disabled(
              state.syncing || state.scanning || state.syncPersistencePending
                || state.hasPendingAccountDeletion || !hasActiveSyncSession
            )
            Button("Download encrypted vault") {
              guard let target = boundActionServerURL else { return }
              if state.hasUnsyncedLocalChanges || state.hasPendingWalletLabelDrafts {
                pendingDownloadServerURL = target
                confirmingDiscardDownload = true
              } else {
                Task { await state.downloadEncryptedVault(expectedServerURL: target) }
              }
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            .disabled(
              state.syncing || state.scanning || state.syncPersistencePending
                || state.hasPendingAccountDeletion || !hasActiveSyncSession
            )
            if state.syncPersistencePending {
              Button(state.pendingVaultUpload == nil ? "Retry local save" : "Retry upload recovery")
              {
                Task { await state.retryPendingSyncPersistence() }
              }
              .buttonStyle(AtlasSecondaryButtonStyle())
              .disabled(state.syncing || state.scanning || state.isUnlocking)
              if state.pendingVaultUpload != nil {
                Button("Stop upload recovery", role: .destructive) {
                  confirmingStopUploadRecovery = true
                }
                .buttonStyle(AtlasSecondaryButtonStyle())
                .disabled(state.syncing || state.scanning || boundActionServerURL == nil)
              }
            }
          }
        }
      }

      Surface {
        VStack(alignment: .leading, spacing: 12) {
          SectionHeader(title: "Sync state", meta: "Plain metadata only")
          KeyValueGrid(rows: [
            ("Server", persistedServerOrigin),
            ("Account", state.document.syncState.accountId ?? "not connected"),
            (
              "Session",
              state.document.syncState.sessionToken.isEmpty ? "sign in required" : "active"
            ),
            (
              "Account deletion",
              state.document.syncState.accountDeletionIdempotencyKey == nil
                ? "not pending"
                : "retry safely with saved operation"
            ),
            ("Endpoint config", state.endpointConfigStatus),
            ("Config version", "\(state.endpointConfig.configVersion)"),
            (
              "Local changes",
              state.syncPersistencePending
                ? state.pendingVaultUpload == nil
                  ? "remote synced; local save pending"
                  : state.pendingVaultUploadHasRemoteConflict
                    ? "upload recovery conflict"
                    : "upload recovery pending"
                : state.hasUnsyncedLocalChanges || state.hasPendingWalletLabelDrafts
                  ? "not uploaded"
                  : "synced"
            ),
            (
              "Local persistence",
              state.pendingVaultUpload != nil
                ? "full local vault protected"
                : state.syncPersistencePending ? "retry required" : "saved"
            ),
            (
              "Last synced",
              state.document.syncState.lastSyncedAt?.formatted(date: .abbreviated, time: .shortened)
                ?? "never"
            ),
            ("Checksum", state.document.syncState.lastChecksum ?? "none"),
          ])
        }
      }

      Surface {
        VStack(alignment: .leading, spacing: 12) {
          SectionHeader(title: "Account controls", meta: persistedServerOrigin)
          Text(
            "Revoking signs out only this Mac. Deleting the sync account removes the remote account and encrypted server snapshots, while keeping this Mac's encrypted local vault."
          )
          .font(.callout)
          .foregroundStyle(AtlasTheme.ink2)
          AdaptiveStack {
            Button("Revoke this Mac's session") {
              guard let target = boundActionServerURL else { return }
              pendingRevocationServerURL = target
              confirmingSessionRevocation = true
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            .disabled(
              state.vaultEditsDisabled || state.document.syncState.sessionToken.isEmpty
                || boundActionServerURL == nil
            )
            Button(
              state.document.syncState.accountDeletionIdempotencyKey == nil
                ? "Delete sync account"
                : "Retry account deletion",
              role: .destructive
            ) {
              guard let target = boundActionServerURL else { return }
              pendingDeletionServerURL = target
              confirmingAccountDeletion = true
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            .disabled(state.accountDeletionControlDisabled || boundActionServerURL == nil)
          }
        }
      }
    }
    .onAppear {
      serverURL = state.document.syncState.serverURL
      Task {
        await state.refreshEndpointConfig(silent: true)
      }
    }
    .confirmationDialog(
      "Stop encrypted upload recovery?",
      isPresented: $confirmingStopUploadRecovery,
      titleVisibility: .visible
    ) {
      Button("Stop recovery and keep local vault", role: .destructive) {
        guard let target = boundActionServerURL else { return }
        Task { await state.abandonPendingVaultUpload(expectedServerURL: target) }
      }
      Button("Continue recovery", role: .cancel) {}
    } message: {
      Text(
        "The full local vault will be kept, but the server may already contain the interrupted upload. Export the local vault as JSON before downloading or otherwise discarding local data."
      )
    }
    .confirmationDialog(
      "Discard local changes and download from \(pendingDownloadServerURL?.absoluteString ?? persistedServerOrigin)?",
      isPresented: $confirmingDiscardDownload,
      titleVisibility: .visible
    ) {
      Button("Discard local changes", role: .destructive) {
        guard let target = pendingDownloadServerURL else { return }
        Task {
          await state.downloadEncryptedVault(
            discardingLocalChanges: true,
            expectedServerURL: target
          )
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This replaces the local vault with the latest authenticated remote snapshot from \(pendingDownloadServerURL?.absoluteString ?? persistedServerOrigin). Export or upload anything you need first."
      )
    }
    .confirmationDialog(
      "Revoke this Mac's sync session on \(pendingRevocationServerURL?.absoluteString ?? persistedServerOrigin)?",
      isPresented: $confirmingSessionRevocation,
      titleVisibility: .visible
    ) {
      Button("Revoke session", role: .destructive) {
        guard let target = pendingRevocationServerURL else { return }
        Task { await state.revokeCurrentSyncSession(expectedServerURL: target) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This revokes the session on \(pendingRevocationServerURL?.absoluteString ?? persistedServerOrigin). This Mac will need a new passkey sign-in before it can sync again. Other signed-in devices are not affected."
      )
    }
    .confirmationDialog(
      "Permanently delete the sync account on \(pendingDeletionServerURL?.absoluteString ?? persistedServerOrigin)?",
      isPresented: $confirmingAccountDeletion,
      titleVisibility: .visible
    ) {
      Button("Delete sync account", role: .destructive) {
        guard let target = pendingDeletionServerURL else { return }
        Task { await state.deleteSyncAccount(expectedServerURL: target) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "A passkey check confirms this destructive action on \(pendingDeletionServerURL?.absoluteString ?? persistedServerOrigin). If a previous attempt had an uncertain network outcome, Address Atlas safely resumes the same deletion operation. This permanently removes the remote account, passkeys, sessions, and encrypted server snapshots; your encrypted local vault on this Mac is kept."
      )
    }
  }
}

enum ExportPayload: Sendable {
  case csv([TrackedAsset])
  case json(VaultDocument)

  var suggestedName: String {
    switch self {
    case .csv: "address-atlas-holdings.csv"
    case .json: "address-atlas-vault.json"
    }
  }

  var contentType: UTType {
    switch self {
    case .csv: .commaSeparatedText
    case .json: .json
    }
  }

  var displayName: String {
    switch self {
    case .csv: "CSV"
    case .json: "JSON"
    }
  }
}

enum ExportPipeline {
  static let maximumPreviewByteCount = 256 * 1_024

  nonisolated static func data(for payload: ExportPayload) throws -> Data {
    switch payload {
    case .csv(let assets):
      return Data(AddressAtlasExporter.csv(for: assets).utf8)
    case .json(let document):
      return try AddressAtlasExporter.json(for: document)
    }
  }

  nonisolated static func preview(
    for data: Data,
    maximumByteCount: Int = maximumPreviewByteCount
  ) -> String {
    guard maximumByteCount > 0 else {
      return data.isEmpty ? "" : "Preview omitted. The saved export still includes all records."
    }
    guard data.count > maximumByteCount else {
      return String(decoding: data, as: UTF8.self)
    }
    return String(decoding: data.prefix(maximumByteCount), as: UTF8.self)
      + "\n\n— Preview truncated to \(maximumByteCount.formatted()) bytes. The saved export includes all records."
  }

  nonisolated static func renderPreview(for payload: ExportPayload) throws -> String {
    try preview(for: data(for: payload))
  }

  nonisolated static func write(_ payload: ExportPayload, to url: URL) throws -> String {
    let exportData = try data(for: payload)
    try exportData.write(to: url, options: .atomic)
    return preview(for: exportData)
  }
}

struct ExportView: View {
  @EnvironmentObject private var state: AppState
  @State private var exportedPreview = ""

  var body: some View {
    Page(
      eyebrow: "Local reports",
      title: "Export",
      subtitle: "Generate CSV or JSON from the encrypted vault after unlock.",
      statTitle: "Latest assets",
      statValue: "\(state.latestScan?.holdings.count ?? 0)"
    ) {
      AdaptiveStack {
        Button("Generate CSV") {
          guard let payload = csvPayloadIncludingDrafts() else { return }
          generatePreview(for: payload)
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        Button("Save CSV") {
          guard let payload = csvPayloadIncludingDrafts() else { return }
          save(payload)
        }
        .buttonStyle(AtlasPrimaryButtonStyle())
        Button("Generate JSON") {
          guard let payload = jsonPayloadIncludingDrafts() else { return }
          generatePreview(for: payload)
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        Button("Save JSON") {
          guard let payload = jsonPayloadIncludingDrafts() else { return }
          save(payload)
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        if state.isExportOperationInProgress {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Preparing export")
        }
      }
      .disabled(state.isExportOperationInProgress)
      Surface {
        ScrollView([.vertical, .horizontal]) {
          Text(
            exportedPreview.isEmpty
              ? "Generate an export to inspect a bounded, read-only preview."
              : exportedPreview
          )
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .accessibilityLabel("Read-only export preview")
        }
        .frame(minHeight: 280, maxHeight: 520)
      }
    }
  }

  private func generatePreview(for payload: ExportPayload) {
    guard state.beginExportOperation() else { return }
    state.error = ""
    Task { @MainActor in
      defer { state.finishExportOperation() }
      do {
        exportedPreview = try await Task.detached(priority: .userInitiated) {
          try ExportPipeline.renderPreview(for: payload)
        }.value
      } catch {
        state.presentUserFacingError(error)
      }
    }
  }

  private func csvPayloadIncludingDrafts() -> ExportPayload? {
    payloadIncludingDrafts {
      .csv(try state.holdingsForExportIncludingWalletLabelDrafts())
    }
  }

  private func jsonPayloadIncludingDrafts() -> ExportPayload? {
    payloadIncludingDrafts {
      .json(try state.documentForExportIncludingWalletLabelDrafts())
    }
  }

  private func payloadIncludingDrafts(
    _ makePayload: () throws -> ExportPayload
  ) -> ExportPayload? {
    do {
      return try makePayload()
    } catch WalletLabelDraftError.invalidLabel {
      state.notice = ""
      state.error = "Wallet labels must be between 1 and 80 characters before exporting."
      return nil
    } catch {
      state.presentUserFacingError(error)
      return nil
    }
  }

  private func save(_ payload: ExportPayload) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = payload.suggestedName
    panel.allowedContentTypes = [payload.contentType]
    panel.canCreateDirectories = true
    if panel.runModal() == .OK, let url = panel.url {
      guard state.beginExportOperation() else { return }
      state.error = ""
      Task { @MainActor in
        defer { state.finishExportOperation() }
        do {
          exportedPreview = try await Task.detached(priority: .userInitiated) {
            try ExportPipeline.write(payload, to: url)
          }.value
          state.notice = "\(payload.displayName) export saved."
          state.error = ""
        } catch {
          state.presentUserFacingError(error)
        }
      }
    }
  }
}

struct SettingsView: View {
  @EnvironmentObject private var state: AppState
  @State private var recoveryCode = ""
  @State private var restoreCode = ""

  var body: some View {
    Page(
      eyebrow: "Local preferences",
      title: "Settings",
      subtitle: "Display and scan preferences stored inside the encrypted vault.",
      statTitle: "Currency",
      statValue: "USD"
    ) {
      Surface {
        VStack(alignment: .leading, spacing: 18) {
          SectionHeader(title: "Scan behavior", meta: "Encrypted preferences")
          Toggle(
            "Auto-refresh",
            isOn: Binding(
              get: {
                state.document.preferences.autoRefresh
              },
              set: {
                let value = $0
                Task { await state.setAutoRefresh(value) }
              }))
          Text(
            "When enabled, Address Atlas refreshes saved sources every 15 minutes while the app is open and unlocked."
          )
          .font(.callout)
          .foregroundStyle(AtlasTheme.ink3)
          Toggle(
            "Hide dust",
            isOn: Binding(
              get: {
                state.document.preferences.hideDust
              },
              set: {
                let value = $0
                Task { await state.setHideDust(value) }
              }))
          AdaptiveStack(horizontalSpacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
              AtlasLabel("Dust threshold (USD)")
              TextField(
                "0.00",
                value: Binding(
                  get: {
                    state.document.preferences.dustThreshold
                  },
                  set: {
                    let value = $0
                    Task { await state.setDustThreshold(value) }
                  }), format: .number
              )
              .textFieldStyle(AtlasTextFieldStyle())
              .accessibilityLabel("Dust threshold in US dollars")
            }
            VStack(alignment: .leading, spacing: 7) {
              AtlasLabel("Display currency")
              HStack {
                Text("USD")
                  .font(.callout.monospaced().weight(.semibold))
                Spacer()
                Badge("PRICE SOURCE")
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .frame(minHeight: 40)
              .overlay(Rectangle().stroke(AtlasTheme.rule, lineWidth: 1))
            }
          }
        }
      }
      .disabled(state.vaultEditsDisabled)

      Surface {
        VStack(alignment: .leading, spacing: 16) {
          SectionHeader(title: "Recovery kit", meta: "File plus code")
          Text(
            "Export a recovery file and store the recovery code separately. Both are required to restore the Mac vault key."
          )
          .font(.callout)
          .foregroundStyle(AtlasTheme.ink2)
          AdaptiveStack {
            Button("Export recovery kit") {
              exportRecoveryKit()
            }
            .buttonStyle(AtlasPrimaryButtonStyle())
            SecureField("Recovery code for restore", text: $restoreCode)
              .textFieldStyle(AtlasTextFieldStyle())
              .accessibilityLabel("Recovery code for restore")
            Button("Restore from kit") {
              restoreRecoveryKit()
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            .disabled(
              state.vaultEditsDisabled
                || restoreCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
          }
          if !recoveryCode.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              AtlasLabel("Store this code separately")
              Text(recoveryCode)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AtlasTheme.paper2)
                .overlay(Rectangle().stroke(AtlasTheme.ruleSoft, lineWidth: 1))
            }
          }
        }
      }
    }
  }

  private func exportRecoveryKit() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "address-atlas.atlas-recovery"
    panel.allowedContentTypes = [UTType(filenameExtension: "atlas-recovery") ?? .data]
    panel.canCreateDirectories = true
    if panel.runModal() == .OK, let url = panel.url {
      do {
        recoveryCode = try state.exportRecoveryKit(to: url)
      } catch {
        state.presentUserFacingError(error)
      }
    }
  }

  private func restoreRecoveryKit() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "atlas-recovery") ?? .data]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    if panel.runModal() == .OK, let url = panel.url {
      Task {
        await state.restoreRecoveryKit(from: url, recoveryCode: restoreCode)
      }
    }
  }
}
