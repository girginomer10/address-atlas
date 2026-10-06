import AddressAtlasCore
import SwiftUI

/// Chooses the iPhone tab shell or the iPad sidebar shell from the size class.
struct MainShell: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  var body: some View {
    if horizontalSizeClass == .regular {
      SplitShell()
    } else {
      TabShell()
    }
  }
}

enum MainTab: Hashable, Sendable {
  case section(AtlasSection)
  case more
}

/// iPhone: four primary tabs plus a "More" list for the remaining sections.
/// The selected section lives in `IOSNavigationModel` so onboarding and
/// empty-state buttons can switch tabs; a "More" section is pushed onto the
/// More stack.
struct TabShell: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: IOSNavigationModel
  @State private var selectedTab: MainTab = .section(.portfolio)
  @State private var morePath = NavigationPath()

  /// The source page's transient status is cleared before SwiftUI installs
  /// the destination, matching the ordering the macOS sidebar relies on.
  private var tabSelection: Binding<MainTab> {
    Binding(
      get: { selectedTab },
      set: { newValue in
        guard newValue != selectedTab else {
          if case .more = newValue { morePath = NavigationPath() }
          return
        }
        state.clearTransientMessagesForNavigation()
        selectedTab = newValue
      }
    )
  }

  var body: some View {
    TabView(selection: tabSelection) {
      ForEach(AtlasSection.primaryTabs) { section in
        NavigationStack {
          section.screen
        }
        .tabItem { Label(section.title, systemImage: section.systemImage) }
        .tag(MainTab.section(section))
      }

      NavigationStack(path: $morePath) {
        MoreList(path: $morePath)
          .navigationDestination(for: AtlasSection.self) { section in
            section.screen
          }
      }
      .tabItem { Label("More", systemImage: "ellipsis.circle") }
      .tag(MainTab.more)
    }
    .toolbarBackground(AtlasTheme.surface, for: .tabBar)
    .toolbarBackground(.visible, for: .tabBar)
    .onAppear {
      if navigation.openRequest > 0 { follow(navigation.selectedSection) }
    }
    .onChange(of: navigation.openRequest) { _, _ in
      follow(navigation.selectedSection)
    }
  }

  private func follow(_ section: AtlasSection) {
    if AtlasSection.primaryTabs.contains(section) {
      guard selectedTab != .section(section) else { return }
      selectedTab = .section(section)
    } else {
      selectedTab = .more
      var path = NavigationPath()
      path.append(section)
      morePath = path
    }
  }
}

/// The iPhone "More" tab: the remaining sections plus a one-row privacy note.
struct MoreList: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Binding var path: NavigationPath

  var body: some View {
    List {
      Section {
        ForEach(AtlasSection.moreSections) { section in
          // A Button (not NavigationLink) so the transient status is cleared
          // before the destination is pushed; a gesture attached to a link
          // would compete with the row's own tap handling.
          Button {
            state.clearTransientMessagesForNavigation()
            path.append(section)
          } label: {
            HStack(spacing: 14) {
              // At accessibility sizes the words need the whole width; a
              // single-word title never breaks mid-word.
              if !dynamicTypeSize.isAccessibilitySize {
                SectionIconTile(section: section)
              }
              VStack(alignment: .leading, spacing: 1) {
                Text(section.title)
                  .font(.body)
                  .foregroundStyle(AtlasTheme.ink)
                  .lineLimit(1)
                  .minimumScaleFactor(0.6)
                Text(section.summary)
                  .font(.footnote)
                  .foregroundStyle(AtlasTheme.ink3)
                  .fixedSize(horizontal: false, vertical: true)
              }
              Spacer(minLength: 8)
              if !dynamicTypeSize.isAccessibilitySize {
                Image(systemName: "chevron.right")
                  .font(.footnote.weight(.semibold))
                  .foregroundStyle(AtlasTheme.ink3.opacity(0.7))
                  .accessibilityHidden(true)
              }
            }
            .padding(.vertical, 4)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(section.title)
          .accessibilityHint(section.summary)
          .accessibilityAddTraits(.isLink)
        }
      }
      .listRowBackground(AtlasTheme.surface)

      Section {
        CompactPrivacyRow()
      }
      .listRowBackground(AtlasTheme.surface)
    }
    .scrollContentBackground(.hidden)
    .background(AtlasTheme.canvas)
    .navigationTitle("More")
  }
}

/// Settings-style colored tile behind a section's symbol.
private struct SectionIconTile: View {
  @ScaledMetric(relativeTo: .body) private var size: CGFloat = 30
  var section: AtlasSection

  var body: some View {
    Image(systemName: section.systemImage)
      .font(.system(size: size * 0.5, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
          .fill(section.iconTint.gradient)
      )
      .accessibilityHidden(true)
  }
}

/// The privacy promise in one full-width row; the details live on the
/// screens where they matter.
private struct CompactPrivacyRow: View {
  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "lock.shield.fill")
        .font(.body.weight(.semibold))
        .foregroundStyle(AtlasTheme.gain)
        .frame(width: 30, height: 30)
        .background(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(AtlasTheme.gain.opacity(0.12))
        )
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text("Private by design")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(AtlasTheme.ink)
        Text("Read-only and encrypted on this \(PlatformCopy.deviceNoun)")
          .font(.footnote)
          .foregroundStyle(AtlasTheme.ink3)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Private by design. Read-only and encrypted on this \(PlatformCopy.deviceNoun).")
  }
}

/// iPad: every section in a sidebar with the brand lockup and privacy note.
struct SplitShell: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: IOSNavigationModel
  @State private var selectedSection: AtlasSection? = .portfolio

  private var sectionSelection: Binding<AtlasSection?> {
    Binding(
      get: { selectedSection },
      set: { newValue in
        guard let newValue, newValue != selectedSection else { return }
        state.clearTransientMessagesForNavigation()
        selectedSection = newValue
      }
    )
  }

  var body: some View {
    NavigationSplitView {
      List(selection: sectionSelection) {
        Section {
          BrandLockup()
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 12, trailing: 8))
        }
        Section {
          ForEach(AtlasSection.allCases) { section in
            Label {
              Text(section.title)
            } icon: {
              SectionIconTile(section: section)
            }
            .tag(section)
          }
        }
        Section {
          CompactPrivacyRow()
            .listRowBackground(Color.clear)
        }
      }
      .scrollContentBackground(.hidden)
      .background(AtlasTheme.surface)
      // The brand lockup is the sidebar's title; a bar title would repeat
      // it. The bar itself stays for the sidebar toggle.
      .navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(AtlasTheme.surface, for: .navigationBar)
      .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
    } detail: {
      NavigationStack {
        (selectedSection ?? .portfolio).screen
          .id(selectedSection ?? .portfolio)
      }
      // Inside the detail column so the toast centers on the content and
      // never spans the sidebar.
      .overlay {
        IOSStatusToast(bottomPadding: 24)
      }
    }
    .navigationSplitViewStyle(.balanced)
    .onAppear { selectedSection = navigation.selectedSection }
    .onChange(of: navigation.openRequest) { _, _ in
      selectedSection = navigation.selectedSection
    }
  }
}
