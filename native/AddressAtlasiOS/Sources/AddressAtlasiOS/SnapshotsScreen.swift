import AddressAtlasCore
import SwiftUI

/// Encrypted scan history kept on this device. Ports the `SnapshotList` half
/// of the macOS `SnapshotsView`; manual holdings live on the Tokens screen on
/// iOS. Runs are listed newest first, each with its asset count, total, and
/// any partial-scan warnings the run recorded. Removal goes through the same
/// confirmation and the shared `AppState.removeScanRun(id:)`.
struct SnapshotsScreen: View {
  @EnvironmentObject private var state: AppState

  private var sortedRuns: [ScanRunRecord] {
    state.document.scanRuns.sorted { $0.generatedAt > $1.generatedAt }
  }

  var body: some View {
    IOSPage(
      title: "Snapshots",
      subtitle:
        "Every scan is saved as an encrypted snapshot on this device so earlier portfolio states can be reviewed. Offline balances are managed under Tokens."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        SectionHeader(
          title: "Snapshot history",
          meta: "\(sortedRuns.count) of \(AppState.maximumStoredScanRuns) saved"
        )

        if sortedRuns.isEmpty {
          EmptyState(
            title: "No snapshots",
            systemImage: "clock.arrow.circlepath",
            copy: "Run a scan to create the first snapshot."
          )
        } else {
          Surface(padding: 0) {
            VStack(spacing: 0) {
              ForEach(sortedRuns) { run in
                SnapshotsRunRow(run: run)
                if run.id != sortedRuns.last?.id {
                  Divider().overlay(AtlasTheme.ruleSoft)
                }
              }
            }
          }
        }

        retentionNote
      }
    }
  }

  @ViewBuilder
  private var retentionNote: some View {
    let removedCount = state.lastSaveRemovedScanRunCount
    if removedCount > 0 {
      InfoCallout(
        title: "Older snapshots were removed",
        copy: state.pruningNoticeSuffix(removedCount)
          .trimmingCharacters(in: .whitespaces),
        tone: .info
      )
    }
    Text(
      "Up to \(AppState.maximumStoredScanRuns) snapshots are kept on this device. When the encrypted vault would exceed its size limit, the oldest snapshots are removed first."
    )
    .font(.caption)
    .foregroundStyle(AtlasTheme.ink3)
    .lineSpacing(2)
    .fixedSize(horizontal: false, vertical: true)
  }
}

// MARK: - Row

private struct SnapshotsRunRow: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var confirmingRemoval = false
  @State private var isRemoving = false
  @State private var showsWarnings = false
  var run: ScanRunRecord

  private var identity: String { AtlasAccessibility.snapshotIdentity(run) }

  private var assetsSummary: String {
    "\(run.holdings.count) asset\(run.holdings.count == 1 ? "" : "s")"
  }

  private var warningsSummary: String {
    "\(run.warnings.count) warning\(run.warnings.count == 1 ? "" : "s")"
  }

  /// Expansion is animated through the shared motion tokens so Reduce Motion
  /// applies to the disclosure as well as the row.
  private var warningsExpanded: Binding<Bool> {
    Binding(
      get: { showsWarnings },
      set: { newValue in
        withAnimation(AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion)) {
          showsWarnings = newValue
        }
      }
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      SnapshotsSwipeRow(
        removeAccessibilityLabel: "Remove snapshot \(identity)",
        onRemove: { confirmingRemoval = true }
      ) {
        HStack(alignment: .top, spacing: 14) {
          Image(systemName: "clock.arrow.circlepath")
            .foregroundStyle(AtlasTheme.accent)
            .frame(width: 34, height: 34)
            .background(AtlasTheme.accent.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 3) {
            Text(AtlasFormatting.dateTime(run.generatedAt))
              .font(.body.weight(.semibold))
            Text(assetsSummary)
              .font(.subheadline)
              .foregroundStyle(AtlasTheme.ink3)
          }
          Spacer(minLength: 8)
          VStack(alignment: .trailing, spacing: 6) {
            Text(money(run.totalUsd))
              .font(.body.monospaced())
            if !run.warnings.isEmpty {
              Badge(warningsSummary, color: AtlasTheme.warning)
            }
          }
        }
      } trailing: {
        Button(role: .destructive) {
          confirmingRemoval = true
        } label: {
          if isRemoving {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "trash")
          }
        }
        .buttonStyle(SnapshotsIconButtonStyle())
        .disabled(isRemoving)
        .accessibilityLabel("Remove snapshot \(identity)")
        .accessibilityHint("Asks for confirmation before deleting the snapshot from this device.")
      }

      if !run.warnings.isEmpty {
        warningsDisclosure
      }
    }
    .confirmationDialog(
      "Remove \(identity)?",
      isPresented: $confirmingRemoval,
      titleVisibility: .visible
    ) {
      Button("Remove snapshot", role: .destructive) {
        isRemoving = true
        Task {
          await state.removeScanRun(id: run.id)
          isRemoving = false
        }
      }
      Button("Cancel", role: .cancel) {}
    }
    .disabled(state.vaultEditsDisabled)
  }

  private var warningsDisclosure: some View {
    DisclosureGroup(isExpanded: warningsExpanded) {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(run.warnings.enumerated()), id: \.offset) { _, warning in
          HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(AtlasTheme.warning)
              .padding(.top, 2)
            Text(warning)
              .font(.callout)
              .foregroundStyle(AtlasTheme.ink2)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .padding(.top, 8)
    } label: {
      Text("Partial scan warnings")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(AtlasTheme.ink2)
        .frame(minHeight: 44)
    }
    .tint(AtlasTheme.ink3)
    .padding(.horizontal, 16)
    .padding(.bottom, 8)
    .accessibilityHint(
      showsWarnings ? "Hides the warnings for this snapshot." : "Shows the warnings for this snapshot."
    )
  }
}

