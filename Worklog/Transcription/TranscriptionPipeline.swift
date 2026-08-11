import Foundation

/// Explicit pipeline steps shown as live per-library-entry state (spec
/// `07-transcription-pipeline.md`: export → transcribe → translate →
/// summarize → done, never a silent "is it doing anything?" gap).
/// Translation is language-parameterized - languages are data, not
/// code-level concepts.
enum PipelineStep: Equatable, Hashable {
    case exportClip
    case transcribe
    case translate(language: String)
    case summarize(preset: SummaryPreset)
    case tag
    case done
}

/// Runs the transcription + translation + summary steps in the background,
/// queueable, non-blocking. Export itself already happens in
/// `ClipScreenViewModel.transcribe()` before a `TranscriptRecord` exists -
/// this type owns everything from "clip is on disk" onward.
///
/// Each step's output is persisted to `worklog.db` the moment it succeeds,
/// so a later retry-just-this-step never redoes (or re-pays API cost for)
/// already-succeeded steps, and a killed process picks up exactly where it
/// left off on the next launch (state lives on the transcript/translation/
/// summary rows, not in memory). One transcript per clip; many translations
/// per transcript; one summary per transcript - adding a target language is
/// a row insert, never new code.
@MainActor
final class TranscriptionPipeline: ObservableObject {
    static let shared = TranscriptionPipeline()

    /// Which steps are actively running for a given transcript, so the
    /// Library can render live spinners on the right rows without polling
    /// `worklog.db`. A set because translations run in parallel - several
    /// steps can be in flight for one transcript at once. Not itself the
    /// source of truth - the database is - this only tracks "in flight
    /// right now, in this process."
    @Published private(set) var runningSteps: [String: Set<PipelineStep>] = [:]

    private init() {}

    private func begin(_ step: PipelineStep, transcriptID: String) {
        runningSteps[transcriptID, default: []].insert(step)
    }

    private func end(_ step: PipelineStep, transcriptID: String) {
        runningSteps[transcriptID]?.remove(step)
        if runningSteps[transcriptID]?.isEmpty == true {
            runningSteps[transcriptID] = nil
        }
    }

    /// Starts (or resumes) the full pipeline for a transcript row that
    /// already has an exported clip. Steps already `succeeded` are skipped;
    /// `pending`/`failed` steps run. Multiple calls for different
    /// transcript IDs run concurrently and don't block the UI or each other.
    func run(transcriptID: String, clipPath: String) {
        Task {
            ensureDerivedRows(transcriptID: transcriptID)
            await transcribeIfNeeded(transcriptID: transcriptID, clipPath: clipPath)
            await translateAll(transcriptID: transcriptID)
            await summarizeIfNeeded(transcriptID: transcriptID)
            await tagIfNeeded(transcriptID: transcriptID)
        }
    }

    /// Re-runs transcription on demand - after a failure, or even after a
    /// prior success (per the ticket's explicit "retry any individual step
    /// at will" rule). A fresh transcript invalidates everything derived
    /// from it, so all translations and the summary re-run too.
    func retryTranscription(transcriptID: String, clipPath: String) {
        Task {
            ensureDerivedRows(transcriptID: transcriptID)
            let changed = await transcribeIfNeeded(transcriptID: transcriptID, clipPath: clipPath, forceRerun: true)
            // Everything downstream is derived from the transcript text. If
            // the retry produced the same text - the common case when the
            // first attempt died on a network error rather than a bad
            // recognition - re-running seven paid calls would buy identical
            // output. Only a genuinely different transcript invalidates them.
            guard changed else { return }
            await translateAll(transcriptID: transcriptID, forceRerun: true)
            await summarizeIfNeeded(transcriptID: transcriptID, forceRerun: true)
            await tagIfNeeded(transcriptID: transcriptID, forceRerun: true)
        }
    }

    /// Re-runs a single translation on demand.
    func retryTranslation(translationID: String) {
        Task {
            guard let translation = WorklogDatabase.shared.translation(id: translationID) else { return }
            await translateIfNeeded(translation, forceRerun: true)
        }
    }

