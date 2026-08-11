import Foundation

/// One physical segment file contributing to a loaded virtual range, along
/// with where it sits on the range's continuous timeline. `rangeOffset` is
/// the segment's start time expressed as seconds-from-range-start, so the
/// waveform/selection code can work entirely in "seconds since range start"
/// without ever re-deriving wall-clock alignment per segment.
struct LoadedSegment {
    let record: SegmentRecord
    let rangeOffset: TimeInterval
    let duration: TimeInterval
    let peaksPerSecond: Double
    let peaks: [Float]
    /// True if the underlying file could not be decoded at all (e.g.
    /// corrupted by an unclean shutdown mid-write). Distinct from "peaks not
    /// computed yet" - an unreadable segment will never successfully compute
    /// peaks no matter how many times it's retried, so `isFullyPeaked` must
    /// not wait on it forever. It still occupies real time on the timeline
    /// (real audio was recorded, it just can't be decoded back), so it stays
    /// in `segments` rather than being dropped, and renders as a flat/empty
    /// region instead of a real waveform.
    let isUnreadable: Bool
}

/// A virtually-stitched continuous range assembled from one or more 5-minute
/// segment files - the mechanism behind "time-travel" (spec: present a
/// single continuous waveform/timeline even though the underlying data is N
/// separate files). Gaps between segments (e.g. the pinned device was
/// disconnected, or recording was off) are preserved as real gaps in the
/// timeline rather than silently compressed out, so the displayed duration
/// always matches true wall-clock span.
struct LoadedRange {
    let requestedStart: Date
    let requestedEnd: Date
    let segments: [LoadedSegment]

    /// Total wall-clock span of the request, in seconds - the waveform's
    /// horizontal axis is always this, not the sum of segment durations, so
    /// gaps read as silence rather than vanishing.
    var totalDuration: TimeInterval {
        requestedEnd.timeIntervalSince(requestedStart)
    }

    var isEmpty: Bool { segments.isEmpty }

    /// The stretches of the timeline that actually have audio behind them, in
    /// seconds from range start, merged and in order.
    ///
    /// Leading and trailing gaps are already gone - the range is trimmed to
    /// its recorded extent when it loads - so this is only ever more than one
    /// span when recording stopped and restarted inside the range. The Clip
    /// screen uses it to keep the playhead out of those holes: scrubbing into
    /// a stretch that was never recorded has nothing to play.
    var recordedSpans: [ClosedRange<TimeInterval>] {
        var merged: [ClosedRange<TimeInterval>] = []
        for segment in segments.sorted(by: { $0.rangeOffset < $1.rangeOffset }) {
            let from = min(max(segment.rangeOffset, 0), totalDuration)
            let to = min(max(segment.rangeOffset + segment.duration, 0), totalDuration)
            guard to > from else { continue }
            // Segments butt up against each other on a continuous recording;
            // a sub-second seam between two files is not a gap the user has
            // any business being bounced out of.
            if let last = merged.last, from <= last.upperBound + Self.seamTolerance {
                if to > last.upperBound {
                    merged[merged.count - 1] = last.lowerBound...to
                }
            } else {
                merged.append(from...to)
            }
        }
        return merged
    }

    /// `offset` if it lands on recorded audio, otherwise the nearest edge of
    /// a recorded span - the boundary the user was reaching for when they
    /// dropped the playhead into a hole.
    func nearestRecordedOffset(_ offset: TimeInterval) -> TimeInterval {
        let spans = recordedSpans
        guard !spans.isEmpty else { return offset }
        if spans.contains(where: { $0.contains(offset) }) { return offset }
        let edges = spans.flatMap { [$0.lowerBound, $0.upperBound] }
        return edges.min(by: { abs($0 - offset) < abs($1 - offset) }) ?? offset
    }

    private static let seamTolerance: TimeInterval = 1

    /// Whether every contributing segment either has cached peaks or is
    /// known-unreadable (and therefore will never get peaks, no matter how
    /// many times it's retried). When false, the Clip screen shows the
    /// loading state (spec: "peaks still computing for a freshly loaded
    /// historical range") for the segments still missing them, rather than
    /// blocking the whole range on the slowest one - or, before this
    /// distinction existed, hanging forever on a segment that was corrupt
    /// rather than merely uncached.
    var isFullyPeaked: Bool {
        !segments.isEmpty && segments.allSatisfy { !$0.peaks.isEmpty || $0.isUnreadable }
    }
}

