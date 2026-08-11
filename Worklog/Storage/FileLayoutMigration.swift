import Foundation

/// One-time, idempotent moves from the legacy on-disk layout to the current
/// one, run at every launch before reconciliation (each step no-ops once
/// its work is done):
///
/// - `audio/` → `recordings/` (folder rename + DB path rewrite)
/// - per-day `locations.json` sidecars → segment rows, then deleted
/// - `recording-state.json` / `settings.json` sidecars → `app_state`
///   key-value rows, then deleted
/// - flat `clips/<name>.m4a` + `transcripts/<id>.*` files → per-clip
///   folders `clips/<clipID>/{audio.m4a, transcript.json,
///   translation-<language>.md}` (files moved + DB paths updated)
///
/// All per explicit user request: one database as the single source of
/// truth (no sidecar JSON files), and every clip's artifacts grouped in
/// its own folder.
enum FileLayoutMigration {
    static func run() {
        migrateAudioFolderToRecordings()
        importLocationSidecars()
        importAppStateSidecars()
        migrateClipsIntoPerClipFolders()
        removeLegacyTranscriptsFolderIfEmpty()
    }

    // MARK: audio/ → recordings/

    private static func migrateAudioFolderToRecordings() {
        let fileManager = FileManager.default
        let legacy = WorklogPaths.legacyAudioRoot
        let current = WorklogPaths.recordingsRoot
        guard fileManager.fileExists(atPath: legacy.path) else { return }

        if !fileManager.fileExists(atPath: current.path) {
            try? fileManager.moveItem(at: legacy, to: current)
        } else {
            // Both exist (interrupted earlier migration): move children
            // across, then drop the legacy folder.
            if let children = try? fileManager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) {
                for child in children {
                    try? fileManager.moveItem(at: child, to: current.appendingPathComponent(child.lastPathComponent))
                }
            }
            try? fileManager.removeItem(at: legacy)
        }

        WorklogDatabase.shared.migratePathPrefix(from: legacy.path, to: current.path)
    }

    // MARK: locations.json sidecars → segment rows

    private static func importLocationSidecars() {
        let fileManager = FileManager.default
        guard let dayFolders = try? fileManager.contentsOfDirectory(at: WorklogPaths.recordingsRoot, includingPropertiesForKeys: nil) else { return }
        for dayFolder in dayFolders {
            guard (try? dayFolder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let indexURL = dayFolder.appendingPathComponent("locations.json")
            guard let data = try? Data(contentsOf: indexURL),
                  let index = try? JSONDecoder().decode([String: SegmentLocationTag].self, from: data) else { continue }
            for (fileName, tag) in index {
                let path = dayFolder.appendingPathComponent(fileName).path
                WorklogDatabase.shared.updateSegmentLocationIfMissing(path: path, latitude: tag.latitude, longitude: tag.longitude)
            }
            try? fileManager.removeItem(at: indexURL)
        }
    }

    // MARK: recording-state.json / settings.json → app_state rows

    private static func importAppStateSidecars() {
        importSidecar(fileName: "recording-state.json", appStateKey: "recording-state")
        importSidecar(fileName: "settings.json", appStateKey: "settings")
    }

    private static func importSidecar(fileName: String, appStateKey: String) {
        let url = WorklogPaths.root.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let json = String(data: data, encoding: .utf8) else { return }
        // The file only wins if the DB has nothing yet - once the app has
        // written newer state to the DB, a stale leftover file must never
        // clobber it.
        if WorklogDatabase.shared.appStateValue(forKey: appStateKey) == nil {
            WorklogDatabase.shared.setAppStateValue(json, forKey: appStateKey)
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: flat clip/transcript files → clips/<clipID>/ folders

    private static func migrateClipsIntoPerClipFolders() {
        let fileManager = FileManager.default
        for clip in WorklogDatabase.shared.allClips() {
            let folder = WorklogPaths.clipFolder(clipID: clip.id)
            let audioURL = WorklogPaths.clipAudioURL(clipID: clip.id)

            if clip.path != audioURL.path {
                try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: clip.path) {
                    try? fileManager.moveItem(atPath: clip.path, toPath: audioURL.path)
                }
                WorklogDatabase.shared.updateClipPath(id: clip.id, path: audioURL.path)
            }

            guard let transcript = WorklogDatabase.shared.transcript(clipID: clip.id) else { continue }

            if let oldPath = transcript.path {
                let newURL = WorklogPaths.clipTranscriptURL(clipID: clip.id)
                if oldPath != newURL.path {
                    try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                    if fileManager.fileExists(atPath: oldPath) {
                        try? fileManager.moveItem(atPath: oldPath, toPath: newURL.path)
                    }
                    WorklogDatabase.shared.updateTranscript(id: transcript.id, path: newURL.path)
                }
            }

            for translation in WorklogDatabase.shared.translations(transcriptID: transcript.id) {
                guard let oldPath = translation.path else { continue }
                let newURL = WorklogPaths.clipTranslationURL(clipID: clip.id, language: translation.language)
                guard oldPath != newURL.path else { continue }
                try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: oldPath) {
                    try? fileManager.moveItem(atPath: oldPath, toPath: newURL.path)
                }
                WorklogDatabase.shared.updateTranslation(id: translation.id, path: newURL.path)
            }
        }
    }

    private static func removeLegacyTranscriptsFolderIfEmpty() {
        let fileManager = FileManager.default
        let legacy = WorklogPaths.legacyTranscriptsRoot
        guard let contents = try? fileManager.contentsOfDirectory(atPath: legacy.path) else { return }
        if contents.isEmpty {
            try? fileManager.removeItem(at: legacy)
        }
    }
}
