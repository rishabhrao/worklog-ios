import Foundation
import UserNotifications

/// Fires macOS user notifications for automatic/unexpected recording-state
/// transitions only. There is deliberately no API here for "manual
/// start/stop" or "sleep/wake" - those must never notify per spec, so the
/// call sites that would notify for them simply don't exist rather than
/// relying on every caller to remember to skip a generic `notify()`.
enum WorklogNotifier {
    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func pinnedDeviceLost(deviceName: String) {
        post(title: "Recording stopped", body: "Pinned device \u{201c}\(deviceName)\u{201d} is unavailable.", highPriority: false)
    }

    static func pinnedDeviceRestored(deviceName: String) {
        post(title: "Recording resumed", body: "Pinned device \u{201c}\(deviceName)\u{201d} is back - recording resumed.", highPriority: false)
    }

    static func errorAutoRestart() {
        post(title: "Recording restarted", body: "A capture error occurred and recording was automatically restarted.", highPriority: false)
    }

    static func micPermissionDenied() {
        post(
            title: "Recording stopped",
            body: "Microphone access is denied. Turn it on in Settings › Worklog › Microphone, then try again.",
            highPriority: false
        )
    }

    static func inputWentSilent(deviceName: String) {
        post(
            title: "Microphone input went silent",
            body: "\u{201c}\(deviceName)\u{201d} is delivering no audio despite repeated restarts - a Bluetooth device may have taken over the microphone. Worklog keeps retrying; check your audio devices.",
            highPriority: true
        )
    }

    static func crashRecoveryResumed() {
        post(
            title: "Recording resumed automatically",
            body: "Worklog was recording before it quit unexpectedly and has resumed.",
            highPriority: true
        )
    }

    // MARK: - Dictation

    /// The hotkey was pressed but capture can't run. Dictation has no
    /// window of its own to show an error in - the bubble is a
    /// non-interactive overlay - so a refusal has to say why here, or it
    /// reads as the hotkey simply not working.
    static func dictationUnavailable(reason: String) {
        post(title: "Dictation couldn't start", body: reason, highPriority: false)
    }

    static func dictationFailed(reason: String) {
        post(title: "Dictation failed", body: reason, highPriority: false)
    }

    /// Focus moved between starting the dictation and having text to
    /// insert, so it was copied instead of typed into the wrong window.
    static func dictationCopiedNotPasted() {
        post(
            title: "Dictation ready",
            body: "You switched apps, so it wasn't pasted. Press \u{2318}V to paste it.",
            highPriority: false
        )
    }

    private static func post(title: String, body: String, highPriority: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if highPriority {
            content.interruptionLevel = .timeSensitive
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
