import SwiftUI

/// Renders a `LoadedRange`'s peak data as a waveform, drawing from
/// downsampled peaks (never full-resolution PCM) so it stays fast at any
/// zoom level per spec. `Canvas` draws at the view's native resolution, so
/// this is retina-sharp without any extra scale-factor handling.
struct WaveformView: View {
    let range: LoadedRange
    let selectionStart: TimeInterval
    let selectionEnd: TimeInterval

    var body: some View {
        Canvas { context, size in
            let totalDuration = max(range.totalDuration, 1)
            let midY = size.height / 2

            // Dynamic amplitude scale: normalize to the loudest peak in the
            // currently loaded range so normal speech fills the vertical
            // space instead of rendering as a tiny sliver (raw mic peaks
            // rarely approach 1.0). Amplification is capped so a range of
            // pure room tone doesn't get its noise floor blown up into
            // something that reads as speech.
            let maxPeak = range.segments.lazy.flatMap(\.peaks).max() ?? 0
            let amplitudeScale = maxPeak > 0 ? min(0.95 / CGFloat(maxPeak), 40) : 1

            for segment in range.segments {
                let segmentStartX = CGFloat(segment.rangeOffset / totalDuration) * size.width

                if segment.isUnreadable {
                    // No decodable audio to draw a real waveform from, but
                    // real time was recorded here - mark it distinctly
                    // (a thin warning-colored band) rather than leaving an
                    // unexplained blank gap indistinguishable from "nothing
                    // was ever recorded."
                    let segmentEndX = CGFloat((segment.rangeOffset + segment.duration) / totalDuration) * size.width
                    let rect = CGRect(x: segmentStartX, y: midY - 2, width: max(1, segmentEndX - segmentStartX), height: 4)
                    context.fill(Path(rect), with: .color(Color.worklogWarning.opacity(0.6)))
                    continue
                }

                guard !segment.peaks.isEmpty else { continue }
                let pixelsPerPeak = size.width / CGFloat(totalDuration * segment.peaksPerSecond)

                var path = Path()
                for (i, peak) in segment.peaks.enumerated() {
                    let x = segmentStartX + CGFloat(i) * pixelsPerPeak
                    guard x >= 0, x <= size.width else { continue }
                    let barHeight = max(1, CGFloat(peak) * amplitudeScale * midY)
                    path.addRect(CGRect(x: x, y: midY - barHeight, width: max(1, pixelsPerPeak), height: barHeight * 2))
                }

                let offsetStart = segment.rangeOffset
                let offsetEnd = segment.rangeOffset + segment.duration
                let overlapsSelection = offsetEnd > selectionStart && offsetStart < selectionEnd
                context.fill(path, with: .color(overlapsSelection ? Color.worklogAccent : Color.worklogTextTertiary))
            }
        }
        .drawingGroup()
    }
}

/// The selection overlay: a translucent band over `[selectionStart,
/// selectionEnd]` plus two draggable handles. Handles are independently
/// draggable per spec's hard constraint (not a movable start with fixed
/// end) and spring subtly on release.
struct SelectionOverlay: View {
    let totalDuration: TimeInterval
    @Binding var selectionStart: TimeInterval
    @Binding var selectionEnd: TimeInterval
    let onStartDragged: (TimeInterval) -> Void
    let onEndDragged: (TimeInterval) -> Void

    /// Owned by the clip screen, not here - the words strip below the
    /// waveform brightens whichever edge is being dragged, so the drag
    /// state has to be visible outside this overlay.
    @Binding var isDraggingStart: Bool
    @Binding var isDraggingEnd: Bool

    /// One per handle: they drag independently, so they cannot share the
    /// memory of which mark was last passed.
    @State private var startScrub = ScrubHaptics()
    @State private var endScrub = ScrubHaptics()

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = max(totalDuration, 1)
            let startX = CGFloat(selectionStart / duration) * width
            let endX = CGFloat(selectionEnd / duration) * width

