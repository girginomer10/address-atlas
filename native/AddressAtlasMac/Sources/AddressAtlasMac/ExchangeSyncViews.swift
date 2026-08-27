import AddressAtlasCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExchangesView: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var provider: ExchangeProvider = .binance
  @State private var label = ""
  @State private var apiKey = ""
  @State private var secret = ""
  @State private var revealsAPIKey = false
  @State private var revealsSecret = false

  private var hasRequiredCredentialInput: Bool {
    !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    Page(
      eyebrow: "Secure connections",
      title: "Exchanges",
      subtitle:
        "Bring exchange balances into your portfolio without enabling trading or withdrawals.",
      statTitle: "Connections",
      statValue: "\(state.document.exchangeConnections.count)"
    ) {
      if !state.document.exchangeConnections.isEmpty {
        savedConnections
      }

      connectionSetup

      if state.document.exchangeConnections.isEmpty {
        savedConnections
      }
    }
  }

  @ViewBuilder
  private var connectionSetup: some View {
    if state.document.exchangeConnections.isEmpty {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 18) {
          credentialCard
          connectionGuide
            .frame(width: 300)
        }
        VStack(alignment: .leading, spacing: 18) {
          credentialCard
          connectionGuide
        }
      }
    } else {
      credentialCard
    }
  }

  private var savedConnections: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionHeader(
        title: "Saved connections",
        meta: "\(state.document.exchangeConnections.count) encrypted on this Mac"
      )
      Surface(padding: 0) {
        if state.document.exchangeConnections.isEmpty {
          EmptyState(
            title: "No exchange connections", systemImage: "building.columns",
            copy: "Connect a read-only API key to include exchange balances in your next scan."
          )
          .padding(18)
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

  private var credentialCard: some View {
    Surface {
      VStack(alignment: .leading, spacing: 20) {
        PanelHeader(
          title: "Connect an exchange",
          subtitle: "Credentials are sealed locally before they are saved",
          systemImage: "building.columns.fill"
        )

        VStack(alignment: .leading, spacing: 8) {
          FieldLabel("Provider")
          Picker("Provider", selection: $provider) {
            ForEach(ExchangeProvider.allCases, id: \.self) { item in
              Text(item.label).tag(item)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .accessibilityLabel("Exchange provider")
        }

        VStack(alignment: .leading, spacing: 8) {
          FieldLabel("Connection name", detail: "Optional")
          TextField(provider.connectionPlaceholder, text: $label)
            .textFieldStyle(AtlasTextFieldStyle())
            .accessibilityLabel("Connection name")
        }

        AdaptiveStack(horizontalSpacing: 12, verticalSpacing: 14) {
          ExchangeCredentialField(
            title: provider.apiKeyTitle,
            placeholder: provider.apiKeyPlaceholder,
            text: $apiKey,
            isRevealed: $revealsAPIKey
          )
          ExchangeCredentialField(
            title: provider.secretTitle,
            placeholder: provider.secretPlaceholder,
            text: $secret,
            isRevealed: $revealsSecret
          )
        }

        ExchangePermissionGuide(provider: provider)
          .id(provider)
          .transition(.opacity.combined(with: .move(edge: .top)))
          .animation(
            AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
            value: provider
          )

        AdaptiveStack(horizontalSpacing: 12) {
          Button {
            saveConnection()
          } label: {
            Label("Add connection", systemImage: "lock.fill")
          }
          .buttonStyle(AtlasPrimaryButtonStyle())
          .disabled(!hasRequiredCredentialInput)

          Label("Encrypted before storage", systemImage: "checkmark.shield.fill")
            .font(.caption)
            .foregroundStyle(AtlasTheme.ink3)
        }
      }
    }
    .disabled(state.vaultEditsDisabled)
  }

  private var connectionGuide: some View {
    Surface(style: .accent) {
      VStack(alignment: .leading, spacing: 18) {
        PanelHeader(
          title: "Read-only by default",
          subtitle: "Your exchange account remains under your control",
          systemImage: "shield.lefthalf.filled"
        )

        VStack(alignment: .leading, spacing: 14) {
          ConnectionStep(
            number: 1,
            title: "Create a restricted key",
            copy: "Enable balance or query access only."
          )
          ConnectionStep(
            number: 2,
            title: "Store it in the local vault",
            copy: "A dedicated encryption key protects credentials."
          )
          ConnectionStep(
            number: 3,
            title: "Refresh when you choose",
            copy: "Requests go directly from this Mac to the exchange."
          )
        }

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
      }
    }
  }

  private func saveConnection() {
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
        revealsAPIKey = false
        revealsSecret = false
      }
    }
  }
}

extension ExchangeProvider {
  fileprivate var systemImage: String {
    switch self {
    case .binance: "diamond.fill"
    case .coinbase: "c.circle.fill"
    case .kraken: "wave.3.right.circle.fill"
    }
  }

  fileprivate var connectionPlaceholder: String {
    switch self {
    case .binance: "Binance main account"
    case .coinbase: "Coinbase portfolio"
    case .kraken: "Kraken read-only"
    }
  }

  fileprivate var apiKeyTitle: String {
    switch self {
    case .coinbase: "CDP API key name"
    case .binance, .kraken: "API key"
    }
  }

  fileprivate var apiKeyPlaceholder: String {
    switch self {
    case .coinbase: "organizations/…/apiKeys/…"
    case .binance, .kraken: "Paste API key"
    }
  }

  fileprivate var secretTitle: String {
    switch self {
    case .coinbase: "ES256 private key"
    case .binance: "Secret key"
    case .kraken: "Private key"
    }
  }

  fileprivate var secretPlaceholder: String {
    switch self {
    case .coinbase: "Paste private key"
    case .binance: "Paste secret key"
    case .kraken: "Paste private key"
    }
  }
}

private struct ExchangeCredentialField: View {
  var title: String
  var placeholder: String
  @Binding var text: String
  @Binding var isRevealed: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      FieldLabel(title)
      HStack(spacing: 8) {
        Group {
          if isRevealed {
            TextField(placeholder, text: $text)
          } else {
            SecureField(placeholder, text: $text)
          }
        }
        .textFieldStyle(AtlasTextFieldStyle())
        .accessibilityLabel(title)

        Button {
          isRevealed.toggle()
        } label: {
          Image(systemName: isRevealed ? "eye.slash" : "eye")
        }
        .buttonStyle(IconButtonStyle())
        .accessibilityLabel(isRevealed ? "Hide \(title)" : "Show \(title)")
      }
    }
    .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
  }
}

