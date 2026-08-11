import AVFoundation
import Foundation

enum ClipExportError: LocalizedError {
    case noSegments
    case exportFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noSegments:
            return "Nothing was recorded in your selection - recording was off during that time. Move the selection to a stretch that has audio."
        case .exportFailed(let error):
            return "Couldn't export the clip: \(error.localizedDescription)"
        }
    }
}

/// Cuts `[start, end]` out of a (possibly multi-segment) loaded range into a
/// single `.m4a` in `clips/`, stitching across 5-minute segment boundaries
/// when the selection spans more than one file (spec `05-clip-screen-and-
/// waveform.md`'s Transcribe action, and the export step of
/// `07-transcription-pipeline.md`). This only produces the on-disk clip
/// file; indexing it into `worklog.db` and handing off to Scribe/Hinglish is
/// Priority 5's job.
enum ClipExporter {
    /// Result of an export: the file on disk, the audio duration it
    /// actually contains - which can be shorter than the requested
    /// `[start, end]` span if some segments in that range were unreadable
    /// and got skipped (see `stitch`; callers must persist *this* duration,
    /// never `end.timeIntervalSince(start)`) - and a best-effort location.
    struct ExportResult {
        let url: URL
        let actualDurationSeconds: TimeInterval
        /// Location the clip was recorded at, taken from the first
        /// contributing raw segment that has one - `nil` if location
        /// tagging was off, permission was denied, or no segment in the
        /// range had a fix yet. Read from `worklog.db`'s `segments` table
        /// (already the queryable copy of the raw-layer location tag), not
        /// from `LocationTagger`/`SegmentLocationIndex` directly - this
        /// keeps `ClipExporter` itself with no import of the live location
        /// stack, only of already-recorded, already-decided data.
        let locationLatitude: Double?
        let locationLongitude: Double?
        /// Capture device of the first contributing segment - clips carry
        /// the same metadata shape as raw recordings.
        let deviceUID: String?
        /// Where the audio that got written sits on the requested range's
        /// wall-clock timeline. Only playback needs it.
        let timeline: ExportTimeline
    }

    /// One contiguous run of real audio, expressed both on the range's
    /// wall-clock timeline (seconds from range start) and inside the exported
    /// file. The two differ whenever the range has a hole in it.
    struct TimelineSpan {
        let rangeStart: TimeInterval
        let rangeEnd: TimeInterval
        let fileStart: TimeInterval
        let fileEnd: TimeInterval
    }

    /// Translates between the range's wall-clock timeline and positions in
    /// the exported file.
    ///
    /// Exports are compacted: a stretch where nothing was recorded takes no
    /// space in the file. That used to be papered over for playback by
    /// manufacturing real silence to fill the holes - which meant writing
    /// (and, on the Android side, encoding) minutes of nothing just so a
    /// playhead had somewhere to sit. Carrying the mapping instead keeps the
    /// playhead exactly where the waveform says it should be, for free.
    struct ExportTimeline {
        let spans: [TimelineSpan]

        var fileDuration: TimeInterval { spans.last?.fileEnd ?? 0 }

        /// Where `rangeTime` lives in the file. A time inside a hole maps to
        /// the start of the next recorded run - the audio the user was
        /// reaching for.
        func fileTime(_ rangeTime: TimeInterval) -> TimeInterval {
            guard !spans.isEmpty else { return 0 }
            for span in spans {
                if rangeTime < span.rangeStart { return span.fileStart }
                if rangeTime <= span.rangeEnd {
                    return span.fileStart + (rangeTime - span.rangeStart)
                }
            }
            return fileDuration
        }

        /// Where `fileTime` sits on the wall-clock timeline.
        func rangeTime(_ fileTime: TimeInterval) -> TimeInterval {
            guard !spans.isEmpty else { return fileTime }
            for span in spans where fileTime <= span.fileEnd {
                return span.rangeStart + max(0, fileTime - span.fileStart)
            }
            return spans.last?.rangeEnd ?? fileTime
        }

        /// Runs closer together than this are one continuous take: 5-minute
        /// segments butt up against each other with a sub-second seam.
        static let seamTolerance: TimeInterval = 1

