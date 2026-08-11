import Foundation

/// A suggested clip start point: a moment where talking picks up after a
/// lull, ranked by how good a place it is to begin. Purely a suggestion -
/// `CandidateDetector` never decides anything on the user's behalf.
struct StartCandidate: Identifiable {
    var id: TimeInterval { offsetSeconds }
    /// Seconds since range start where speech begins.
    let offsetSeconds: TimeInterval
    /// How long the quiet immediately before this point lasted.
    let precedingSilenceSeconds: TimeInterval
}

/// Adjustable parameters for candidate detection, exposed on the Clip
/// screen's disclosure section (not Settings - these are per-session tuning,
/// not persistent app config).
struct CandidateDetectionParameters {
    /// How eager the detector is to call a dip in level a pause, 0 to 1.
    ///
    /// Deliberately not an absolute amplitude. The level that means "quiet"
    /// depends entirely on the recording: a laptop mic in a meeting room has
    /// a noise floor that would read as loud speech on a headset in a quiet
    /// office. This picks a line between the two levels the audio itself
    /// exhibits, so the same setting behaves the same way on both.
    var sensitivity: Float = 0.5
    /// Minimum quiet duration (seconds) before a following speech onset
    /// counts as a candidate at all - filters out normal pauses between words.
    var minimumSilenceDuration: TimeInterval = 2.0
    /// How many ranked candidates to surface (spec: "top ~3-5").
    var maxCandidates: Int = 5

    static let `default` = CandidateDetectionParameters()
}

/// Finds places in a range where a conversation picks up again after a lull.
///
/// The previous version compared the envelope against a fixed amplitude and
/// ranked purely by how long the preceding silence was. Both were wrong in
/// the same way - they assumed things about the recording that aren't true.
///
/// Measured against a real hour of meeting audio: the room's noise floor sat
/// at 0.022, *above* the fixed 0.02 threshold, so 94% of the hour registered
/// as continuous speech. The handful of dips that did fall below all happened
/// within a couple of minutes of each other, and ranking by silence length
/// then picked those and nothing else - four suggestions inside the same
/// ninety seconds, 80% of the way through an hour, for audio that had people
/// talking throughout.
///
/// What replaces it:
///
///  - The quiet line is derived from the audio's own levels, so it works the
///    same on a loud recording and a quiet one (verified: scaling that same
///    hour down tenfold produces identical suggestions).
///  - An onset has to be sustained to count, so one cough no longer reads as
///    a conversation starting, and one cough in the middle of a long silence
///    no longer splits it into two unremarkable ones.
///  - Suggestions are spread across the range rather than clustered, because
///    five markers within a minute of each other are worth one marker.
///
/// Deliberately identical to the Android implementation, down to the
/// constants - the same range must produce the same suggestions on both.
enum CandidateDetector {
    /// Speech must hold above the line this long for an onset to count.
    private static let sustainSeconds: Double = 0.5

    /// How much of the audio after an onset judges how promising it is.
    private static let lookaheadSeconds: Double = 8

    /// Quiet longer than this is no more meaningful than exactly this.
    private static let silenceScoreCap: Double = 60

    /// Below this ratio between the loud and quiet levels there is nothing
    /// here but room tone, and no honest start point to offer.
    private static let minimumDynamicRange: Float = 2

    /// One detected onset, before ranking.
    private struct Onset {
        let offsetSeconds: TimeInterval
        let precedingSilenceSeconds: TimeInterval
        /// Mean level over the audio just after the onset - how much is
        /// actually being said here.
        let strength: Float
    }

    /// Flattens a `LoadedRange`'s per-segment peaks into one envelope over
    /// the full range, preserving gaps as silence (a gap - pinned device
    /// disconnected, or simply no recording - should never itself look like
    /// a false "speech" candidate, but the silence before the next real
    /// segment still counts toward preceding-silence length).
    private static func flattenEnvelope(_ range: LoadedRange, peaksPerSecond: Double) -> [Float] {
        guard !range.segments.isEmpty else { return [] }
        let totalWindows = Int(range.totalDuration * peaksPerSecond)
        guard totalWindows > 0 else { return [] }
        var envelope = [Float](repeating: 0, count: totalWindows)

        for segment in range.segments {
            guard segment.peaksPerSecond > 0, !segment.peaks.isEmpty else { continue }
            let startWindow = Int(segment.rangeOffset * peaksPerSecond)
            for (i, value) in segment.peaks.enumerated() {
                // Segment peaks may be at a different resolution than the
                // requested envelope resolution if a future writer changes
                // `PeakComputer.peaksPerSecond` - reproject by time, not index.
                let sampleTime = Double(i) / segment.peaksPerSecond
                let windowIndex = startWindow + Int(sampleTime * peaksPerSecond)
                guard windowIndex >= 0, windowIndex < envelope.count else { continue }
                envelope[windowIndex] = max(envelope[windowIndex], value)
            }
        }
        return envelope
    }