            ZStack(alignment: .topLeading) {
                // Purely decorative - must never intercept clicks meant for
                // the waveform beneath it. Without allowsHitTesting(false),
                // this filled shape (which spans nearly the whole width by
                // default, since selectionEnd starts at totalDuration)
                // silently swallowed every click-to-seek gesture on the
                // waveform underneath, no matter where in the range the
                // user clicked - found via user report: "click on any part
                // of the timeline, it does not seek."
                Rectangle()
                    .fill(Color.worklogAccent.opacity(0.12))
                    .frame(width: max(0, endX - startX), height: geometry.size.height)
                    .offset(x: startX)
                    .allowsHitTesting(false)

                handle(at: startX, isDragging: isDraggingStart)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDraggingStart = true
                                let offset = Double(value.location.x / width) * duration
                                onStartDragged(offset)
                                // Choosing where a clip begins is the one
                                // drag in the app where knowing *how far*
                                // you have moved matters more than where you
                                // have landed - which is exactly what a
                                // ruler under the finger tells you.
                                startScrub.update(time: offset, duration: duration, width: width)
                            }
                            .onEnded { _ in
                                startScrub.end()
                                withAnimation(MotionPrimitives.aware(MotionPrimitives.interactive)) {
                                    isDraggingStart = false
                                }
                            }
                    )
                    .accessibilityLabel("Selection start")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAdjustableAction { direction in
                        onStartDragged(nudged(selectionStart, direction, duration: duration))
                    }

                handle(at: endX, isDragging: isDraggingEnd)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDraggingEnd = true
                                let offset = Double(value.location.x / width) * duration
                                onEndDragged(offset)
                                endScrub.update(time: offset, duration: duration, width: width)
                            }
                            .onEnded { _ in
                                endScrub.end()
                                withAnimation(MotionPrimitives.aware(MotionPrimitives.interactive)) {
                                    isDraggingEnd = false
                                }
                            }
                    )
                    .accessibilityLabel("Selection end")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAdjustableAction { direction in
                        onEndDragged(nudged(selectionEnd, direction, duration: duration))
                    }
            }
        }
    }

    /// One-second nudge per VoiceOver swipe - the accessible equivalent of a
    /// fine drag. The macOS build bound this to the arrow keys; on iOS the
    /// handles are dragged with a thumb, and this is the path for someone who
    /// cannot see where the thumb is going.
    private func nudged(_ current: TimeInterval, _ direction: AccessibilityAdjustmentDirection, duration: TimeInterval) -> TimeInterval {
        let step: TimeInterval = 1.0
        switch direction {
        case .decrement: return max(0, current - step)
        case .increment: return min(duration, current + step)
        @unknown default: return current
        }
    }

    /// The visible handle stays slim - it is a precision instrument and a fat
    /// bar would hide the audio under it - but the *touchable* area around it
    /// is 44pt wide, which is the smallest target a thumb can hit reliably and
    /// the figure iOS itself is built around. The macOS build could get away
    /// with 24pt because a pointer is exact.
    private func handle(at x: CGFloat, isDragging: Bool) -> some View {
        Capsule()
            .fill(Color.worklogAccent)
            .frame(width: 6, height: isDragging ? 96 : 88)
            .scaleEffect(isDragging ? 1.12 : 1.0)
            .offset(x: x - 3)
            .animation(MotionPrimitives.aware(MotionPrimitives.interactive), value: isDragging)
            .contentShape(Rectangle().size(width: 44, height: 120).offset(x: x - 22))
    }
}

/// The animated playhead - glides during playback rather than jumping
/// discretely, per spec, tying into the shared motion primitives.
struct PlayheadView: View {
    let totalDuration: TimeInterval
    let position: TimeInterval

