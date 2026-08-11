import Foundation

/// Builds a clip's `.worklog.zip` (see `ClipArchive`) in a temp folder,
/// ready to hand to the share picker. Exports what has *succeeded*: pending
/// or failed pipeline steps simply aren't in the archive, and the importing
/// side runs whatever is missing through its own pipeline.
enum ClipArchiveExporter {

    /// Heavy (reads the whole clip folder, then zips it) - call from a
    /// background task. Row reads hop to the main actor, matching how the
    /// rest of the app talks to `WorklogDatabase`.
    static func export(clipID: String) async throws -> URL {
        struct Gathered {
            let clip: ClipRecord
            let transcript: TranscriptRecord?
            let translations: [TranslationRecord]
            let summaries: [SummaryRecord]
            let manifest: ArchiveManifest
        }

        let gathered: Gathered = try await MainActor.run {
            let db = WorklogDatabase.shared
            guard let clip = db.allClips().first(where: { $0.id == clipID }) else {
                throw ClipArchiveError(message: "This clip no longer exists.")
            }
            guard FileManager.default.fileExists(atPath: clip.path) else {
                throw ClipArchiveError(message: "This clip's audio file is missing on disk.")
            }

            let transcript = db.transcript(clipID: clipID)
                .flatMap { record -> TranscriptRecord? in
                    guard record.state == .succeeded, let path = record.path,
                          FileManager.default.fileExists(atPath: path) else { return nil }
                    return record
                }
            // Unfiltered map first: a summary may reference a translation
            // that itself isn't exportable, and that mapping shouldn't
            // invent one.
            let allTranslations = transcript.map { db.translations(transcriptID: $0.id) } ?? []
            let translations = allTranslations.filter { $0.exportable }
            let exportedLanguages = Set(translations.map(\.language))
            let summaries = (transcript.map { db.summaries(transcriptID: $0.id) } ?? [])
                .filter { $0.exportable }

            let now = ClipArchive.millis(Date())
            let manifest = ArchiveManifest(
                format: ClipArchive.format,
                version: ClipArchive.version,
                exportedAtMillis: now,
                exportedAt: ClipArchive.isoTimestamp(millis: now),
                exportedBy: "worklog-mac",
                clip: ArchiveClipInfo(
                    id: clip.id,
                    defaultName: clip.defaultName,
                    displayName: clip.displayName,
                    createdAtMillis: ClipArchive.millis(clip.createdAt),
                    createdAt: ClipArchive.isoTimestamp(millis: ClipArchive.millis(clip.createdAt)),
                    sourceStartMillis: ClipArchive.millis(clip.sourceStart),
                    sourceEndMillis: ClipArchive.millis(clip.sourceEnd),
                    durationSeconds: clip.durationSeconds,
                    audioFile: ClipArchive.audioEntry,
                    deviceUid: clip.deviceUID,
                    location: clip.locationLatitude.flatMap { lat in
                        clip.locationLongitude.map { lon in
                            ArchiveLocation(latitude: lat, longitude: lon)
                        }
                    }
                ),
                transcript: transcript.map {
                    ArchiveTranscript(
                        id: $0.id,
                        file: ClipArchive.transcriptEntry,
                        textFile: ClipArchive.transcriptTextEntry,
                        provider: $0.provider,
                        model: $0.model,
                        speakerCount: $0.speakerCount,
                        cost: ArchiveCost($0.cost)
                    )
                },
                translations: translations.map {
                    ArchiveTranslation(
                        language: $0.language,
                        file: ClipArchive.translationEntry(language: $0.language),
                        provider: $0.provider,
                        model: $0.model,
                        cost: ArchiveCost($0.cost)
                    )
                },
                summaries: summaries.map { summary in
                    ArchiveSummary(
                        preset: summary.preset.rawValue,
                        file: ClipArchive.summaryEntry(presetID: summary.preset.rawValue),
                        // Only name a derivation source that made it into the
                        // archive - otherwise the importer would link a
                        // summary to a translation that isn't there.
                        translationLanguage: summary.translationID
                            .flatMap { id in allTranslations.first { $0.id == id }?.language }
                            .flatMap { exportedLanguages.contains($0) ? $0 : nil },
                        provider: summary.provider,
                        model: summary.model,
                        cost: ArchiveCost(summary.cost)
                    )
                },
                // Tags travel; the place does not. A tag is something
                // somebody decided about this recording, so it belongs to
                // the recording. A place is a fact about whose library the
                // clip is sitting in, so the importer works it out from the
                // coordinates above against their own places.
                tags: db.clipTagsForExport(clipID: clipID).map {
                    ArchiveTag(name: $0.name, color: $0.colorKey, source: $0.source)
                },
                previewWords: db.clipPreviewWords(clipID: clipID).map {
                    ArchivePreviewWord(
                        startMillis: Int64($0.start.timeIntervalSince1970 * 1000),
                        endMillis: Int64($0.end.timeIntervalSince1970 * 1000),
                        text: $0.text,
                        engine: nil
                    )
                }
            )
            return Gathered(
                clip: clip,
                transcript: transcript,
                translations: translations,
                summaries: summaries,
                manifest: manifest
            )
        }

        // Everything below is file work - stays off the main actor.
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("worklog-export-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        try gathered.manifest.encoded()
            .write(to: staging.appendingPathComponent(ClipArchive.manifestEntry))
        try fileManager.copyItem(
            at: URL(fileURLWithPath: gathered.clip.path),
            to: staging.appendingPathComponent(ClipArchive.audioEntry)
        )
        if let transcript = gathered.transcript, let path = transcript.path {
            try fileManager.copyItem(
                at: URL(fileURLWithPath: path),
                to: staging.appendingPathComponent(ClipArchive.transcriptEntry)
            )
            // Rendered plain text is a courtesy for humans unzipping by
            // hand; a transcript that won't parse just means it's skipped.
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let parsed = try? JSONDecoder().decode(TranscriptResponse.self, from: data) {
                try? TranscriptFormatter.displayTranscript(parsed)
                    .data(using: .utf8)?
                    .write(to: staging.appendingPathComponent(ClipArchive.transcriptTextEntry))
            }
        }
        for translation in gathered.translations {
            guard let path = translation.path else { continue }
            try fileManager.copyItem(
                at: URL(fileURLWithPath: path),
                to: staging.appendingPathComponent(ClipArchive.translationEntry(language: translation.language))
            )
        }
        for summary in gathered.summaries {
            guard let path = summary.path else { continue }
            try fileManager.copyItem(
                at: URL(fileURLWithPath: path),
                to: staging.appendingPathComponent(ClipArchive.summaryEntry(presetID: summary.preset.rawValue))
            )
        }

        // The zip gets its own folder so the user-facing file name is free
        // of uniquing suffixes.
        let shareFolder = fileManager.temporaryDirectory
            .appendingPathComponent("worklog-share-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: shareFolder, withIntermediateDirectories: true)
        let destination = shareFolder
            .appendingPathComponent(ClipArchive.archiveFileName(displayName: gathered.clip.displayName))

        // Archives the *contents* of the staging folder as top-level entries
        // - exactly the flat layout the format requires, and byte-compatible
        // with the `ditto -c -k` archives the macOS build writes.
        do {
            try ZipArchive.zip(contentsOf: staging, to: destination)
        } catch {
            throw ClipArchiveError(message: "Couldn't build the export zip.")
        }
        return destination
    }

}

private extension TranslationRecord {
    var exportable: Bool {
        state == .succeeded && path.map { FileManager.default.fileExists(atPath: $0) } == true
    }
}

private extension SummaryRecord {
    var exportable: Bool {
        state == .succeeded && path.map { FileManager.default.fileExists(atPath: $0) } == true
    }
}
