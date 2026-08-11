import Foundation

/// Import/export failed for a reason worth showing the user verbatim.
struct ClipArchiveError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The portable form of one Library clip - `<name>.worklog.zip` - written and
/// read identically by the macOS and Android apps. The contract lives in
/// `docs/clip-archive-format.md` (kept in both repos); this file is its macOS
/// implementation: entry names and the manifest model. Zip mechanics live in
/// `ClipArchiveExporter` / `ClipImporter`.
enum ClipArchive {
    static let format = "worklog-clip"
    static let version = 1

    static let manifestEntry = "manifest.json"
    static let audioEntry = "audio.m4a"
    static let transcriptEntry = "transcript.json"
    static let transcriptTextEntry = "transcript.txt"

    static func translationEntry(language: String) -> String {
        "translation-\(language).md"
    }

    /// Always suffixed in the archive - `summary-overview.md` - even though
    /// the overview is stored unsuffixed locally. The manifest maps names,
    /// so readers never have to know either convention.
    static func summaryEntry(presetID: String) -> String {
        "summary-\(presetID).md"
    }

    /// File-name-safe rendering of a clip name for the exported zip.
    static func archiveFileName(displayName: String) -> String {
        var cleaned = displayName
        for character in "\\/:*?\"<>|" {
            cleaned = cleaned.replacingOccurrences(of: String(character), with: " ")
        }
        cleaned = cleaned
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        cleaned = String(cleaned.prefix(60))
        return "\(cleaned.isEmpty ? "Clip" : cleaned).worklog.zip"
    }

    /// True when `name` is safe to consume as a zip entry: a plain file name
    /// with no path structure - the archive's zip-slip guard.
    static func isPlainEntryName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\") && !name.contains("..")
    }

    /// Human-readable ISO-8601 companion to the authoritative epoch-millis
    /// fields - written for people reading the manifest, never parsed back.
    static func isoTimestamp(millis: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }

    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(fromMillis millis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(millis) / 1000)
    }
}

// MARK: - Manifest model (Codable field names ARE the format - see the doc)

/// Cost provenance exactly as the rows store it; `source` stays a raw string
/// ("reported"/"estimated") so an unknown future value survives a round trip.
struct ArchiveCost: Codable {
    var usd: Double?
    var source: String?
    var billedSeconds: Double?
    var inputTokens: Int?
    var outputTokens: Int?

    init?(_ cost: CostRecord) {
        if cost.usd == nil, cost.source == nil, cost.billedSeconds == nil,
           cost.inputTokens == nil, cost.outputTokens == nil {
            return nil
        }
        usd = cost.usd
        source = cost.source?.rawValue
        billedSeconds = cost.billedSeconds
        inputTokens = cost.inputTokens
        outputTokens = cost.outputTokens
    }

    var costRecord: CostRecord {
        CostRecord(
            usd: usd,
            source: source.flatMap(CostSource.init(rawValue:)),
            billedSeconds: billedSeconds,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
    }
}

struct ArchiveLocation: Codable {
    var latitude: Double
    var longitude: Double
}

struct ArchiveClipInfo: Codable {
    var id: String
    var defaultName: String?
    var displayName: String?
    var createdAtMillis: Int64?
    var createdAt: String?
    var sourceStartMillis: Int64?
    var sourceEndMillis: Int64?
    var durationSeconds: Double?
    var audioFile: String
    var deviceUid: String?
    var location: ArchiveLocation?
}

struct ArchiveTranscript: Codable {
    var id: String?
    var file: String
    var textFile: String?
    var provider: String?
    var model: String?
    var speakerCount: Int?
    var cost: ArchiveCost?
}

struct ArchiveTranslation: Codable {
    var language: String
    var file: String
    var provider: String?
    var model: String?
    var cost: ArchiveCost?
}

struct ArchiveSummary: Codable {
    var preset: String
    var file: String
    var translationLanguage: String?
    var provider: String?
    var model: String?
    var cost: ArchiveCost?
}

/// A tag travelling with a clip.
///
/// Carried by **name**, never by ID: tag IDs are local rows and mean nothing
/// on the importing device. The importer matches an existing tag of the same
/// name or creates one, so a clip lands in whatever vocabulary is already
/// there rather than dragging a parallel one in behind it.
///
/// Deliberately unlike a place, which is *not* in the archive at all: a place
/// is a fact about the importer's world, so it is recomputed from the clip's
/// coordinates against their own places. A tag is a fact about the clip, so
/// it travels with it.
struct ArchiveTag: Codable {
    var name: String
    /// A hint, applied only when the importer has to create this tag. An
    /// existing local tag keeps the colour its owner chose.
    var color: String?
    /// `manual` or `auto`. Preserved so re-running tagging on the importing
    /// side replaces exactly what it would have replaced on the exporting
    /// side - without it, imported auto-tags would be indistinguishable from
    /// hand-picked ones and would pile up on every re-tag.
    var source: String?
}

/// One word of the on-device preview, on the archive's millisecond clock.
struct ArchivePreviewWord: Codable {
    var startMillis: Int64
    var endMillis: Int64
    var text: String
    var engine: String?
}

struct ArchiveManifest: Codable {
    var format: String
    var version: Int
    var exportedAtMillis: Int64?
    var exportedAt: String?
    var exportedBy: String?
    var clip: ArchiveClipInfo
    var transcript: ArchiveTranscript?
    var translations: [ArchiveTranslation]?
    var summaries: [ArchiveSummary]?
    /// Optional, and the format version is deliberately *not* bumped for it:
    /// readers reject a manifest newer than they understand, so a bump would
    /// make every already-installed build refuse files it can otherwise read
    /// perfectly well. An unknown key is ignored by both decoders, so old
    /// readers skip the tags and new readers pick them up.
    var tags: [ArchiveTag]?
    /// The on-device preview transcript, carried for the same reason it is
    /// kept forever on the clip itself: it is the only record of what the
    /// recording device heard, and an archive without it arrives missing
    /// half of what the clip knew. Optional and version-neutral, exactly
    /// like `tags` above.
    var previewWords: [ArchivePreviewWord]?

    /// Every file the archive promises. Validated as plain names on parse.
    var referencedFiles: [String] {
        [clip.audioFile]
            + (transcript.map { [$0.file] } ?? [])
            + (translations ?? []).map(\.file)
            + (summaries ?? []).map(\.file)
    }

    static func parse(_ data: Data) throws -> ArchiveManifest {
        guard let manifest = try? JSONDecoder().decode(ArchiveManifest.self, from: data) else {
            throw ClipArchiveError(message: "This zip isn't a Worklog clip export.")
        }
        guard manifest.format == ClipArchive.format else {
            throw ClipArchiveError(message: "This zip isn't a Worklog clip export.")
        }
        guard manifest.version <= ClipArchive.version else {
            throw ClipArchiveError(
                message: "This clip was exported by a newer Worklog - update this app to import it."
            )
        }
        for name in manifest.referencedFiles where !ClipArchive.isPlainEntryName(name) {
            throw ClipArchiveError(message: "The manifest references an unsafe file name (\u{201c}\(name)\u{201d}).")
        }
        return manifest
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
