import Foundation

/// Row models for `worklog.db`. IDs are stable strings (UUIDs) rather than
/// row-autoincrement ints, because clips/transcripts are meant to be
/// "addressable artifacts" per the ticket's phase-2 headroom note - a
/// stable ID that doesn't depend on this being the only writer ever.
struct SegmentRecord {
    let path: String
    let startedAt: Date
    let endedAt: Date?
    let deviceUID: String
    let locationLatitude: Double?
    let locationLongitude: Double?
}

struct SessionRecord {
    let id: String
    let startedAt: Date
    let endedAt: Date?
    let deviceUID: String
}

struct ClipRecord {
    let id: String
    let path: String
    let defaultName: String
    let displayName: String
    let sourceStart: Date
    let sourceEnd: Date
    let durationSeconds: Double
    let createdAt: Date
    /// Best-effort location the clip was recorded at, derived from whichever
    /// contributing raw segment(s) had a location tag at export time (see
    /// `ClipExporter`). `nil` if location tagging was off, permission was
    /// denied, or none of the segments had a fix yet - never blocks export.
    let locationLatitude: Double?
    let locationLongitude: Double?
    /// Device the source audio was captured on, from the first contributing
    /// segment - clips carry the same metadata shape as raw recordings, per
    /// explicit user request.
    var deviceUID: String? = nil
}

/// What a billable pipeline step cost, and the usage that produced the
/// figure. Kept together so a displayed price can always be traced back to
/// the numbers behind it rather than being an unexplained amount.
///
/// Defaulted to empty everywhere so rows written before cost tracking
/// existed - and call sites that don't know a cost yet - stay valid.
struct CostRecord {
    var usd: Double?
    var source: CostSource?
    /// Audio seconds billed, for speech-to-text steps.
    var billedSeconds: Double?
    /// Token counts, for LLM steps.
    var inputTokens: Int?
    var outputTokens: Int?

    static let empty = CostRecord()

    /// Display string, or `nil` when there's nothing trustworthy to show.
    var label: String? { Pricing.label(costUSD: usd, source: source) }
}

/// Per-step transcription pipeline state, persisted so progress survives
/// app relaunch and each step can be retried independently (spec
/// `07-transcription-pipeline.md`).
enum PipelineStepState: String {
    case pending
    case running
    case succeeded
    case failed
}

/// One transcript per clip - the speech-to-text output, whatever
/// provider/model produced it (that's data on the row, recorded at run
/// time, never a code-level concept).
struct TranscriptRecord {
    let id: String
    let clipID: String
    let state: PipelineStepState
    let error: String?
    /// Provider/model that actually produced this transcript - recorded at
    /// run time, NOT re-read from current Settings, which the user can
    /// change at any moment after the fact.
    let provider: String?
    let model: String?
    /// Output JSON path on disk, once the step has succeeded.
    let path: String?
    let speakerCount: Int?
    let createdAt: Date
    var cost: CostRecord = .empty
}

/// One transcript → many translations, each keyed by target language
/// (today just one; more languages - or other derived renderings - are a
/// row insert away, never a schema change).
struct TranslationRecord {
    let id: String
    let transcriptID: String
    let language: String
    let state: PipelineStepState
    let error: String?
    /// Provider/model that actually produced this translation - recorded
    /// at run time, same rule as `TranscriptRecord`.
    let provider: String?
    let model: String?
    /// Output markdown path on disk, once the step has succeeded.
    let path: String?
    let createdAt: Date
    var cost: CostRecord = .empty
}

/// One summary per transcript - an LLM-condensed rendering of either the
/// raw transcript or one of its translations (whichever the user's Settings
/// selected at run time, recorded here via `translationID`). Same
/// state/provenance shape as transcripts and translations: what actually
/// produced this output is data on the row, never re-read from Settings.
struct SummaryRecord {
    let id: String
    let transcriptID: String
    /// Which kind of summary this row holds. Rows written before presets
    /// existed read as `.overview`, which is what they are.
    let preset: SummaryPreset
    /// The translation this summary was derived from - `nil` when it was
    /// created from the raw transcript ("original" source).
    let translationID: String?
    let state: PipelineStepState
    let error: String?
    let provider: String?
    let model: String?
    /// Output markdown path on disk, once the step has succeeded.
    let path: String?
    let createdAt: Date
    var cost: CostRecord = .empty
}

/// How a dictation was delimited by the user. Recorded as data (like
/// provider/model) rather than inferred later - a `hold` dictation and a
/// `handsFree` one are indistinguishable from their audio alone.
enum DictationMode: String {
    /// Press-and-hold: recorded for exactly as long as the hotkey was down.
    case hold
    /// Latched hands-free (hotkey → Space): recorded until the hotkey was
    /// pressed again to save, or Escape to discard.
    case handsFree = "hands_free"

    var displayName: String {
        switch self {
        case .hold: return "Hold"
        case .handsFree: return "Hands-free"
        }
    }
}

/// Whether the transcript reached the user's focused text field, and how
/// completely. `partial` is reachable only on the realtime path, where the
/// frontmost app can change (or the stream can die) after some text has
/// already been typed.
enum DictationInsertion: Int {
    case none = 0
    case full = 1
    case partial = 2
}

/// A push-to-talk dictation. Deliberately NOT a `ClipRecord`: there are no
/// translations, no summary, no diarization and no waveform-selection
/// provenance, and its single transcription step is 1:1 - so the state that
/// clips spread across `transcripts` collapses onto this one row rather
/// than dragging in a hierarchy none of it uses.
struct DictationRecord {
    let id: String
    /// `dictations/<id>/audio.m4a`. Written after the text has already been
    /// inserted on the realtime path, so it can briefly not exist yet.
    let path: String
    let defaultName: String
    let displayName: String
    let sourceStart: Date
    let sourceEnd: Date
    /// The audio actually exported, never the requested window - same
    /// guardrail as `ClipRecord.durationSeconds`.
    let durationSeconds: Double
    let createdAt: Date
    let mode: DictationMode
    let locationLatitude: Double?
    let locationLongitude: Double?
    var deviceUID: String? = nil
    let state: PipelineStepState
    let error: String?
    /// Provider/model that actually produced this text, recorded at run
    /// time. A realtime dictation retried via the batch path simply rewrites
    /// `model` - the column reports what factually ran, and nothing in the
    /// app branches on its value.
    let provider: String?
    let model: String?
    let textPath: String?
    let rawPath: String?
    var insertion: DictationInsertion = .none
    var cost: CostRecord = .empty
}

/// One tag. Tags are a flat, user-owned vocabulary - no hierarchy, no
/// required fields beyond a name - because the moment a tag needs explaining
/// it has stopped being a tag.
struct TagRecord: Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    /// Palette key. `nil` means "derive one from the name", so a tag always
    /// has a colour without anyone having to choose.
    var colorKey: String?
    /// Whether the user made this tag or the tagging model proposed it -
    /// shown in the manager so an auto-grown vocabulary can be pruned.
    var isAutoCreated: Bool
    var createdAt: Date
}

/// How a tag got onto a clip. A re-run replaces what the model chose and
/// leaves what the user chose alone, which is only possible because the two
/// are distinguishable.
enum TagSource: String {
    case manual
    case auto
}

/// The auto-tagging step's own row: one per transcript, holding the same
/// state/provenance/cost shape every other pipeline step has, so retry,
/// spinners and the Costs breakdown work identically. Its output isn't a
/// file - it's rows in `clip_tags`.
struct TaggingRecord {
    let id: String
    let transcriptID: String
    let state: PipelineStepState
    let error: String?
    let provider: String?
    let model: String?
    let createdAt: Date
    var cost: CostRecord = .empty
}

/// A user-named place: a circle on the map that claims every recording made
/// inside it. Deliberately NOT a name copied onto each clip row - the name
/// is resolved from this table at read time, which is what makes renaming
/// or removing a place apply to every past recording at once (and to every
/// future one, with no backfill pass).
struct PlaceRecord: Identifiable, Equatable {
    let id: String
    var name: String
    var latitude: Double
    var longitude: Double
    /// How far from the center still counts as "here". A home or an office
    /// is a building, not a point, and consecutive fixes at the same desk
    /// routinely differ by tens of meters.
    var radiusMeters: Double
    var createdAt: Date
    var updatedAt: Date
}

/// A reverse-geocoded name for one coordinate cell, cached in the database
/// rather than in memory. Persisting it is what lets the OS-provided name
/// ("Marol CHS Road") be *searchable* across the whole library - including
/// entries never opened - and keeps it readable with no network at all.
struct GeocodeRecord {
    /// Coordinates rounded to 4 decimal places (~11 m), which is the same
    /// precision the UI has always displayed raw coordinates at.
    let cell: String
    let name: String
    /// Locality/area/country, kept apart from the display name so a search
    /// for "Mumbai" hits a clip whose name is just the street.
    let context: String?
}

/// Owns `worklog.db` - the single index of segments, sessions, clips,
/// dictations, and transcripts described in
/// `specs/03-retention-and-storage.md`. One instance per process; all access
/// goes through this type so the schema stays a single source of truth.
final class WorklogDatabase {
    static let shared = WorklogDatabase()

    private let sqlite: SQLite

    private init() {
        try? WorklogPaths.ensureRootExists()
        do {
            sqlite = try SQLite(path: WorklogPaths.databaseURL.path)
            try createSchema()
        } catch {
            fatalError("Failed to open worklog.db: \(error)")
        }
    }

