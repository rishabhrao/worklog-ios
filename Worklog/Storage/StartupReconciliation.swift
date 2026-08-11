import AVFoundation
import Combine
import Foundation

/// Reconciles `worklog.db`'s `segments` table against what's actually on
/// disk under `audio/`, per the spec's acceptance criterion: "index
/// survives app restarts and correctly reflects existing on-disk state (no
/// orphaned rows for deleted segments, no missing rows for existing ones)."
///
/// Drift is possible because segment files can be removed outside the app's
/// own purge path (e.g. the user deletes a day folder in Finder), and
/// because `RecordingSession` only calls `recordSegmentClosed` for segments
/// closed while the app is running - a segment left on disk from a build
/// that predates this reconciliation pass (or any other gap) would
/// otherwise never get an index row.
enum StartupReconciliation {
    /// Fires on the main actor every time `run()` completes - the live-
    /// update hook other view models subscribe to so a newly-indexed
    /// segment (recovered by the periodic timer, not by
    /// `RecordingSession`'s own live indexing) reaches an already-open
    /// screen automatically instead of needing a manual refresh or a
    /// screen switch to re-query. Per explicit user request: the app
    /// should be "in live state... event-driven," not require a manual
    /// hack to see fresh data.
    static let didRun = PassthroughSubject<Void, Never>()

    /// Can be called from a background task (`ClipScreenViewModel.refresh()`
    /// dispatches it off the main actor) as well as the main-queue periodic
    /// timer and `AppDelegate`'s launch-time call - `didRun.send()` always
    /// hops to main so subscribers (SwiftUI-observed view models) never
    /// receive it off the main actor.
    static func run() {
        removeOrphanedRows()
        addMissingRows()
        closeOrphanedOpenRows()
        repairClipLocations()
        repairClipDurations()
        backfillTranscriptionCosts()
        DispatchQueue.main.async { didRun.send() }
    }

    /// Prices transcriptions that already succeeded before cost tracking
    /// existed, so the feature is useful on day one instead of only for
    /// whatever you happen to record next.
    ///
    /// Speech-to-text is priced purely on audio duration, so an old row can
    /// be costed exactly as accurately as a new one - the only thing missing
    /// is ElevenLabs' own reported duration, so the stored clip/dictation
    /// length stands in. LLM steps are deliberately *not* backfilled: their
    /// price depends on token counts nobody recorded at the time, and
    /// inventing a number for them would be worse than showing none.
    private static func backfillTranscriptionCosts() {
        for clip in WorklogDatabase.shared.allClips() {
            guard let transcript = WorklogDatabase.shared.transcript(clipID: clip.id),
                  transcript.state == .succeeded,
                  transcript.cost.usd == nil,
                  let usd = Pricing.transcriptionCostUSD(model: transcript.model, seconds: clip.durationSeconds)
            else { continue }
            WorklogDatabase.shared.updateCost(table: "transcripts", id: transcript.id, cost: CostRecord(
                usd: usd,
                source: .estimated,
                billedSeconds: clip.durationSeconds
            ))
        }

        for dictation in WorklogDatabase.shared.allDictations() {
            guard dictation.state == .succeeded,
                  dictation.cost.usd == nil,
                  let usd = Pricing.transcriptionCostUSD(model: dictation.model, seconds: dictation.durationSeconds)
            else { continue }
            WorklogDatabase.shared.updateCost(table: "dictations", id: dictation.id, cost: CostRecord(
                usd: usd,
                source: .estimated,
                billedSeconds: dictation.durationSeconds
            ))
        }
    }

    /// Clips exported while their source segments' rows were missing
    /// location got none - re-derive it the same way ClipExporter does
    /// (first contributing segment with a tag). Location now lands on
    /// segment rows directly at close time (no sidecar), so this only
    /// repairs older clips.
    private static func repairClipLocations() {
        for clip in WorklogDatabase.shared.allClips() where clip.locationLatitude == nil {
            let segments = WorklogDatabase.shared.segments(overlapping: clip.sourceStart, clip.sourceEnd)
            guard let location = segments.lazy.compactMap({ segment -> (Double, Double)? in
                guard let lat = segment.locationLatitude, let lon = segment.locationLongitude else { return nil }
                return (lat, lon)
            }).first else { continue }
            WorklogDatabase.shared.updateClipLocation(id: clip.id, latitude: location.0, longitude: location.1)
        }
    }

    /// Rows still marked open (`ended_at IS NULL`) whose file is NOT the
    /// one actively recording right now are orphans: the segment's close-
    /// write is dispatched to the main queue, so an app quit (or crash) can
    /// finalize the file on disk but lose the DB update - leaving a row
    /// that claims to be "still recording" forever. Such phantom-open rows
    /// poison every range that touches them (their duration reads resolve
    /// against a stale header and misreport how much audio exists - seen
    /// live as "0:20 of your selection wasn't available" on a selection
    /// that visibly had audio). Close them from the file's real readable
    /// duration; if the file can't be read at all (crash mid-write, no
    /// finalized header), drop the row per the "never index unreadable
    /// audio" guardrail - `addMissingRows` re-indexes it automatically if
    /// it ever becomes readable.
    private static func closeOrphanedOpenRows() {
        let activePath = LivePeakStore.shared.currentActivePath
        for path in WorklogDatabase.shared.openSegmentPaths() where path != activePath {
            guard FileManager.default.fileExists(atPath: path) else {
                WorklogDatabase.shared.removeSegmentRows(paths: [path])
                continue
            }
            if let duration = AudioFileDuration.current(for: URL(fileURLWithPath: path)) {
                WorklogDatabase.shared.closeOrphanedSegmentRow(path: path, durationSeconds: duration)
            } else {
                WorklogDatabase.shared.removeSegmentRows(paths: [path])
            }
        }
    }