        static func of(_ spans: [TimelineSpan]) -> ExportTimeline {
            var merged: [TimelineSpan] = []
            for span in spans where span.fileEnd > span.fileStart {
                if let last = merged.last,
                   span.rangeStart <= last.rangeEnd + seamTolerance,
                   span.fileStart <= last.fileEnd + 0.001 {
                    merged[merged.count - 1] = TimelineSpan(
                        rangeStart: last.rangeStart,
                        rangeEnd: max(last.rangeEnd, span.rangeEnd),
                        fileStart: last.fileStart,
                        fileEnd: max(last.fileEnd, span.fileEnd)
                    )
                } else {
                    merged.append(span)
                }
            }
            return ExportTimeline(spans: merged)
        }
    }

    /// Exports `[start, end]` (wall-clock) to `destination`, reading from
    /// the segment files that overlap the range (and, for location, from
    /// their already-indexed `worklog.db` rows - not from any live location
    /// API). The caller chooses the destination: real clips live at
    /// `clips/<clipID>/audio.m4a`; playback previews go to a temp file.
    ///
    /// The output is always compacted: stretches of the range where nothing
    /// was recorded take no space in the file. `ExportResult.timeline` says
    /// where the audio that was written sits on the requested range's
    /// wall-clock timeline, which is everything playback needs to keep a
    /// playhead honest without storing manufactured silence.
    static func export(start: Date, end: Date, destination: URL) throws -> ExportResult {
        // Peaks are the waveform's business, not the exporter's - asking for
        // them here makes a cold export decode every uncached segment twice.
        let range = RangeLoader.load(start: start, end: end, withPeaks: false)
        guard !range.segments.isEmpty else { throw ClipExportError.noSegments }

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let written: (seconds: TimeInterval, timeline: ExportTimeline)
        do {
            written = try stitch(range: range, to: destination)
        } catch let error as ClipExportError {
            // Keep the specific case (e.g. noSegments when every segment in
            // the selection was skipped/empty) - wrapping it in
            // .exportFailed would bury its user-facing copy.
            throw error
        } catch {
            throw ClipExportError.exportFailed(error)
        }

        let location = range.segments.lazy.compactMap { segment -> (Double, Double)? in
            guard let lat = segment.record.locationLatitude, let lon = segment.record.locationLongitude else { return nil }
            return (lat, lon)
        }.first

        return ExportResult(
            url: destination,
            actualDurationSeconds: written.seconds,
            locationLatitude: location?.0,
            locationLongitude: location?.1,
            deviceUID: range.segments.first.map(\.record.deviceUID).flatMap { $0.isEmpty ? nil : $0 },
            timeline: written.timeline
        )
    }