    var body: some View {
        GeometryReader { geometry in
            let duration = max(totalDuration, 1)
            let x = CGFloat(position / duration) * geometry.size.width
            Rectangle()
                .fill(Color.worklogTextPrimary)
                .frame(width: 1.5, height: geometry.size.height)
                .offset(x: x)
                .animation(MotionPrimitives.aware(.linear(duration: 1.0 / 30.0)), value: position)
        }
        .allowsHitTesting(false)
    }
}

/// Faint hover-position indicator that follows the cursor before a click
/// commits a seek, per spec.
struct HoverPreviewView: View {
    let totalDuration: TimeInterval
    let hoverPosition: TimeInterval?

    var body: some View {
        GeometryReader { geometry in
            if let hoverPosition {
                let duration = max(totalDuration, 1)
                let x = CGFloat(hoverPosition / duration) * geometry.size.width
                Rectangle()
                    .fill(Color.worklogTextTertiary.opacity(0.5))
                    .frame(width: 1, height: geometry.size.height)
                    .offset(x: x)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Numbered, auditionable candidate markers (spec: "① 12:30 - after 4 min
/// silence"). Ease in on load; tapping the marker body selects that
/// candidate as the new selection start, tapping ▶ auditions it via a seek.
struct CandidateMarkersView: View {
    let totalDuration: TimeInterval
    let candidates: [StartCandidate]
    let selectedOffset: TimeInterval?
    let rangeStart: Date
    let onSelect: (StartCandidate) -> Void
    let onAudition: (StartCandidate) -> Void

    @State private var appeared = false

    var body: some View {
        GeometryReader { geometry in
            let duration = max(totalDuration, 1)
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                let x = CGFloat(candidate.offsetSeconds / duration) * geometry.size.width
                marker(index: index, candidate: candidate)
                    .offset(x: x - 10, y: 4)
                    .opacity(appeared ? 1 : 0)
                    .animation(MotionPrimitives.aware(MotionPrimitives.standard)?.delay(Double(index) * 0.04), value: appeared)
            }
        }
        .allowsHitTesting(true)
        .onAppear { appeared = true }
        .onChange(of: candidates.map(\.id)) { _ in
            appeared = false
            DispatchQueue.main.async { appeared = true }
        }
    }

    private func marker(index: Int, candidate: StartCandidate) -> some View {
        let isSelected = selectedOffset == candidate.offsetSeconds
        let label = candidateLabel(index: index, candidate: candidate)

        return HStack(spacing: WorklogSpacing.xs) {
            Button(action: { onAudition(candidate) }) {
                Image(systemName: "play.fill")
                    .font(.system(size: 8))
            }
            .buttonStyle(.plain)
            .focusable(true)
            .focusEffectDisabled()
            .accessibilityLabel("Audition candidate \(index + 1)")

            Button(action: { onSelect(candidate) }) {
                Text(label)
                    .font(WorklogFont.footnote)
            }
            .buttonStyle(.plain)
            .focusable(true)
            .focusEffectDisabled()
            .accessibilityLabel("Select candidate \(index + 1) as start")
        }
        .padding(.horizontal, WorklogSpacing.xs)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(isSelected ? Color.worklogAccent : Color.worklogElevatedSurface)
        )
        .overlay(Capsule().strokeBorder(Color.worklogHairline, lineWidth: isSelected ? 0 : 1))
        .foregroundStyle(isSelected ? Color.worklogOnAccent : Color.worklogTextSecondary)
    }

    private func candidateLabel(index: Int, candidate: StartCandidate) -> String {
        let circledDigits = ["①", "②", "③", "④", "⑤"]
        let marker = index < circledDigits.count ? circledDigits[index] : "(\(index + 1))"
        let time = rangeStart.addingTimeInterval(candidate.offsetSeconds)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let silenceMinutes = Int(candidate.precedingSilenceSeconds / 60)
        let silenceLabel = silenceMinutes >= 1 ? "\(silenceMinutes) min" : "\(Int(candidate.precedingSilenceSeconds))s"
        return "\(marker) \(formatter.string(from: time)) - after \(silenceLabel) silence"
    }
}