    /// Runs reconciliation on a repeating timer while the app is running, in
    /// addition to the one-time launch call in `AppDelegate`. Without this,
    /// a segment file that lands on disk from a source `run()` doesn't see
    /// (e.g. it finished closing in a process instance that was already
    /// running before that segment existed - normal live recording indexes
    /// itself immediately via `RecordingSession.handleSegmentClosed` and
    /// doesn't depend on this timer) stays invisible to the Clip screen's
    /// range queries until the next full app relaunch. A manual "Refresh"
    /// action (Clip screen) also calls `run()` directly for the "I need this
    /// now" case.
    static func schedulePeriodicReconciliation(interval: TimeInterval = 5 * 60) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler {
            run()
        }
        timer.resume()
        return timer
    }

    /// Rows whose file no longer exists on disk - drop them.
    private static func removeOrphanedRows() {
        let indexedPaths = WorklogDatabase.shared.allSegmentPaths()
        let orphaned = indexedPaths.filter { !FileManager.default.fileExists(atPath: $0) }
        WorklogDatabase.shared.removeSegmentRows(paths: orphaned)
    }

    /// Files on disk with no matching row - add one so retention and
    /// historical lookup can see them. Metadata is inferred from the
    /// filename (day folder + `HHmm_ss.m4a`), matching `WorklogPaths`'
    /// own naming scheme.
    private static func addMissingRows() {
        let fileManager = FileManager.default
        guard let dayFolders = try? fileManager.contentsOfDirectory(at: WorklogPaths.recordingsRoot, includingPropertiesForKeys: nil) else { return }

        let indexed = Set(WorklogDatabase.shared.allSegmentPaths())
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = .current
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "yyyy-MM-dd HHmm_ss"
        timeFormatter.timeZone = .current

        for dayFolder in dayFolders {
            guard (try? dayFolder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let segmentFiles = try? fileManager.contentsOfDirectory(at: dayFolder, includingPropertiesForKeys: nil) else { continue }

            for file in segmentFiles where file.pathExtension == "m4a" {
                guard !indexed.contains(file.path) else { continue }
                let dayName = dayFolder.lastPathComponent
                let stem = file.deletingPathExtension().lastPathComponent
                guard let startedAt = timeFormatter.date(from: "\(dayName) \(stem)") else { continue }

                // Read the file's true duration rather than defaulting
                // ended_at to startedAt - a zero-duration row would make the
                // Clip screen's range loader (Priority 4) silently skip a
                // recovered segment's audio entirely.
                //
                // If the file can't be opened at all, do NOT index it with a
                // fake duration - that poisons every future range/peak/
                // export/playback attempt that touches it (found via a real
                // corrupted segment: it got a zero-duration row, then every
                // subsequent read attempt failed identically, forever). Two
                // legitimate reasons a read can fail here: (1) this is the
                // segment currently being written to - it has no finalized
                // header yet and will become readable once it rolls over, so
                // skipping it now is correct, it'll be picked up on a later
                // reconciliation pass once `RecordingSession` closes it and
                // indexes it live; (2) the file is genuinely corrupt (e.g.
                // the writing process was killed mid-segment with no clean
                // close) - also correctly skipped, since there's nothing
                // useful this pass can do with unreadable audio.
                guard let audioFile = try? AVAudioFile(forReading: file) else { continue }
                let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
                let endedAt = startedAt.addingTimeInterval(duration)
                WorklogDatabase.shared.recordUnindexedSegmentFound(path: file, startedAt: startedAt, endedAt: endedAt)
            }
        }
    }

    /// One-time repair for clips exported before `ClipExporter` started
    /// returning the audio it actually wrote instead of the requested
    /// selection length: if some segments in the selection were unreadable,
    /// the exported file could be materially shorter than the stored
    /// `duration_seconds`, and playback/waveform code would trust the wrong
    /// number. Cheap to run every launch - `afinfo`-style duration reads on
    /// a handful of short clip files, not the whole `audio/` tree - and
    /// self-limiting: once a clip's stored duration matches its real file,
    /// this is a no-op for it on every subsequent run.
    private static func repairClipDurations() {
        for clip in WorklogDatabase.shared.allClips() {
            guard let audioFile = try? AVAudioFile(forReading: URL(fileURLWithPath: clip.path)) else { continue }
            let actualDuration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            guard abs(actualDuration - clip.durationSeconds) > 1 else { continue }
            WorklogDatabase.shared.updateClipDuration(id: clip.id, durationSeconds: actualDuration)
        }
    }
}
