import SwiftUI

/// The app's single shell: a tab bar across Clip / Library / Dictations /
/// Settings with the recording status bar pinned above it - the iOS
/// counterpart of the macOS sidebar plus always-present recording card, and a
/// direct match for the Android build's bottom navigation.
///
/// There is deliberately no Places tab. Places and tags are both things you
/// set up occasionally and then forget; the tabs are for what you open every
/// day. Both live in Settings, and a clip's own location chip still edits its
/// place directly.
struct AppShellView: View {
    @StateObject private var clipViewModel = ClipScreenViewModel()
    @StateObject private var libraryViewModel = LibraryViewModel()
    @StateObject private var dictationsViewModel = DictationsViewModel()
    @StateObject private var settingsViewModel = AppEnvironment.shared.makeSettingsViewModel()

    @State private var selection: AppShellRoute = Self.initialRoute
    @State private var libraryPath = NavigationPath()
    @State private var dictationsPath = NavigationPath()

    var body: some View {
        TabView(selection: tabSelection) {
            NavigationStack {
                ClipScreenView(viewModel: clipViewModel)
            }
            .withRecordingStatusBar()
            .tag(AppShellRoute.clip)
            .tabItem { Label("Clip", systemImage: "waveform") }

            NavigationStack(path: $libraryPath) {
                LibraryView(viewModel: libraryViewModel, onOpenEntry: openClip)
                    .navigationDestination(for: String.self) { clipID in
                        LibraryDetailScreen(viewModel: libraryViewModel, clipID: clipID)
                    }
            }
            .withRecordingStatusBar()
            .tag(AppShellRoute.library)
            .tabItem { Label("Library", systemImage: "tray.full") }

            NavigationStack(path: $dictationsPath) {
                DictationsView(viewModel: dictationsViewModel, onOpenEntry: openDictation)
                    .navigationDestination(for: String.self) { dictationID in
                        DictationDetailScreen(viewModel: dictationsViewModel, dictationID: dictationID)
                    }
            }
            .withRecordingStatusBar()
            .tag(AppShellRoute.dictations)
            .tabItem { Label("Dictations", systemImage: "mic") }

            NavigationStack {
                SettingsView(viewModel: settingsViewModel)
            }
            .withRecordingStatusBar()
            .tag(AppShellRoute.settings)
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        // Creating a clip takes the user straight to it in the Library, which
        // is where everything about it lives from that moment on.
        .onAppear {
            clipViewModel.onClipCreated = { clipID in
                openClip(clipID)
            }
        }
        .onReceive(AppNavigationRequests.publisher) { route in
            AppNavigationRequests.consume()
            guard route != selection else { return }
            selection = route
        }
        // Leaving a screen silences it. These view models are shell-scoped and
        // outlive the screens that drive them, so nothing else would: audio
        // started on one page would otherwise keep playing underneath whatever
        // the user opened next.
        .onChange(of: selection) { _, _ in stopAllPlayback() }
        .onChange(of: libraryPath) { _, _ in stopAllPlayback() }
        .onChange(of: dictationsPath) { _, _ in stopAllPlayback() }
    }

    /// A tab tap is a way back to that tab's list, always - tapping Library
    /// from inside a clip lands on the Library, not back on that same clip.
    /// It also resets the page when you are already on it, because these view
    /// models are shell-scoped and outlive their screens: a search typed days
    /// ago would otherwise still be filtering the list.
    private var tabSelection: Binding<AppShellRoute> {
        Binding(
            get: { selection },
            set: { newValue in
                WorklogHaptics.play(newValue == selection ? .tap : .select)
                switch newValue {
                case .clip:
                    clipViewModel.resetToCleanState()
                case .library:
                    libraryPath = NavigationPath()
                    libraryViewModel.resetToCleanState()
                case .dictations:
                    dictationsPath = NavigationPath()
                    dictationsViewModel.resetToCleanState()
                case .settings:
                    break
                }
                selection = newValue
            }
        )
    }

    /// Which tab to open on. Normally Clip; overridable so a screenshot run
    /// can land on any tab without driving the UI. The macOS build has the
    /// same escape hatch in `WORKLOG_DATA_ROOT`, for the same reason:
    /// documentation shots must be reproducible.
    private static var initialRoute: AppShellRoute {
        guard let raw = ProcessInfo.processInfo.environment["WORKLOG_INITIAL_TAB"],
              let route = AppShellRoute(rawValue: raw) else { return .clip }
        return route
    }

    private func openClip(_ clipID: String) {
        libraryViewModel.focusEntry(clipID: clipID)
        selection = .library
        libraryPath = NavigationPath()
        libraryPath.append(clipID)
    }

    private func openDictation(_ dictationID: String) {
        dictationsViewModel.focusEntry(dictationID: dictationID)
        dictationsPath.append(dictationID)
    }

    private func stopAllPlayback() {
        clipViewModel.stopPlaybackOnNavigate()
        libraryViewModel.stopPlaybackOnNavigate()
        dictationsViewModel.stopPlaybackOnNavigate()
    }
}