    /// Returns the total seconds of audio actually written - the sum of
    /// each contributing segment's written frame count, not the requested
    /// range span. Skipped (unreadable) segments simply don't add to it -
    /// alongside a timeline saying where each written run belongs in
    /// wall-clock terms.
    private static func stitch(range: LoadedRange, to destination: URL) throws -> (seconds: TimeInterval, timeline: ExportTimeline) {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        var outputFile: AVAudioFile?
        var framesWritten: Int64 = 0
        var writtenSampleRate: Double = 0
        var spans: [TimelineSpan] = []

        for segment in range.segments {
            let sourceURL = URL(fileURLWithPath: segment.record.path)
            // A segment can be indexed but still fail to open - e.g. it was
            // corrupted by an unclean shutdown mid-write, or (rarer, given
            // `RangeLoader` only surfaces genuinely-closed segments) a race
            // with an in-progress write. Skip it rather than aborting the
            // whole export: one bad 5-minute segment shouldn't make an
            // entire multi-segment range unplayable/untranscribable - but
            // see `ExportResult`: skipping a segment means the exported
            // file is shorter than the requested range, and the caller must
            // record the real duration, not the requested one.
            //
            // A real, still-open file can also transiently fail to open
            // here - the Clip screen kicks off a background preview export
            // (`ClipScreenViewModel.prepareAndStartPlayback`) that can read
            // the same source segment concurrently with a real Transcribe
            // export, and two concurrent `AVAudioFile(forReading:)` opens
            // on the identical path have been observed to intermittently
            // fail even though the file itself is completely valid (verified
            // independently via `afinfo` and a standalone decode). One retry
            // after a short delay resolves this without misreporting a fine
            // file as "unreadable audio" to the user.
            guard let sourceFile = openAudioFileWithRetry(sourceURL) else { continue }
            let format = sourceFile.processingFormat

            if outputFile == nil {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount,
                    AVEncoderBitRateKey: 64_000,
                ]
                outputFile = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                writtenSampleRate = format.sampleRate
            }

            // Trim the segment to only the portion inside [start, end]:
            // segment.rangeOffset is where this file begins relative to the
            // requested range start, so a range that begins mid-segment (the
            // common case) skips the leading frames that fall before it.
            let segmentRangeStart = max(0, -segment.rangeOffset)
            let segmentRangeEnd = min(segment.duration, range.totalDuration - segment.rangeOffset)
            guard segmentRangeEnd > segmentRangeStart else { continue }

            let startFrame = AVAudioFramePosition(segmentRangeStart * format.sampleRate)
            let requestedFrameCount = AVAudioFrameCount((segmentRangeEnd - segmentRangeStart) * format.sampleRate)
            guard requestedFrameCount > 0 else { continue }
            // Sub-second rounding in the Date-based trim math above can ask
            // for a few more frames than the file actually has left past
            // startFrame - AVAudioFile.read(into:frameCount:) doesn't throw
            // in that case, it just silently returns fewer frames than
            // requested, which is fine and already handled by using
            // buffer.frameLength (not frameCount) below. Clamping here just
            // avoids over-allocating a buffer for frames that can't exist.
            let framesRemainingInFile = max(0, sourceFile.length - Int64(startFrame))
            let frameCount = min(requestedFrameCount, AVAudioFrameCount(framesRemainingInFile))
            guard frameCount > 0 else { continue }

            // Where this segment's contribution begins, in the file and on
            // the range's timeline. The audio taken starts at
            // rangeOffset + segmentRangeStart, and segmentRangeStart is
            // max(0, -rangeOffset) - which is exactly max(0, rangeOffset).
            let spanFileStart = writtenSampleRate > 0 ? Double(framesWritten) / writtenSampleRate : 0
            let spanRangeStart = max(0, segment.rangeOffset)

            sourceFile.framePosition = startFrame
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { continue }
            try sourceFile.read(into: buffer, frameCount: frameCount)

            // Segments can carry different stream formats (a Bluetooth
            // route change mid-recording re-clocks the mic, and capture
            // adapts) - convert to the output's format when they differ
            // instead of failing the whole export.
            if let outputFile, outputFile.processingFormat.sampleRate == format.sampleRate,
               outputFile.processingFormat.channelCount == format.channelCount {
                try outputFile.write(from: buffer)
                framesWritten += Int64(buffer.frameLength)
            } else if let outputFile {
                let outFormat = outputFile.processingFormat
                guard let converter = AVAudioConverter(from: format, to: outFormat) else { continue }
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * outFormat.sampleRate / format.sampleRate) + 1024
                guard let converted = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { continue }
                var served = false
                var conversionError: NSError?
                converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                    if served {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    served = true
                    inputStatus.pointee = .haveData
                    return buffer
                }
                if conversionError == nil, converted.frameLength > 0 {
                    try outputFile.write(from: converted)
                    framesWritten += Int64(converted.frameLength)
                }
            }
            let spanFileEnd = writtenSampleRate > 0 ? Double(framesWritten) / writtenSampleRate : 0
            if spanFileEnd > spanFileStart {
                spans.append(TimelineSpan(
                    rangeStart: spanRangeStart,
                    rangeEnd: spanRangeStart + (spanFileEnd - spanFileStart),
                    fileStart: spanFileStart,
                    fileEnd: spanFileEnd
                ))
            }
        }

        guard outputFile != nil else { throw ClipExportError.noSegments }

        return (
            seconds: writtenSampleRate > 0 ? Double(framesWritten) / writtenSampleRate : 0,
            timeline: ExportTimeline.of(spans)
        )
    }

    /// `AVAudioFile(forReading:)` can transiently fail against a completely
    /// valid, already-closed file when another `AVAudioFile` instance is
    /// concurrently reading the same path (see call site) - one short retry
    /// distinguishes that from a genuinely unreadable/corrupted file.
    private static func openAudioFileWithRetry(_ url: URL, attempts: Int = 3) -> AVAudioFile? {
        for attempt in 0..<attempts {
            if let file = try? AVAudioFile(forReading: url) {
                return file
            }
            if attempt < attempts - 1 {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return nil
    }
}
