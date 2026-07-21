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

private struct SyncActionLabel: View {
  var idleTitle: String
  var systemImage: String?
  var activity: SyncActivity
  var activeActivity: SyncActivity?

  @ViewBuilder
  var body: some View {
    if activeActivity == activity {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text(activity.progressTitle)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(activity.accessibilityLabel)
    } else if let systemImage {
      Label(idleTitle, systemImage: systemImage)
    } else {
      Text(idleTitle)
    }
  }
}

struct SyncView: View {
  @EnvironmentObject private var state: AppState
  @State private var serverURL = ""
  @State private var confirmingDiscardDownload = false
  @State private var confirmingSessionRevocation = false
  @State private var confirmingAccountDeletion = false
  @State private var confirmingAccountDisconnect = false
  @State private var confirmingStopUploadRecovery = false
  @State private var confirmingRollbackRestore = false
  @State private var pendingDownloadServerURL: URL?
  @State private var pendingRevocationServerURL: URL?
  @State private var pendingDeletionServerURL: URL?
  @State private var pendingDisconnectServerURL: URL?

  private var hasValidServerInput: Bool {
    AppState.validatedSyncURL(serverURL) != nil
  }

  private var hasActiveSyncSession: Bool {
    boundActionServerURL != nil
      && state.document.syncState.accountId != nil
      && !state.document.syncState.sessionToken.isEmpty
  }

  private var hasConnectedSyncAccount: Bool {
    state.document.syncState.accountId.flatMap(SyncAccountIdentifier.normalized) != nil
  }

