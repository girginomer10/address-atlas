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
      Text(
        "The encrypted API credentials will be removed from this Mac and from its automatic rollback point. A previously uploaded encrypted snapshot may still contain them until you upload the replacement vault."
      )
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
  @State private var confirmingLocalAccountDisconnect = false
  @State private var confirmingStopUploadRecovery = false
  @State private var confirmingDiscardQuarantinedUpload = false
  @State private var confirmingRollbackRestore = false
  @State private var pendingDownloadServerURL: URL?
  @State private var pendingRevocationServerURL: URL?
  @State private var pendingDeletionServerURL: URL?
  @State private var pendingDisconnectServerURL: URL?
  @State private var pendingLocalDisconnectServerURL: URL?
  @State private var sessionEvaluationDate = Date()

  private var hasValidServerInput: Bool {
    AppState.validatedSyncURL(serverURL) != nil
  }

  private var hasActiveSyncSession: Bool {
    boundActionServerURL != nil
      && state.document.syncState.accountId != nil
      && state.hasUsableSyncSession(at: sessionEvaluationDate)
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
      statTitle: "Last confirmed remote version",
      statValue: AppState.remoteVersionStatus(state.document.syncState)
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
              if state.hasUnsyncedLocalChanges || state.hasPendingWalletLabelDrafts
                || state.document.syncState.remoteOutcomeUncertain
              {
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
              if state.quarantinedPendingVaultUpload != nil {
                Button(role: .destructive) {
                  confirmingDiscardQuarantinedUpload = true
                } label: {
                  Label("Discard damaged recovery record", systemImage: "exclamationmark.shield")
                }
                .buttonStyle(AtlasSecondaryButtonStyle())
                .disabled(state.syncing || state.scanning || state.isUnlocking)
              } else {
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
              }
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
              state.syncSessionStatus(at: sessionEvaluationDate)
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
                ? state.quarantinedPendingVaultUpload != nil
                  ? "recovery record quarantined; read-only"
                  : state.pendingVaultUpload == nil
                  ? "remote synced; local save pending"
                  : state.pendingVaultUploadHasRemoteConflict
                    ? "upload recovery conflict"
                    : "upload recovery pending"
                : state.document.syncState.remoteOutcomeUncertain
                  ? "remote outcome unknown; reconcile required"
                  : state.document.syncState.pendingExchangeCredentialCleanup
                    ? "remote credential cleanup pending"
                  : state.hasUnsyncedLocalChanges || state.hasPendingWalletLabelDrafts
                  ? "local changes not confirmed remotely"
                  : "synced"
            ),
            (
              "Local persistence",
              state.quarantinedPendingVaultUpload != nil
                ? "primary vault protected; damaged journal quarantined"
                : state.pendingVaultUpload != nil
                ? "full local vault protected"
                : state.syncPersistencePending ? "retry required" : "saved"
            ),
            (
              "Exchange credential cleanup",
              state.document.syncState.pendingExchangeCredentialCleanup
                ? "remote replacement upload required"
                : "no pending remote cleanup"
            ),
            (
              "Last confirmed sync",
              AppState.lastConfirmedSyncStatus(state.document.syncState)
            ),
            (
              "Last confirmed checksum",
              AppState.lastConfirmedChecksumStatus(state.document.syncState)
            ),
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
            "Before a remote download replaces local data, Address Atlas automatically saves the previous vault content and credentials as an encrypted rollback point. Restoring it keeps the current sync account and remote baseline, replaces the remaining local content, and consumes that point. Portfolio exports omit credentials but include identifying addresses, labels, balances, and history; they are not backups and cannot serve as rollback points."
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
            "Revoking signs out only this Mac. Disconnecting revokes this Mac's session and clears its local account binding so you can switch, while keeping the remote account and encrypted server vault. If the server is unavailable, an explicit local-only disconnect remains available. Deleting permanently removes the remote account and its server snapshots. Every option keeps this Mac's encrypted local vault."
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
              state.vaultEditsDisabled || !state.hasUsableSyncSession(at: sessionEvaluationDate)
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
              guard let target = persistedServerURL else { return }
              pendingLocalDisconnectServerURL = target
              confirmingLocalAccountDisconnect = true
            } label: {
              Label("Disconnect locally without contacting server", systemImage: "wifi.slash")
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
      sessionEvaluationDate = Date()
      serverURL = state.document.syncState.serverURL
      Task {
        await state.refreshEndpointConfig(silent: true)
      }
    }
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(30))
        sessionEvaluationDate = Date()
      }
    }
    .confirmationDialog(
      "Discard the damaged encrypted upload recovery record?",
      isPresented: $confirmingDiscardQuarantinedUpload,
      titleVisibility: .visible
    ) {
      Button("Discard only the damaged recovery record", role: .destructive) {
        Task { await state.discardQuarantinedPendingVaultUpload() }
      }
      Button("Keep vault read-only", role: .cancel) {}
    } message: {
      Text(
        "Your full local vault will be kept. Only the exact quarantined upload journal row will be removed. Because its interrupted remote result cannot be recovered, Address Atlas will mark the remote outcome unknown and require reconciliation before a later destructive download."
      )
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
        "This revokes this Mac's server session, then atomically clears its local account binding, sync baseline, and any automatic rollback point tied to the current account. If the server cannot be reached, nothing local is removed. It does not delete the remote account, passkeys, encrypted remote vault, or this Mac's encrypted local vault."
      )
    }
    .confirmationDialog(
      "Disconnect locally without contacting the sync server?",
      isPresented: $confirmingLocalAccountDisconnect,
      titleVisibility: .visible
    ) {
      Button("Disconnect locally", role: .destructive) {
        guard let target = pendingLocalDisconnectServerURL else { return }
        let requestedServerDraft = serverURL
        Task {
          await state.disconnectSyncAccountLocallyForSwitch(expectedServerURL: target)
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
        "Use this only when the saved server cannot be reached. Address Atlas will atomically remove this Mac's local account binding, bearer token, sync baseline, and account-bound rollback point without making a server request. The remote account and encrypted vault remain, and this Mac's old server session may remain valid until it expires or is revoked elsewhere."
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
        "The full local vault will be kept, but the server may already contain the interrupted upload. Portfolio exports omit credentials but include identifying addresses, labels, balances, and history; they are not backups. If a later remote download replaces this vault, Address Atlas will first create an automatic encrypted rollback point."
      )
    }
    .confirmationDialog(
      state.document.syncState.remoteOutcomeUncertain
        ? "Reconcile the unknown remote upload outcome by downloading from \(pendingDownloadServerURL?.absoluteString ?? persistedServerOrigin)?"
        : "Discard local changes and download from \(pendingDownloadServerURL?.absoluteString ?? persistedServerOrigin)?",
      isPresented: $confirmingDiscardDownload,
      titleVisibility: .visible
    ) {
      Button(
        state.document.syncState.remoteOutcomeUncertain
          ? "Download and reconcile unknown outcome" : "Discard local changes",
        role: .destructive
      ) {
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
        state.document.syncState.remoteOutcomeUncertain
          ? "The last upload response was not confirmed, so the server may contain either the old or new encrypted vault. This downloads the latest authenticated snapshot to reconcile that uncertainty and replaces local content only after saving an automatic encrypted rollback point. Review the remote result carefully."
          : "This replaces the local vault with the latest authenticated remote snapshot from \(pendingDownloadServerURL?.absoluteString ?? persistedServerOrigin). Address Atlas first saves the current local content and credentials as an automatic encrypted rollback point; a later restore keeps the downloaded sync account and remote baseline. Portfolio exports omit credentials but include identifying addresses, labels, balances, and history; they are not backups. Upload anything you need on the server before continuing."
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
  case shareSafeCSV(VaultDocument)
  case shareSafeJSON(VaultDocument)
  case csv([TrackedAsset])
  case json(VaultDocument)

  var suggestedName: String {
    switch self {
    case .shareSafeCSV: "address-atlas-share-safer-summary.csv"
    case .shareSafeJSON: "address-atlas-share-safer-summary.json"
    case .csv: "address-atlas-full-identifying-holdings-report.csv"
    case .json: "address-atlas-full-identifying-portfolio-report.json"
    }
  }

  var contentType: UTType {
    switch self {
    case .shareSafeCSV, .csv: .commaSeparatedText
    case .shareSafeJSON, .json: .json
    }
  }

  var displayName: String {
    switch self {
    case .shareSafeCSV: "Share-safer CSV summary"
    case .shareSafeJSON: "Share-safer JSON summary"
    case .csv: "Full identifying CSV report"
    case .json: "Full identifying JSON report"
    }
  }

  var isShareSafer: Bool {
    switch self {
    case .shareSafeCSV, .shareSafeJSON: true
    case .csv, .json: false
    }
  }
}

enum ExportPipeline {
  static let maximumPreviewByteCount = 256 * 1_024

  nonisolated static func data(for payload: ExportPayload) throws -> Data {
    switch payload {
    case .shareSafeCSV(let document):
      return Data(try AddressAtlasExporter.shareSafeCSV(for: document).utf8)
    case .shareSafeJSON(let document):
      return try AddressAtlasExporter.shareSafeJSON(for: document)
    case .csv(let assets):
      return Data(try AddressAtlasExporter.csv(for: assets).utf8)
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
  static let shareSaferExplanation =
    "It omits addresses, labels, symbols, names, record IDs, URLs, notes, history, timestamps, settings, credentials, sessions, and exact amounts, prices, and values. The latest holdings are grouped only by closed source categories and coarse ranges."
  static let fullIdentifyingExplanation =
    "Full exports are credential-free but identifying. CSV includes the latest addresses, labels, asset names, and exact balances. JSON also includes portfolio records, settings, timestamps, and scan history. They omit exchange credentials and sync authentication, and they are not backups."

  @EnvironmentObject private var state: AppState
  @State private var exportedPreview = ""
  @State private var showFullIdentifyingExports = false

  var body: some View {
    Page(
      eyebrow: "Local reports",
      title: "Export",
      subtitle:
        "Use the share-safer summary for intentional sharing. Full identifying reports remain available behind an explicit disclosure.",
      statTitle: "Latest assets",
      statValue: "\(state.latestScan?.holdings.count ?? 0)"
    ) {
      Surface {
        VStack(alignment: .leading, spacing: 14) {
          SectionHeader(title: "Share-safer summary", meta: "Recommended · not anonymous")
          Text(ShareSafePortfolioReport.privacyNotice)
            .font(.body.weight(.semibold))
            .foregroundStyle(AtlasTheme.ink)
          Text(Self.shareSaferExplanation)
            .font(.callout)
            .foregroundStyle(AtlasTheme.ink2)
          AdaptiveStack {
            Button("Save share-safer CSV") {
              save(.shareSafeCSV(state.document))
            }
            .buttonStyle(AtlasPrimaryButtonStyle())
            Button("Preview share-safer CSV") {
              generatePreview(for: .shareSafeCSV(state.document))
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            Button("Save share-safer JSON") {
              save(.shareSafeJSON(state.document))
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            Button("Preview share-safer JSON") {
              generatePreview(for: .shareSafeJSON(state.document))
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
          }
          .disabled(state.isExportOperationInProgress)
          if state.isExportOperationInProgress {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("Preparing export")
          }
        }
      }

      Surface {
        DisclosureGroup(isExpanded: $showFullIdentifyingExports) {
          VStack(alignment: .leading, spacing: 14) {
            Text(Self.fullIdentifyingExplanation)
              .font(.callout)
              .foregroundStyle(AtlasTheme.loss)
            AdaptiveStack {
              Button("Preview full identifying CSV") {
                guard let payload = csvPayloadIncludingDrafts() else { return }
                generatePreview(for: payload)
              }
              .buttonStyle(AtlasSecondaryButtonStyle())
              Button("Save full identifying CSV") {
                guard let payload = csvPayloadIncludingDrafts() else { return }
                save(payload)
              }
              .buttonStyle(AtlasSecondaryButtonStyle())
              Button("Preview full identifying JSON") {
                guard let payload = jsonPayloadIncludingDrafts() else { return }
                generatePreview(for: payload)
              }
              .buttonStyle(AtlasSecondaryButtonStyle())
              Button("Save full identifying JSON") {
                guard let payload = jsonPayloadIncludingDrafts() else { return }
                save(payload)
              }
              .buttonStyle(AtlasSecondaryButtonStyle())
            }
            .disabled(state.isExportOperationInProgress)
          }
          .padding(.top, 12)
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text("Full identifying exports")
              .font(.headline)
            Text("Secondary · disclose addresses, balances, and portfolio details")
              .font(.caption)
              .foregroundStyle(AtlasTheme.ink3)
          }
        }
        .accessibilityIdentifier("full-identifying-export-disclosure")
      }

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

struct ExportPreviewRow: Identifiable, Equatable, Sendable {
  let id: Int
  let sourceLine: Int
  let part: Int
  let partCount: Int
  let content: String

  var locationLabel: String {
    if partCount == 1 {
      return "Line \(sourceLine)"
    }
    return "Line \(sourceLine), part \(part) of \(partCount)"
  }

  var visibleContent: String { content.isEmpty ? " " : content }
  var accessibilityValue: String { content.isEmpty ? "Empty line" : content }
  var accessibilityIdentifier: String { "export-preview-row-\(id)" }
}

struct ExportPreviewAccessibilityModel: Equatable, Sendable {
  static let maximumNodeValueByteCount = 512
  static let maximumNavigableRowCount = 2_048
  static let maximumSummaryByteCount = 256

  let rows: [ExportPreviewRow]
  let sourceLineCount: Int
  let sourceByteCount: Int
  let didOmitContent: Bool

  init(text: String) {
    let splitLines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let sourceLines = splitLines.isEmpty ? [text[...]] : splitLines
    var generatedRows: [ExportPreviewRow] = []
    generatedRows.reserveCapacity(min(sourceLines.count, Self.maximumNavigableRowCount))

    rowGeneration: for (lineIndex, sourceLine) in sourceLines.enumerated() {
      let chunks = Self.boundedUTF8Chunks(String(sourceLine))
      for (chunkIndex, chunk) in chunks.enumerated() {
        guard generatedRows.count < Self.maximumNavigableRowCount else {
          break rowGeneration
        }
        generatedRows.append(
          ExportPreviewRow(
            id: generatedRows.count + 1,
            sourceLine: lineIndex + 1,
            part: chunkIndex + 1,
            partCount: chunks.count,
            content: chunk
          )
        )
      }
    }

    rows = generatedRows
    sourceLineCount = sourceLines.count
    sourceByteCount = text.utf8.count
    didOmitContent = generatedRows.last?.sourceLine != sourceLines.count
      || generatedRows.last?.part != generatedRows.last?.partCount
  }

  var spokenSummary: String {
    if didOmitContent {
      return
        "Read-only export preview. Showing the first \(rows.count) navigable rows from \(sourceLineCount) lines. Save the report to inspect all content."
    }
    return "Read-only export preview. \(sourceLineCount) lines in \(rows.count) navigable rows."
  }

  var accessibilitySummaryLabel: String { "Preview summary: \(spokenSummary)" }

  static let navigationHint =
    "Navigate the table by row. Long source lines are split into numbered parts."

  private static func boundedUTF8Chunks(_ text: String) -> [String] {
    guard !text.isEmpty else { return [""] }

    let bytes = Array(text.utf8)
    var chunks: [String] = []
    var start = 0

    while start < bytes.count {
      var end = min(start + maximumNodeValueByteCount, bytes.count)
      if end < bytes.count {
        while end > start, bytes[end] & 0xC0 == 0x80 {
          end -= 1
        }
      }
      // A UTF-8 scalar is at most four bytes, well below the configured bound.
      precondition(end > start)
      chunks.append(String(decoding: bytes[start..<end], as: UTF8.self))
      start = end
    }

    return chunks
  }
}

struct ExportPreview: View {
  static let contentAccessibilityIdentifier = "export-preview-content"

  var exportedPreview: String

  var displayedText: String {
    exportedPreview.isEmpty
      ? "Preview the recommended share-safer summary here. It reduces direct exposure, but portfolio composition can still identify you; it is not anonymous."
      : exportedPreview
  }

  var accessibilityModel: ExportPreviewAccessibilityModel {
    ExportPreviewAccessibilityModel(text: displayedText)
  }

  var body: some View {
    let model = accessibilityModel

    Surface {
      VStack(alignment: .leading, spacing: 10) {
        AtlasLabel("Read-only export preview")
          .accessibilityAddTraits(.isHeader)
        Text(model.spokenSummary)
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink2)
          .accessibilityLabel(model.accessibilitySummaryLabel)
        Table(model.rows) {
          TableColumn("Location") { row in
            Text(row.locationLabel)
              .font(.caption.monospacedDigit())
              .accessibilityHidden(true)
          }
          TableColumn("Preview content") { row in
            Text(row.visibleContent)
              .font(.caption.monospaced())
              .textSelection(.enabled)
              .accessibilityLabel(row.locationLabel)
              .accessibilityValue(row.accessibilityValue)
              .accessibilityIdentifier(row.accessibilityIdentifier)
          }
        }
        .accessibilityLabel("Read-only export preview table")
        .accessibilityHint(ExportPreviewAccessibilityModel.navigationHint)
        .accessibilityIdentifier(Self.contentAccessibilityIdentifier)
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

      Surface {
        PrivacySafeDiagnosticsControls()
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
