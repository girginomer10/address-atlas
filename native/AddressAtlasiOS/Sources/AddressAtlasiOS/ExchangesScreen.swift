import AddressAtlasCore
import SwiftUI

/// Read-only exchange connections. Ports the macOS `ExchangesView`: the same
/// provider-specific permission guidance, the same scope check through
/// `saveExchangeConnection`, and the same removal confirmation, laid out for a
/// phone-width scroll page instead of a desktop window.
struct ExchangesScreen: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var reachability: NetworkReachability
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var provider: ExchangeProvider = .binance
  @State private var label = ""
  @State private var apiKey = ""
  @State private var secret = ""
  @State private var revealsAPIKey = false
  @State private var revealsSecret = false
  @FocusState private var focusedField: ExchangesFormField?

  private var connections: [ExchangeConnectionRecord] {
    state.document.exchangeConnections
  }

  private var hasRequiredCredentialInput: Bool {
    !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var isAtConnectionLimit: Bool {
    connections.count >= AppState.maximumExchangeConnections
  }

  private var canSubmit: Bool {
    hasRequiredCredentialInput && !isAtConnectionLimit
      && !state.isValidatingExchangeCredentials && !state.vaultEditsDisabled
  }

  var body: some View {
    IOSPage(
      title: "Exchanges",
      subtitle:
        "Bring exchange balances into your portfolio without enabling trading or withdrawals."
    ) {
      if !connections.isEmpty {
        savedConnections
      }

      credentialCard

      if connections.isEmpty {
        savedConnections
        connectionGuide
      }
    }
  }

  // MARK: Saved connections

  private var savedConnections: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionHeader(
        title: "Saved connections",
        meta: "\(connections.count) encrypted on this device"
      )
      Surface(padding: 0) {
        if connections.isEmpty {
          EmptyState(
            title: "No exchange connections",
            systemImage: "building.columns",
            copy: "Connect a read-only API key to include exchange balances in your next scan."
          )
          .padding(18)
        } else {
          VStack(spacing: 0) {
            ForEach(connections) { connection in
              ExchangesConnectionRow(connection: connection)
              if connection.id != connections.last?.id {
                Divider()
                  .overlay(AtlasTheme.ruleSoft)
                  .padding(.leading, 68)
              }
            }
          }
        }
      }
    }
  }

  // MARK: Add a connection

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
          TextField(provider.exchangesConnectionPlaceholder, text: $label)
            .textFieldStyle(AtlasTextFieldStyle())
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .submitLabel(.next)
            .focused($focusedField, equals: .label)
            .onSubmit { focusedField = .apiKey }
            .accessibilityLabel("Connection name")
        }

        ExchangesSecretField(
          title: provider.exchangesAPIKeyTitle,
          placeholder: provider.exchangesAPIKeyPlaceholder,
          text: $apiKey,
          isRevealed: $revealsAPIKey,
          field: .apiKey,
          focusedField: $focusedField,
          submitLabel: .next
        ) {
          focusedField = .secret
        }

        ExchangesSecretField(
          title: provider.exchangesSecretTitle,
          placeholder: provider.exchangesSecretPlaceholder,
          text: $secret,
          isRevealed: $revealsSecret,
          field: .secret,
          focusedField: $focusedField,
          submitLabel: .done
        ) {
          if canSubmit {
            saveConnection()
          } else {
            focusedField = nil
          }
        }

        ExchangesPermissionGuide(provider: provider)
          .id(provider)
          .transition(.opacity.combined(with: .move(edge: .top)))
          .animation(
            AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
            value: provider
          )

        if isAtConnectionLimit {
          InfoCallout(
            title: "Connection limit reached",
            copy:
              "A vault can contain at most \(AppState.maximumExchangeConnections) exchange connections. Remove one before adding another.",
            tone: .warning
          )
        }

        VStack(alignment: .leading, spacing: 10) {
          Button {
            saveConnection()
          } label: {
            Group {
              if state.isValidatingExchangeCredentials {
                HStack(spacing: 8) {
                  ProgressView()
                    .controlSize(.small)
                  Text("Checking key permissions…")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Checking API key permissions")
              } else {
                Label("Add connection", systemImage: "lock.fill")
              }
            }
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(AtlasPrimaryButtonStyle())
          .disabled(!hasRequiredCredentialInput || isAtConnectionLimit)

          Label("Encrypted before storage", systemImage: "checkmark.shield.fill")
            .font(.caption)
            .foregroundStyle(AtlasTheme.ink3)
        }
      }
    }
    .disabled(state.vaultEditsDisabled)
  }

  // MARK: Guide

  private var connectionGuide: some View {
    Surface(style: .accent) {
      VStack(alignment: .leading, spacing: 18) {
        PanelHeader(
          title: "Read-only by default",
          subtitle: "Your exchange account remains under your control",
          systemImage: "shield.lefthalf.filled"
        )

        VStack(alignment: .leading, spacing: 14) {
          ExchangesConnectionStep(
            number: 1,
            title: "Create a restricted key",
            copy: "Enable balance or query access only."
          )
          ExchangesConnectionStep(
            number: 2,
            title: "Store it in the local vault",
            copy: "A dedicated encryption key protects credentials."
          )
          ExchangesConnectionStep(
            number: 3,
            title: "Refresh when you choose",
            copy: "Requests go directly from this device to the exchange."
          )
        }

        Button {
          if state.scanning {
            state.cancelScan()
          } else {
            state.startScanIfReachable(reachability)
          }
        } label: {
          Group {
            if state.scanning {
              Label("Cancel scan", systemImage: "xmark.circle")
            } else {
              Label("Scan all sources", systemImage: "arrow.clockwise")
            }
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(AtlasPrimaryButtonStyle())
        .disabled(
          !state.scanning
            && (state.syncing || state.syncPersistencePending || !state.hasScanSources))
      }
    }
  }

  // MARK: Actions

  private func saveConnection() {
    focusedField = nil
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

// MARK: - Provider copy

extension ExchangeProvider {
  fileprivate var exchangesSystemImage: String {
    switch self {
    case .binance: "diamond.fill"
    case .coinbase: "c.circle.fill"
    case .kraken: "wave.3.right.circle.fill"
    }
  }

  fileprivate var exchangesConnectionPlaceholder: String {
    switch self {
    case .binance: "Binance main account"
    case .coinbase: "Coinbase portfolio"
    case .kraken: "Kraken read-only"
    }
  }

  fileprivate var exchangesAPIKeyTitle: String {
    switch self {
    case .coinbase: "CDP API key name"
    case .binance, .kraken: "API key"
    }
  }

  fileprivate var exchangesAPIKeyPlaceholder: String {
    switch self {
    case .coinbase: "organizations/…/apiKeys/…"
    case .binance, .kraken: "Paste API key"
    }
  }

  fileprivate var exchangesSecretTitle: String {
    switch self {
    case .coinbase: "ES256 private key"
    case .binance: "Secret key"
    case .kraken: "Private key"
    }
  }

  fileprivate var exchangesSecretPlaceholder: String {
    switch self {
    case .coinbase: "Paste private key"
    case .binance: "Paste secret key"
    case .kraken: "Paste private key"
    }
  }
}

// MARK: - Form pieces

private enum ExchangesFormField: Hashable {
  case label
  case apiKey
  case secret
}

/// Masked credential entry with a reveal toggle. Identifier hygiene applies to
/// both the masked and revealed variants: no autocorrect, no capitalization,
/// and the one-time-code content type so password AutoFill never offers to
/// save or fill exchange secrets.
private struct ExchangesSecretField: View {
  var title: String
  var placeholder: String
  @Binding var text: String
  @Binding var isRevealed: Bool
  var field: ExchangesFormField
  var focusedField: FocusState<ExchangesFormField?>.Binding
  var submitLabel: SubmitLabel
  var onSubmit: () -> Void

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
        .atlasIdentifierInput()
        .focused(focusedField, equals: field)
        .submitLabel(submitLabel)
        .onSubmit(onSubmit)
        .accessibilityLabel(title)

        Button {
          isRevealed.toggle()
        } label: {
          Image(systemName: isRevealed ? "eye.slash" : "eye")
        }
        .buttonStyle(ExchangesTouchIconButtonStyle())
        .accessibilityLabel(isRevealed ? "Hide \(title)" : "Show \(title)")
        .accessibilityHint(
          isRevealed ? "Masks the value again." : "Shows the pasted value on screen.")
      }
    }
  }
}

