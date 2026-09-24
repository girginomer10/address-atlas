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
struct TabShell: View {
  @EnvironmentObject private var state: AppState
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
  }
}

/// The iPhone "More" tab: the remaining sections plus the privacy card.
struct MoreList: View {
  @EnvironmentObject private var state: AppState
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
            HStack(spacing: 12) {
              Image(systemName: section.systemImage)
                .font(.title3)
                .foregroundStyle(AtlasTheme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                  .font(.body.weight(.medium))
                  .foregroundStyle(AtlasTheme.ink)
                Text(section.summary)
                  .font(.caption)
                  .foregroundStyle(AtlasTheme.ink3)
              }
              Spacer(minLength: 8)
              Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AtlasTheme.ink3)
                .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
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
        PrivacyCard()
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
      }
    }
    .scrollContentBackground(.hidden)
    .background(AtlasTheme.canvas)
    .navigationTitle("More")
  }
}

/// iPad: every section in a sidebar with the brand lockup and privacy card.
struct SplitShell: View {
  @EnvironmentObject private var state: AppState
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
            Label(section.title, systemImage: section.systemImage)
              .tag(section)
          }
        }
        Section {
          PrivacyCard()
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
      }
      .scrollContentBackground(.hidden)
      .background(AtlasTheme.surface)
      .navigationTitle("Address Atlas")
      .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
    } detail: {
      NavigationStack {
        (selectedSection ?? .portfolio).screen
          .id(selectedSection ?? .portfolio)
      }
    }
    .navigationSplitViewStyle(.balanced)
  }
}
