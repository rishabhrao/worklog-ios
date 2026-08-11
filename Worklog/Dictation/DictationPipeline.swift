import Foundation

/// Runs the one transcription step a dictation has.
///
/// Deliberately not `TranscriptionPipeline`: a dictation has no
/// translations, no summary, and no diarization, so none of that machinery
/// (or the Anthropic key it needs) is reachable from here. Dictation works
/// with an ElevenLabs key alone.
///
/// Like the clip pipeline, state lives on the row rather than in memory, so
/// a killed process leaves an accurate record and nothing retries itself
/// behind the user's back - a failure waits for an explicit Retry.
@MainActor
final class DictationPipeline: ObservableObject {
    static let shared = DictationPipeline()

    /// Dictation IDs with a transcription in flight right now, so the
    /// Dictations tab can show live spinners without polling the database.
    /// Not the source of truth - the row's `state` is - this only tracks
    /// "in flight in this process."
    @Published private(set) var runningIDs: Set<String> = []

    private init() {}

    /// Transcribes a dictation whose audio is already exported and hands
    /// back the text, so the batch path can insert it once it arrives.
    /// Returns `nil` when transcription failed - the row carries the reason.
    @discardableResult
    func run(dictationID: String) async -> String? {
        await transcribe(dictationID: dictationID, forceRerun: false)
    }

    /// Re-runs transcription on demand from the Dictations tab.
    ///
    /// Always the batch path, whatever originally produced the row. Replaying
    /// a WebSocket against a recording that already finished buys nothing -
    /// the streaming model exists to beat latency that no longer applies -
    /// and the batch model is the more accurate of the two. The row's
    /// `model` column is rewritten to say what actually ran this time.
    func retry(dictationID: String) {
        Task { _ = await transcribe(dictationID: dictationID, forceRerun: true) }
    }

    /// Records the outcome of a realtime dictation whose text arrived over
    /// the socket, so the row matches what the user already saw typed.
    ///
    /// A realtime failure that still produced some text is stored as
    /// `failed` *with* that text kept: the transcript is partial, Retry will
    /// redo the whole thing properly from the saved audio, and nothing the
    /// user watched appear on screen is thrown away in the meantime.
    func recordRealtimeResult(dictationID: String, text: String, rawJSON: Data?, error: String?) {
        // The raw JSON below is still stored verbatim - only the text that
        // reaches the user's field is cleaned up.
        let trimmed = SoundLabels.applyingSetting(to: text)
        var textPath: String?
        var rawPath: String?

        do {
            try FileManager.default.createDirectory(
                at: WorklogPaths.dictationFolder(dictationID: dictationID),
                withIntermediateDirectories: true
            )
            if !trimmed.isEmpty {
                let url = WorklogPaths.dictationTextURL(dictationID: dictationID)
                try trimmed.write(to: url, atomically: true, encoding: .utf8)
                textPath = url.path
            }
            if let rawJSON {
                let url = WorklogPaths.dictationTranscriptURL(dictationID: dictationID)
                try rawJSON.write(to: url, options: .atomic)
                rawPath = url.path
            }
        } catch {
            WorklogDatabase.shared.updateDictation(
                id: dictationID,
                state: .failed,
                error: .some("Couldn't save the dictation transcript: \(error.localizedDescription)")
            )
            return
        }

        WorklogDatabase.shared.updateDictation(
            id: dictationID,
            state: error == nil ? .succeeded : .failed,
            error: .some(error),
            provider: RealtimeTranscriptionSession.providerID,
            model: RealtimeTranscriptionSession.modelID,
            textPath: .some(textPath),
            rawPath: .some(rawPath)
        )

        // Realtime is billed on streamed audio, and the socket reports no
        // duration - so this uses the dictation's own recorded length, which
        // is the same window that was streamed.
        let seconds = WorklogDatabase.shared.dictation(id: dictationID)?.durationSeconds ?? 0
        WorklogDatabase.shared.updateCost(table: "dictations", id: dictationID, cost: CostRecord(
            usd: Pricing.transcriptionCostUSD(model: RealtimeTranscriptionSession.modelID, seconds: seconds),
            source: .estimated,
            billedSeconds: seconds
        ))
    }

    /// The text a dictation ended up with, read back from disk. `nil` when
    /// transcription hasn't produced anything yet.
    static func text(for dictation: DictationRecord) -> String? {
        guard let path = dictation.textPath else { return nil }
        return try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    }

    // MARK: - Batch transcription

    private func transcribe(dictationID: String, forceRerun: Bool) async -> String? {
        guard let dictation = WorklogDatabase.shared.dictation(id: dictationID) else { return nil }
        guard forceRerun || dictation.state != .succeeded else {
            return Self.text(for: dictation)
        }

        runningIDs.insert(dictationID)
        defer { runningIDs.remove(dictationID) }

        WorklogDatabase.shared.updateDictation(id: dictationID, state: .running, error: .some(nil))

        do {
            // diarize: false - one person talking into their own mic has no
            // speakers to label, and asking for them costs more for nothing.
            //
            // The language is read now rather than frozen when the dictation
            // was recorded: a retry should honour whatever the user has since
            // set, which is usually *why* they're retrying.
            let (raw, parsed) = try await TranscriptionClient.transcribe(
                clipURL: URL(fileURLWithPath: dictation.path),
                diarize: false,
                languageCode: WorklogSettingsStore.load().effectiveDictationLanguage.code
            )

            // The raw `text` verbatim - deliberately NOT run through
            // `TranscriptFormatter`, which exists to group Scribe's word
            // array into `speaker_N:` lines for the Library's diarized
            // transcripts. That formatting would be actively wrong here:
            // this string goes straight into the user's text field.
            let text = SoundLabels.applyingSetting(to: parsed.text)

            let folder = WorklogPaths.dictationFolder(dictationID: dictationID)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let jsonURL = WorklogPaths.dictationTranscriptURL(dictationID: dictationID)
            try raw.write(to: jsonURL, options: .atomic)
            let textURL = WorklogPaths.dictationTextURL(dictationID: dictationID)
            try text.write(to: textURL, atomically: true, encoding: .utf8)

            WorklogDatabase.shared.updateDictation(
                id: dictationID,
                state: .succeeded,
                error: .some(nil),
                provider: TranscriptionClient.providerID,
                model: TranscriptionClient.effectiveModel(),
                textPath: .some(textURL.path),
                rawPath: .some(jsonURL.path)
            )

            // ElevenLabs' own reported duration is what they bill against;
            // the row's stored length is only a fallback.
            let billedSeconds = parsed.audioDurationSecs ?? dictation.durationSeconds
            WorklogDatabase.shared.updateCost(table: "dictations", id: dictationID, cost: CostRecord(
                usd: Pricing.transcriptionCostUSD(model: TranscriptionClient.effectiveModel(), seconds: billedSeconds),
                source: .estimated,
                billedSeconds: billedSeconds
            ))
            return text
        } catch {
            WorklogDatabase.shared.updateDictation(
                id: dictationID,
                state: .failed,
                error: .some(error.localizedDescription)
            )
            return nil
        }
    }
}
