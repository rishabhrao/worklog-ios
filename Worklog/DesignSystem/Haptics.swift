import SwiftUI
import UIKit

/// The app's haptics.
///
/// The vocabulary here is identical to the macOS and Android builds - call
/// sites name an event, never a pattern - but the substrate is very
/// different. macOS offers three fixed trackpad patterns and nothing else, so
/// everything expressive there had to be built out of *timing*. iOS gives
/// real impact styles with a continuous intensity, so an event maps to a
/// weight directly, and sequences are reserved for the few events that are
/// genuinely two-part (a success, a failure).
///
/// Restraint is still the point. A light tick the instant a control goes down
/// is right - that is the system saying it heard you - but the heavier
/// patterns belong only to things that happen a few times an hour. Anything
/// felt hundreds of times a day gets the lightest thing available, or it
/// stops reading as feedback and starts reading as noise.
@MainActor
enum WorklogHaptics {

    // MARK: - Vocabulary

    /// What happened, never how it should feel. The mapping from these to
    /// actual pulses lives in `sequence(for:)` and nowhere else.
    enum Event {
        /// A control went down under the finger. By a wide margin the most
        /// common event in the app, so it gets the lightest thing available.
        case tap
        /// Selection moved - a different row, tab, destination, or chip.
        case select
        /// A switch flipped.
        case toggle
        /// A slider passed one of its stops, or a drag passed a minor mark
        /// on a timeline ruler.
        case detent
        /// A drag passed a *round* mark on a timeline ruler - a minute, an
        /// hour. Firmer than `detent`, so scrubbing has texture at two
        /// scales and you can count without looking.
        case detentMajor
        /// A draggable thing was picked up - a waveform handle, a playhead.
        /// Firmer than a tap, because what it confirms is that you have hold
        /// of something and the next movement will move it.
        case grab
        /// A control refused to go further, or an action was declined.
        case boundary
        /// Something finished and worked: a save, a merge, a copy.
        case success
        /// Something needs confirming, or finished with a caveat.
        case warning
        /// Something failed.
        case failure

        /// Dictation engaged - capture began.
        case dictationStart
        /// Dictation latched hands-free.
        case dictationLatch
        /// Dictation ended and is being transcribed.
        case dictationStop
        /// Dictation was thrown away.
        case dictationCancel
    }

    // MARK: - Playing

    static func play(_ event: Event) {
        guard isEnabled else { return }
        guard passesRateLimit(for: event) else { return }

        var offset: TimeInterval = 0
        for pulse in sequence(for: event) {
            offset += pulse.gap
            guard offset > 0 else {
                actuate(pulse)
                continue
            }
            // A sequence is a shape in time, so the tail cannot be skipped
            // when the app is busy - `asyncAfter` on main is close enough at
            // these gaps, and a dropped pulse would change what the event
            // means rather than merely delay it.
            DispatchQueue.main.asyncAfter(deadline: .now() + offset) {
                actuate(pulse)
            }
        }
    }

    /// One pulse: what to fire, and how long after the previous one.
    private struct Pulse {
        enum Kind {
            case impact(UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat)
            case selection
            case notification(UINotificationFeedbackGenerator.FeedbackType)
        }
        let kind: Kind
        let gap: TimeInterval