private struct ExchangePermissionGuide: View {
  var provider: ExchangeProvider

  var body: some View {
    InfoCallout(
      title: title,
      copy: copy,
      tone: provider == .binance ? .success : .warning
    )
  }

  private var title: String {
    switch provider {
    case .binance: "Permissions checked before saving"
    case .coinbase: "Confirm view-only access in Coinbase"
    case .kraken: "Enable Query Funds only"
    }
  }

  private var copy: String {
    switch provider {
    case .coinbase:
      "Address Atlas accepts a CDP key name and ES256 private key. Scope cannot be verified automatically, so keep trading and transfer permissions off. Escaped \\n line breaks are accepted."
    case .kraken:
      "Use a different key for every Mac. Keep trading, deposits, withdrawals, and account changes disabled; Kraken scope cannot be verified automatically."
    case .binance:
      "Trading, transfer, margin, futures, options, and withdrawal permissions are refused automatically. Only balance and read access is accepted."
    }
  }
}

private struct ConnectionStep: View {
  var number: Int
  var title: String
  var copy: String

  var body: some View {
    HStack(alignment: .top, spacing: 11) {
      Text("\(number)")
        .font(.caption.monospacedDigit().weight(.bold))
        .foregroundStyle(AtlasTheme.accent)
        .frame(width: 24, height: 24)
        .background(AtlasTheme.accent.opacity(0.12))
        .clipShape(Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout.weight(.semibold))
        Text(copy)
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink3)
      }
    }
    .accessibilityElement(children: .combine)
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

  private var statusLabel: String {
    switch connection.status {
    case .ok: "Ready"
    case .empty: "Not scanned"
    case .failed: "Needs attention"
    }
  }

  private var statusColor: Color {
    switch connection.status {
    case .ok: AtlasTheme.gain
    case .empty: AtlasTheme.ink3
    case .failed: AtlasTheme.loss
    }
  }

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: connection.provider.systemImage)
        .font(.body.weight(.semibold))
        .foregroundStyle(AtlasTheme.accent)
        .frame(width: 40, height: 40)
        .background(AtlasTheme.accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(connection.label)
            .font(.body.weight(.semibold))
          Text(connection.provider.label)
            .font(.caption)
            .foregroundStyle(AtlasTheme.ink3)
        }
        if connection.lastError?.isEmpty == false || hasInvalidKrakenBinding {
          Text(
            connection.lastError?.isEmpty == false
              ? connection.lastError ?? ""
              : "Legacy Kraken key: add a new per-device read-only key before scanning."
          )
          .font(.callout)
          .foregroundStyle(AtlasTheme.loss)
          .lineLimit(2)
        } else if let lastSync = connection.lastSyncAt {
          Text(
            "Last refreshed \(AtlasFormatting.dateTime(lastSync))"
          )
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink3)
        } else {
          Text("Ready for the next portfolio scan")
            .font(.caption)
            .foregroundStyle(AtlasTheme.ink3)
        }
      }
      Spacer()
      Badge(
        connection.credentialScopeAssurance == .verifiedReadOnly
          ? "Read-only verified"
          : "Confirm scope",
        color: connection.credentialScopeAssurance == .verifiedReadOnly
          ? AtlasTheme.gain
          : AtlasTheme.warning
      )
      Badge(statusLabel, color: statusColor)
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
    .padding(.vertical, 12)
    .frame(minHeight: 72)
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
  @State private var serverURL: String
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

  init(initialServerURL: String = "") {
    _serverURL = State(initialValue: initialServerURL)
  }

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
      eyebrow: "Private multi-device access",
      title: "Sync",
      subtitle:
        "Move an encrypted copy of your vault between Macs. The server never receives a key that can decrypt it.",
      statTitle: "Remote version",
      statValue: AppState.remoteVersionStatus(state.document.syncState)
    ) {
      Surface {
        VStack(alignment: .leading, spacing: 18) {
          PanelHeader(
            title: "Sync connection",
            subtitle: "Passkeys authenticate you; vault encryption protects your data",
            systemImage: "icloud.fill"
          )
          VStack(alignment: .leading, spacing: 8) {
            FieldLabel("Sync server")
            TextField("Enter your HTTPS sync server", text: $serverURL)
              .textFieldStyle(AtlasTextFieldStyle())
              .disabled(
                state.syncing || state.scanning || state.syncPersistencePending
                  || state.hasPendingAccountDeletion || hasConnectedSyncAccount
              )
          }
          if hasConnectedSyncAccount {
            InfoCallout(
              title: persistedServerURL == nil ? "Saved server needs attention" : "Connected",
              copy: persistedServerURL == nil
                ? "This vault has connected account metadata, but its saved server is invalid. Account switching is locked to protect the sync baseline; restore a valid local vault before continuing."
                : "This Mac is bound to \(persistedServerOrigin). Disconnect it explicitly before switching accounts or servers.",
              tone: persistedServerURL == nil ? .danger : .success
            )
          } else if hasValidServerInput, persistedServerURL != nil,
            boundActionServerURL == nil
          {
            InfoCallout(
              title: "Unsaved server change",
              copy:
                "The saved server remains \(persistedServerOrigin). Save this address or restore the saved origin before using existing-server controls.",
              tone: .warning
            )
          }

          SectionHeader(title: "Account access", meta: "Passkey protected")
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

          Divider().overlay(AtlasTheme.ruleSoft)
          SectionHeader(title: "Encrypted vault transfer", meta: "You stay in control")
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

      Surface(style: .subtle) {
        VStack(alignment: .leading, spacing: 16) {
          PanelHeader(
            title: "Connection details",
            subtitle: "Operational metadata only—never portfolio content",
            systemImage: "list.bullet.rectangle"
          )
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

      Surface(style: .warning) {
        VStack(alignment: .leading, spacing: 14) {
          PanelHeader(
            title: "Automatic encrypted rollback",
            subtitle: state.hasVaultRollbackCheckpoint
              ? "A verified restore point is ready"
              : "A restore point is created before a remote download",
            systemImage: "arrow.uturn.backward.circle.fill",
            tint: AtlasTheme.warning
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

      Surface(style: .danger) {
        VStack(alignment: .leading, spacing: 16) {
          PanelHeader(
            title: "Account and device controls",
            subtitle: persistedServerOrigin,
            systemImage: "exclamationmark.shield.fill",
            tint: AtlasTheme.loss
          )
          InfoCallout(
            title: "Know what each action removes",
            copy:
              "Revoke signs out this Mac. Disconnect clears only its local account binding so you can switch. Delete permanently removes the remote account and encrypted server snapshots. Every option keeps this Mac's encrypted local vault.",
            tone: .danger
          )
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
      + "\n\n— Preview truncated to \(maximumByteCount.formatted(.number.locale(AtlasFormatting.locale))) bytes. The saved export includes all records."
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
      eyebrow: "Controlled sharing",
      title: "Export",
      subtitle:
        "Choose the minimum detail your recipient needs. Every export is generated locally on this Mac.",
      statTitle: "Latest assets",
      statValue: "\(state.latestScan?.holdings.count ?? 0)"
    ) {
      Surface(style: .accent) {
        VStack(alignment: .leading, spacing: 18) {
          PanelHeader(
            title: "Share-safer summary",
            subtitle: "Recommended for intentional sharing · not anonymous",
            systemImage: "person.crop.circle.badge.checkmark"
          )
          InfoCallout(
            title: "Reduced exposure—not anonymous",
            copy: "\(ShareSafePortfolioReport.privacyNotice) \(Self.shareSaferExplanation)",
            tone: .info
          )
          AdaptiveStack {
            Button {
              save(.shareSafeCSV(state.document))
            } label: {
              Label("Save CSV", systemImage: "arrow.down.doc")
            }
            .buttonStyle(AtlasPrimaryButtonStyle())
            Button {
              generatePreview(for: .shareSafeCSV(state.document))
            } label: {
              Label("Preview CSV", systemImage: "eye")
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            Button {
              save(.shareSafeJSON(state.document))
            } label: {
              Label("Save JSON", systemImage: "arrow.down.doc")
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            Button {
              generatePreview(for: .shareSafeJSON(state.document))
            } label: {
              Label("Preview JSON", systemImage: "eye")
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

      Surface(style: .danger) {
        DisclosureGroup(isExpanded: $showFullIdentifyingExports) {
          VStack(alignment: .leading, spacing: 14) {
            InfoCallout(
              title: "This report can identify your portfolio",
              copy: Self.fullIdentifyingExplanation,
              tone: .danger
            )
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
          PanelHeader(
            title: "Full identifying reports",
            subtitle: "Addresses, balances, and portfolio details are disclosed",
            systemImage: "exclamationmark.triangle.fill",
            tint: AtlasTheme.loss
          )
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
      let isAccessing = url.startAccessingSecurityScopedResource()
      state.error = ""
      Task { @MainActor in
        defer {
          state.finishExportOperation()
          if isAccessing {
            url.stopAccessingSecurityScopedResource()
          }
        }
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
    didOmitContent =
      generatedRows.last?.sourceLine != sourceLines.count
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
        PanelHeader(
          title: "Read-only preview",
          subtitle: "Inspect the exact report before saving",
          systemImage: "doc.text.magnifyingglass"
        )
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
      eyebrow: "Preferences and recovery",
      title: "Settings",
      subtitle:
        "Control refresh behavior, portfolio display, recovery, and privacy-safe support tools.",
      statTitle: "Currency",
      statValue: "USD"
    ) {
      Surface {
        VStack(alignment: .leading, spacing: 20) {
          PanelHeader(
            title: "Portfolio preferences",
            subtitle: "Stored inside your encrypted local vault",
            systemImage: "slider.horizontal.3"
          )
          PreferenceToggleRow(
            title: "Automatic refresh",
            copy: "Refresh saved sources every 15 minutes while the app is open and unlocked.",
            systemImage: "arrow.clockwise",
            isOn: Binding(
              get: {
                state.document.preferences.autoRefresh
              },
              set: {
                let value = $0
                Task { await state.setAutoRefresh(value) }
              })
          )
          Divider().overlay(AtlasTheme.ruleSoft)
          PreferenceToggleRow(
            title: "Hide small balances",
            copy: "Keep low-value holdings out of the main asset list without deleting them.",
            systemImage: "line.3.horizontal.decrease.circle",
            isOn: Binding(
              get: {
                state.document.preferences.hideDust
              },
              set: {
                let value = $0
                Task { await state.setHideDust(value) }
              })
          )
          Divider().overlay(AtlasTheme.ruleSoft)
          AdaptiveStack(horizontalSpacing: 14, verticalSpacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
              FieldLabel("Small-balance threshold", detail: "USD")
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
              FieldLabel("Display currency")
              HStack {
                Text("USD")
                  .font(.callout.weight(.semibold))
                Spacer()
                Badge("Current")
              }
              .padding(.horizontal, 13)
              .frame(minHeight: 42)
              .background(AtlasTheme.surfaceMuted.opacity(0.44))
              .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
              .overlay {
                RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
                  .stroke(AtlasTheme.ruleSoft, lineWidth: 1)
              }
            }
          }
        }
      }
      .disabled(state.vaultEditsDisabled)

      Surface {
        VStack(alignment: .leading, spacing: 16) {
          PanelHeader(
            title: "Privacy and support",
            subtitle: "Review data boundaries, get help, or inspect the price-data source",
            systemImage: "hand.raised.fill"
          )
          AdaptiveStack {
            Link(destination: AppState.privacyPolicyURL) {
              Label("Privacy policy", systemImage: "lock.doc")
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            Link(destination: AppState.supportURL) {
              Label("Support", systemImage: "questionmark.circle")
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            Link(destination: AppState.termsOfUseURL) {
              Label("Terms of use", systemImage: "doc.text")
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            Link(destination: AppState.coinGeckoAttributionURL) {
              Label("Data provided by CoinGecko", systemImage: "chart.line.uptrend.xyaxis")
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
          }
          Text(
            "Address Atlas is read-only analytics software. It never creates wallets, stores private keys, signs transactions, executes trades, or provides personalized investment advice."
          )
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink2)
          .lineSpacing(2)
        }
      }

      Surface(style: .warning) {
        VStack(alignment: .leading, spacing: 16) {
          PanelHeader(
            title: "Recovery kit",
            subtitle: "A recovery file and separately stored code restore this Mac's vault key",
            systemImage: "key.fill",
            tint: AtlasTheme.warning
          )
          AdaptiveStack {
            Button {
              exportRecoveryKit()
            } label: {
              Label("Export recovery kit", systemImage: "arrow.down.doc")
            }
            .buttonStyle(AtlasPrimaryButtonStyle())
            VStack(alignment: .leading, spacing: 8) {
              FieldLabel("Recovery code")
              SecureField("Enter recovery code", text: $restoreCode)
                .textFieldStyle(AtlasTextFieldStyle())
                .accessibilityLabel("Recovery code for restore")
            }
            Button {
              restoreRecoveryKit()
            } label: {
              Label("Choose recovery file", systemImage: "folder")
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            .disabled(
              state.vaultEditsDisabled
                || restoreCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
          }
          if !recoveryCode.isEmpty {
            InfoCallout(
              title: "Store this code separately from the recovery file",
              copy: recoveryCode,
              tone: .warning
            )
            VStack(alignment: .leading, spacing: 6) {
              FieldLabel("Recovery code", detail: "Selectable")
              Text(recoveryCode)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AtlasTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
                .overlay {
                  RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
                    .stroke(AtlasTheme.ruleSoft, lineWidth: 1)
                }
            }
          }
        }
      }

      Surface(style: .subtle) {
        PrivacySafeDiagnosticsControls()
      }
    }
  }

  private func exportRecoveryKit() {
    let panel = NSOpenPanel()
    panel.title = "Export Recovery Kit"
    panel.message = "Choose a folder for a uniquely named encrypted recovery file."
    panel.prompt = "Export Here"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    if panel.runModal() == .OK, let directory = panel.url {
      let isAccessing = directory.startAccessingSecurityScopedResource()
      defer {
        if isAccessing {
          directory.stopAccessingSecurityScopedResource()
        }
      }
      do {
        let filename = "address-atlas-\(Self.recoveryExportTimestamp()).atlas-recovery"
        let destination = directory.appending(path: filename)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
          state.error = "A recovery file with this timestamp already exists. Wait one second and retry."
          return
        }
        recoveryCode = try state.exportRecoveryKit(to: destination)
        state.notice = "Recovery kit saved as \(filename)."
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
      let isAccessing = url.startAccessingSecurityScopedResource()
      Task {
        defer {
          if isAccessing {
            url.stopAccessingSecurityScopedResource()
          }
        }
        await state.restoreRecoveryKit(from: url, recoveryCode: restoreCode)
      }
    }
  }

  private static func recoveryExportTimestamp(now: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return formatter.string(from: now)
  }
}

private struct PreferenceToggleRow: View {
  var title: String
  var copy: String
  var systemImage: String
  @Binding var isOn: Bool

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      Image(systemName: systemImage)
        .font(.body.weight(.semibold))
        .foregroundStyle(AtlasTheme.accent)
        .frame(width: 38, height: 38)
        .background(AtlasTheme.accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.callout.weight(.semibold))
        Text(copy)
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink3)
      }
      .accessibilityHidden(true)
      Spacer(minLength: 16)
      Toggle(title, isOn: $isOn)
        .labelsHidden()
        .accessibilityLabel(title)
        .accessibilityHint(copy)
    }
  }
}
