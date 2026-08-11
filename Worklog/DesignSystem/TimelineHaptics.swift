import SwiftUI

/// Ruler-style haptics for dragging along a timeline.
///
/// The radius slider was the easy case: it has ten real stops, so every bump
/// is a value worth feeling and the haptics only had to point at what was
/// already there. A waveform has no stops at all - it is continuous time -
/// so its bumps have to be invented, and the only invention worth making is
/// one that tells you something you didn't already know.
///
/// So this is a ruler. Ticks land on round numbers of seconds or minutes,
/// with a firmer one at each round unit, and - the part that matters - the
/// spacing is chosen from the *distance on screen*, not from the duration.
/// That is what lets a twenty-second dictation and a one-hour clip both feel
/// right under the finger: the bumps stay about the same distance apart, and
/// what changes is what each one is worth. Scrubbing the length of a long
/// recording gives a fast patter of minutes; the same gesture over a short
/// one gives a few deliberate seconds. The difference in feel *is* the
/// information about scale.
struct TimelineRuler {
    /// Seconds between minor ticks.
    let minorStep: TimeInterval
    /// How many minor ticks make one major one.
    let majorEvery: Int

    /// Roughly how far apart the bumps should land on screen, in points.
    /// Calibrated against the radius slider, which puts ten stops across a
    /// comparable width: a little denser than that stops reading as a set of
    /// positions and starts reading as a ruler, which is the point.
    private static let targetSpacing: CGFloat = 26

    /// Steps a person would actually count in, each paired with how many of
    /// them make a round unit - five seconds, a minute, five minutes, an
    /// hour. A ladder of powers of two would be evenly spaced and mean
    /// nothing; the whole value of the firmer tick is that it lands
    /// somewhere you could name.
    private static let ladder: [(step: TimeInterval, majorEvery: Int)] = [
        (0.5, 4),      // major: 2s
        (1, 5),        // 5s
        (2, 5),        // 10s
        (5, 6),        // 30s
        (10, 6),       // 1m
        (15, 4),       // 1m
        (30, 2),       // 1m
        (60, 5),       // 5m
        (120, 5),      // 10m
        (300, 6),      // 30m
        (600, 6),      // 1h
        (900, 4),      // 1h
        (1800, 2),     // 1h
        (3600, 1),     // 1h
    ]

    /// The finest ruler whose ticks are still far enough apart to be felt
    /// separately at this width.
    static func fitting(duration: TimeInterval, width: CGFloat) -> TimelineRuler {
        guard duration > 0, width > 0 else { return TimelineRuler(minorStep: 1, majorEvery: 5) }
        let pixelsPerSecond = width / CGFloat(duration)
        let choice = ladder.first { CGFloat($0.step) * pixelsPerSecond >= targetSpacing } ?? ladder[ladder.count - 1]
        return TimelineRuler(minorStep: choice.step, majorEvery: choice.majorEvery)
    }

    func index(at time: TimeInterval) -> Int {
        Int((time / minorStep).rounded(.down))
    }

    func isMajor(_ index: Int) -> Bool {
        majorEvery <= 1 || index % majorEvery == 0
    }
}

/// Tracks one drag along a timeline and plays the ruler under it.
///
/// A reference type held in `@State`: its identity never changes, so
/// mutating it on every pointer move doesn't invalidate the view. A struct
/// here would redraw the waveform on each tick for no reason.
final class ScrubHaptics {

    /// The floor on how fast ticks may come. A quick drag across a long
    /// recording crosses a line every few milliseconds, and below roughly
    /// this the actuator stops producing separate taps and starts producing
    /// a smear - so the ruler thins out under speed instead of turning to
    /// mush. Deliberately looser than the engine's own limit, which exists
    /// to catch accidents rather than to shape a drag.
    private static let minimumGap: TimeInterval = 0.04

    private var hasBegun = false
    private var lastIndex: Int?
    private var lastTick: TimeInterval = 0
    private var wasAtStart = false
    private var wasAtEnd = false

    /// Announces the grab. Only needed by callers whose gesture reports a
    /// drag start of its own; `update` does it otherwise, so a plain
    /// click-to-seek still gets exactly one tick.
    @MainActor
    func begin() {
        guard !hasBegun else { return }
        hasBegun = true
        lastIndex = nil
        WorklogHaptics.play(.grab)
    }

    @MainActor
    func update(time: TimeInterval, duration: TimeInterval, width: CGFloat) {
        let ruler = TimelineRuler.fitting(duration: duration, width: width)
        let clamped = min(max(time, 0), max(duration, 0))

        guard hasBegun else {
            begin()
            lastIndex = ruler.index(at: clamped)
            wasAtStart = clamped <= 0
            wasAtEnd = duration > 0 && clamped >= duration
            return
        }

        // Each end is worth feeling once, on arrival - not over and over
        // while the pointer sits out past it, which is what dragging to the
        // very edge of the window does.
        let atStart = clamped <= 0
        let atEnd = duration > 0 && clamped >= duration
        defer { wasAtStart = atStart; wasAtEnd = atEnd }

        if (atStart && !wasAtStart) || (atEnd && !wasAtEnd) {
            lastIndex = ruler.index(at: clamped)
            lastTick = ProcessInfo.processInfo.systemUptime
            WorklogHaptics.play(.boundary)
            return
        }
        guard !atStart, !atEnd else { return }

        // One tick per line *arrived at*, never one per line crossed: a
        // fast drag can skip several between two pointer events, and firing
        // for each would spend them all in the same instant.
        let index = ruler.index(at: clamped)
        guard index != lastIndex else { return }
        lastIndex = index

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTick >= Self.minimumGap else { return }
        lastTick = now

        WorklogHaptics.play(ruler.isMajor(index) ? .detentMajor : .detent)
    }

    func end() {
        hasBegun = false
        lastIndex = nil
    }
}
