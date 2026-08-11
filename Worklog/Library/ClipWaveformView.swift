import SwiftUI

/// A single-file seekable waveform, for the Library detail view's clip
/// player. Distinct from `Clip/WaveformView.swift`, which renders a
/// multi-segment `LoadedRange` with gaps - a Library entry's clip is
/// already one continuous exported `.m4a`, so this is the simpler
/// one-array-of-peaks case: no segment boundaries, no gaps, just a
/// playhead and click/drag-to-seek.
struct ClipWaveformView: View {
    let peaks: [Float]?
    let duration: TimeInterval
    let playheadPosition: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @State private var trackWidth: CGFloat = 1
    /// Held across the drag so the ruler knows which mark it last passed.
    @State private var scrub = ScrubHaptics()

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: WorklogRadius.md, style: .continuous)
                .fill(Color.worklogSurface)
            RoundedRectangle(cornerRadius: WorklogRadius.md, style: .continuous)
                .strokeBorder(Color.worklogHairline, lineWidth: 1)

            content

            playhead
        }
        .frame(height: 120)
        .contentShape(Rectangle())
        .background(WidthReader { trackWidth = $0 })
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let time = offset(forX: value.location.x)
                    onSeek(time)
                    // A plain click-to-seek is a drag of one event, so this
                    // gives it exactly one tick - the playhead landing -
                    // and only a real drag goes on to feel the ruler.
                    scrub.update(time: time, duration: duration, width: trackWidth)
                }
                .onEnded { _ in scrub.end() }
        )
    }

    @ViewBuilder
    private var content: some View {
        if let peaks, !peaks.isEmpty {
            Canvas { context, size in
                let midY = size.height / 2
                let pixelsPerPeak = size.width / CGFloat(peaks.count)
                // Same dynamic amplitude scale as the Clip screen's
                // `WaveformView`: normalize to this clip's loudest peak
                // (capped, so near-silence isn't amplified into a full
                // waveform) instead of assuming peaks approach 1.0.
                let maxPeak = peaks.max() ?? 0
                let amplitudeScale = maxPeak > 0 ? min(0.95 / CGFloat(maxPeak), 40) : 1
                var path = Path()
                for (i, peak) in peaks.enumerated() {
                    let x = CGFloat(i) * pixelsPerPeak
                    let barHeight = max(1, CGFloat(peak) * amplitudeScale * midY)
                    path.addRect(CGRect(x: x, y: midY - barHeight, width: max(1, pixelsPerPeak), height: barHeight * 2))
                }
                context.fill(path, with: .color(Color.worklogAccent.opacity(0.85)))
            }
            .drawingGroup()
        } else if peaks == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Computed but empty - the file couldn't be decoded (consistent
            // with `RangeLoader`'s `isUnreadable` handling for raw segments,
            // see guardrails). Show it as a real, distinct state rather than
            // a silent blank waveform.
            VStack(spacing: WorklogSpacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.worklogWarning)
                Text("Couldn't decode this clip's audio")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var playhead: some View {
        let x = duration > 0 ? CGFloat(playheadPosition / duration) * trackWidth : 0
        return Rectangle()
            .fill(Color.worklogAccent)
            .frame(width: 2, height: 120)
            .offset(x: x)
            .allowsHitTesting(false)
    }

    private func offset(forX x: CGFloat) -> TimeInterval {
        let width = max(1, trackWidth)
        return Double(x / width) * duration
    }
}

/// Reads the width of its container into a callback - same pattern as
/// `Clip/ClipScreenView.swift`'s private `WidthReader`, duplicated here
/// rather than shared since it's a two-line utility not worth threading a
/// new shared file through for.
private struct WidthReader: View {
    let onChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear { onChange(geometry.size.width) }
                .onChange(of: geometry.size.width) { onChange($0) }
        }
    }
}
