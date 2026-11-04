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

/// Where each pushed route leads. Every tab's stack uses this.
struct IOSRouteDestination: View {
  var route: IOSRoute

  var body: some View {
    switch route {
    case .coin(let key): CoinDetailScreen(coinKey: key)
    case .snapshot(let id): SnapshotDetailScreen(runID: id)
    case .iCloud: ICloudScreen()
    case .export: ExportScreen()
    }
  }
}

/// One tab's navigation stack. The pushed routes live in `IOSNavigationModel`
/// so a chart, a toast or another tab can open a coin or a snapshot.
private struct SectionStack: View {
  @EnvironmentObject private var navigation: IOSNavigationModel
  var section: AtlasSection

  var body: some View {
    NavigationStack(
      path: Binding(
        get: { navigation.paths[section] ?? [] },
        set: { navigation.paths[section] = $0 }
      )
    ) {
      section.screen
        .navigationDestination(for: IOSRoute.self) { route in
          IOSRouteDestination(route: route)
        }
    }
  }
}

/// iPhone: five tabs drawn by `IOSTabBar` (the system bar takes no theme
/// font or shape). Each tab keeps its own stack; choosing the tab that is
/// already showing returns to its first screen.
struct TabShell: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: IOSNavigationModel

  private func select(_ section: AtlasSection) {
    if section == navigation.selectedSection {
      navigation.paths[section] = []
      return
    }
    // The source page's transient status is cleared before SwiftUI installs
    // the destination, matching the ordering the macOS sidebar relies on.
    state.clearTransientMessagesForNavigation()
    navigation.selectedSection = section
  }

  var body: some View {
    TabView(selection: $navigation.selectedSection) {
      ForEach(AtlasSection.allCases) { section in
        SectionStack(section: section)
          .toolbar(.hidden, for: .tabBar)
          .tag(section)
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      IOSTabBar(selection: navigation.selectedSection, select: select)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
    .ignoresSafeArea(.keyboard, edges: .bottom)
  }
}

/// The wordmark, without a tagline.
struct IOSBrandMark: View {
  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "map.fill")
        .font(.body.weight(.semibold))
        .foregroundStyle(AtlasTheme.onAccent)
        .frame(width: 34, height: 34)
        .atlasChrome(
          fill: AtlasTheme.accent,
          border: AtlasTheme.outline,
          level: .control,
          radius: AtlasTheme.shape.pillControls ? 12 : AtlasRadius.control,
          borderWidth: AtlasTheme.shape.hasBoldBorders ? AtlasTheme.shape.controlBorderWidth : 0,
          showsShadow: false
        )
        .accessibilityHidden(true)
      Text("Address Atlas")
        .font(AtlasTheme.font(.display, .headline))
        .foregroundStyle(AtlasTheme.ink)
    }
    .accessibilityElement(children: .combine)
  }
}

/// iPad: the five sections in a sidebar.
struct SplitShell: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: IOSNavigationModel

  private var sectionSelection: Binding<AtlasSection?> {
    Binding(
      get: { navigation.selectedSection },
      set: { newValue in
        guard let newValue else { return }
        if newValue == navigation.selectedSection {
          navigation.paths[newValue] = []
          return
        }
        state.clearTransientMessagesForNavigation()
        navigation.selectedSection = newValue
      }
    )
  }

  var body: some View {
    NavigationSplitView {
      List(selection: sectionSelection) {
        Section {
          IOSBrandMark()
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 12, trailing: 8))
        }
        Section {
          ForEach(AtlasSection.allCases) { section in
            Label(section.title, systemImage: section.systemImage)
              .font(AtlasTheme.font(.body, .body, weight: .medium))
              .tag(section)
              .listRowBackground(
                navigation.selectedSection == section
                  ? AtlasTheme.selection : Color.clear
              )
              .foregroundStyle(
                navigation.selectedSection == section
                  ? AtlasTheme.onSelection : AtlasTheme.ink2
              )
          }
        }
      }
      .scrollContentBackground(.hidden)
      .background(AtlasTheme.surface)
      // The wordmark is the sidebar's title; a bar title would repeat it.
      .navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(AtlasTheme.surface, for: .navigationBar)
      .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
    } detail: {
      SectionStack(section: navigation.selectedSection)
        .id(navigation.selectedSection)
        // Inside the detail column so the toast centers on the content and
        // never spans the sidebar.
        .overlay {
          IOSStatusToast(bottomPadding: 24)
        }
    }
    .navigationSplitViewStyle(.balanced)
  }
}
