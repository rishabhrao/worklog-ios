import Foundation

/// Durable, eagerly-written record of "were we recording." Written on every
/// actual start/stop (not just clean shutdown) so a force-quit or crash
/// leaves an accurate trail for the next launch's crash-recovery check.
struct PersistedRecordingState: Codable {
    var isRecording: Bool
    var pinnedDeviceUID: String?
    var lastUpdated: Date
}

/// Backed by `worklog.db`'s `app_state` key-value table - everything lives
/// in one database, per explicit user request (previously its own
/// `recording-state.json` sidecar file, migrated in by
/// `FileLayoutMigration`).
enum RecordingStateStore {
    private static let key = "recording-state"

    static func load() -> PersistedRecordingState? {
        guard let json = WorklogDatabase.shared.appStateValue(forKey: key),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PersistedRecordingState.self, from: data)
    }

    /// Writes eagerly and synchronously - called at the moment recording
    /// actually starts/stops, not batched, so an unclean shutdown still
    /// leaves the last-known-true state persisted.
    static func save(isRecording: Bool, pinnedDeviceUID: String?) {
        let state = PersistedRecordingState(
            isRecording: isRecording,
            pinnedDeviceUID: pinnedDeviceUID,
            lastUpdated: Date()
        )
        guard let data = try? JSONEncoder().encode(state),
              let json = String(data: data, encoding: .utf8) else { return }
        WorklogDatabase.shared.setAppStateValue(json, forKey: key)
    }
}

/// Shared data root - a single, plain, visible folder. `recordings/` is
/// subject to retention; `clips/` and `dictations/` are never auto-deleted by
/// anything. Each clip owns a folder (`clips/<clipID>/`) holding its audio,
/// transcript, and per-language translations together; each dictation owns
/// the same shape under `dictations/<dictationID>/`.
///
/// On iOS the root is the app's own Documents directory, published to the
/// Files app by `UIFileSharingEnabled`. That is as close as the platform gets
/// to the macOS build's `~/worklog` and the Android build's browsable
/// `/storage/emulated/0/worklog`: the layout on disk is identical across all
/// three, and a recording can be pulled off the phone in Files without a
/// cable or a companion app.
enum WorklogPaths {
    static var root: URL {
        // An explicit root, for running a throwaway instance against a
        // synthetic library: documentation screenshots must never be taken
        // from someone's real recordings, and pointing the app at a scratch
        // folder is the only way to do that without going anywhere near the
        // real one.
        if let override = ProcessInfo.processInfo.environment["WORKLOG_DATA_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("worklog", isDirectory: true)
    }

    /// Append-only raw recordings, in dated folders. Renamed from `audio/`
    /// per explicit user request - `FileLayoutMigration` moves an existing
    /// `audio/` folder here on first launch after the rename.
    static var recordingsRoot: URL {
        root.appendingPathComponent("recordings", isDirectory: true)
    }

    static var clipsRoot: URL {
        root.appendingPathComponent("clips", isDirectory: true)
    }

    /// Push-to-talk dictations. Deliberately a sibling of `clips/` and NOT
    /// under `recordings/` - `RetentionSweeper` only ever walks
    /// `recordingsRoot`, so keeping dictations here is what makes "dictation
    /// audio is never auto-deleted" true by construction rather than by an
    /// exclusion rule someone has to remember.
    static var dictationsRoot: URL {
        root.appendingPathComponent("dictations", isDirectory: true)
    }

    static var databaseURL: URL {
        root.appendingPathComponent("worklog.db")
    }

    // Legacy locations - referenced only by FileLayoutMigration.
    static var legacyAudioRoot: URL {
        root.appendingPathComponent("audio", isDirectory: true)
    }

    static var legacyTranscriptsRoot: URL {
        root.appendingPathComponent("transcripts", isDirectory: true)
    }

    static func ensureRootExists() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static func ensureRecordingsRootExists() throws {
        try FileManager.default.createDirectory(at: recordingsRoot, withIntermediateDirectories: true)
    }

    /// Creates every folder in the `~/worklog` layout. Called once at
    /// launch so a first run always has the full documented structure
    /// present, not just the pieces a given code path happens to touch.
    static func ensureFullLayoutExists() throws {
        try ensureRootExists()
        try ensureRecordingsRootExists()
        try FileManager.default.createDirectory(at: clipsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dictationsRoot, withIntermediateDirectories: true)
    }

    /// Dated folder for a given segment start time, e.g. `recordings/2026-07-09/`.
    static func dayFolder(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return recordingsRoot.appendingPathComponent(formatter.string(from: date), isDirectory: true)
    }

    /// Segment file name for a given start time, e.g. `0905_00.m4a`.
    static func segmentFileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmm_ss"
        formatter.timeZone = .current
        return "\(formatter.string(from: date)).m4a"
    }

    /// One folder per clip holding every artifact that belongs to it.
    static func clipFolder(clipID: String) -> URL {
        clipsRoot.appendingPathComponent(clipID, isDirectory: true)
    }

    static func clipAudioURL(clipID: String) -> URL {
        clipFolder(clipID: clipID).appendingPathComponent("audio.m4a")
    }

    static func clipTranscriptURL(clipID: String) -> URL {
        clipFolder(clipID: clipID).appendingPathComponent("transcript.json")
    }

    /// The language here is data forming a file name - never a code-level
    /// concept.
    static func clipTranslationURL(clipID: String, language: String) -> URL {
        clipFolder(clipID: clipID).appendingPathComponent("translation-\(language).md")
    }

    /// The overview keeps the plain `summary.md` name it has always had; the
    /// optional presets sit beside it, one file each.
    static func clipSummaryURL(clipID: String, preset: SummaryPreset = .overview) -> URL {
        clipFolder(clipID: clipID).appendingPathComponent(
            preset.isDefault ? "summary.md" : "summary-\(preset.rawValue).md"
        )
    }

    /// One folder per dictation, mirroring `clipFolder`'s shape so both
    /// artifact kinds are browsable the same way in Finder.
    static func dictationFolder(dictationID: String) -> URL {
        dictationsRoot.appendingPathComponent(dictationID, isDirectory: true)
    }

    static func dictationAudioURL(dictationID: String) -> URL {
        dictationFolder(dictationID: dictationID).appendingPathComponent("audio.m4a")
    }

    /// Verbatim provider response - the batch path stores Scribe's JSON body
    /// byte-for-byte; the realtime path stores the array of committed
    /// messages it received. Same "raw provider output is on disk" property
    /// either way.
    static func dictationTranscriptURL(dictationID: String) -> URL {
        dictationFolder(dictationID: dictationID).appendingPathComponent("transcript.json")
    }

    /// The plain text that actually gets inserted into the user's field.
    static func dictationTextURL(dictationID: String) -> URL {
        dictationFolder(dictationID: dictationID).appendingPathComponent("transcript.txt")
    }
}
