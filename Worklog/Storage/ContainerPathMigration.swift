import Foundation
import os

/// Rewrites stored file paths onto the current app container.
///
/// The database stores absolute paths - `clips.path`, `transcripts.path`,
/// every translation, summary, dictation and segment. On macOS that is safe:
/// `~/worklog` is a fixed location that never moves. On iOS it is not. The
/// app's Documents directory lives under a container whose UUID the system
/// owns, and that UUID changes - on a restore from backup, on some reinstalls,
/// and reliably between installs during development. Every path in the
/// database then points at a directory that no longer exists, and the app
/// looks like it has lost every recording it ever made while the files sit
/// intact a few directories away.
///
/// So paths are repaired at launch instead. Each stored path is split at the
/// `worklog/` root and re-anchored onto the current one; anything that already
/// resolves is left alone, and anything that resolves neither way is left
/// alone too, because a missing file is a separate problem and rewriting its
/// path would only hide it.
///
/// Storing relative paths in the first place would avoid this, but the schema
/// is shared with two other platforms and with the clip-archive format, and a
/// launch-time repair costs one query per table against a column that is
/// already indexed by rowid.
enum ContainerPathMigration {
    private static let log = Logger(subsystem: "com.rishabhrao.worklog", category: "storage")

    /// Every table with a column holding an absolute path.
    private static let pathColumns: [(table: String, column: String)] = [
        ("segments", "path"),
        ("clips", "path"),
        ("transcripts", "path"),
        ("translations", "path"),
        ("summaries", "path"),
        ("dictations", "path"),
        ("dictations", "text_path"),
        ("dictations", "raw_path"),
    ]

    static func run() {
        let root = WorklogPaths.root.path
        // The marker the split happens at. Using the folder name rather than
        // the full prefix means it works no matter how deep the container is
        // or how the previous one was laid out.
        let marker = "/worklog/"

        var repaired = 0
        for (table, column) in pathColumns {
            let rows = WorklogDatabase.shared.allPaths(table: table, column: column)
            for stored in rows {
                guard !stored.isEmpty, !stored.hasPrefix(root) else { continue }
                guard let markerRange = stored.range(of: marker, options: .backwards) else { continue }
                let suffix = String(stored[markerRange.upperBound...])
                let candidate = (root as NSString).appendingPathComponent(suffix)
                guard candidate != stored,
                      FileManager.default.fileExists(atPath: candidate) else { continue }
                WorklogDatabase.shared.rewritePath(table: table, column: column, from: stored, to: candidate)
                repaired += 1
            }
        }
        if repaired > 0 {
            log.info("container moved - repaired \(repaired, privacy: .public) stored paths")
        }
    }
}