        static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle, _ intensity: CGFloat = 1.0, after gap: TimeInterval = 0) -> Pulse {
            Pulse(kind: .impact(style, intensity: intensity), gap: gap)
        }
        static func selection(after gap: TimeInterval = 0) -> Pulse {
            Pulse(kind: .selection, gap: gap)
        }
        static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType, after gap: TimeInterval = 0) -> Pulse {
            Pulse(kind: .notification(type), gap: gap)
        }
    }

    /// Generators are retained rather than made per pulse. Creating one is
    /// not free, and more importantly a fresh generator has a cold Taptic
    /// Engine behind it - the first pulse from it lands late, which is
    /// exactly the pulse that has to feel instant.
    private static let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private static let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private static let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
    private static let rigidImpact = UIImpactFeedbackGenerator(style: .rigid)
    private static let softImpact = UIImpactFeedbackGenerator(style: .soft)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notificationGenerator = UINotificationFeedbackGenerator()

    private static func generator(for style: UIImpactFeedbackGenerator.FeedbackStyle) -> UIImpactFeedbackGenerator {
        switch style {
        case .light: return lightImpact
        case .medium: return mediumImpact
        case .heavy: return heavyImpact
        case .rigid: return rigidImpact
        case .soft: return softImpact
        @unknown default: return mediumImpact
        }
    }

    private static func actuate(_ pulse: Pulse) {
        switch pulse.kind {
        case let .impact(style, intensity):
            generator(for: style).impactOccurred(intensity: intensity)
        case .selection:
            selectionGenerator.selectionChanged()
        case let .notification(type):
            notificationGenerator.notificationOccurred(type)
        }
    }

    /// Warms the Taptic Engine so the next pulse lands immediately. Call on
    /// the frame before a haptic becomes likely - a drag starting, a sheet
    /// appearing - never speculatively, because a prepared engine draws power
    /// for a couple of seconds.
    static func prepare() {
        guard isEnabled else { return }
        lightImpact.prepare()
        selectionGenerator.prepare()
    }

    private static func sequence(for event: Event) -> [Pulse] {
        switch event {
        // The everyday events. `.selectionChanged` is the lightest thing iOS
        // has and is exactly what it is named for.
        case .tap:
            return [.impact(.light, 0.45)]
        case .select, .detent:
            return [.selection()]

        case .toggle:
            return [.impact(.light, 0.75)]
        case .detentMajor:
            return [.impact(.rigid, 0.7)]
        case .grab:
            return [.impact(.medium, 0.8)]
        case .boundary:
            return [.impact(.soft, 0.9)]

        // Two-part shapes. A rise then a firmer landing reads as "done"; the
        // reverse reads as "no".
        case .success:
            return [.impact(.light, 0.6), .impact(.medium, 0.9, after: 0.08)]
        case .warning:
            return [.notification(.warning)]
        case .failure:
            return [.impact(.heavy, 0.9), .impact(.heavy, 0.6, after: 0.11)]

        // Dictation. These punctuate speech, so they are deliberately
        // distinct from anything in the list above: you have to be able to
        // tell start from stop without looking at the screen.
        case .dictationStart:
            return [.impact(.medium, 0.85)]
        case .dictationLatch:
            return [.impact(.light, 0.5), .impact(.light, 0.5, after: 0.07)]
        case .dictationStop:
            return [.impact(.soft, 0.7)]
        case .dictationCancel:
            return [.impact(.soft, 0.45), .impact(.soft, 0.3, after: 0.06)]
        }
    }

    // MARK: - Rate limiting

    /// Two haptics inside 20ms are felt as one mushy thing rather than two
    /// ticks, so the second is dropped rather than felt as slop. Only the
    /// high-frequency events are limited - a `.success` that genuinely lands
    /// during a drag should still be felt.
    private static let minimumInterval: TimeInterval = 0.02
    private static var lastActuation: TimeInterval = 0

    private static func passesRateLimit(for event: Event) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        switch event {
        case .tap, .select, .detent, .detentMajor:
            guard now - lastActuation >= minimumInterval else { return false }
        default:
            break
        }
        lastActuation = now
        return true
    }

    // MARK: - Settings

    /// Cached, because this is read on every finger-down and
    /// `WorklogSettingsStore.load()` is a SQLite round-trip on the main
    /// thread. Settings invalidates it on save.
    private static var cachedEnabled: Bool?

    static var isEnabled: Bool {
        if let cachedEnabled { return cachedEnabled }
        let value = WorklogSettingsStore.load().areHapticsEnabled
        cachedEnabled = value
        return value
    }

    /// Call after writing settings. Cheap - the next haptic re-reads.
    static func settingsDidChange() {
        cachedEnabled = nil
    }
}

// MARK: - Press physics

extension View {
    /// The app's shared finger-down behaviour: flips `isPressing` the
    /// instant the finger lands, fires a haptic with it, and releases on a
    /// soft spring.
    ///
    /// Every pressable control in the app used to carry its own copy of this
    /// gesture. Having one means the press feel and the haptic can never
    /// drift apart between components - and that a control added later gets
    /// both by construction rather than by remembering.
    ///
    /// Deliberately `simultaneousGesture`: the wrapped `Button`'s own action
    /// must still fire on release, and a plain `.gesture` would swallow it.
    func worklogPressFeedback(
        isPressing: Binding<Bool>,
        haptic: WorklogHaptics.Event? = .tap
    ) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressing.wrappedValue else { return }
                    if let haptic { WorklogHaptics.play(haptic) }
                    withAnimation(MotionPrimitives.aware(MotionPrimitives.pressDown)) {
                        isPressing.wrappedValue = true
                    }
                }
                .onEnded { _ in
                    withAnimation(MotionPrimitives.aware(MotionPrimitives.interactive)) {
                        isPressing.wrappedValue = false
                    }
                }
        )
    }
}
