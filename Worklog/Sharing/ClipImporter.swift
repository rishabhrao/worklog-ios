import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// The Library's import entry point: takes whatever the user picked -
/// `.worklog.zip` exports or bare audio files - and lands each one as a
/// Library clip.
///
/// Dispatch is by content, never by name: bytes starting `PK\x03\x04` are a
/// zip (and must carry a valid manifest); anything else goes to the audio
/// importer, which normalizes it into the library's canonical AAC `.m4a`
/// and queues the regular pipeline.
enum ClipImporter {

    enum Outcome {
        case imported(clipID: String, name: String)
        case duplicate(name: String)
        case failed(name: String, reason: String)
    }

    /// What this app will take: a `.worklog.zip` clip export, or an audio
    /// file in any format AVFoundation reads.
    ///
    /// Defined here rather than at each door, because there are two of them -
    /// the Library's import panel and dropping onto the window - and a drop
    /// that refused a file the picker would have accepted (or the reverse)
    /// would be a difference nobody could explain.
    static let importableTypes: [UTType] = [.audio, .zip]

    /// Imports each file in order - sequential on purpose, so picking the
    /// same export twice in one batch dedupes instead of racing.
    static func importFiles(at urls: [URL]) async -> [Outcome] {
        var outcomes: [Outcome] = []
        for url in urls {
            let name = url.lastPathComponent
            do {
                if try isZip(url) {
                    outcomes.append(try await importArchive(at: url))
                } else {
                    outcomes.append(try await importAudio(at: url))
                }
            } catch let error as ClipArchiveError {
                outcomes.append(.failed(name: name, reason: error.message))
            } catch {
                outcomes.append(.failed(name: name, reason: error.localizedDescription))
            }
        }
        return outcomes
    }

    /// One alert-sized line for however the batch went.
    static func summaryMessage(_ outcomes: [Outcome]) -> String {
        if let single = outcomes.first, outcomes.count == 1 {
            switch single {
            case .imported(_, let name): return "Imported \u{201c}\(name)\u{201d}."
            case .duplicate(let name): return "\u{201c}\(name)\u{201d} is already in your library."
            case .failed(let name, let reason): return "Couldn't import \u{201c}\(name)\u{201d}: \(reason)"
            }
        }
        let imported = outcomes.filter { if case .imported = $0 { true } else { false } }.count
        let duplicates = outcomes.filter { if case .duplicate = $0 { true } else { false } }.count
        let failures = outcomes.compactMap { outcome -> String? in
            if case .failed(_, let reason) = outcome { return reason } else { return nil }
        }
        var parts: [String] = []
        if imported > 0 { parts.append("Imported \(imported) clip\(imported == 1 ? "" : "s")") }
        if duplicates > 0 { parts.append("\(duplicates) already in your library") }
        if !failures.isEmpty { parts.append("\(failures.count) failed (\(failures[0]))") }
        return parts.isEmpty ? "Nothing to import." : parts.joined(separator: " · ") + "."
    }

