import Foundation

/// Settings-facing disk usage figures. Total across `~/worklog` is
/// required by spec; per-folder breakdown is the documented nice-to-have.
/// Transcripts/translations now live inside each clip's folder, so
/// `clipsBytes` covers them.
struct WorklogDiskUsage {
    let totalBytes: Int64
    let audioBytes: Int64
    let clipsBytes: Int64
}

enum WorklogDiskUsageCalculator {
    static func current() -> WorklogDiskUsage {
        let recordings = directorySize(WorklogPaths.recordingsRoot)
        let clips = directorySize(WorklogPaths.clipsRoot)
        return WorklogDiskUsage(
            totalBytes: recordings + clips,
            audioBytes: recordings,
            clipsBytes: clips
        )
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}

enum WorklogFinderReveal {
    /// The data folder is browsable in the Files app under On My iPhone ›
    /// Worklog (that is what `UIFileSharingEnabled` buys), but no API opens
    /// Files at a path, so there is nothing to reveal. Settings shows the
    /// location as text instead and this stays as the one place that knows
    /// the folder exists.
    static var browsableLocation: String { "Files › On My iPhone › Worklog" }
}