    /// Ranked candidates for `range`, ordered by time.
    static func detectCandidates(in range: LoadedRange, parameters: CandidateDetectionParameters = .default) -> [StartCandidate] {
        let resolution = PeakComputer.peaksPerSecond
        let envelope = flattenEnvelope(range, peaksPerSecond: resolution)
        guard !envelope.isEmpty else { return [] }
        let totalSeconds = Double(envelope.count) / resolution

        let sorted = envelope.sorted()
        func percentile(_ fraction: Double) -> Float {
            sorted[min(max(Int(Double(sorted.count) * fraction), 0), sorted.count - 1)]
        }

        // The quiet level and the talking level, as this recording actually
        // exhibits them.
        let quietLevel = percentile(0.10)
        let loudLevel = percentile(0.90)
        guard loudLevel >= quietLevel * minimumDynamicRange else { return [] }

        let sensitivity = min(max(parameters.sensitivity, 0), 1)
        let threshold = quietLevel + (0.05 + 0.20 * sensitivity) * (loudLevel - quietLevel)

        let sustainWindows = max(1, Int(Self.sustainSeconds * resolution))
        let lookaheadWindows = max(1, Int(Self.lookaheadSeconds * resolution))
        // A start point in the last stretch of the range can't begin a clip
        // worth making - there's nothing after it.
        let lastUsableWindow = envelope.count - Int(min(60, totalSeconds * 0.05) * resolution)

        var onsets: [Onset] = []
        var quietRun = 0
        var index = 0
        while index < envelope.count {
            if envelope[index] < threshold {
                quietRun += 1
                index += 1
                continue
            }

            // Speech has to hold, or it was a cough rather than a sentence.
            var held = 0
            var probe = index
            while probe < envelope.count, held < sustainWindows, envelope[probe] >= threshold {
                held += 1
                probe += 1
            }

            if held >= sustainWindows {
                if Double(quietRun) / resolution >= parameters.minimumSilenceDuration, index < lastUsableWindow {
                    var total: Float = 0
                    var counted = 0
                    var ahead = index
                    while ahead < envelope.count, counted < lookaheadWindows {
                        total += envelope[ahead]
                        counted += 1
                        ahead += 1
                    }
                    onsets.append(Onset(
                        offsetSeconds: Double(index) / resolution,
                        precedingSilenceSeconds: Double(quietRun) / resolution,
                        strength: counted > 0 ? total / Float(counted) : 0
                    ))
                }
                quietRun = 0
                // Skip past this burst - its interior isn't a start point.
                while index < envelope.count, envelope[index] >= threshold { index += 1 }
            } else {
                // A blip inside quiet: it doesn't end the silence.
                quietRun += held
                index = probe + 1
            }
        }
        guard !onsets.isEmpty else { return [] }

        let loudestOnset = max(onsets.map(\.strength).max() ?? 1, .leastNonzeroMagnitude)
        let ranked = onsets.sorted { first, second in
            func score(_ onset: Onset) -> Double {
                // A long lull before it, and real talking after it.
                0.6 * min(onset.precedingSilenceSeconds, Self.silenceScoreCap) / Self.silenceScoreCap
                    + 0.4 * Double(onset.strength / loudestOnset)
            }
            return score(first) > score(second)
        }

        // Spread them out: five markers inside one minute are worth one.
        let spacing = max(30, totalSeconds / (Double(parameters.maxCandidates) * 1.6))
        var chosen: [Onset] = []
        for onset in ranked {
            if !chosen.contains(where: { abs($0.offsetSeconds - onset.offsetSeconds) < spacing }) {
                chosen.append(onset)
                if chosen.count == parameters.maxCandidates { break }
            }
        }

        return chosen
            .sorted { $0.offsetSeconds < $1.offsetSeconds }
            .map { StartCandidate(offsetSeconds: $0.offsetSeconds, precedingSilenceSeconds: $0.precedingSilenceSeconds) }
    }
}