private struct ExchangesPermissionGuide: View {
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
      "Use a different key for every device: a Kraken key saved here is bound to this device and is skipped on another device. Keep trading, deposits, withdrawals, and account changes disabled; Kraken scope cannot be verified automatically."
    case .binance:
      "Trading, transfer, margin, futures, options, and withdrawal permissions are refused automatically. Only balance and read access is accepted."
    }
  }
}

private struct ExchangesConnectionStep: View {
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
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Saved connection row

/// Two-line row (label + provider, then the last outcome) with a badge strip
/// and a 44pt remove control. Removal goes through the same confirmation the
/// macOS row uses; a long press offers the same action for one-handed use.
private struct ExchangesConnectionRow: View {
  @EnvironmentObject private var state: AppState
  @State private var confirmingRemoval = false
  var connection: ExchangeConnectionRecord

  private var hasInvalidKrakenBinding: Bool {
    connection.provider == .kraken
      && connection.krakenDeviceIdentifier.flatMap(KrakenDeviceIdentity.normalizedIdentifier)
        == nil
  }

  private var isScopeVerified: Bool {
    connection.credentialScopeAssurance == .verifiedReadOnly
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

  private var detailText: String {
    if let lastError = connection.lastError, !lastError.isEmpty {
      return lastError
    }
    if hasInvalidKrakenBinding {
      return "Legacy Kraken key: add a new per-device read-only key before scanning."
    }
    if let lastSync = connection.lastSyncAt {
      return "Last refreshed \(AtlasFormatting.dateTime(lastSync))"
    }
    return "Ready for the next portfolio scan"
  }

  private var detailNeedsAttention: Bool {
    connection.lastError?.isEmpty == false || hasInvalidKrakenBinding
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: connection.provider.exchangesSystemImage)
        .font(.body.weight(.semibold))
        .foregroundStyle(AtlasTheme.accent)
        .frame(width: 40, height: 40)
        .background(AtlasTheme.accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(connection.label)
            .font(.body.weight(.semibold))
            .lineLimit(1)
          Text(connection.provider.label)
            .font(.caption)
            .foregroundStyle(AtlasTheme.ink3)
            .fixedSize()
        }
        Text(detailText)
          .font(detailNeedsAttention ? .callout : .caption)
          .foregroundStyle(detailNeedsAttention ? AtlasTheme.loss : AtlasTheme.ink3)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
        AdaptiveStack(horizontalSpacing: 6, verticalSpacing: 6) {
          Badge(
            isScopeVerified ? "Read-only verified" : "Confirm scope",
            color: isScopeVerified ? AtlasTheme.gain : AtlasTheme.warning
          )
          Badge(statusLabel, color: statusColor)
        }
        .padding(.top, 2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button(role: .destructive) {
        confirmingRemoval = true
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(ExchangesTouchIconButtonStyle())
      .accessibilityLabel(
        "Remove exchange connection \(AtlasAccessibility.exchangeIdentity(connection))"
      )
      .accessibilityHint("Asks for confirmation before removing the encrypted credentials.")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(minHeight: 72)
    .contentShape(Rectangle())
    .contextMenu {
      Button(role: .destructive) {
        confirmingRemoval = true
      } label: {
        Label("Remove connection", systemImage: "trash")
      }
    }
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
        "The encrypted API credentials will be removed from this device and from its automatic rollback point. An encrypted iCloud copy saved earlier may still contain them until you save the updated portfolio to iCloud or delete that copy."
      )
    }
    .disabled(state.vaultEditsDisabled)
  }
}

// MARK: - Touch-sized icon button

/// The shared `IconButtonStyle` renders a 34pt control, which is below the iOS
/// 44pt touch-target floor; this keeps its colors, focus ring, and motion rules
/// on a 44pt frame.
private struct ExchangesTouchIconButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout)
      .foregroundStyle(
        isEnabled
          ? (configuration.isPressed
            ? (configuration.role == .destructive ? AtlasTheme.loss : AtlasTheme.accent)
            : AtlasTheme.ink3)
          : AtlasTheme.rule
      )
      .frame(width: 44, height: 44)
      .background(
        configuration.isPressed
          ? (configuration.role == .destructive
            ? AtlasTheme.loss.opacity(0.09) : AtlasTheme.accent.opacity(0.09))
          : Color.clear
      )
      .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
      .overlay {
        if isFocused {
          RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
            .stroke(AtlasTheme.accent, lineWidth: 3)
            .accessibilityHidden(true)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
      .opacity(isEnabled ? 1 : 0.55)
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .animation(
        AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion),
        value: configuration.isPressed
      )
  }
}