    /// Re-runs one summary on demand. Forced - an explicit click on an
    /// existing summary row runs even if summaries, or that preset, have
    /// since been toggled off in Settings (the source is still resolved from
    /// current Settings).
    func retrySummary(transcriptID: String, preset: SummaryPreset = .overview) {
        Task {
            await summarize(
                transcriptID: transcriptID,
                preset: preset,
                forceRerun: true,
                settings: WorklogSettingsStore.load()
            )
        }
    }

    /// Re-runs auto-tagging on demand. Forced - an explicit click runs even
    /// if auto-tagging has since been switched off in Settings.
    func retryTagging(transcriptID: String) {
        Task { await tagIfNeeded(transcriptID: transcriptID, forceRerun: true) }
    }

    /// Rows for everything this run will derive from the transcript, per
    /// current Settings: one translation per enabled language, plus the
    /// summary row when summaries are on. Rows for since-disabled languages
    /// are left alone - their output already exists and stays visible.
    private func ensureDerivedRows(transcriptID: String) {
        let settings = WorklogSettingsStore.load()
        for language in settings.enabledTranslationLanguages {
            WorklogDatabase.shared.ensureTranslationRow(transcriptID: transcriptID, language: language)
        }
        if settings.isSummariesEnabled {
            for preset in settings.enabledSummaryPresets {
                WorklogDatabase.shared.ensureSummaryRow(transcriptID: transcriptID, preset: preset)
            }
        }
        if settings.isAutoTaggingEnabled {
            WorklogDatabase.shared.ensureTaggingRow(transcriptID: transcriptID)
        }
    }

    // MARK: - Cost bookkeeping

    /// Persists what an LLM step cost. The provider's own figure wins when
    /// the endpoint reports one (a LiteLLM-style proxy does, and it reflects
    /// the actual billing arrangement rather than Anthropic list price);
    /// otherwise this falls back to list-rate arithmetic and marks the
    /// result as an estimate.
    private func recordLLMCost(table: String, id: String, result: (text: String, model: String, usage: LLMUsage)) {
        let resolved = result.usage.resolvedCost(model: result.model)
        WorklogDatabase.shared.updateCost(table: table, id: id, cost: CostRecord(
            usd: resolved?.usd,
            source: resolved?.source,
            inputTokens: result.usage.inputTokens,
            outputTokens: result.usage.outputTokens
        ))
    }

    /// Fallback billed duration when ElevenLabs doesn't report one.
    private func clipDurationSeconds(transcriptID: String) -> Double {
        guard let clipID = WorklogDatabase.shared.transcript(id: transcriptID)?.clipID else { return 0 }
        return WorklogDatabase.shared.allClips().first { $0.id == clipID }?.durationSeconds ?? 0
    }

    // MARK: - Transcribe step

