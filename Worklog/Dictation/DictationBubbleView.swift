import SwiftUI

/// What the dictation bubble is showing. Owned by `DictationController` and
/// observed by the overlay panel.
@MainActor
final class DictationBubbleState: ObservableObject {
    enum Stage: Equatable {
        /// Hotkey is held; recording the user's voice.
        case listening
        /// Latched hands-free; recording continues with the key released.
        case handsFree
        /// Batch engine only - audio is uploading and we're waiting on text.
        /// The realtime engine never shows this: its text is already in the
        /// user's field by the time the dictation ends.
        case transcribing
        /// Something went wrong; shown briefly before the bubble goes away.
        case failed(String)
        /// The dictation ran fine and there was simply nothing to transcribe
        /// - the user held the key and didn't speak. Deliberately not a
        /// failure: nothing went wrong, so nothing should look alarming.
        case nothingHeard
    }

    @Published var stage: Stage = .listening

    /// Recent microphone peaks, newest last, each 0...1. Drives the dots.
    @Published var levels: [Float] = []

    /// The realtime engine's current `partial_transcript`. The *only* place
    /// provisional text is ever shown - it is deliberately never typed into
    /// the user's document, because the model revises it as more audio
    /// arrives.
    @Published var partialText: String = ""

    /// Set when a realtime dictation fell back to the batch engine (the
    /// socket wouldn't open, or dropped). Without this, the user just
    /// experiences realtime mysteriously behaving like batch.
    @Published var didFallBackToBatch = false

    func reset() {
        stage = .listening
        levels = []
        partialText = ""
        didFallBackToBatch = false
    }
}

/// The floating capsule shown while dictating: live level dots on the left,
/// state on the right. Deliberately small, non-interactive and quiet - it
/// exists to answer "is it listening?" at a glance, nothing more.
struct DictationBubbleView: View {
    @ObservedObject var state: DictationBubbleState

    private let dotCount = 14

    private static let barWidth: CGFloat = 3.5
    /// Full-scale bar height. The bubble is glanced at from across the
    /// screen while you're looking at your own text, not studied - so the
    /// waveform is sized to read as "it's hearing me" peripherally rather
    /// than to be an accurate meter.
    private static let maxBarHeight: CGFloat = 38
    /// Height at silence. Never zero: a row of bars that vanishes reads as
    /// the feature having died, not as you being quiet.
    private static let restingBarHeight: CGFloat = 3

    /// Floor for the auto-scaling ceiling. Without it, normalizing against
    /// the loudest recent peak would divide a silent room's noise floor by
    /// itself and render idle hiss as a full-scale light show.
    private static let minimumCeiling: Float = 0.06

    /// Transparent breathing room around the capsule so the shadow has
    /// somewhere to fade out. The hosting panel is sized from this view's
    /// `fittingSize`, which measures the capsule but *not* the shadow's blur
    /// radius - without the margin the blur is clipped square by the panel
    /// bounds and reads as a grey rectangle sitting behind the bubble
    /// (invisible against a dark app, obvious against a white one).
    /// `DictationOverlayController` subtracts this when positioning so the
    /// visible capsule still sits where it's meant to.
    static let shadowMargin: CGFloat = 18