// MARK: - Row chrome

/// 44pt variant of the design system's `IconButtonStyle` for touch targets;
/// the shared style fixes its frame at 34pt for pointer-driven rows.
private struct SnapshotsIconButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout)
      .foregroundStyle(
        isEnabled
          ? (configuration.isPressed ? AtlasTheme.loss : AtlasTheme.ink3)
          : AtlasTheme.rule
      )
      .frame(width: 44, height: 44)
      .background(configuration.isPressed ? AtlasTheme.loss.opacity(0.09) : Color.clear)
      .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.small, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: AtlasRadius.small, style: .continuous))
      .opacity(isEnabled ? 1 : 0.55)
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .animation(
        AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion),
        value: configuration.isPressed
      )
  }
}

/// Compact-page stand-in for `List` swipe actions, because the page scrolls in
/// a `ScrollView` where a nested `List` has no intrinsic height. The leading
/// text region can be dragged left to reveal a Remove control; the trailing
/// controls keep their own gestures. The drag is simultaneous with the scroll
/// view and locks to an axis on first movement, so vertical scrolling is never
/// blocked. The visible trash button remains the accessible path, so assistive
/// technologies never depend on the swipe.
private struct SnapshotsSwipeRow<Leading: View, Trailing: View>: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  var removeAccessibilityLabel: String
  var onRemove: () -> Void
  @ViewBuilder var leading: () -> Leading
  @ViewBuilder var trailing: () -> Trailing

  @State private var offset: CGFloat = 0
  @State private var isOpen = false
  @State private var lockedAxis: Axis?
  @GestureState private var isDragging = false

  private let actionWidth: CGFloat = 88

  var body: some View {
    HStack(spacing: 12) {
      leading()
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
          if isOpen { settle(open: false) }
        }
        .simultaneousGesture(dragGesture)
      trailing()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(minHeight: 66)
    .background(AtlasTheme.surface)
    .offset(x: offset)
    .background(alignment: .trailing) {
      removeControl
    }
    .clipped()
    .onChange(of: isDragging) { _, dragging in
      guard !dragging else { return }
      lockedAxis = nil
      settle(open: isOpen)
    }
  }

  private var removeControl: some View {
    Button(role: .destructive) {
      settle(open: false)
      onRemove()
    } label: {
      VStack(spacing: 4) {
        Image(systemName: "trash")
          .font(.body.weight(.semibold))
        Text("Remove")
          .font(.caption2.weight(.semibold))
      }
      .foregroundStyle(.white)
      .frame(width: actionWidth)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(AtlasTheme.loss)
    .allowsHitTesting(isOpen)
    .accessibilityHidden(!isOpen)
    .accessibilityLabel(removeAccessibilityLabel)
  }

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: 12, coordinateSpace: .local)
      .updating($isDragging) { _, dragging, _ in
        dragging = true
      }
      .onChanged { value in
        guard isEnabled else { return }
        let translation = value.translation
        if lockedAxis == nil {
          lockedAxis = abs(translation.width) > abs(translation.height) ? .horizontal : .vertical
        }
        guard lockedAxis == .horizontal else { return }
        let base: CGFloat = isOpen ? -actionWidth : 0
        offset = min(0, max(-actionWidth, base + translation.width))
      }
      .onEnded { value in
        guard isEnabled, lockedAxis == .horizontal else { return }
        let base: CGFloat = isOpen ? -actionWidth : 0
        let projected = base + value.predictedEndTranslation.width
        settle(open: projected < -actionWidth / 2)
      }
  }

  private func settle(open: Bool) {
    withAnimation(AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion)) {
      isOpen = open
      offset = open ? -actionWidth : 0
    }
  }
}
