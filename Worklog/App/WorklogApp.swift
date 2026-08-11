import AVFoundation
import SwiftUI
import UIKit
import UserNotifications

/// The app entry point.
///
/// Where the macOS build is a menu-bar agent with a manually-hosted window,
/// this is an ordinary SwiftUI app around a tab shell - the same shape as the
/// Android build, because a phone is a phone. Everything below the UI is the
/// same code.
@main
struct WorklogApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var recordingController = AppEnvironment.shared.recordingController
    @StateObject private var themeManager = ThemeManager.shared
    @State private var isOnboarded = OnboardingState.hasCompleted

    var body: some Scene {
        WindowGroup {
            Group {
                if isOnboarded {
                    AppShellView()
                } else {
                    OnboardingView(
                        viewModel: OnboardingViewModel(recordingController: recordingController),
                        onFinished: {
                            OnboardingState.hasCompleted = true
                            isOnboarded = true
                        }
                    )
                }
            }
            .environmentObject(recordingController)
            .preferredColorScheme(themeManager.theme.colorScheme)
            // Share-to-Worklog. An audio file or a `.worklog.zip` opened from
            // any app lands here; the import stages a copy immediately,
            // because the security-scoped grant does not outlive this call.
            .onOpenURL { url in
                Task {
                    // The security-scoped grant does not outlive this call,
                    // so the importer stages its own copy before anything
                    // else happens to it.
                    _ = await ClipImporter.importFiles(at: [url])
                    AppNavigationRequests.request(.library)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { recordingController.applicationDidBecomeActive() }
        }
    }
}

/// The single owner of the app's long-lived objects. Kept off the SwiftUI
/// view tree so a view being torn down can never take capture with it, and so
/// non-UI callers (the notification handler, the keyboard extension's host)
/// reach exactly the same instances.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let recordingController: RecordingController
    let dictationController: DictationController

    /// Held for the lifetime of the app - a dispatch timer stops firing the
    /// moment nothing references it.
    private var retentionTimer: DispatchSourceTimer?

    private init() {
        // The full folder layout has to exist before anything reads it - the
        // database opens on first touch, and the retention sweeper walks
        // folders that may never have been created on a fresh install.
        try? WorklogPaths.ensureFullLayoutExists()
        FileLayoutMigration.run()
        recordingController = RecordingController()
        dictationController = DictationController(recordingController: recordingController)
        StartupReconciliation.run()
        retentionTimer = RetentionSweeper.schedulePeriodicSweeps()
        SpeechPreviewEngine.shared.activate(recordingController: recordingController)
        dictationController.syncWithSettings()
        ScreenWakeLock.sync()
    }

    /// Settings is rebuilt each time it appears so it reflects true current
    /// state rather than a snapshot from launch - the view model reads
    /// everything in its initializer.
    func makeSettingsViewModel() -> SettingsViewModel {
        SettingsViewModel(
            recordingController: recordingController,
            locationTagger: recordingController.locationTagger,
            dictationController: dictationController
        )
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        _ = AppEnvironment.shared
        return true
    }

    /// Worklog's notifications are all about capture - it stopped, a device
    /// vanished, it recovered. Those matter while the app is open too, so
    /// they are shown rather than swallowed.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        AppNavigationRequests.request(.clip)
        completionHandler()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AppEnvironment.shared.recordingController.stopForQuit()
    }
}
