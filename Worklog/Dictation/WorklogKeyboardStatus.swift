import Foundation
import UIKit

/// Whether the Worklog keyboard has been enabled by the user, and whether it
/// has been granted Full Access.
///
/// iOS deliberately makes a keyboard extension hard to enable - it is a
/// serious trust decision, since a keyboard sees everything typed - and gives
/// an app no way to enable one on its own behalf or to prompt for it. All the
/// app can do is read the enabled list and say so plainly, which is what the
/// Settings screen's setup row does.
enum WorklogKeyboardStatus {
    static let bundleIdentifier = "com.rishabhrao.worklog.keyboard"

    /// `AppleKeyboards` is the list of keyboard identifiers the user has
    /// added. It is a documented, stable defaults key that keyboard-hosting
    /// apps have read for years; there is no first-party API for this.
    static var isEnabled: Bool {
        guard let keyboards = UserDefaults.standard.object(forKey: "AppleKeyboards") as? [String] else { return false }
        return keyboards.contains { $0.hasPrefix(bundleIdentifier) }
    }

    /// Full Access is what lets the keyboard reach the shared container - the
    /// database it saves dictations into - and the network for cloud
    /// transcription. Without it the keyboard still runs but can only insert
    /// what it recognises on-device, and cannot record the dictation to the
    /// Dictations tab.
    ///
    /// Only the extension itself can answer this (`hasFullAccess` on its own
    /// input controller), so the extension writes the answer into the shared
    /// defaults each time it loads and the app reads it back here.
    static var hasFullAccess: Bool {
        AppGroup.defaults?.bool(forKey: "keyboard.hasFullAccess") ?? false
    }

    /// True once the keyboard has actually run at least once, which is the
    /// only way to know Full Access has been answered rather than merely
    /// never asked.
    static var hasEverLoaded: Bool {
        AppGroup.defaults?.bool(forKey: "keyboard.hasEverLoaded") ?? false
    }
}

/// The container shared between the app and its keyboard extension. Both
/// write to the same `worklog.db`, so a dictation spoken into the keyboard
/// shows up in the app's Dictations tab with no syncing step.
enum AppGroup {
    static let identifier = "group.com.rishabhrao.worklog"

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }

    /// The shared container URL, or nil when the app group is not provisioned
    /// (an unsigned local build). Callers fall back to their own container,
    /// which keeps the app fully working and costs only the keyboard's
    /// ability to record what it dictated.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
