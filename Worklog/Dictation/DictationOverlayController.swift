import Combine
import Foundation

/// Owns the dictation bubble's state and its visibility.
///
/// The macOS build put the bubble in its own borderless `NSPanel` floating
/// above every app, and this class managed that window. iOS has no such
/// thing - an app cannot draw outside itself - so the bubble is an overlay
/// inside whichever surface is running the dictation: the app's own screen,
/// or the keyboard extension's view. This class therefore manages only state;
/// the view observes it and animates itself in and out.
///
/// The API is deliberately the same as the macOS one, `refreshLayout()`
/// included (a no-op here, since SwiftUI resizes itself), so
/// `DictationController` reads identically on both platforms.
@MainActor
final class DictationOverlayController: ObservableObject {
    let state = DictationBubbleState()

    /// Whether the bubble should be on screen.
    @Published private(set) var isVisible = false

    private var dismissTask: Task<Void, Never>?

    func show() {
        dismissTask?.cancel()
        dismissTask = nil
        state.stage = .listening
        state.partialText = ""
        state.didFallBackToBatch = false
        isVisible = true
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        isVisible = false
    }

    /// Leaves the bubble up long enough to read a terminal state - "nothing
    /// heard", a failure - then takes it away.
    func dismiss(after delay: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.isVisible = false
        }
    }

    /// No-op. The macOS bubble was a manually-sized window that had to be
    /// re-laid-out whenever its text changed; a SwiftUI overlay does that on
    /// its own. Kept so the controller's call sites match the macOS build.
    func refreshLayout() {}
}