    var body: some View {
        HStack(spacing: WorklogSpacing.sm) {
            levelDots

            if !state.partialText.isEmpty {
                Text(state.partialText)
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 220, alignment: .leading)
                    .transition(.opacity)
            }

            trailingIndicator
        }
        .padding(.horizontal, WorklogSpacing.md)
        .padding(.vertical, WorklogSpacing.sm)
        .frame(minWidth: 160)
        .background(
            Capsule(style: .continuous)
                .fill(Color.worklogElevatedSurface)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(borderColor, lineWidth: isHandsFree ? 1.5 : 1)
                )
                // Softer than a typical panel shadow, and split into a tight
                // contact shadow plus a wide ambient one. A single heavy
                // shadow was fine on a dark desktop but muddied into a grey
                // smear over light content - this floats over whatever the
                // user happens to be typing into, so it can't assume a
                // background.
                .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
                .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
        )
        .padding(Self.shadowMargin)
        .animation(MotionPrimitives.aware(MotionPrimitives.standard), value: state.partialText.isEmpty)
        .animation(MotionPrimitives.aware(MotionPrimitives.standard), value: isHandsFree)
    }

    // MARK: - Pieces

    /// One bar per recent audio window, height tracking that window's peak.
    /// Fed from `LivePeakStore`, the same peaks the Clip screen's live
    /// waveform draws - no second audio path just for this.
    private var levelDots: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<dotCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(dotColor)
                    .frame(width: Self.barWidth, height: height(at: index))
            }
        }
        .frame(height: Self.maxBarHeight)
        .animation(MotionPrimitives.aware(.easeOut(duration: 0.08)), value: state.levels)
    }

    @ViewBuilder
    private var trailingIndicator: some View {
        switch state.stage {
        case .listening:
            EmptyView()
        case .handsFree:
            Image(systemName: "lock.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.worklogAccent)
                .help("Hands-free - press the hotkey to save, Escape to discard")
        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 14, height: 14)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.worklogError)
        case .nothingHeard:
            Image(systemName: "waveform.slash")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.worklogTextTertiary)
                .help("Nothing was said")
        }

        if state.didFallBackToBatch {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.worklogTextTertiary)
                .help("Realtime was unavailable - finishing with Scribe v2")
        }
    }

    // MARK: - Derived appearance

    private var isHandsFree: Bool {
        if case .handsFree = state.stage { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = state.stage { return true }
        return false
    }

    private var borderColor: Color {
        if isFailed { return Color.worklogError.opacity(0.7) }
        if isHandsFree { return Color.worklogAccent.opacity(0.7) }
        return Color.worklogHairline
    }

    private var dotColor: Color {
        if isFailed { return Color.worklogError }
        if isHandsFree { return Color.worklogAccent }
        return Color.worklogTextSecondary
    }

    /// Maps the newest `dotCount` peaks onto dot heights. Older peaks sit to
    /// the left, so the row reads as the last second of speech scrolling by.
    /// Reduce Motion freezes the dots at a flat resting height rather than
    /// removing them - the indicator still has to say "listening."
    private func height(at index: Int) -> CGFloat {
        let resting = Self.restingBarHeight
        guard !MotionPrimitives.reduceMotionEnabled else { return resting }
        let levels = state.levels
        guard levels.count >= dotCount else {
            // Not enough history yet: pad from the left so incoming audio
            // fills the row rightward instead of jumping.
            let offset = dotCount - levels.count
            guard index >= offset else { return resting }
            return scaled(levels[index - offset])
        }
        return scaled(levels[levels.count - dotCount + index])
    }

    /// Loudest peak currently on screen, floored. The bars are scaled
    /// against this rather than against 1.0, which is what actually makes
    /// them move: raw capture peaks for ordinary speech occupy a narrow
    /// band well below full scale, so an absolute mapping leaves the row
    /// nearly flat no matter how tall the bars are. Auto-scaling to what's
    /// actually in view means normal talking uses the full height - the
    /// same approach the Clip screen's waveform takes.
    private var ceiling: Float {
        let visible = state.levels.suffix(dotCount)
        return max(visible.max() ?? 0, Self.minimumCeiling)
    }

    private func scaled(_ level: Float) -> CGFloat {
        let normalized = CGFloat(max(0, min(1, level / ceiling)))
        // Mild shaping on top of the normalization. Gentler than before
        // (0.4) because auto-scaling already does most of the lifting;
        // stacking an aggressive curve on top of it flattens the loud end
        // back out and costs the contrast this is meant to create.
        let shaped = pow(normalized, 0.7)
        return Self.restingBarHeight + shaped * (Self.maxBarHeight - Self.restingBarHeight)
    }
}
