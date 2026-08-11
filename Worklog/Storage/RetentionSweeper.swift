import Foundation

/// Deletes raw `audio/` segments older than the configured retention
/// window. **Absolute rule (spec `03-retention-and-storage.md`): this type
/// only ever touches paths returned by `WorklogDatabase.segmentPaths`,
/// which only ever queries the `segments` table - it has no path into
/// `clips/` or `transcripts/` and must never be given one.**
enum RetentionSweeper {
    /// Runs the raw-audio-only purge for the given window. Returns the
    /// number of segment files actually removed, for Settings' "purge now"
    /// action to report back (and for disk-usage to be recomputed after).
    @discardableResult
    static func purge(window: RetentionWindow) -> Int {
        guard let interval = window.timeInterval else { return 0 }
        let cutoff = Date(timeIntervalSinceNow: -interval)
        let staleSegmentPaths = WorklogDatabase.shared.segmentPaths(olderThan: cutoff)

        var removedPaths: [String] = []
        for path in staleSegmentPaths {
            let url = URL(fileURLWithPath: path)
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removedPaths.append(path)
            } else if !FileManager.default.fileExists(atPath: path) {
                // Already gone (e.g. manually removed) - still clear the
                // index row so it doesn't linger as an orphan.
                removedPaths.append(path)
            }
        }
        WorklogDatabase.shared.removeSegmentRows(paths: removedPaths)
        // Speech-preview words describe raw audio, so they share its
        // retention exactly. Database rows only - no file paths involved,
        // so the absolute file rule above is untouched.
        WorklogDatabase.shared.prunePreviewWords(olderThan: cutoff)
        pruneEmptyDayFolders()
        return removedPaths.count
    }

    /// Removes now-empty dated folders under `audio/` left behind after a
    /// purge, so `~/worklog/audio/` doesn't accumulate empty date stubs
    /// forever. Never removes `audio/` itself, and never looks outside it.
    private static func pruneEmptyDayFolders() {
        let fileManager = FileManager.default
        guard let dayFolders = try? fileManager.contentsOfDirectory(at: WorklogPaths.recordingsRoot, includingPropertiesForKeys: nil) else { return }
        for folder in dayFolders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let contents = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
            let remaining = contents.filter { $0 != "locations.json" }
            if remaining.isEmpty {
                try? fileManager.removeItem(at: folder)
            }
        }
    }

    /// Runs a purge on a repeating timer while the app is running, plus one
    /// immediate check at launch to catch time missed while quit (spec:
    /// "a periodic timer while the app is running, plus a check on launch").
    static func schedulePeriodicSweeps(interval: TimeInterval = 60 * 60) -> DispatchSourceTimer {
        purge(window: WorklogSettingsStore.load().retentionWindow)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler {
            purge(window: WorklogSettingsStore.load().retentionWindow)
        }
        timer.resume()
        return timer
    }
}