  private var pendingRetryActivity: SyncActivity {
    state.pendingVaultUpload == nil ? .retryingLocalSave : .recoveringUpload
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
                || state.hasPendingAccountDeletion || hasConnectedSyncAccount
            )
          if hasConnectedSyncAccount {
            Text(
              persistedServerURL == nil
                ? "This vault has connected account metadata, but its saved server is invalid. Account switching is locked to protect the sync baseline; restore a valid local vault before continuing."
                : "This vault is connected to \(persistedServerOrigin). Disconnect this Mac explicitly before changing the server or creating another account. Sign in remains available to refresh the current account's session."
            )
            .font(.callout)
            .foregroundStyle(persistedServerURL == nil ? AtlasTheme.loss : AtlasTheme.ink2)
          } else if hasValidServerInput, persistedServerURL != nil,
            boundActionServerURL == nil
          {
            Text(
              "The saved sync server remains \(persistedServerOrigin). Save the edited server or restore that origin before using existing-server controls."
            )
            .font(.callout)
            .foregroundStyle(AtlasTheme.loss)
          }
          AdaptiveStack {
            Button {
              Task {
                await state.createPasskeyAccount(serverURL: serverURL)
                serverURL = state.document.syncState.serverURL
              }
            } label: {
              SyncActionLabel(
                idleTitle: "Create passkey account",
                systemImage: "key.badge.plus",
                activity: .creatingPasskeyAccount,
                activeActivity: state.syncActivity
              )
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            .disabled(
              state.syncing || state.scanning || state.syncPersistencePending
                || state.hasPendingAccountDeletion || !hasValidServerInput
                || hasConnectedSyncAccount
            )
            Button {
              Task {
                await state.signInWithPasskey(serverURL: serverURL)
                serverURL = state.document.syncState.serverURL
              }
            } label: {
              SyncActionLabel(
                idleTitle: "Sign in with passkey",
                systemImage: "key.fill",
                activity: .signingIn,
                activeActivity: state.syncActivity
              )
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
                || hasConnectedSyncAccount
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
              SyncActionLabel(
                idleTitle: "Upload encrypted vault",
                systemImage: "arrow.up.doc",
                activity: .uploadingVault,
                activeActivity: state.syncActivity
              )
            }
            .buttonStyle(AtlasPrimaryButtonStyle())
            .disabled(
              state.syncing || state.scanning || state.syncPersistencePending
                || state.hasPendingAccountDeletion || !hasActiveSyncSession
            )
            Button {
              guard let target = boundActionServerURL else { return }
              if state.hasUnsyncedLocalChanges || state.hasPendingWalletLabelDrafts {
                pendingDownloadServerURL = target
                confirmingDiscardDownload = true
              } else {
                Task { await state.downloadEncryptedVault(expectedServerURL: target) }
              }
            } label: {
              SyncActionLabel(
                idleTitle: "Download encrypted vault",
                systemImage: "arrow.down.doc",
                activity: .downloadingVault,
                activeActivity: state.syncActivity
              )
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            .disabled(
              state.syncing || state.scanning || state.syncPersistencePending
                || state.hasPendingAccountDeletion || !hasActiveSyncSession
            )
            if state.syncPersistencePending {
              Button {
                Task { await state.retryPendingSyncPersistence() }
              } label: {
                SyncActionLabel(
                  idleTitle: state.pendingVaultUpload == nil
                    ? "Retry local save"
                    : "Retry upload recovery",
                  systemImage: "arrow.clockwise",
                  activity: pendingRetryActivity,
                  activeActivity: state.syncActivity
                )
              }
              .buttonStyle(AtlasSecondaryButtonStyle())
              .disabled(state.syncing || state.scanning || state.isUnlocking)
              if state.pendingVaultUpload != nil {
                Button(role: .destructive) {
                  confirmingStopUploadRecovery = true
                } label: {
                  SyncActionLabel(
                    idleTitle: "Stop upload recovery",
                    systemImage: "stop.circle",
                    activity: .stoppingUploadRecovery,
                    activeActivity: state.syncActivity
                  )
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
          SectionHeader(
            title: "Automatic encrypted rollback",
            meta: state.hasVaultRollbackCheckpoint ? "Ready to restore" : "No restore point"
          )
          Text(
            "Before a remote download replaces local data, Address Atlas automatically saves the previous vault content and credentials as an encrypted rollback point. Restoring it keeps the current sync account and remote baseline, replaces the remaining local content, and consumes that point. CSV and JSON exports are redacted reports—not backups—and cannot restore credentials or serve as rollback points."
          )
          .font(.callout)
          .foregroundStyle(AtlasTheme.ink2)
          Button(role: .destructive) {
            confirmingRollbackRestore = true
          } label: {
            SyncActionLabel(
              idleTitle: "Restore previous encrypted local content",
              systemImage: "arrow.uturn.backward.circle",
              activity: .restoringRollbackCheckpoint,
              activeActivity: state.syncActivity
            )
          }
          .buttonStyle(AtlasSecondaryButtonStyle())
          .disabled(
            !state.hasVaultRollbackCheckpoint || state.vaultEditsDisabled
          )
        }
      }

      Surface {
        VStack(alignment: .leading, spacing: 12) {
          SectionHeader(title: "Account controls", meta: persistedServerOrigin)
          Text(
            "Revoking signs out only this Mac. Disconnecting revokes this Mac's session and clears its local account binding so you can switch, while keeping the remote account and encrypted server vault. Deleting permanently removes the remote account and its server snapshots. Every option keeps this Mac's encrypted local vault."
          )
          .font(.callout)
          .foregroundStyle(AtlasTheme.ink2)
          AdaptiveStack {
            Button {
              guard let target = boundActionServerURL else { return }
              pendingRevocationServerURL = target
              confirmingSessionRevocation = true
            } label: {
              SyncActionLabel(
                idleTitle: "Revoke this Mac's session",
                systemImage: "rectangle.portrait.and.arrow.right",
                activity: .revokingSession,
                activeActivity: state.syncActivity
              )
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            .disabled(
              state.vaultEditsDisabled || state.document.syncState.sessionToken.isEmpty
                || boundActionServerURL == nil
            )
            Button(role: .destructive) {
              guard let target = persistedServerURL else { return }
              pendingDisconnectServerURL = target
              confirmingAccountDisconnect = true
            } label: {
              SyncActionLabel(
                idleTitle: "Disconnect to switch account or server",
                systemImage: "arrow.triangle.branch",
                activity: .disconnectingAccount,
                activeActivity: state.syncActivity
              )
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            .disabled(
              state.vaultEditsDisabled || !hasConnectedSyncAccount || persistedServerURL == nil
            )
            Button(role: .destructive) {
              guard let target = boundActionServerURL else { return }
              pendingDeletionServerURL = target
              confirmingAccountDeletion = true
            } label: {
              SyncActionLabel(
                idleTitle: state.document.syncState.accountDeletionIdempotencyKey == nil
                  ? "Delete sync account"
                  : "Retry account deletion",
                systemImage: "trash",
                activity: .deletingAccount,
                activeActivity: state.syncActivity
              )
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
      "Restore the previous encrypted local content?",
      isPresented: $confirmingRollbackRestore,
      titleVisibility: .visible
    ) {
      Button("Restore previous local content", role: .destructive) {
        Task { await state.restoreVaultRollbackCheckpoint() }
      }
      Button("Keep current local vault", role: .cancel) {}
    } message: {
      Text(
        "This restores the rollback point's settings, wallets, holdings, scan history, exchange connections, and credentials while keeping the current sync account and remote baseline. It then consumes the restore point. The remote vault is not changed unless you upload afterward."
      )
    }
    .confirmationDialog(
      "Disconnect this Mac to switch sync accounts or servers?",
      isPresented: $confirmingAccountDisconnect,
      titleVisibility: .visible
    ) {
      Button("Disconnect and allow switching", role: .destructive) {
        guard let target = pendingDisconnectServerURL else { return }
        let requestedServerDraft = serverURL
        Task {
          await state.disconnectSyncAccountForSwitch(expectedServerURL: target)
          if state.document.syncState.accountId == nil {
            serverURL =
              AppState.validatedSyncURL(requestedServerDraft) == nil
              ? state.document.syncState.serverURL
              : requestedServerDraft
          } else {
            serverURL = state.document.syncState.serverURL
          }
        }
      }
      Button("Keep current connection", role: .cancel) {}
    } message: {
      Text(
        "This first permanently removes any automatic rollback point tied to the current account, then revokes this Mac's server session when possible and clears its local account binding and sync baseline. It does not delete the remote account, passkeys, encrypted remote vault, or this Mac's encrypted local vault."
      )
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
        "The full local vault will be kept, but the server may already contain the interrupted upload. CSV and JSON exports are redacted reports, not backups. If a later remote download replaces this vault, Address Atlas will first create an automatic encrypted rollback point."
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
        "This replaces the local vault with the latest authenticated remote snapshot from \(pendingDownloadServerURL?.absoluteString ?? persistedServerOrigin). Address Atlas first saves the current local content and credentials as an automatic encrypted rollback point; a later restore keeps the downloaded sync account and remote baseline. CSV and JSON exports are redacted reports, not backups. Upload anything you need on the server before continuing."
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
        "A passkey check confirms this destructive action on \(pendingDeletionServerURL?.absoluteString ?? persistedServerOrigin). If a previous attempt had an uncertain network outcome, Address Atlas safely resumes the same deletion operation. This permanently removes the remote account, passkeys, sessions, encrypted server snapshots, and any automatic rollback point tied to that account; your encrypted local vault on this Mac is kept."
      )
    }
  }
}

enum ExportPayload: Sendable {
  case csv([TrackedAsset])
  case json(VaultDocument)

  var suggestedName: String {
    switch self {
    case .csv: "address-atlas-holdings-report.csv"
    case .json: "address-atlas-redacted-report.json"
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
    case .csv: "CSV report"
    case .json: "JSON report"
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
      subtitle:
        "Generate redacted CSV or JSON reports after unlock. They are not backups and cannot restore credentials or sync state; destructive sync downloads create an automatic encrypted rollback point first.",
      statTitle: "Latest assets",
      statValue: "\(state.latestScan?.holdings.count ?? 0)"
    ) {
      AdaptiveStack {
        Button("Generate CSV report") {
          guard let payload = csvPayloadIncludingDrafts() else { return }
          generatePreview(for: payload)
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        Button("Save CSV report") {
          guard let payload = csvPayloadIncludingDrafts() else { return }
          save(payload)
        }
        .buttonStyle(AtlasPrimaryButtonStyle())
        Button("Generate JSON report") {
          guard let payload = jsonPayloadIncludingDrafts() else { return }
          generatePreview(for: payload)
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        Button("Save JSON report") {
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
      ExportPreview(exportedPreview: exportedPreview)
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
          state.notice = "\(payload.displayName) saved."
          state.error = ""
        } catch {
          state.presentUserFacingError(error)
        }
      }
    }
  }
}

struct ExportPreview: View {
  static let contentAccessibilityIdentifier = "export-preview-content"

  var exportedPreview: String

  var displayedText: String {
    exportedPreview.isEmpty
      ? "Generate a redacted report to inspect a bounded, read-only preview."
      : exportedPreview
  }

  var accessibilityContent: String { displayedText }

  var body: some View {
    Surface {
      VStack(alignment: .leading, spacing: 10) {
        AtlasLabel("Read-only redacted report preview")
          .accessibilityAddTraits(.isHeader)
        ScrollView([.vertical, .horizontal]) {
          Text(displayedText)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // The label is the generated content itself—not the section title—
            // so VoiceOver can inspect the same bounded preview as sighted users.
            .accessibilityLabel(accessibilityContent)
            .accessibilityIdentifier(Self.contentAccessibilityIdentifier)
        }
        .frame(minHeight: 280, maxHeight: 520)
      }
      .accessibilityElement(children: .contain)
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