    /// Returns whether the transcript *text* ended up different from what was
    /// already on disk - the signal `retryTranscription` uses to decide
    /// whether anything derived from it is actually stale. Compares the
    /// rendered text rather than the raw JSON, because word-level timings and
    /// confidences differ run to run while the words downstream steps consume
    /// stay identical.
    @discardableResult
    private func transcribeIfNeeded(transcriptID: String, clipPath: String, forceRerun: Bool = false) async -> Bool {
        let existing = WorklogDatabase.shared.transcript(id: transcriptID)
        guard forceRerun || existing?.state != .succeeded else { return false }

        let previousText = existing?.path
            .flatMap { FileManager.default.contents(atPath: $0) }
            .flatMap { try? JSONDecoder().decode(TranscriptResponse.self, from: $0) }
            .map { TranscriptFormatter.promptTranscript($0) }

        begin(.transcribe, transcriptID: transcriptID)
        WorklogDatabase.shared.updateTranscript(id: transcriptID, state: .running, error: .some(nil))

        do {
            let (raw, parsed) = try await TranscriptionClient.transcribe(clipURL: URL(fileURLWithPath: clipPath))
            guard let clipID = WorklogDatabase.shared.transcript(id: transcriptID)?.clipID else {
                end(.transcribe, transcriptID: transcriptID)
                return false
            }
            let jsonURL = WorklogPaths.clipTranscriptURL(clipID: clipID)
            try FileManager.default.createDirectory(at: WorklogPaths.clipFolder(clipID: clipID), withIntermediateDirectories: true)
            try raw.write(to: jsonURL, options: .atomic)

            WorklogDatabase.shared.updateTranscript(
                id: transcriptID,
                state: .succeeded,
                error: .some(nil),
                // What actually produced THIS transcript - recorded at run
                // time, never re-read from Settings later.
                provider: TranscriptionClient.providerID,
                model: TranscriptionClient.effectiveModel(),
                path: jsonURL.path,
                speakerCount: TranscriptFormatter.speakerCount(parsed)
            )
            // Prefer the duration ElevenLabs itself reports over the clip's
            // stored length - that's the figure they bill against, and it can
            // differ from what we think the file contains.
            let billedSeconds = parsed.audioDurationSecs ?? clipDurationSeconds(transcriptID: transcriptID)
            WorklogDatabase.shared.updateCost(table: "transcripts", id: transcriptID, cost: CostRecord(
                usd: Pricing.transcriptionCostUSD(model: TranscriptionClient.effectiveModel(), seconds: billedSeconds),
                source: .estimated,
                billedSeconds: billedSeconds
            ))
            end(.transcribe, transcriptID: transcriptID)
            return TranscriptFormatter.promptTranscript(parsed) != previousText
        } catch {
            WorklogDatabase.shared.updateTranscript(id: transcriptID, state: .failed, error: .some(error.localizedDescription))
        }

        end(.transcribe, transcriptID: transcriptID)
        // A failed transcription leaves the old text in place, so nothing
        // derived from it is stale.
        return false
    }

    // MARK: - Translate step

    /// All of a transcript's translations run in parallel - they're
    /// independent LLM calls off the same input; nothing about one depends
    /// on another.
    private func translateAll(transcriptID: String, forceRerun: Bool = false) async {
        let translations = WorklogDatabase.shared.translations(transcriptID: transcriptID)
        await withTaskGroup(of: Void.self) { group in
            for translation in translations {
                group.addTask { @MainActor in
                    await self.translateIfNeeded(translation, forceRerun: forceRerun)
                }
            }
        }
    }

    private func translateIfNeeded(_ translation: TranslationRecord, forceRerun: Bool = false) async {
        guard let transcript = WorklogDatabase.shared.transcript(id: translation.transcriptID) else { return }
        // A translation derives from the transcript's output; never run it
        // against a missing/failed transcript even on a forced retry.
        guard transcript.state == .succeeded, let transcriptPath = transcript.path else { return }
        guard forceRerun || translation.state != .succeeded else { return }

        begin(.translate(language: translation.language), transcriptID: translation.transcriptID)
        WorklogDatabase.shared.updateTranslation(id: translation.id, state: .running, error: .some(nil))

        do {
            let transcriptData = try Data(contentsOf: URL(fileURLWithPath: transcriptPath))
            let parsed = try JSONDecoder().decode(TranscriptResponse.self, from: transcriptData)
            let promptTranscript = TranscriptFormatter.promptTranscript(parsed)

            let result = try await LLMClient.runPrompt(
                system: TranscriptFormatter.translationSystemPrompt(language: translation.language),
                input: "Produce the output described above for that transcript.",
                // The transcript, shared by every call this clip makes.
                cachedPrefix: promptTranscript,
                modelOverride: WorklogSettingsStore.load().translationModel
            )

            let markdown = TranscriptFormatter.buildMarkdown(dialogue: result.text)
            let markdownURL = WorklogPaths.clipTranslationURL(clipID: transcript.clipID, language: translation.language)
            try FileManager.default.createDirectory(at: WorklogPaths.clipFolder(clipID: transcript.clipID), withIntermediateDirectories: true)
            try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)

            WorklogDatabase.shared.updateTranslation(
                id: translation.id,
                state: .succeeded,
                error: .some(nil),
                // What actually served THIS translation - resolved by the
                // client at call time, not re-read from Settings later.
                provider: LLMClient.providerID,
                model: result.model,
                path: markdownURL.path
            )
            recordLLMCost(table: "translations", id: translation.id, result: result)
        } catch {
            WorklogDatabase.shared.updateTranslation(id: translation.id, state: .failed, error: .some(error.localizedDescription))
        }