    private func createSchema() throws {
        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS segments (
                path TEXT PRIMARY KEY,
                started_at REAL NOT NULL,
                ended_at REAL,
                device_uid TEXT NOT NULL,
                location_latitude REAL,
                location_longitude REAL
            )
            """)

        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                started_at REAL NOT NULL,
                ended_at REAL,
                device_uid TEXT NOT NULL
            )
            """)

        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS clips (
                id TEXT PRIMARY KEY,
                path TEXT NOT NULL,
                default_name TEXT NOT NULL,
                display_name TEXT NOT NULL,
                source_start REAL NOT NULL,
                source_end REAL NOT NULL,
                duration_seconds REAL NOT NULL,
                created_at REAL NOT NULL,
                location_latitude REAL,
                location_longitude REAL
            )
            """)
        // Older installs created `clips` before location columns existed;
        // ALTER TABLE ADD COLUMN is a no-op error (caught, ignored) if the
        // column is already present - cheaper than a migrations table for
        // this app's single-writer, low-table-count shape.
        try? sqlite.execute("ALTER TABLE clips ADD COLUMN location_latitude REAL")
        try? sqlite.execute("ALTER TABLE clips ADD COLUMN location_longitude REAL")
        try? sqlite.execute("ALTER TABLE clips ADD COLUMN device_uid TEXT")

        // One-time migration from the legacy shape (transcript + a single
        // hardcoded translation conflated as columns on one row) to the
        // hierarchy: one transcript per clip, many translations per
        // transcript. The provider/language literals below describe what
        // the legacy rows factually were - historical data, not code-level
        // concepts.
        var hasLegacyTranscripts = false
        try? sqlite.query("SELECT 1 FROM pragma_table_info('transcripts') WHERE name = 'scribe_state'") { _ in
            hasLegacyTranscripts = true
        }
        if hasLegacyTranscripts {
            try sqlite.execute("ALTER TABLE transcripts RENAME TO transcripts_legacy")
        }

        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS transcripts (
                id TEXT PRIMARY KEY,
                clip_id TEXT NOT NULL REFERENCES clips(id),
                state TEXT NOT NULL DEFAULT 'pending',
                error TEXT,
                provider TEXT,
                model TEXT,
                path TEXT,
                speaker_count INTEGER,
                created_at REAL NOT NULL
            )
            """)

        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS translations (
                id TEXT PRIMARY KEY,
                transcript_id TEXT NOT NULL REFERENCES transcripts(id),
                language TEXT NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending',
                error TEXT,
                provider TEXT,
                model TEXT,
                path TEXT,
                created_at REAL NOT NULL
            )
            """)

        if hasLegacyTranscripts {
            try sqlite.execute("""
                INSERT INTO transcripts (id, clip_id, state, error, provider, model, path, speaker_count, created_at)
                SELECT id, clip_id, scribe_state, scribe_error, 'elevenlabs', COALESCE(scribe_model, 'scribe_v2'), scribe_json_path, speaker_count, created_at
                FROM transcripts_legacy
                """)
            try sqlite.execute("""
                INSERT INTO translations (id, transcript_id, language, state, error, provider, model, path, created_at)
                SELECT id || '-hinglish', id, 'hinglish', hinglish_state, hinglish_error, COALESCE(hinglish_provider, 'anthropic'), hinglish_model, hinglish_markdown_path, created_at
                FROM transcripts_legacy
                """)
            try sqlite.execute("DROP TABLE transcripts_legacy")
        }

        // One summary per transcript, optionally derived from one of its
        // translations (translation_id records which - NULL means it was
        // built from the raw transcript). Supersedes the never-populated
        // `derived_documents` headroom table, dropped below.
        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS summaries (
                id TEXT PRIMARY KEY,
                transcript_id TEXT NOT NULL REFERENCES transcripts(id),
                preset TEXT NOT NULL DEFAULT 'overview',
                translation_id TEXT REFERENCES translations(id),
                state TEXT NOT NULL DEFAULT 'pending',
                error TEXT,
                provider TEXT,
                model TEXT,
                path TEXT,
                created_at REAL NOT NULL
            )
            """)
        try? sqlite.execute("DROP TABLE IF EXISTS derived_documents")

        // Peak-cache (spec `05-clip-screen-and-waveform.md`): downsampled
        // amplitude peaks computed once per segment when it's finalized, so
        // loading a historical range for the waveform never has to
        // re-decode raw PCM from `audio/`. One row per segment; `peaks` is a
        // flat array of Float peak values packed as raw bytes (little-
        // endian), `peaks_per_second` records the resolution they were
        // computed at so the renderer can downsample further for zoomed-out
        // views without re-reading the audio file.
        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS segment_peaks (
                segment_path TEXT PRIMARY KEY REFERENCES segments(path),
                peaks_per_second REAL NOT NULL,
                peaks BLOB NOT NULL
            )
            """)

        // Push-to-talk dictations. A flat table, not a clip + transcript
        // pair: one dictation has exactly one transcription, no translations
        // and no summary, so the pipeline state that clips keep in
        // `transcripts` lives directly on the row here. `state` reuses
        // `PipelineStepState` so the retry semantics and the UI's
        // pending/running/succeeded/failed vocabulary are identical to the
        // clip pipeline's.
        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS dictations (
                id TEXT PRIMARY KEY,
                path TEXT NOT NULL,
                default_name TEXT NOT NULL,
                display_name TEXT NOT NULL,
                source_start REAL NOT NULL,
                source_end REAL NOT NULL,
                duration_seconds REAL NOT NULL,
                created_at REAL NOT NULL,
                mode TEXT NOT NULL,
                location_latitude REAL,
                location_longitude REAL,
                device_uid TEXT,
                state TEXT NOT NULL DEFAULT 'pending',
                error TEXT,
                provider TEXT,
                model TEXT,
                text_path TEXT,
                raw_path TEXT,
                inserted INTEGER NOT NULL DEFAULT 0
            )
            """)

        // User-named places. Small table (one row per place the user has
        // actually named), read whole into memory by `PlaceStore` - there is
        // no per-clip join, because a clip's place is decided by distance,
        // not by a foreign key.
        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS places (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                latitude REAL NOT NULL,
                longitude REAL NOT NULL,
                radius_meters REAL NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """)

        // Reverse-geocode cache, keyed by a ~11 m coordinate cell. Both apps
        // geocode lazily and rate-limited (CLGeocoder is a real network call
        // with a hard throttle), so the result has to outlive the process -
        // otherwise search could only ever match places the user had already
        // scrolled past this session.
        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS geocodes (
                cell TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                context TEXT,
                resolved_at REAL NOT NULL
            )
            """)

        // Tags: a flat vocabulary, plus the clip↔tag join that carries how
        // each assignment was made. `source` is what lets a re-run replace
        // the model's choices without touching the user's.
        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS tags (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                color_key TEXT,
                auto_created INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            )
            """)
        // Names are the identity users actually work with, so two tags that
        // differ only in case are the same tag.
        try? sqlite.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_tags_name ON tags(lower(name))")

        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS clip_tags (
                clip_id TEXT NOT NULL,
                tag_id TEXT NOT NULL,
                source TEXT NOT NULL DEFAULT 'manual',
                created_at REAL NOT NULL,
                PRIMARY KEY (clip_id, tag_id)
            )
            """)
        try sqlite.execute("CREATE INDEX IF NOT EXISTS idx_clip_tags_tag ON clip_tags(tag_id)")

        // The auto-tagging step, shaped exactly like `summaries` so it
        // inherits the retry/state/cost vocabulary rather than inventing one.
        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS taggings (
                id TEXT PRIMARY KEY,
                transcript_id TEXT NOT NULL REFERENCES transcripts(id),
                state TEXT NOT NULL DEFAULT 'pending',
                error TEXT,
                provider TEXT,
                model TEXT,
                created_at REAL NOT NULL,
                cost_usd REAL,
                cost_source TEXT,
                input_tokens INTEGER,
                output_tokens INTEGER
            )
            """)

        // Small key-value store for app state that previously lived in
        // sidecar JSON files (settings, crash-recovery recording state) -
        // everything in one database, per explicit user request.
        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS app_state (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """)

        // On-device speech-preview words: rough live transcription of the
        // raw recording, one row per word, on the same wall-clock timeline
        // as segments. Deliberately free-floating (no clip/segment foreign
        // key) - a word describes a moment in time, and every consumer
        // (selection-edge strip, transcript range picker, pending-transcript
        // placeholders) asks by time range. Device-local by design: never
        // exported, never in clip archives - the archive carries the real
        // Scribe transcript, and an importer's own engine can re-preview.
        // Pruned on the raw-audio retention window, since the words are a
        // description of audio that no longer exists.
        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS preview_words (
                start_at REAL NOT NULL,
                end_at REAL NOT NULL,
                text TEXT NOT NULL,
                engine TEXT NOT NULL
            )
            """)
        try sqlite.execute("CREATE INDEX IF NOT EXISTS idx_preview_words_start ON preview_words(start_at)")

        // The permanent half of previews. `preview_words` above describes raw
        // audio and dies with it; these two describe a *clip* or a
        // *dictation*, which the user keeps, so they are snapshotted at the
        // moment the clip or dictation is cut and then never pruned. They are
        // not a fallback for a missing Scribe transcript - they stay
        // alongside it forever, because they are the only record of what the
        // device itself heard at the time, and because a clip made today
        // should still show its preview years after the raw audio has aged
        // out.
        //
        // Rows are copied rather than referenced by time range for exactly
        // that reason: pointing at `preview_words` would mean the clip's
        // preview evaporating on the next retention sweep.
        for (table, parent) in [("clip_preview_words", "clips"), ("dictation_preview_words", "dictations")] {
            let ownerColumn = parent == "clips" ? "clip_id" : "dictation_id"
            try sqlite.execute("""
                CREATE TABLE IF NOT EXISTS \(table) (
                    \(ownerColumn) TEXT NOT NULL REFERENCES \(parent)(id) ON DELETE CASCADE,
                    start_at REAL NOT NULL,
                    end_at REAL NOT NULL,
                    text TEXT NOT NULL,
                    engine TEXT NOT NULL
                )
                """)
            // Every read is "all words for this owner, in order".
            try sqlite.execute("""
                CREATE INDEX IF NOT EXISTS idx_\(table)_owner
                ON \(table)(\(ownerColumn), start_at)
                """)
        }

        // Cost accounting, added after the fact - same ALTER-and-ignore
        // pattern as the clips location columns above. Each row keeps both
        // the money and the usage it was derived from, so a figure can be
        // re-checked later against whatever the rates were, and `cost_source`
        // records whether the provider told us the price or we worked it out
        // from a rate table (see `CostSource`).
        for table in ["transcripts", "dictations"] {
            try? sqlite.execute("ALTER TABLE \(table) ADD COLUMN cost_usd REAL")
            try? sqlite.execute("ALTER TABLE \(table) ADD COLUMN cost_source TEXT")
            try? sqlite.execute("ALTER TABLE \(table) ADD COLUMN billed_seconds REAL")
        }
        // Summary presets, added after the fact. An existing summary is an
        // overview by definition - that's the only kind the app made - so the
        // backfill is what keeps old rows rendering under the right heading.
        try? sqlite.execute("ALTER TABLE summaries ADD COLUMN preset TEXT NOT NULL DEFAULT 'overview'")
        try? sqlite.execute("UPDATE summaries SET preset = 'overview' WHERE preset IS NULL")

        for table in ["translations", "summaries"] {
            try? sqlite.execute("ALTER TABLE \(table) ADD COLUMN cost_usd REAL")
            try? sqlite.execute("ALTER TABLE \(table) ADD COLUMN cost_source TEXT")
            try? sqlite.execute("ALTER TABLE \(table) ADD COLUMN input_tokens INTEGER")
            try? sqlite.execute("ALTER TABLE \(table) ADD COLUMN output_tokens INTEGER")
        }

        try sqlite.execute("CREATE INDEX IF NOT EXISTS idx_segments_started_at ON segments(started_at)")
        try sqlite.execute("CREATE INDEX IF NOT EXISTS idx_clips_created_at ON clips(created_at)")
        try sqlite.execute("CREATE INDEX IF NOT EXISTS idx_transcripts_clip_id ON transcripts(clip_id)")
        try sqlite.execute("CREATE INDEX IF NOT EXISTS idx_translations_transcript_id ON translations(transcript_id)")
        try sqlite.execute("CREATE INDEX IF NOT EXISTS idx_summaries_transcript_id ON summaries(transcript_id)")
        try sqlite.execute("CREATE INDEX IF NOT EXISTS idx_dictations_created_at ON dictations(created_at)")
        try sqlite.execute("CREATE INDEX IF NOT EXISTS idx_taggings_transcript_id ON taggings(transcript_id)")
    }

    // MARK: - Layout migration helpers

    /// Rewrites a path prefix across every path-bearing column - used by
    /// `FileLayoutMigration` when a folder moves (e.g. audio/ → recordings/).
    func migratePathPrefix(from oldPrefix: String, to newPrefix: String) {
        let pattern = oldPrefix + "%"
        try? sqlite.execute("UPDATE segments SET path = REPLACE(path, ?, ?) WHERE path LIKE ?", [oldPrefix, newPrefix, pattern])
        try? sqlite.execute("UPDATE segment_peaks SET segment_path = REPLACE(segment_path, ?, ?) WHERE segment_path LIKE ?", [oldPrefix, newPrefix, pattern])
        try? sqlite.execute("UPDATE clips SET path = REPLACE(path, ?, ?) WHERE path LIKE ?", [oldPrefix, newPrefix, pattern])
        try? sqlite.execute("UPDATE transcripts SET path = REPLACE(path, ?, ?) WHERE path LIKE ?", [oldPrefix, newPrefix, pattern])
        try? sqlite.execute("UPDATE translations SET path = REPLACE(path, ?, ?) WHERE path LIKE ?", [oldPrefix, newPrefix, pattern])
        try? sqlite.execute("UPDATE summaries SET path = REPLACE(path, ?, ?) WHERE path LIKE ?", [oldPrefix, newPrefix, pattern])
    }

    func updateClipPath(id: String, path: String) {
        try? sqlite.execute("UPDATE clips SET path = ? WHERE id = ?", [path, id])
    }

    // MARK: - App state (key-value)

    /// A dictation spoken into the Worklog keyboard. No audio and no
    /// provider: the text was recognised on-device inside the extension and
    /// inserted there, so it arrives already finished.
    func insertKeyboardDictation(id: String, name: String, startedAt: Date, endedAt: Date, textPath: String) {
        try? sqlite.execute(
            """
            INSERT OR IGNORE INTO dictations
                (id, path, default_name, display_name, source_start, source_end, duration_seconds,
                 created_at, mode, device_uid, state, provider, model, text_path, inserted)
            VALUES (?, '', ?, ?, ?, ?, ?, ?, 'hold', NULL, 'succeeded', 'apple_on_device', 'keyboard', ?, 1)
            """,
            [id, name, name, startedAt.timeIntervalSince1970, endedAt.timeIntervalSince1970,
             endedAt.timeIntervalSince(startedAt), startedAt.timeIntervalSince1970, textPath]
        )
    }

    // MARK: - Container-path repair

    /// Every non-null value in a path column. Used only by
    /// `ContainerPathMigration`, which runs once at launch.
    func allPaths(table: String, column: String) -> [String] {
        var paths: [String] = []
        // The table and column names are compile-time constants from a fixed
        // list in the migration, never user input - but they still cannot be
        // bound as parameters, so the list is the guarantee.
        try? sqlite.query("SELECT \(column) FROM \(table) WHERE \(column) IS NOT NULL") { row in
            if let value = row.string(0) { paths.append(value) }
        }
        return paths
    }

    func rewritePath(table: String, column: String, from oldPath: String, to newPath: String) {
        try? sqlite.execute("UPDATE \(table) SET \(column) = ? WHERE \(column) = ?", [newPath, oldPath])
    }

    func appStateValue(forKey key: String) -> String? {
        var value: String?
        try? sqlite.query("SELECT value FROM app_state WHERE key = ?", [key]) { row in
            value = row.string(0)
        }
        return value
    }

    func setAppStateValue(_ value: String, forKey key: String) {
        try? sqlite.execute(
            "INSERT INTO app_state (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [key, value]
        )
    }

    // MARK: - Speech preview words

    func insertPreviewWords(_ words: [PreviewWord], engine: String) {
        guard !words.isEmpty else { return }
        for word in words {
            try? sqlite.execute(
                "INSERT INTO preview_words (start_at, end_at, text, engine) VALUES (?, ?, ?, ?)",
                [word.start.timeIntervalSince1970, word.end.timeIntervalSince1970, word.text, engine]
            )
        }
    }

    /// Words overlapping `[start, end]`, in spoken order. The limit is a
    /// backstop against pathological ranges (a week at conversational pace),
    /// not a pagination mechanism.
    func previewWords(from start: Date, to end: Date, limit: Int = 25_000) -> [PreviewWord] {
        var words: [PreviewWord] = []
        try? sqlite.query(
            "SELECT start_at, end_at, text FROM preview_words WHERE end_at >= ? AND start_at <= ? ORDER BY start_at LIMIT ?",
            [start.timeIntervalSince1970, end.timeIntervalSince1970, limit]
        ) { row in
            guard let startAt = row.double(0), let endAt = row.double(1), let text = row.string(2) else { return }
            words.append(PreviewWord(start: Date(timeIntervalSince1970: startAt), end: Date(timeIntervalSince1970: endAt), text: text))
        }
        return words
    }

    /// The first words spoken at or after `start` (up to `end`) - what a
    /// clip beginning at `start` opens with.
    func firstPreviewWords(from start: Date, to end: Date, limit: Int) -> [PreviewWord] {
        var words: [PreviewWord] = []
        try? sqlite.query(
            "SELECT start_at, end_at, text FROM preview_words WHERE end_at >= ? AND start_at <= ? ORDER BY start_at LIMIT ?",
            [start.timeIntervalSince1970, end.timeIntervalSince1970, limit]
        ) { row in
            guard let startAt = row.double(0), let endAt = row.double(1), let text = row.string(2) else { return }
            words.append(PreviewWord(start: Date(timeIntervalSince1970: startAt), end: Date(timeIntervalSince1970: endAt), text: text))
        }
        return words
    }

    /// The last words spoken at or before `end` (back to `start`) - what a
    /// clip ending at `end` closes with. Returned in spoken order.
    func lastPreviewWords(from start: Date, to end: Date, limit: Int) -> [PreviewWord] {
        var words: [PreviewWord] = []
        try? sqlite.query(
            "SELECT start_at, end_at, text FROM preview_words WHERE end_at >= ? AND start_at <= ? ORDER BY start_at DESC LIMIT ?",
            [start.timeIntervalSince1970, end.timeIntervalSince1970, limit]
        ) { row in
            guard let startAt = row.double(0), let endAt = row.double(1), let text = row.string(2) else { return }
            words.append(PreviewWord(start: Date(timeIntervalSince1970: startAt), end: Date(timeIntervalSince1970: endAt), text: text))
        }
        return words.reversed()
    }

    /// Whether any preview words exist at all - the clip screen uses this
    /// to distinguish "feature never produced anything yet" from "silence
    /// in this particular range."
    func hasPreviewWords() -> Bool {
        var exists = false
        try? sqlite.query("SELECT 1 FROM preview_words LIMIT 1") { _ in exists = true }
        return exists
    }

    /// Retention: preview words describe raw audio, so they die with it.
    ///
    /// Deliberately only this table. The per-clip and per-dictation snapshots
    /// are kept forever - see `snapshotPreviewWords`.
    func prunePreviewWords(olderThan cutoff: Date) {
        try? sqlite.execute("DELETE FROM preview_words WHERE end_at < ?", [cutoff.timeIntervalSince1970])
    }

    // MARK: - Preview words kept with a clip or dictation

    /// Copies whatever the on-device engine heard across `[start, end]` onto
    /// a clip or dictation, permanently.
    ///
    /// Called as the clip or dictation is created, which is the only moment
    /// the source rows are guaranteed to still exist: `preview_words` is
    /// pruned on the raw-audio retention window, so a clip that merely
    /// *pointed* at that range would silently lose its preview the first time
    /// the sweeper ran past it. Copying is what makes "saved forever with the
    /// recording" true.
    ///
    /// Idempotent: re-snapshotting an owner replaces its rows rather than
    /// doubling them, so a retried creation can't duplicate a transcript.
    private func snapshotPreviewWords(
        table: String, ownerColumn: String, ownerID: String, from start: Date, to end: Date
    ) {
        guard ["clip_preview_words", "dictation_preview_words"].contains(table) else { return }
        try? sqlite.execute("DELETE FROM \(table) WHERE \(ownerColumn) = ?", [ownerID])
        try? sqlite.execute("""
            INSERT INTO \(table) (\(ownerColumn), start_at, end_at, text, engine)
            SELECT ?, start_at, end_at, text, engine FROM preview_words
            WHERE end_at >= ? AND start_at <= ?
            ORDER BY start_at
            """,
            [ownerID, start.timeIntervalSince1970, end.timeIntervalSince1970]
        )
    }

    func snapshotPreviewWordsForClip(id: String, from start: Date, to end: Date) {
        snapshotPreviewWords(table: "clip_preview_words", ownerColumn: "clip_id", ownerID: id, from: start, to: end)
    }

    func snapshotPreviewWordsForDictation(id: String, from start: Date, to end: Date) {
        snapshotPreviewWords(table: "dictation_preview_words", ownerColumn: "dictation_id", ownerID: id, from: start, to: end)
    }

    private func ownedPreviewWords(table: String, ownerColumn: String, ownerID: String) -> [PreviewWord] {
        guard ["clip_preview_words", "dictation_preview_words"].contains(table) else { return [] }
        var words: [PreviewWord] = []
        try? sqlite.query(
            "SELECT start_at, end_at, text FROM \(table) WHERE \(ownerColumn) = ? ORDER BY start_at",
            [ownerID]
        ) { row in
            guard let startAt = row.double(0), let endAt = row.double(1), let text = row.string(2) else { return }
            words.append(PreviewWord(start: Date(timeIntervalSince1970: startAt), end: Date(timeIntervalSince1970: endAt), text: text))
        }
        return words
    }

    /// Writes a clip's preview words directly, for an imported archive whose
    /// words describe audio this device never recorded.
    func replaceClipPreviewWords(clipID: String, words: [PreviewWord], engine: String) {
        try? sqlite.execute("DELETE FROM clip_preview_words WHERE clip_id = ?", [clipID])
        for word in words {
            try? sqlite.execute(
                "INSERT INTO clip_preview_words (clip_id, start_at, end_at, text, engine) VALUES (?, ?, ?, ?, ?)",
                [clipID, word.start.timeIntervalSince1970, word.end.timeIntervalSince1970, word.text, engine]
            )
        }
    }

    func clipPreviewWords(clipID: String) -> [PreviewWord] {
        ownedPreviewWords(table: "clip_preview_words", ownerColumn: "clip_id", ownerID: clipID)
    }

    func dictationPreviewWords(dictationID: String) -> [PreviewWord] {
        ownedPreviewWords(table: "dictation_preview_words", ownerColumn: "dictation_id", ownerID: dictationID)
    }

    // MARK: - Segments

    /// Records a segment the moment its file is opened for writing -
    /// ended_at is NULL until `recordSegmentClosed` upserts it on close.
    /// Without this, a still-recording segment has zero row in `segments`
    /// at all (not just an unfinalized one), so `RangeLoader` - which can
    /// only query rows that exist - has nothing to find for the most
    /// recent, most relevant part of any "last N minutes" range until the
    /// segment finishes and rotates (up to 5 minutes later). This is what
    /// made a live waveform go blank for everything after the previous
    /// segment's close, even though real audio was actively being recorded.
    func recordSegmentOpened(path: URL, startedAt: Date, deviceUID: String) {
        try? sqlite.execute(
            """
            INSERT INTO segments (path, started_at, ended_at, device_uid)
            VALUES (?, ?, NULL, ?)
            ON CONFLICT(path) DO NOTHING
            """,
            [path.path, startedAt.timeIntervalSince1970, deviceUID]
        )
    }

    /// Paths of rows still marked open (`ended_at IS NULL`) - at most one
    /// of these is genuinely recording right now; the rest are orphans from
    /// a quit/crash that lost the close-write (see `StartupReconciliation.
    /// closeOrphanedOpenRows`).
    func openSegmentPaths() -> [String] {
        var paths: [String] = []
        try? sqlite.query("SELECT path FROM segments WHERE ended_at IS NULL") { row in
            if let path = row.string(0) { paths.append(path) }
        }
        return paths
    }

    /// Backfills a segment row's location from the sidecar index, only if
    /// the row doesn't already have one - repair path for rows whose
    /// close-time location write was lost.
    func updateSegmentLocationIfMissing(path: String, latitude: Double, longitude: Double) {
        try? sqlite.execute(
            "UPDATE segments SET location_latitude = ?, location_longitude = ? WHERE path = ? AND location_latitude IS NULL",
            [latitude, longitude, path]
        )
    }

    /// Backfills a clip's location, re-derived from its source segments -
    /// repair path for clips exported while their segments' rows were
    /// missing location.
    func updateClipLocation(id: String, latitude: Double, longitude: Double) {
        try? sqlite.execute(
            "UPDATE clips SET location_latitude = ?, location_longitude = ? WHERE id = ?",
            [latitude, longitude, id]
        )
    }

    /// Closes an orphaned-open row using the file's real readable duration.
    /// Guarded on `ended_at IS NULL` so it can never clobber a row the
    /// normal close path already finalized.
    func closeOrphanedSegmentRow(path: String, durationSeconds: TimeInterval) {
        try? sqlite.execute(
            "UPDATE segments SET ended_at = started_at + ? WHERE path = ? AND ended_at IS NULL",
            [durationSeconds, path]
        )
    }

    /// Records a newly-closed raw segment. Called from `RecordingSession`
    /// each time `SegmentWriter` finalizes a file - this is the index-write
    /// hook Priority 1 left as a no-op placeholder.
    func recordSegmentClosed(path: URL, startedAt: Date, endedAt: Date, deviceUID: String, location: SegmentLocationTag?) {
        // The conflict branch is now the NORMAL path - recordSegmentOpened
        // pre-creates every row at open time - so it must carry everything
        // the insert would, not just ended_at. (Updating only ended_at here
        // silently dropped every segment's location for a while: the tag
        // was in the sidecar but never reached the row, so clips derived
        // no location despite tracking working fine.) COALESCE keeps an
        // already-backfilled location if this close happens to have none.
        try? sqlite.execute(
            """
            INSERT INTO segments (path, started_at, ended_at, device_uid, location_latitude, location_longitude)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                ended_at = excluded.ended_at,
                device_uid = excluded.device_uid,
                location_latitude = COALESCE(excluded.location_latitude, location_latitude),
                location_longitude = COALESCE(excluded.location_longitude, location_longitude)
            """,
            [
                path.path,
                startedAt.timeIntervalSince1970,
                endedAt.timeIntervalSince1970,
                deviceUID,
                location.map(\.latitude).asBindable,
                location.map(\.longitude).asBindable,
            ]
        )
    }

    /// All segment file paths strictly older than `cutoff`, for the
    /// retention sweeper to consider deleting.
    func segmentPaths(olderThan cutoff: Date) -> [String] {
        var paths: [String] = []
        try? sqlite.query(
            "SELECT path FROM segments WHERE started_at < ?",
            [cutoff.timeIntervalSince1970]
        ) { row in
            if let path = row.string(0) { paths.append(path) }
        }
        return paths
    }

    /// Removes segment rows whose files no longer exist on disk (called
    /// after a purge, and at startup reconciliation) - keeps the index from
    /// claiming rows for files that are already gone.
    func removeSegmentRows(paths: [String]) {
        for path in paths {
            try? sqlite.execute("DELETE FROM segment_peaks WHERE segment_path = ?", [path])
            try? sqlite.execute("DELETE FROM segments WHERE path = ?", [path])
        }
    }

    /// All segment paths currently indexed - used by startup reconciliation
    /// to detect drift against what's actually on disk.
    func allSegmentPaths() -> [String] {
        var paths: [String] = []
        try? sqlite.query("SELECT path FROM segments") { row in
            if let path = row.string(0) { paths.append(path) }
        }
        return paths
    }

    /// Inserts a row for an on-disk segment found with no matching index
    /// entry (reconciliation's "missing row" repair). Best-effort metadata:
    /// device UID is unknown at reconciliation time, so it's left empty
    /// rather than guessed. `endedAt` should reflect the file's true decoded
    /// duration, not default to `startedAt` - a zero-duration row is
    /// invisible to any range load that needs real segment duration
    /// (Priority 4's waveform/clip export).
    func recordUnindexedSegmentFound(path: URL, startedAt: Date, endedAt: Date) {
        try? sqlite.execute(
            """
            INSERT OR IGNORE INTO segments (path, started_at, ended_at, device_uid)
            VALUES (?, ?, ?, '')
            """,
            [path.path, startedAt.timeIntervalSince1970, endedAt.timeIntervalSince1970]
        )
    }

    /// Segments overlapping `[start, end]`, ordered by start time - the
    /// query the Clip screen's range loader uses to resolve a requested
    /// time range into the on-disk segment files it needs to stitch.
    func segments(overlapping start: Date, _ end: Date) -> [SegmentRecord] {
        var results: [SegmentRecord] = []
        try? sqlite.query(
            """
            SELECT path, started_at, ended_at, device_uid, location_latitude, location_longitude
            FROM segments
            WHERE started_at <= ? AND (ended_at IS NULL OR ended_at >= ?)
            ORDER BY started_at ASC
            """,
            [end.timeIntervalSince1970, start.timeIntervalSince1970]
        ) { row in
            guard let path = row.string(0), let startedAt = row.double(1), let deviceUID = row.string(3) else { return }
            results.append(SegmentRecord(
                path: path,
                startedAt: Date(timeIntervalSince1970: startedAt),
                endedAt: row.double(2).map(Date.init(timeIntervalSince1970:)),
                deviceUID: deviceUID,
                locationLatitude: row.double(4),
                locationLongitude: row.double(5)
            ))
        }
        return results
    }

    /// Earliest and latest indexed segment start times, used to bound
    /// "last N minutes" presets and the historical range picker against
    /// what actually exists on disk.
    func segmentTimeBounds() -> (earliest: Date, latest: Date)? {
        var earliest: Double?
        var latest: Double?
        try? sqlite.query("SELECT MIN(started_at), MAX(started_at) FROM segments") { row in
            earliest = row.double(0)
            latest = row.double(1)
        }
        guard let earliest, let latest else { return nil }
        return (Date(timeIntervalSince1970: earliest), Date(timeIntervalSince1970: latest))
    }

    // MARK: - Segment peaks (waveform peak-cache)

    /// Stores precomputed downsampled peaks for a finalized segment. Called
    /// once, right after `recordSegmentClosed`, from the same finalize hook
    /// - so a segment's peaks exist by the time any Clip-screen range load
    /// could possibly need them, without a background backfill pass.
    func storeSegmentPeaks(segmentPath: String, peaksPerSecond: Double, peaks: [Float]) {
        let data = peaks.withUnsafeBufferPointer { Data(buffer: $0) }
        try? sqlite.execute(
            """
            INSERT INTO segment_peaks (segment_path, peaks_per_second, peaks)
            VALUES (?, ?, ?)
            ON CONFLICT(segment_path) DO UPDATE SET peaks_per_second = excluded.peaks_per_second, peaks = excluded.peaks
            """,
            [segmentPath, peaksPerSecond, BlobBinding(data: data)]
        )
    }

    /// Reads back a segment's cached peaks, or `nil` if not yet computed
    /// (e.g. a segment written by a previous build before peak-caching
    /// existed, or reconciliation-recovered rows with no writer-side hook).
    func segmentPeaks(segmentPath: String) -> (peaksPerSecond: Double, peaks: [Float])? {
        var result: (Double, [Float])?
        try? sqlite.query(
            "SELECT peaks_per_second, peaks FROM segment_peaks WHERE segment_path = ?",
            [segmentPath]
        ) { row in
            guard let rate = row.double(0), let blob = row.blob(1) else { return }
            let floats = blob.withUnsafeBytes { pointer in
                Array(pointer.bindMemory(to: Float.self))
            }
            result = (rate, floats)
        }
        return result
    }

    func hasPeaks(segmentPath: String) -> Bool {
        var found = false
        try? sqlite.query("SELECT 1 FROM segment_peaks WHERE segment_path = ?", [segmentPath]) { _ in found = true }
        return found
    }

    // MARK: - Clips

    func insertClip(_ clip: ClipRecord) {
        try? sqlite.execute(
            """
            INSERT INTO clips (id, path, default_name, display_name, source_start, source_end, duration_seconds, created_at, location_latitude, location_longitude, device_uid)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                clip.id, clip.path, clip.defaultName, clip.displayName,
                clip.sourceStart.timeIntervalSince1970, clip.sourceEnd.timeIntervalSince1970,
                clip.durationSeconds, clip.createdAt.timeIntervalSince1970,
                clip.locationLatitude.asBindable, clip.locationLongitude.asBindable,
                clip.deviceUID.asBindable,
            ]
        )
        // Take the preview snapshot now, while the raw-audio words for this
        // range are certain to still exist.
        snapshotPreviewWordsForClip(id: clip.id, from: clip.sourceStart, to: clip.sourceEnd)
    }

    /// Renames only the display-name column - never touches `path`, so the
    /// clip↔JSON↔transcript linkage (which is keyed by IDs/paths, not name)
    /// can never break via a rename.
    func renameClip(id: String, displayName: String) {
        try? sqlite.execute("UPDATE clips SET display_name = ? WHERE id = ?", [displayName, id])
    }

    /// Corrects a clip row's stored duration - used by a one-time startup
    /// repair pass for clips created before `ClipExporter` started returning
    /// the actually-written duration instead of the requested selection
    /// length (see the corresponding guardrail sign). Never touches `path`
    /// or any other column.
    func updateClipDuration(id: String, durationSeconds: TimeInterval) {
        try? sqlite.execute("UPDATE clips SET duration_seconds = ? WHERE id = ?", [durationSeconds, id])
    }

    func allClips() -> [ClipRecord] {
        var clips: [ClipRecord] = []
        try? sqlite.query("SELECT id, path, default_name, display_name, source_start, source_end, duration_seconds, created_at, location_latitude, location_longitude, device_uid FROM clips ORDER BY created_at DESC") { row in
            guard let id = row.string(0), let path = row.string(1),
                  let defaultName = row.string(2), let displayName = row.string(3),
                  let sourceStart = row.double(4), let sourceEnd = row.double(5),
                  let duration = row.double(6), let createdAt = row.double(7) else { return }
            clips.append(ClipRecord(
                id: id, path: path, defaultName: defaultName, displayName: displayName,
                sourceStart: Date(timeIntervalSince1970: sourceStart),
                sourceEnd: Date(timeIntervalSince1970: sourceEnd),
                durationSeconds: duration,
                createdAt: Date(timeIntervalSince1970: createdAt),
                locationLatitude: row.double(8),
                locationLongitude: row.double(9),
                deviceUID: row.string(10)
            ))
        }
        return clips
    }

    /// Deletes the clip row and its transcript row (if any) - used by the
    /// Library's manual, confirmed delete. Never called by retention.
    func deleteClip(id: String) {
        try? sqlite.execute("DELETE FROM clip_tags WHERE clip_id = ?", [id])
        try? sqlite.execute("DELETE FROM taggings WHERE transcript_id IN (SELECT id FROM transcripts WHERE clip_id = ?)", [id])
        try? sqlite.execute("DELETE FROM summaries WHERE transcript_id IN (SELECT id FROM transcripts WHERE clip_id = ?)", [id])
        try? sqlite.execute("DELETE FROM translations WHERE transcript_id IN (SELECT id FROM transcripts WHERE clip_id = ?)", [id])
        try? sqlite.execute("DELETE FROM transcripts WHERE clip_id = ?", [id])
        // The schema declares ON DELETE CASCADE, but this database runs with
        // SQLite's default `foreign_keys = OFF` - several older tables carry
        // REFERENCES that predate any enforcement, and switching it on
        // globally would start rejecting writes that work today. So the
        // cascade is spelled out, exactly like the related-row cleanup above.
        try? sqlite.execute("DELETE FROM clip_preview_words WHERE clip_id = ?", [id])
        try? sqlite.execute("DELETE FROM clips WHERE id = ?", [id])
    }

    // MARK: - Cost

    /// Records what a step cost, alongside the usage it was derived from.
    /// Written as its own call rather than folded into each step's `update`
    /// because the four tables share exactly this shape - and because a cost
    /// is only ever known *after* the call it describes has already
    /// succeeded and been persisted.
    func updateCost(table: String, id: String, cost: CostRecord) {
        // Table name is interpolated, not bound - SQLite can't parameterize
        // identifiers. Every caller passes one of four literals below; this
        // guard is what keeps it that way if someone adds a fifth.
        guard ["transcripts", "translations", "summaries", "dictations", "taggings"].contains(table) else { return }

        try? sqlite.execute(
            "UPDATE \(table) SET cost_usd = ?, cost_source = ? WHERE id = ?",
            [cost.usd.asBindable, (cost.source?.rawValue).asBindable, id]
        )
        if table == "transcripts" || table == "dictations" {
            try? sqlite.execute("UPDATE \(table) SET billed_seconds = ? WHERE id = ?", [cost.billedSeconds.asBindable, id])
        } else {
            try? sqlite.execute(
                "UPDATE \(table) SET input_tokens = ?, output_tokens = ? WHERE id = ?",
                [cost.inputTokens.asBindable, cost.outputTokens.asBindable, id]
            )
        }
    }

    /// Spend for one model within one category, plus the usage it was
    /// billed on - the numbers behind the money, so a total can be sanity
    /// checked against the provider's own rate rather than taken on faith.
    struct CostTotal: Identifiable {
        let model: String
        let usd: Double
        let calls: Int
        /// True when any call in this total was priced from the rate table
        /// rather than reported by the provider - the whole figure is then
        /// only as good as those rates, and says so.
        let isEstimated: Bool
        /// Audio billed, for speech-to-text. ElevenLabs bills per audio
        /// minute, so this is the unit the price is actually charged in.
        let billedSeconds: Double
        /// Tokens billed, for LLM steps.
        let inputTokens: Int
        let outputTokens: Int

        var id: String { model }

        /// The usage line shown next to the call count. Empty when a total
        /// has no usage recorded (LLM rows from before token tracking).
        var usageSummary: String? {
            if billedSeconds > 0 {
                return String(format: "%@ min", Self.trim(billedSeconds / 60))
            }
            guard inputTokens > 0 || outputTokens > 0 else { return nil }
            return "\(Self.tokens(inputTokens)) in · \(Self.tokens(outputTokens)) out"
        }

        /// Scales the unit to the magnitude. Rendering everything in
        /// millions as literally asked would show a 56-token call as
        /// "0.000056M" - the intent was readability at scale, so small
        /// counts stay whole and only large ones switch units.
        private static func tokens(_ count: Int) -> String {
            if count >= 1_000_000 { return String(format: "%.2fM", Double(count) / 1_000_000) }
            if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
            return "\(count)"
        }

        private static func trim(_ value: Double) -> String {
            value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        }
    }

    /// One row of the Costs section: an artifact kind, broken down by
    /// whichever models actually served it.
    struct CostGroup: Identifiable {
        let title: String
        let totals: [CostTotal]

        var id: String { title }
        var usd: Double { totals.reduce(0) { $0 + $1.usd } }
        var isEstimated: Bool { totals.contains(where: \.isEstimated) }
    }

    /// Everything spent so far, grouped the way the Settings screen shows
    /// it. Rows with no recorded cost are skipped entirely rather than
    /// counted as zero - "not priced" and "free" are different claims, and
    /// summing the former as the latter would quietly understate the total.
    func costSummary() -> [CostGroup] {
        var groups: [CostGroup] = []

        if let transcripts = costTotals(sql: """
            SELECT model, SUM(cost_usd), COUNT(*), SUM(cost_source = 'estimated'),
                   SUM(COALESCE(billed_seconds, 0)), 0, 0
            FROM transcripts WHERE cost_usd IS NOT NULL AND model IS NOT NULL GROUP BY model
            """) {
            groups.append(CostGroup(title: "Transcript", totals: transcripts))
        }

        // Translations are grouped per language, matching how the Library
        // renders one section per language - languages are data, so this
        // discovers them from the rows rather than from a hardcoded list.
        var languages: [String] = []
        try? sqlite.query("SELECT DISTINCT language FROM translations WHERE cost_usd IS NOT NULL ORDER BY language ASC") { row in
            if let language = row.string(0) { languages.append(language) }
        }
        for language in languages {
            if let totals = costTotals(sql: """
                SELECT model, SUM(cost_usd), COUNT(*), SUM(cost_source = 'estimated'),
                       0, SUM(COALESCE(input_tokens, 0)), SUM(COALESCE(output_tokens, 0))
                FROM translations WHERE cost_usd IS NOT NULL AND model IS NOT NULL AND language = ? GROUP BY model
                """, bindings: [language]) {
                groups.append(CostGroup(title: "Translation - \(language.capitalized)", totals: totals))
            }
        }

        if let summaries = costTotals(sql: """
            SELECT model, SUM(cost_usd), COUNT(*), SUM(cost_source = 'estimated'),
                   0, SUM(COALESCE(input_tokens, 0)), SUM(COALESCE(output_tokens, 0))
            FROM summaries WHERE cost_usd IS NOT NULL AND model IS NOT NULL GROUP BY model
            """) {
            groups.append(CostGroup(title: "Summary", totals: summaries))
        }

        if let taggings = costTotals(sql: """
            SELECT model, SUM(cost_usd), COUNT(*), SUM(cost_source = 'estimated'),
                   0, SUM(COALESCE(input_tokens, 0)), SUM(COALESCE(output_tokens, 0))
            FROM taggings WHERE cost_usd IS NOT NULL AND model IS NOT NULL GROUP BY model
            """) {
            groups.append(CostGroup(title: "Tags", totals: taggings))
        }

        if let dictations = costTotals(sql: """
            SELECT model, SUM(cost_usd), COUNT(*), SUM(cost_source = 'estimated'),
                   SUM(COALESCE(billed_seconds, 0)), 0, 0
            FROM dictations WHERE cost_usd IS NOT NULL AND model IS NOT NULL GROUP BY model
            """) {
            groups.append(CostGroup(title: "Dictation", totals: dictations))
        }

        return groups
    }

    private func costTotals(sql: String, bindings: [Bindable] = []) -> [CostTotal]? {
        var totals: [CostTotal] = []
        try? sqlite.query(sql, bindings) { row in
            guard let model = row.string(0), let usd = row.double(1), let calls = row.int(2) else { return }
            totals.append(CostTotal(
                model: model,
                usd: usd,
                calls: calls,
                isEstimated: (row.int(3) ?? 0) > 0,
                billedSeconds: row.double(4) ?? 0,
                inputTokens: row.int(5) ?? 0,
                outputTokens: row.int(6) ?? 0
            ))
        }
        return totals.isEmpty ? nil : totals.sorted { $0.usd > $1.usd }
    }

    // MARK: - Dictations

    private static let dictationColumns = """
        id, path, default_name, display_name, source_start, source_end, duration_seconds, \
        created_at, mode, location_latitude, location_longitude, device_uid, state, error, \
        provider, model, text_path, raw_path, inserted, cost_usd, cost_source, billed_seconds
        """

    /// Inserted the moment the audio export finishes, always in `pending` -
    /// the row exists (and is visible in the Dictations tab) before any
    /// network call, exactly like a clip's. On the realtime path it is
    /// inserted with text already in hand.
    func insertDictation(_ dictation: DictationRecord) {
        try? sqlite.execute(
            """
            INSERT INTO dictations (\(Self.dictationColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                dictation.id, dictation.path, dictation.defaultName, dictation.displayName,
                dictation.sourceStart.timeIntervalSince1970, dictation.sourceEnd.timeIntervalSince1970,
                dictation.durationSeconds, dictation.createdAt.timeIntervalSince1970,
                dictation.mode.rawValue,
                dictation.locationLatitude.asBindable, dictation.locationLongitude.asBindable,
                dictation.deviceUID.asBindable,
                dictation.state.rawValue, dictation.error.asBindable,
                dictation.provider.asBindable, dictation.model.asBindable,
                dictation.textPath.asBindable, dictation.rawPath.asBindable,
                dictation.insertion.rawValue,
                dictation.cost.usd.asBindable,
                (dictation.cost.source?.rawValue).asBindable,
                dictation.cost.billedSeconds.asBindable,
            ]
        )
        // As with clips: snapshot while the source words still exist. A
        // dictation is inserted the instant it's captured, so this is the
        // earliest and safest possible moment.
        snapshotPreviewWordsForDictation(id: dictation.id, from: dictation.sourceStart, to: dictation.sourceEnd)
    }

    func allDictations() -> [DictationRecord] {
        var results: [DictationRecord] = []
        try? sqlite.query("SELECT \(Self.dictationColumns) FROM dictations ORDER BY created_at DESC") { row in
            if let record = Self.dictation(from: row) { results.append(record) }
        }
        return results
    }

    func dictation(id: String) -> DictationRecord? {
        var result: DictationRecord?
        try? sqlite.query("SELECT \(Self.dictationColumns) FROM dictations WHERE id = ?", [id]) { row in
            result = Self.dictation(from: row)
        }
        return result
    }

    private static func dictation(from row: Row) -> DictationRecord? {
        guard let id = row.string(0), let path = row.string(1),
              let defaultName = row.string(2), let displayName = row.string(3),
              let sourceStart = row.double(4), let sourceEnd = row.double(5),
              let duration = row.double(6), let createdAt = row.double(7),
              let modeRaw = row.string(8), let mode = DictationMode(rawValue: modeRaw),
              let stateRaw = row.string(12), let state = PipelineStepState(rawValue: stateRaw)
        else { return nil }
        return DictationRecord(
            id: id,
            path: path,
            defaultName: defaultName,
            displayName: displayName,
            sourceStart: Date(timeIntervalSince1970: sourceStart),
            sourceEnd: Date(timeIntervalSince1970: sourceEnd),
            durationSeconds: duration,
            createdAt: Date(timeIntervalSince1970: createdAt),
            mode: mode,
            locationLatitude: row.double(9),
            locationLongitude: row.double(10),
            deviceUID: row.string(11),
            state: state,
            error: row.string(13),
            provider: row.string(14),
            model: row.string(15),
            textPath: row.string(16),
            rawPath: row.string(17),
            insertion: row.int(18).flatMap(DictationInsertion.init(rawValue:)) ?? .none,
            cost: CostRecord(
                usd: row.double(19),
                source: row.string(20).flatMap(CostSource.init(rawValue:)),
                billedSeconds: row.double(21)
            )
        )
    }

    /// `error`, `textPath` and `rawPath` are doubly-optional so a retry can
    /// explicitly *clear* a previous failure's message (`.some(nil)`) rather
    /// than only ever overwriting it with a new one.
    func updateDictation(
        id: String,
        state: PipelineStepState? = nil,
        error: String?? = nil,
        provider: String? = nil,
        model: String? = nil,
        textPath: String?? = nil,
        rawPath: String?? = nil,
        durationSeconds: TimeInterval? = nil
    ) {
        if let state { try? sqlite.execute("UPDATE dictations SET state = ? WHERE id = ?", [state.rawValue, id]) }
        if let error { try? sqlite.execute("UPDATE dictations SET error = ? WHERE id = ?", [error.asBindable, id]) }
        if let provider { try? sqlite.execute("UPDATE dictations SET provider = ? WHERE id = ?", [provider, id]) }
        if let model { try? sqlite.execute("UPDATE dictations SET model = ? WHERE id = ?", [model, id]) }
        if let textPath { try? sqlite.execute("UPDATE dictations SET text_path = ? WHERE id = ?", [textPath.asBindable, id]) }
        if let rawPath { try? sqlite.execute("UPDATE dictations SET raw_path = ? WHERE id = ?", [rawPath.asBindable, id]) }
        if let durationSeconds { try? sqlite.execute("UPDATE dictations SET duration_seconds = ? WHERE id = ?", [durationSeconds, id]) }
    }

    /// Backfills location/device once the audio export resolves them - on
    /// the realtime path the row is written before the export finishes, so
    /// these arrive late.
    func updateDictationSource(id: String, latitude: Double?, longitude: Double?, deviceUID: String?) {
        try? sqlite.execute(
            """
            UPDATE dictations SET
                location_latitude = COALESCE(?, location_latitude),
                location_longitude = COALESCE(?, location_longitude),
                device_uid = COALESCE(?, device_uid)
            WHERE id = ?
            """,
            [latitude.asBindable, longitude.asBindable, deviceUID.asBindable, id]
        )
    }

    func markDictationInserted(id: String, insertion: DictationInsertion) {
        try? sqlite.execute("UPDATE dictations SET inserted = ? WHERE id = ?", [insertion.rawValue, id])
    }

    /// Renames only the display-name column - never touches `path`, same
    /// rule as `renameClip`.
    func renameDictation(id: String, displayName: String) {
        try? sqlite.execute("UPDATE dictations SET display_name = ? WHERE id = ?", [displayName, id])
    }

    /// Manual, confirmed delete from the Dictations tab. Never called by
    /// retention - nothing sweeps `dictations/`.
    func deleteDictation(id: String) {
        // Spelled-out cascade - see `deleteClip` for why enforcement is off.
        try? sqlite.execute("DELETE FROM dictation_preview_words WHERE dictation_id = ?", [id])
        try? sqlite.execute("DELETE FROM dictations WHERE id = ?", [id])
    }

    // MARK: - Transcripts

    func insertTranscript(_ transcript: TranscriptRecord) {
        try? sqlite.execute(
            """
            INSERT INTO transcripts (id, clip_id, state, error, provider, model, path, speaker_count, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                transcript.id, transcript.clipID,
                transcript.state.rawValue, transcript.error.asBindable,
                transcript.provider.asBindable, transcript.model.asBindable,
                transcript.path.asBindable, transcript.speakerCount.asBindable,
                transcript.createdAt.timeIntervalSince1970,
            ]
        )
    }

    /// Reads back a transcript row by ID - used by `TranscriptionPipeline`
    /// to check state before deciding whether to run/skip the step.
    func transcript(id: String) -> TranscriptRecord? {
        var result: TranscriptRecord?
        try? sqlite.query(
            "SELECT id, clip_id, state, error, provider, model, path, speaker_count, created_at, cost_usd, cost_source, billed_seconds FROM transcripts WHERE id = ?",
            [id]
        ) { row in
            guard let id = row.string(0), let clipID = row.string(1),
                  let stateRaw = row.string(2), let state = PipelineStepState(rawValue: stateRaw),
                  let createdAt = row.double(8) else { return }
            result = TranscriptRecord(
                id: id,
                clipID: clipID,
                state: state,
                error: row.string(3),
                provider: row.string(4),
                model: row.string(5),
                path: row.string(6),
                speakerCount: row.int(7),
                createdAt: Date(timeIntervalSince1970: createdAt),
                cost: CostRecord(
                    usd: row.double(9),
                    source: row.string(10).flatMap(CostSource.init(rawValue:)),
                    billedSeconds: row.double(11)
                )
            )
        }
        return result
    }

    /// The transcript row for a given clip, if one exists - used to resolve
    /// a clip's transcript for the Library and for pipeline retries.
    func transcript(clipID: String) -> TranscriptRecord? {
        var foundID: String?
        try? sqlite.query("SELECT id FROM transcripts WHERE clip_id = ?", [clipID]) { row in
            foundID = row.string(0)
        }
        return foundID.flatMap { transcript(id: $0) }
    }

    func updateTranscript(id: String, state: PipelineStepState? = nil, error: String?? = nil, provider: String? = nil, model: String? = nil, path: String? = nil, speakerCount: Int? = nil) {
        if let state { try? sqlite.execute("UPDATE transcripts SET state = ? WHERE id = ?", [state.rawValue, id]) }
        if let error { try? sqlite.execute("UPDATE transcripts SET error = ? WHERE id = ?", [error.asBindable, id]) }
        if let provider { try? sqlite.execute("UPDATE transcripts SET provider = ? WHERE id = ?", [provider, id]) }
        if let model { try? sqlite.execute("UPDATE transcripts SET model = ? WHERE id = ?", [model, id]) }
        if let path { try? sqlite.execute("UPDATE transcripts SET path = ? WHERE id = ?", [path, id]) }
        if let speakerCount { try? sqlite.execute("UPDATE transcripts SET speaker_count = ? WHERE id = ?", [speakerCount, id]) }
    }

    // MARK: - Translations

    /// Creates the row for a target language if it doesn't exist yet -
    /// deterministic ID (`<transcriptID>-<language>`) so re-running the
    /// pipeline never duplicates a translation.
    func ensureTranslationRow(transcriptID: String, language: String) {
        try? sqlite.execute(
            """
            INSERT INTO translations (id, transcript_id, language, state, created_at)
            VALUES (?, ?, ?, 'pending', ?)
            ON CONFLICT(id) DO NOTHING
            """,
            [translationID(transcriptID: transcriptID, language: language), transcriptID, language, Date().timeIntervalSince1970]
        )
    }

    func translationID(transcriptID: String, language: String) -> String {
        "\(transcriptID)-\(language)"
    }

    func translations(transcriptID: String) -> [TranslationRecord] {
        var results: [TranslationRecord] = []
        try? sqlite.query(
            "SELECT id, transcript_id, language, state, error, provider, model, path, created_at, cost_usd, cost_source, input_tokens, output_tokens FROM translations WHERE transcript_id = ? ORDER BY created_at ASC, language ASC",
            [transcriptID]
        ) { row in
            guard let id = row.string(0), let transcriptID = row.string(1),
                  let language = row.string(2),
                  let stateRaw = row.string(3), let state = PipelineStepState(rawValue: stateRaw),
                  let createdAt = row.double(8) else { return }
            results.append(TranslationRecord(
                id: id,
                transcriptID: transcriptID,
                language: language,
                state: state,
                error: row.string(4),
                provider: row.string(5),
                model: row.string(6),
                path: row.string(7),
                createdAt: Date(timeIntervalSince1970: createdAt),
                cost: CostRecord(
                    usd: row.double(9),
                    source: row.string(10).flatMap(CostSource.init(rawValue:)),
                    inputTokens: row.int(11),
                    outputTokens: row.int(12)
                )
            ))
        }
        return results
    }

    func translation(id: String) -> TranslationRecord? {
        var result: TranslationRecord?
        try? sqlite.query(
            "SELECT id, transcript_id, language, state, error, provider, model, path, created_at, cost_usd, cost_source, input_tokens, output_tokens FROM translations WHERE id = ?",
            [id]
        ) { row in
            guard let id = row.string(0), let transcriptID = row.string(1),
                  let language = row.string(2),
                  let stateRaw = row.string(3), let state = PipelineStepState(rawValue: stateRaw),
                  let createdAt = row.double(8) else { return }
            result = TranslationRecord(
                id: id,
                transcriptID: transcriptID,
                language: language,
                state: state,
                error: row.string(4),
                provider: row.string(5),
                model: row.string(6),
                path: row.string(7),
                createdAt: Date(timeIntervalSince1970: createdAt),
                cost: CostRecord(
                    usd: row.double(9),
                    source: row.string(10).flatMap(CostSource.init(rawValue:)),
                    inputTokens: row.int(11),
                    outputTokens: row.int(12)
                )
            )
        }
        return result
    }

    func updateTranslation(id: String, state: PipelineStepState? = nil, error: String?? = nil, provider: String? = nil, model: String? = nil, path: String? = nil) {
        if let state { try? sqlite.execute("UPDATE translations SET state = ? WHERE id = ?", [state.rawValue, id]) }
        if let error { try? sqlite.execute("UPDATE translations SET error = ? WHERE id = ?", [error.asBindable, id]) }
        if let provider { try? sqlite.execute("UPDATE translations SET provider = ? WHERE id = ?", [provider, id]) }
        if let model { try? sqlite.execute("UPDATE translations SET model = ? WHERE id = ?", [model, id]) }
        if let path { try? sqlite.execute("UPDATE translations SET path = ? WHERE id = ?", [path, id]) }
    }

    // MARK: - Summaries

    /// Creates the summary row for a transcript+preset if it doesn't exist
    /// yet - deterministic ID so re-running the pipeline never duplicates it.
    func ensureSummaryRow(transcriptID: String, preset: SummaryPreset = .overview) {
        try? sqlite.execute(
            """
            INSERT INTO summaries (id, transcript_id, preset, state, created_at)
            VALUES (?, ?, ?, 'pending', ?)
            ON CONFLICT(id) DO NOTHING
            """,
            [
                summaryID(transcriptID: transcriptID, preset: preset),
                transcriptID,
                preset.rawValue,
                Date().timeIntervalSince1970,
            ]
        )
    }

    /// The overview keeps its original unsuffixed ID so every summary written
    /// before presets existed still resolves.
    func summaryID(transcriptID: String, preset: SummaryPreset = .overview) -> String {
        preset.isDefault ? "\(transcriptID)-summary" : "\(transcriptID)-summary-\(preset.rawValue)"
    }

    func summary(transcriptID: String, preset: SummaryPreset = .overview) -> SummaryRecord? {
        summary(id: summaryID(transcriptID: transcriptID, preset: preset))
    }

    /// Every summary this transcript has, overview first and the rest in
    /// declaration order, so the detail view's sections don't reshuffle when
    /// a preset finishes out of order.
    func summaries(transcriptID: String) -> [SummaryRecord] {
        var result: [SummaryRecord] = []
        try? sqlite.query(
            "SELECT \(Self.summaryColumns) FROM summaries WHERE transcript_id = ?",
            [transcriptID]
        ) { row in
            if let record = Self.summaryRecord(from: row) { result.append(record) }
        }
        let order = SummaryPreset.allCases
        return result.sorted {
            (order.firstIndex(of: $0.preset) ?? 0) < (order.firstIndex(of: $1.preset) ?? 0)
        }
    }

    static let summaryColumns =
        "id, transcript_id, preset, translation_id, state, error, provider, model, path, created_at, "
        + "cost_usd, cost_source, input_tokens, output_tokens"

    static func summaryRecord(from row: Row) -> SummaryRecord? {
        guard let id = row.string(0), let transcriptID = row.string(1),
              let stateRaw = row.string(4), let state = PipelineStepState(rawValue: stateRaw),
              let createdAt = row.double(9) else { return nil }
        return SummaryRecord(
            id: id,
            transcriptID: transcriptID,
            preset: SummaryPreset.from(row.string(2)),
            translationID: row.string(3),
            state: state,
            error: row.string(5),
            provider: row.string(6),
            model: row.string(7),
            path: row.string(8),
            createdAt: Date(timeIntervalSince1970: createdAt),
            cost: CostRecord(
                usd: row.double(10),
                source: row.string(11).flatMap(CostSource.init(rawValue:)),
                inputTokens: row.int(12),
                outputTokens: row.int(13)
            )
        )
    }

    func summary(id: String) -> SummaryRecord? {
        var result: SummaryRecord?
        try? sqlite.query("SELECT \(Self.summaryColumns) FROM summaries WHERE id = ?", [id]) { row in
            result = Self.summaryRecord(from: row)
        }
        return result
    }

    /// `translationID` is doubly-optional like `error`: `.some(nil)` clears
    /// it (summary re-run from the original transcript), `.some(id)` records
    /// the source translation, `nil` leaves it untouched.
    func updateSummary(id: String, state: PipelineStepState? = nil, error: String?? = nil, translationID: String?? = nil, provider: String? = nil, model: String? = nil, path: String? = nil) {
        if let state { try? sqlite.execute("UPDATE summaries SET state = ? WHERE id = ?", [state.rawValue, id]) }
        if let error { try? sqlite.execute("UPDATE summaries SET error = ? WHERE id = ?", [error.asBindable, id]) }
        if let translationID { try? sqlite.execute("UPDATE summaries SET translation_id = ? WHERE id = ?", [translationID.asBindable, id]) }
        if let provider { try? sqlite.execute("UPDATE summaries SET provider = ? WHERE id = ?", [provider, id]) }
        if let model { try? sqlite.execute("UPDATE summaries SET model = ? WHERE id = ?", [model, id]) }
        if let path { try? sqlite.execute("UPDATE summaries SET path = ? WHERE id = ?", [path, id]) }
    }

    // MARK: - Tags

    func allTags() -> [TagRecord] {
        var tags: [TagRecord] = []
        try? sqlite.query(
            "SELECT id, name, color_key, auto_created, created_at FROM tags ORDER BY lower(name) ASC"
        ) { row in
            guard let id = row.string(0), let name = row.string(1), let createdAt = row.double(4) else { return }
            tags.append(TagRecord(
                id: id,
                name: name,
                colorKey: row.string(2),
                isAutoCreated: (row.int(3) ?? 0) == 1,
                createdAt: Date(timeIntervalSince1970: createdAt)
            ))
        }
        return tags
    }

    /// Inserts if the name is new, returns the existing row if it isn't.
    /// Case-insensitive, because "Hiring" and "hiring" are one tag and
    /// letting both exist is how a vocabulary quietly rots.
    @discardableResult
    func upsertTag(name: String, colorKey: String? = nil, isAutoCreated: Bool = false) -> TagRecord? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = tag(named: trimmed) { return existing }
        let record = TagRecord(
            id: UUID().uuidString,
            name: trimmed,
            colorKey: colorKey,
            isAutoCreated: isAutoCreated,
            createdAt: Date()
        )
        try? sqlite.execute(
            "INSERT INTO tags (id, name, color_key, auto_created, created_at) VALUES (?, ?, ?, ?, ?)",
            [record.id, record.name, record.colorKey.asBindable, record.isAutoCreated ? 1 : 0, record.createdAt.timeIntervalSince1970]
        )
        return tag(named: trimmed)
    }

    func tag(named name: String) -> TagRecord? {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allTags().first { $0.name.lowercased() == target }
    }

    /// Renaming into an existing name would break the unique index, so the
    /// caller is told rather than silently losing the edit.
    @discardableResult
    func renameTag(id: String, name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let clash = tag(named: trimmed), clash.id != id { return false }
        try? sqlite.execute(
            "UPDATE tags SET name = ?, auto_created = 0 WHERE id = ?",
            [trimmed, id]
        )
        return true
    }

    func updateTagColor(id: String, colorKey: String?) {
        try? sqlite.execute("UPDATE tags SET color_key = ? WHERE id = ?", [colorKey.asBindable, id])
    }

    /// Deleting a tag unassigns it everywhere. That is the whole contract -
    /// there is no orphaned state to reconcile afterwards.
    func deleteTag(id: String) {
        try? sqlite.execute("DELETE FROM clip_tags WHERE tag_id = ?", [id])
        try? sqlite.execute("DELETE FROM tags WHERE id = ?", [id])
    }

    /// Tag IDs per clip, for every clip at once - the Library renders tags on
    /// every row, and a query per row would be one per clip per reload.
    func allClipTagIDs() -> [String: [String]] {
        var result: [String: [String]] = [:]
        try? sqlite.query("SELECT clip_id, tag_id FROM clip_tags") { row in
            guard let clipID = row.string(0), let tagID = row.string(1) else { return }
            result[clipID, default: []].append(tagID)
        }
        return result
    }

    /// One clip's tags with everything an export needs: the name (which is
    /// the identity across devices - IDs are local and meaningless
    /// elsewhere), the colour so the same tag looks the same on the other
    /// side, and the source so a re-tag over there replaces exactly what a
    /// re-tag over here would have.
    func clipTagsForExport(clipID: String) -> [(name: String, colorKey: String?, source: String)] {
        var result: [(name: String, colorKey: String?, source: String)] = []
        try? sqlite.query(
            """
            SELECT tags.name, tags.color_key, clip_tags.source
            FROM clip_tags JOIN tags ON tags.id = clip_tags.tag_id
            WHERE clip_tags.clip_id = ?
            ORDER BY tags.name
            """,
            [clipID]
        ) { row in
            guard let name = row.string(0) else { return }
            result.append((name: name, colorKey: row.string(1), source: row.string(2) ?? TagSource.manual.rawValue))
        }
        return result
    }

    /// How many clips carry each tag - the manager's usage counts, and what
    /// makes an unused tag obvious enough to delete.
    func tagUsageCounts() -> [String: Int] {
        var result: [String: Int] = [:]
        try? sqlite.query("SELECT tag_id, COUNT(*) FROM clip_tags GROUP BY tag_id") { row in
            guard let tagID = row.string(0), let count = row.int(1) else { return }
            result[tagID] = count
        }
        return result
    }

    func assignTag(clipID: String, tagID: String, source: TagSource) {
        try? sqlite.execute(
            """
            INSERT INTO clip_tags (clip_id, tag_id, source, created_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(clip_id, tag_id) DO UPDATE SET source = excluded.source
            """,
            [clipID, tagID, source.rawValue, Date().timeIntervalSince1970]
        )
    }

    func unassignTag(clipID: String, tagID: String) {
        try? sqlite.execute("DELETE FROM clip_tags WHERE clip_id = ? AND tag_id = ?", [clipID, tagID])
    }

    /// Clears only what the model put there. A re-run rebuilds its own
    /// choices from scratch; anything the user assigned by hand survives it.
    func clearAutoTags(clipID: String) {
        try? sqlite.execute("DELETE FROM clip_tags WHERE clip_id = ? AND source = ?", [clipID, TagSource.auto.rawValue])
    }

    // MARK: - Taggings (the auto-tagging step)

    private static let taggingColumns =
        "id, transcript_id, state, error, provider, model, created_at, cost_usd, cost_source, input_tokens, output_tokens"

    /// Deterministic ID so re-running never duplicates the row.
    func taggingID(transcriptID: String) -> String { "\(transcriptID)-tags" }

    func ensureTaggingRow(transcriptID: String) {
        try? sqlite.execute(
            """
            INSERT INTO taggings (id, transcript_id, state, created_at)
            VALUES (?, ?, 'pending', ?)
            ON CONFLICT(id) DO NOTHING
            """,
            [taggingID(transcriptID: transcriptID), transcriptID, Date().timeIntervalSince1970]
        )
    }

    func tagging(transcriptID: String) -> TaggingRecord? {
        var result: TaggingRecord?
        try? sqlite.query(
            "SELECT \(Self.taggingColumns) FROM taggings WHERE id = ?",
            [taggingID(transcriptID: transcriptID)]
        ) { row in
            result = Self.tagging(from: row)
        }
        return result
    }

    /// Every tagging row, grouped by transcript - same reason as
    /// `allClipTagIDs`: the Library needs all of them at once.
    func allTaggings() -> [String: TaggingRecord] {
        var result: [String: TaggingRecord] = [:]
        try? sqlite.query("SELECT \(Self.taggingColumns) FROM taggings") { row in
            guard let record = Self.tagging(from: row) else { return }
            result[record.transcriptID] = record
        }
        return result
    }

    private static func tagging(from row: Row) -> TaggingRecord? {
        guard let id = row.string(0), let transcriptID = row.string(1),
              let stateRaw = row.string(2), let state = PipelineStepState(rawValue: stateRaw),
              let createdAt = row.double(6) else { return nil }
        return TaggingRecord(
            id: id,
            transcriptID: transcriptID,
            state: state,
            error: row.string(3),
            provider: row.string(4),
            model: row.string(5),
            createdAt: Date(timeIntervalSince1970: createdAt),
            cost: CostRecord(
                usd: row.double(7),
                source: row.string(8).flatMap(CostSource.init(rawValue:)),
                inputTokens: row.int(9),
                outputTokens: row.int(10)
            )
        )
    }

    func updateTagging(id: String, state: PipelineStepState? = nil, error: String?? = nil, provider: String? = nil, model: String? = nil) {
        if let state { try? sqlite.execute("UPDATE taggings SET state = ? WHERE id = ?", [state.rawValue, id]) }
        if let error { try? sqlite.execute("UPDATE taggings SET error = ? WHERE id = ?", [error.asBindable, id]) }
        if let provider { try? sqlite.execute("UPDATE taggings SET provider = ? WHERE id = ?", [provider, id]) }
        if let model { try? sqlite.execute("UPDATE taggings SET model = ? WHERE id = ?", [model, id]) }
    }

    // MARK: - Places & geocodes

    func allPlaces() -> [PlaceRecord] {
        var places: [PlaceRecord] = []
        try? sqlite.query(
            "SELECT id, name, latitude, longitude, radius_meters, created_at, updated_at FROM places ORDER BY name ASC"
        ) { row in
            guard let id = row.string(0), let name = row.string(1),
                  let latitude = row.double(2), let longitude = row.double(3),
                  let radius = row.double(4), let createdAt = row.double(5),
                  let updatedAt = row.double(6) else { return }
            places.append(PlaceRecord(
                id: id,
                name: name,
                latitude: latitude,
                longitude: longitude,
                radiusMeters: radius,
                createdAt: Date(timeIntervalSince1970: createdAt),
                updatedAt: Date(timeIntervalSince1970: updatedAt)
            ))
        }
        return places
    }

    /// Insert-or-replace by ID. Editing an existing place keeps its ID, so
    /// every recording it already claimed stays claimed (and every recording
    /// a widened radius now reaches joins it) with no other write.
    func upsertPlace(_ place: PlaceRecord) {
        try? sqlite.execute(
            """
            INSERT INTO places (id, name, latitude, longitude, radius_meters, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                latitude = excluded.latitude,
                longitude = excluded.longitude,
                radius_meters = excluded.radius_meters,
                updated_at = excluded.updated_at
            """,
            [
                place.id, place.name, place.latitude, place.longitude,
                place.radiusMeters,
                place.createdAt.timeIntervalSince1970,
                place.updatedAt.timeIntervalSince1970,
            ]
        )
    }

    /// Drops a place entirely. Every recording inside it reverts to the
    /// OS-detected name on the next read - there is nothing else to undo,
    /// which is the whole point of resolving names at read time.
    func deletePlace(id: String) {
        try? sqlite.execute("DELETE FROM places WHERE id = ?", [id])
    }

    func allGeocodes() -> [String: GeocodeRecord] {
        var result: [String: GeocodeRecord] = [:]
        try? sqlite.query("SELECT cell, name, context FROM geocodes") { row in
            guard let cell = row.string(0), let name = row.string(1) else { return }
            result[cell] = GeocodeRecord(cell: cell, name: name, context: row.string(2))
        }
        return result
    }

    /// Drops every cached OS name. Safe by construction: nothing here is
    /// user-authored - it is all re-derivable from coordinates.
    func clearGeocodes() {
        try? sqlite.execute("DELETE FROM geocodes")
    }

    func storeGeocode(_ geocode: GeocodeRecord) {
        try? sqlite.execute(
            """
            INSERT INTO geocodes (cell, name, context, resolved_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(cell) DO UPDATE SET
                name = excluded.name,
                context = excluded.context,
                resolved_at = excluded.resolved_at
            """,
            [geocode.cell, geocode.name, geocode.context.asBindable, Date().timeIntervalSince1970]
        )
    }

    /// Every coordinate any clip or dictation carries. Feeds both the
    /// "applies to N recordings" count in the place editor and the
    /// background geocoder's work list.
    func taggedCoordinates() -> [(latitude: Double, longitude: Double)] {
        var result: [(Double, Double)] = []
        try? sqlite.query(
            """
            SELECT location_latitude, location_longitude FROM clips
            WHERE location_latitude IS NOT NULL AND location_longitude IS NOT NULL
            UNION ALL
            SELECT location_latitude, location_longitude FROM dictations
            WHERE location_latitude IS NOT NULL AND location_longitude IS NOT NULL
            """
        ) { row in
            guard let latitude = row.double(0), let longitude = row.double(1) else { return }
            result.append((latitude, longitude))
        }
        return result
    }

    /// One located recording, whichever table it lives in - the Places tab
    /// lists what a place actually contains, and a place doesn't care
    /// whether something was a clip or a dictation.
    struct TaggedEntry: Identifiable {
        enum Kind: String { case clip, dictation }
        let id: String
        let kind: Kind
        let displayName: String
        let sourceStart: Date
        let latitude: Double
        let longitude: Double
    }

    func taggedEntries() -> [TaggedEntry] {
        var result: [TaggedEntry] = []
        try? sqlite.query(
            """
            SELECT id, 'clip', display_name, source_start, location_latitude, location_longitude FROM clips
            WHERE location_latitude IS NOT NULL AND location_longitude IS NOT NULL
            UNION ALL
            SELECT id, 'dictation', display_name, source_start, location_latitude, location_longitude FROM dictations
            WHERE location_latitude IS NOT NULL AND location_longitude IS NOT NULL
            ORDER BY 4 DESC
            """
        ) { row in
            guard let id = row.string(0), let kindRaw = row.string(1),
                  let kind = TaggedEntry.Kind(rawValue: kindRaw),
                  let displayName = row.string(2), let sourceStart = row.double(3),
                  let latitude = row.double(4), let longitude = row.double(5) else { return }
            result.append(TaggedEntry(
                id: id,
                kind: kind,
                displayName: displayName,
                sourceStart: Date(timeIntervalSince1970: sourceStart),
                latitude: latitude,
                longitude: longitude
            ))
        }
        return result
    }

    // MARK: - Sessions

    func insertSession(_ session: SessionRecord) {
        try? sqlite.execute(
            "INSERT INTO sessions (id, started_at, ended_at, device_uid) VALUES (?, ?, ?, ?)",
            [session.id, session.startedAt.timeIntervalSince1970, session.endedAt.map { $0.timeIntervalSince1970 }.asBindable, session.deviceUID]
        )
    }

    func closeSession(id: String, endedAt: Date) {
        try? sqlite.execute("UPDATE sessions SET ended_at = ? WHERE id = ?", [endedAt.timeIntervalSince1970, id])
    }
}