    private static func isZip(_ url: URL) throws -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ClipArchiveError(message: "couldn't read the file")
        }
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 4) ?? Data()
        return header.count == 4 && header[0] == 0x50 && header[1] == 0x4B
            && header[2] == 0x03 && header[3] == 0x04
    }

    // MARK: - Worklog zip import

    private static func importArchive(at url: URL) async throws -> Outcome {
        let fileManager = FileManager.default
        let extraction = fileManager.temporaryDirectory
            .appendingPathComponent("worklog-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: extraction, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: extraction) }

        // Every entry is flattened to a bare file name inside the extraction
        // folder - which kills zip-slip outright, and our archives are flat
        // anyway.
        do {
            try ZipArchive.unzipFlat(at: url, to: extraction)
        } catch {
            throw ClipArchiveError(message: "couldn't read this zip")
        }

        let manifestURL = extraction.appendingPathComponent(ClipArchive.manifestEntry)
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw ClipArchiveError(message: "this zip isn't a Worklog clip export")
        }
        let manifest = try ArchiveManifest.parse(manifestData)
        let displayName = manifest.clip.displayName ?? "Imported clip"

        // Every file the manifest promises must actually be present - a
        // partial restore is worse than a clean refusal.
        for name in manifest.referencedFiles {
            guard fileManager.fileExists(atPath: extraction.appendingPathComponent(name).path) else {
                throw ClipArchiveError(message: "the archive is missing \u{201c}\(name)\u{201d}")
            }
        }

        let alreadyExists = await MainActor.run {
            WorklogDatabase.shared.allClips().contains { $0.id == manifest.clip.id }
        }
        if alreadyExists {
            return .duplicate(name: displayName)
        }

        // Copy files into the clip's own folder first (off-main), then
        // register rows. Identity is preserved (same clip id, same
        // transcript id) so a clip moved between your own devices stays one
        // clip.
        let clipID = manifest.clip.id
        let folder = WorklogPaths.clipFolder(clipID: clipID)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let audioURL = WorklogPaths.clipAudioURL(clipID: clipID)
            try? fileManager.removeItem(at: audioURL)
            try fileManager.copyItem(at: extraction.appendingPathComponent(manifest.clip.audioFile), to: audioURL)

            if let transcript = manifest.transcript {
                let transcriptURL = WorklogPaths.clipTranscriptURL(clipID: clipID)
                try? fileManager.removeItem(at: transcriptURL)
                try fileManager.copyItem(at: extraction.appendingPathComponent(transcript.file), to: transcriptURL)
            }
            for translation in manifest.translations ?? [] {
                let translationURL = WorklogPaths.clipTranslationURL(clipID: clipID, language: translation.language)
                try? fileManager.removeItem(at: translationURL)
                try fileManager.copyItem(at: extraction.appendingPathComponent(translation.file), to: translationURL)
            }
            for summary in manifest.summaries ?? [] {
                // An unrecognized preset is skipped outright - never coerced
                // onto a known one.
                guard let preset = SummaryPreset.allCases.first(where: { $0.rawValue == summary.preset }) else { continue }
                let summaryURL = WorklogPaths.clipSummaryURL(clipID: clipID, preset: preset)
                try? fileManager.removeItem(at: summaryURL)
                try fileManager.copyItem(at: extraction.appendingPathComponent(summary.file), to: summaryURL)
            }

            let now = Date()
            await MainActor.run {
                let db = WorklogDatabase.shared
                let audioPath = WorklogPaths.clipAudioURL(clipID: clipID).path
                db.insertClip(ClipRecord(
                    id: clipID,
                    path: audioPath,
                    defaultName: manifest.clip.defaultName ?? displayName,
                    displayName: displayName,
                    sourceStart: manifest.clip.sourceStartMillis.map(ClipArchive.date(fromMillis:)) ?? now,
                    sourceEnd: manifest.clip.sourceEndMillis.map(ClipArchive.date(fromMillis:)) ?? now,
                    durationSeconds: manifest.clip.durationSeconds ?? 0,
                    createdAt: manifest.clip.createdAtMillis.map(ClipArchive.date(fromMillis:)) ?? now,
                    locationLatitude: manifest.clip.location?.latitude,
                    locationLongitude: manifest.clip.location?.longitude,
                    deviceUID: manifest.clip.deviceUid
                ))

                restorePreviewWords(manifest.previewWords, clipID: clipID)

                // Preserve the foreign transcript id unless it collides -
                // transcripts are found by clip_id, so any string is safe.
                let transcriptID = manifest.transcript?.id
                    .flatMap { db.transcript(id: $0) == nil ? $0 : nil }
                    ?? UUID().uuidString

                if let transcript = manifest.transcript {
                    db.insertTranscript(TranscriptRecord(
                        id: transcriptID,
                        clipID: clipID,
                        state: .succeeded,
                        error: nil,
                        provider: transcript.provider,
                        model: transcript.model,
                        path: WorklogPaths.clipTranscriptURL(clipID: clipID).path,
                        speakerCount: transcript.speakerCount,
                        createdAt: now
                    ))
                    if let cost = transcript.cost {
                        db.updateCost(table: "transcripts", id: transcriptID, cost: cost.costRecord)
                    }

                    for translation in manifest.translations ?? [] {
                        db.ensureTranslationRow(transcriptID: transcriptID, language: translation.language)
                        let translationID = db.translationID(transcriptID: transcriptID, language: translation.language)
                        db.updateTranslation(
                            id: translationID,
                            state: .succeeded,
                            error: .some(nil),
                            provider: translation.provider,
                            model: translation.model,
                            path: WorklogPaths.clipTranslationURL(clipID: clipID, language: translation.language).path
                        )
                        if let cost = translation.cost {
                            db.updateCost(table: "translations", id: translationID, cost: cost.costRecord)
                        }
                    }

                    for summary in manifest.summaries ?? [] {
                        guard let preset = SummaryPreset.allCases.first(where: { $0.rawValue == summary.preset }) else { continue }
                        db.ensureSummaryRow(transcriptID: transcriptID, preset: preset)
                        let summaryID = db.summaryID(transcriptID: transcriptID, preset: preset)
                        db.updateSummary(
                            id: summaryID,
                            state: .succeeded,
                            error: .some(nil),
                            translationID: .some(summary.translationLanguage.map {
                                db.translationID(transcriptID: transcriptID, language: $0)
                            }),
                            provider: summary.provider,
                            model: summary.model,
                            path: WorklogPaths.clipSummaryURL(clipID: clipID, preset: preset).path
                        )
                        if let cost = summary.cost {
                            db.updateCost(table: "summaries", id: summaryID, cost: cost.costRecord)
                        }
                    }
                } else {
                    db.insertTranscript(TranscriptRecord(
                        id: transcriptID,
                        clipID: clipID,
                        state: .pending,
                        error: nil,
                        provider: nil,
                        model: nil,
                        path: nil,
                        speakerCount: nil,
                        createdAt: now
                    ))
                }

                // Tags merge into the vocabulary that's already here rather
                // than arriving as a separate set: matched by name, created
                // only when genuinely new, and keeping the colour whoever
                // owns that tag locally already picked.
                //
                // The clip's *place* is deliberately not imported - there
                // isn't one in the archive to import. Only the coordinates
                // travelled, and the name for them is resolved against this
                // library's own places every time it's shown, so a clip from
                // someone else's phone lands under whatever you call that
                // spot, or under the OS name if you've never named it.
                for tag in manifest.tags ?? [] {
                    let name = tag.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !name.isEmpty else { continue }
                    let existing = TagStore.shared.tags.first { $0.name.lowercased() == name }
                    let color = TagColor(rawValue: tag.color ?? "")
                    guard let record = existing ?? TagStore.shared.createTag(name: name, color: color) else { continue }
                    TagStore.shared.assign(
                        record,
                        toClip: clipID,
                        source: TagSource(rawValue: tag.source ?? "") ?? .manual
                    )
                }

                // Whatever the archive didn't contain proceeds locally:
                // succeeded steps are skipped, missing ones run per settings.
                TranscriptionPipeline.shared.run(transcriptID: transcriptID, clipPath: audioPath)
            }
            return .imported(clipID: clipID, name: displayName)
        } catch {
            // Half a clip is worse than none - take the rows and folder
            // back out before reporting the failure.
            await MainActor.run { WorklogDatabase.shared.deleteClip(id: clipID) }
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    // MARK: - Bare audio import

    private static func importAudio(at url: URL) async throws -> Outcome {
        let fileManager = FileManager.default
        let title = url.deletingPathExtension().lastPathComponent
        let displayName = title.isEmpty ? "Imported audio" : title

        // Normalize into the library's canonical form - AAC in .m4a, the
        // same shape every recorded clip has. Already-AAC mp4 files are
        // taken as they are; everything else decodes and re-encodes.
        let normalized: URL
        var normalizedIsTemporary = false
        if try await isAacInMp4(url) {
            normalized = url
        } else {
            normalized = try await transcodeToM4a(url)
            normalizedIsTemporary = true
        }
        defer { if normalizedIsTemporary { try? fileManager.removeItem(at: normalized) } }

        let asset = AVURLAsset(url: normalized)
        let durationSeconds = (try? await asset.load(.duration).seconds) ?? 0
        guard durationSeconds > 0 else {
            throw ClipArchiveError(message: "couldn't read any audio from it")
        }

        let clipID = UUID().uuidString
        let folder = WorklogPaths.clipFolder(clipID: clipID)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let audioURL = WorklogPaths.clipAudioURL(clipID: clipID)
            try? fileManager.removeItem(at: audioURL)
            try fileManager.copyItem(at: normalized, to: audioURL)

            // Best-effort recording time: a file's modification stamp is
            // usually when the recorder finished writing it, so an old
            // recording lands at its recorded time, not at "just now".
            let now = Date()
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let modified = attributes?[.modificationDate] as? Date
            let end: Date
            if let modified, modified.timeIntervalSince1970 > 0,
               modified < now.addingTimeInterval(24 * 60 * 60) {
                end = modified
            } else {
                end = now
            }

            await MainActor.run {
                let db = WorklogDatabase.shared
                db.insertClip(ClipRecord(
                    id: clipID,
                    path: audioURL.path,
                    defaultName: displayName,
                    displayName: displayName,
                    sourceStart: end.addingTimeInterval(-durationSeconds),
                    sourceEnd: end,
                    durationSeconds: durationSeconds,
                    createdAt: now,
                    locationLatitude: nil,
                    locationLongitude: nil,
                    deviceUID: nil
                ))
                let transcriptID = UUID().uuidString
                db.insertTranscript(TranscriptRecord(
                    id: transcriptID,
                    clipID: clipID,
                    state: .pending,
                    error: nil,
                    provider: nil,
                    model: nil,
                    path: nil,
                    speakerCount: nil,
                    createdAt: now
                ))
                TranscriptionPipeline.shared.run(transcriptID: transcriptID, clipPath: audioURL.path)
            }
            return .imported(clipID: clipID, name: displayName)
        } catch {
            await MainActor.run { WorklogDatabase.shared.deleteClip(id: clipID) }
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    /// AAC inside an MPEG-4 container needs no work - that's already the
    /// library's format, whatever the file was called. A video file with an
    /// AAC track must NOT byte-copy (that would put a whole movie in the
    /// library); transcoding extracts just the audio.
    private static func isAacInMp4(_ url: URL) async throws -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ClipArchiveError(message: "couldn't read the file")
        }
        let header = try handle.read(upToCount: 8) ?? Data()
        try? handle.close()
        guard header.count == 8,
              header[4] == 0x66, header[5] == 0x74, header[6] == 0x79, header[7] == 0x70 else {
            return false
        }

        let asset = AVURLAsset(url: url)
        guard let videoTracks = try? await asset.loadTracks(withMediaType: .video), videoTracks.isEmpty,
              let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
              let track = audioTracks.first,
              let descriptions = try? await track.load(.formatDescriptions),
              let description = descriptions.first else {
            return false
        }
        return CMFormatDescriptionGetMediaSubType(description) == kAudioFormatMPEG4AAC
    }

    /// Decode → AAC re-encode via AVFoundation. Throws when the source
    /// isn't audio this device can read (CoreAudio has no ogg/opus support).
    private static func transcodeToM4a(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let audioTracks = try? await asset.loadTracks(withMediaType: .audio), !audioTracks.isEmpty,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ClipArchiveError(message: "not an audio file this device can read")
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklog-import-transcode-\(UUID().uuidString).m4a")
        session.outputURL = destination
        session.outputFileType = .m4a

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw ClipArchiveError(message: "not an audio file this device can read")
        }
        return destination
    }
}

/// Restores an archive's on-device preview transcript onto the imported
/// clip. Written straight to the clip's own table rather than the rolling
/// one: these words describe audio this device never recorded, so they only
/// ever belong to the clip they arrived with.
@MainActor
private func restorePreviewWords(_ words: [ArchivePreviewWord]?, clipID: String) {
    guard let words, !words.isEmpty else { return }
    WorklogDatabase.shared.replaceClipPreviewWords(
        clipID: clipID,
        words: words.map {
            PreviewWord(
                start: Date(timeIntervalSince1970: Double($0.startMillis) / 1000),
                end: Date(timeIntervalSince1970: Double($0.endMillis) / 1000),
                text: $0.text
            )
        },
        engine: words.first?.engine ?? "imported"
    )
}
