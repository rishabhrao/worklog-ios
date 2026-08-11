import Foundation
import UIKit

/// Keeps the screen from dimming and locking.
///
/// The macOS build's `SleepPreventer` held two IOKit power assertions so the
/// Mac never slept and the display never turned off. iOS has exactly one lever
/// here, `isIdleTimerDisabled`, and it only governs the screen: the app itself
/// keeps running with the screen off because of the `audio` background mode,
/// which is the part that actually matters for an all-day recorder. So this is
/// a comfort setting rather than a correctness one - it exists for the case
/// where the phone is propped up in front of you and you want to see the
/// waveform move - and it is off by default, because leaving a screen on all
/// day is the fastest way to flatten a battery.
@MainActor
enum ScreenWakeLock {
    /// Re-reads the setting and applies it. Safe to call repeatedly.
    static func sync() {
        let wanted = WorklogSettingsStore.load().isKeepAwakeEnabled
        guard UIApplication.shared.isIdleTimerDisabled != wanted else { return }
        UIApplication.shared.isIdleTimerDisabled = wanted
    }
}