        end(.translate(language: translation.language), transcriptID: translation.transcriptID)
    }

    // MARK: - Summarize step

    /// Summarizes either the raw transcript or one of its translations,
    /// per Settings' "Create summary from" selection - resolved at run
    /// time and recorded on the row (`translationID`). Runs after all
    /// translations so a translation-sourced summary has its input ready.
    private func summarizeIfNeeded(transcriptID: String, forceRerun: Bool = false) async {
        let settings = WorklogSettingsStore.load()
        // Auto-runs only when enabled; a forced (explicit user) retry
        // proceeds against the existing rows regardless.
        if !forceRerun {
            guard settings.isSummariesEnabled else { return }
        }
        for preset in settings.enabledSummaryPresets {
            await summarize(transcriptID: transcriptID, preset: preset, forceRerun: forceRerun, settings: settings)
        }
    }

    /// Produces one summary of one kind.
    ///
    /// Each preset is its own row, file and LLM call against the same source
    /// text - enabling "Action items" adds a document rather than changing
    /// the overview. One preset failing leaves the others alone.
    private func summarize(transcriptID: String, preset: SummaryPreset, forceRerun: Bool, settings: WorklogSettings) async {
        guard let transcript = WorklogDatabase.shared.transcript(id: transcriptID) else { return }
        guard transcript.state == .succeeded, let transcriptPath = transcript.path else { return }
        WorklogDatabase.shared.ensureSummaryRow(transcriptID: transcriptID, preset: preset)
        guard let summary = WorklogDatabase.shared.summary(transcriptID: transcriptID, preset: preset) else { return }
        guard forceRerun || summary.state != .succeeded else { return }

        begin(.summarize(preset: preset), transcriptID: transcriptID)
        WorklogDatabase.shared.updateSummary(id: summary.id, state: .running, error: .some(nil))

        do {
            let (sourceText, sourceTranslationID) = try summarySource(for: transcript, transcriptPath: transcriptPath, settings: settings)

            let result = try await LLMClient.runPrompt(
                system: preset.systemPrompt,
                input: "Produce the output described above for that transcript.",
                cachedPrefix: sourceText,
                modelOverride: settings.summaryModel
            )

            let markdownURL = WorklogPaths.clipSummaryURL(clipID: transcript.clipID, preset: preset)
            try FileManager.default.createDirectory(at: WorklogPaths.clipFolder(clipID: transcript.clipID), withIntermediateDirectories: true)
            try result.text.write(to: markdownURL, atomically: true, encoding: .utf8)

            WorklogDatabase.shared.updateSummary(
                id: summary.id,
                state: .succeeded,
                error: .some(nil),
                // Which source this summary was actually built from, and
                // what served it - recorded at run time, same rule as every
                // other step's provenance.
                translationID: .some(sourceTranslationID),
                provider: LLMClient.providerID,
                model: result.model,
                path: markdownURL.path
            )
            recordLLMCost(table: "summaries", id: summary.id, result: result)
        } catch {
            WorklogDatabase.shared.updateSummary(id: summary.id, state: .failed, error: .some(error.localizedDescription))
        }

        end(.summarize(preset: preset), transcriptID: transcriptID)
    }

    // MARK: - Tag step

    /// Picks tags for the clip from the transcript.
    ///
    /// Runs last: it reads the transcript, not the summary, so nothing
    /// depends on it and it can't hold anything else up. Its output is rows
    /// in `clip_tags` rather than a file, but its row carries the same
    /// state/provenance/cost as every other step, so retry and the Costs
    /// breakdown need no special case.
    private func tagIfNeeded(transcriptID: String, forceRerun: Bool = false) async {
        let settings = WorklogSettingsStore.load()
        if !forceRerun {
            guard settings.isAutoTaggingEnabled else { return }
        }
        guard let transcript = WorklogDatabase.shared.transcript(id: transcriptID) else { return }
        guard transcript.state == .succeeded, let transcriptPath = transcript.path else { return }

        WorklogDatabase.shared.ensureTaggingRow(transcriptID: transcriptID)
        guard let tagging = WorklogDatabase.shared.tagging(transcriptID: transcriptID) else { return }
        guard forceRerun || tagging.state != .succeeded else { return }

        begin(.tag, transcriptID: transcriptID)
        WorklogDatabase.shared.updateTagging(id: tagging.id, state: .running, error: .some(nil))

        do {
            let transcriptData = try Data(contentsOf: URL(fileURLWithPath: transcriptPath))
            let parsed = try JSONDecoder().decode(TranscriptResponse.self, from: transcriptData)
            let existingNames = TagStore.shared.tags.map(\.name)
            let allowNewTags = settings.isTaggingAllowedToCreateTags

            let result = try await LLMClient.runPrompt(
                // Constant - the vocabulary and the transcript go in the user
                // turn, so the cached prefix is the same on every call.
                system: TaggingPrompt.systemPrompt,
                input: TaggingPrompt.userMessage(existingTags: existingNames, allowNewTags: allowNewTags),
                cachedPrefix: TranscriptFormatter.promptTranscript(parsed),
                modelOverride: settings.taggingModel,
                // A JSON array of a handful of short strings. Leaving the
                // 16k ceiling in place would let a confused model narrate for
                // pages and bill for it.
                maxTokens: 300
            )

            var names = TaggingPrompt.parse(result.text)
            if !allowNewTags {
                let known = Set(existingNames.map { $0.lowercased() })
                names = names.filter { known.contains($0.lowercased()) }
            }

            TagStore.shared.replaceAutoTags(clipID: transcript.clipID, with: names, allowNewTags: allowNewTags)

            WorklogDatabase.shared.updateTagging(
                id: tagging.id,
                state: .succeeded,
                error: .some(nil),
                provider: LLMClient.providerID,
                model: result.model
            )
            recordLLMCost(table: "taggings", id: tagging.id, result: result)
        } catch {
            WorklogDatabase.shared.updateTagging(id: tagging.id, state: .failed, error: .some(error.localizedDescription))
        }

        end(.tag, transcriptID: transcriptID)
    }

    private enum SummarySourceError: LocalizedError {
        case translationUnavailable(language: String)

        var errorDescription: String? {
            switch self {
            case .translationUnavailable(let language):
                return "The \(language.capitalized) translation isn't available to summarize from yet - retry it first, or switch the summary source in Settings."
            }
        }
    }

    /// Resolves the summary's input text: the selected translation's saved
    /// markdown, or the raw transcript rendered the same way translation
    /// prompts see it. Returns the source translation's row ID when one was
    /// used, for provenance.
    private func summarySource(for transcript: TranscriptRecord, transcriptPath: String, settings: WorklogSettings) throws -> (text: String, translationID: String?) {
        let source = settings.effectiveSummarySource
        if source != WorklogSettings.originalSummarySource {
            let translations = WorklogDatabase.shared.translations(transcriptID: transcript.id)
            guard let translation = translations.first(where: { $0.language == source }),
                  translation.state == .succeeded, let path = translation.path,
                  let data = FileManager.default.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8) else {
                throw SummarySourceError.translationUnavailable(language: source)
            }
            return (text, translation.id)
        }

        let transcriptData = try Data(contentsOf: URL(fileURLWithPath: transcriptPath))
        let parsed = try JSONDecoder().decode(TranscriptResponse.self, from: transcriptData)
        return (TranscriptFormatter.promptTranscript(parsed), nil)
    }
}