/// Resolves a requested `[start, end]` wall-clock range into the on-disk
/// segments that overlap it, reading (or synchronously computing, as a
/// fallback) each segment's peak data. Pure data-layer logic - no SwiftUI
/// dependency - so it's independently testable and reusable from Library's
/// re-clip flow (`06-library.md`).
enum RangeLoader {
    /// Loads a range synchronously. Called from a background queue by the
    /// view model; never call this from the main thread with a large
    /// historical range, since a cold peak-computation fallback decodes
    /// audio.
    ///
    /// `withPeaks: false` skips waveform data entirely, including the
    /// cold-path computation that decodes a segment in full to produce it.
    /// The exporter wants the segment layout and nothing else - making it pay
    /// to decode every uncached segment just to draw a waveform nobody asks
    /// for was most of the cost of exporting a long clip.
    static func load(start: Date, end: Date, withPeaks: Bool = true) -> LoadedRange {
        let records = WorklogDatabase.shared.segments(overlapping: start, end)
        let segments: [LoadedSegment] = records.compactMap { record in
            let url = URL(fileURLWithPath: record.path)
            guard FileManager.default.fileExists(atPath: record.path) else { return nil }

            // A segment still being actively written (no ended_at yet) is
            // real audio, not a gap - per explicit user request, a range
            // that runs right up to "now" (the most common case: clipping
            // something that just happened) must include it. Its waveform
            // comes from LivePeakStore - peaks fed straight from the audio
            // tap - because the on-disk file cannot be used for this: the
            // writer only updates the file's header occasionally, so a
            // fresh AVAudioFile read reports a frozen length no matter how
            // much audio has actually landed since (verified empirically).
            let isStillOpen = record.endedAt == nil
            let liveSnapshot = isStillOpen ? LivePeakStore.shared.snapshot(forPath: record.path) : nil

            let endedAt: Date
            if let recordEndedAt = record.endedAt {
                endedAt = recordEndedAt
            } else if let liveSnapshot {
                endedAt = record.startedAt.addingTimeInterval(liveSnapshot.duration)
            } else if let liveDuration = AudioFileDuration.current(for: url) {
                // Open segment but no live store (e.g. it was left open by
                // a previous process instance that died) - fall back to
                // whatever the file's header exposes.
                endedAt = record.startedAt.addingTimeInterval(liveDuration)
            } else {
                // Still open but nothing readable yet (just created) -
                // nothing to contribute yet; it'll show up next load.
                return nil
            }

            var peaksPerSecond = PeakComputer.peaksPerSecond
            var peaks: [Float]
            var isUnreadable = false
            if !withPeaks {
                peaks = []
            } else if let liveSnapshot {
                peaksPerSecond = liveSnapshot.peaksPerSecond
                peaks = liveSnapshot.peaks
            } else if !isStillOpen, let cached = WorklogDatabase.shared.segmentPeaks(segmentPath: record.path) {
                peaksPerSecond = cached.peaksPerSecond
                peaks = cached.peaks
            } else {
                // Cold-path fallback: a segment written before peak-caching
                // existed, or recovered by startup reconciliation with no
                // writer-side hook. Compute once now and persist so every
                // subsequent load of this range is cache-only. A still-open
                // segment (without live peaks) is never persisted to the
                // cache - it's growing, so a cached peak set would be
                // permanently wrong once the segment finalizes.
                peaks = PeakComputer.computePeaks(for: url)
                if !peaks.isEmpty {
                    if !isStillOpen {
                        WorklogDatabase.shared.storeSegmentPeaks(segmentPath: record.path, peaksPerSecond: peaksPerSecond, peaks: peaks)
                    }
                } else if !isStillOpen {
                    // Empty peaks with no cache entry means the decode
                    // itself failed (a genuinely silent/empty recording
                    // would still produce near-zero, non-empty peak
                    // windows) - mark unreadable so `isFullyPeaked` doesn't
                    // wait forever on a segment that will never succeed.
                    // Not applied to a still-open segment: it may simply
                    // have zero flushed frames yet, not be corrupted.
                    isUnreadable = true
                }
            }

            return LoadedSegment(
                record: record,
                rangeOffset: record.startedAt.timeIntervalSince(start),
                duration: endedAt.timeIntervalSince(record.startedAt),
                peaksPerSecond: peaksPerSecond,
                peaks: peaks,
                isUnreadable: isUnreadable
            )
        }

        return trimmedToRecordedExtent(start: start, end: end, segments: segments.sorted { $0.rangeOffset < $1.rangeOffset })
    }

    /// Narrows `[start, end]` to the stretch that actually contains audio.
    ///
    /// "Last 30 minutes" is a question about the clock, not about the
    /// recording - ask it after five minutes of recording and 25 of those
    /// minutes never existed. Showing them anyway gives a timeline that is
    /// mostly empty, a selection that defaults to mostly nothing, and a
    /// preview that has to account for 25 minutes with nothing in them.
    /// Trimming makes the range mean "the recording inside the last 30
    /// minutes."
    ///
    /// Only the ends are trimmed. A gap in the middle stays where it is, so
    /// the timeline still maps to wall-clock time and two recordings an hour
    /// apart don't get spliced into one continuous-looking take.
    private static func trimmedToRecordedExtent(start: Date, end: Date, segments: [LoadedSegment]) -> LoadedRange {
        guard !segments.isEmpty else {
            return LoadedRange(requestedStart: start, requestedEnd: end, segments: segments)
        }
        let windowDuration = end.timeIntervalSince(start)
        // A segment that began before the window still covers its very start,
        // so a negative offset means there is nothing to trim off the front.
        let firstOffset = min(max(segments.map(\.rangeOffset).min() ?? 0, 0), windowDuration)
        let lastOffset = min(max(segments.map { $0.rangeOffset + $0.duration }.max() ?? 0, 0), windowDuration)
        guard lastOffset > firstOffset else {
            return LoadedRange(requestedStart: start, requestedEnd: end, segments: segments)
        }

        return LoadedRange(
            requestedStart: start.addingTimeInterval(firstOffset),
            requestedEnd: start.addingTimeInterval(lastOffset),
            // Offsets are relative to range start, which just moved.
            segments: segments.map { segment in
                LoadedSegment(
                    record: segment.record,
                    rangeOffset: segment.rangeOffset - firstOffset,
                    duration: segment.duration,
                    peaksPerSecond: segment.peaksPerSecond,
                    peaks: segment.peaks,
                    isUnreadable: segment.isUnreadable
                )
            }
        )
    }

    /// Convenience for the "last N minutes" presets/free-form field: builds
    /// `[now - minutes, now]` and loads it.
    static func loadLastMinutes(_ minutes: Double) -> LoadedRange {
        let end = Date()
        let start = end.addingTimeInterval(-minutes * 60)
        return load(start: start, end: end)
    }
}
