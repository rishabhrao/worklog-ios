import Foundation

/// The Library's per-row display state (spec `06-library.md`): "which step
/// is it on" rather than a binary done/not-done. Distinct from
/// `PipelineStep` (which only exists while a transcript is actively running
/// in this process) because a row also needs to represent steps that
/// haven't started yet or have already finished, purely from persisted
/// `worklog.db` state, with no pipeline task in flight. Fully generic -
/// languages/providers are data carried in the cases, never code concepts.
enum LibraryTranscriptionStage: Equatable {
    case exportOnly
    case transcribing
    case transcriptFailed(String)
    case translating(language: String)
    case translationFailed(language: String, message: String)
    case summarizing
    case summaryFailed(String)
    case tagging
    case tagFailed(String)
    case done

    var label: String {
        switch self {
        case .exportOnly: return "Queued"
        case .transcribing: return "Transcribing…"
        case .transcriptFailed: return "Transcript failed"
        case .translating: return "Translating…"
        case .translationFailed: return "Translation failed"
        case .summarizing: return "Summarizing…"
        case .summaryFailed: return "Summary failed"
        case .tagging: return "Tagging…"
        case .tagFailed: return "Tagging failed"
        case .done: return "Done"
        }
    }

    var isFailed: Bool {
        switch self {
        case .transcriptFailed, .translationFailed, .summaryFailed, .tagFailed: return true
        default: return false
        }
    }

    var errorMessage: String? {
        switch self {
        case .transcriptFailed(let message), .summaryFailed(let message), .tagFailed(let message),
             .translationFailed(_, let message):
            return message
        default: return nil
        }
    }
}

/// One Library row: a clip joined with its transcript, that transcript's
/// translations, and its summary.
struct LibraryEntry: Identifiable {
    let clip: ClipRecord
    let transcript: TranscriptRecord?
    let translations: [TranslationRecord]
    /// Every summary preset that has a row, overview first.
    let summaries: [SummaryRecord]
    /// The auto-tagging step's row, when one exists. Tags themselves live in
    /// `TagStore` - this is only the step's state, for the badge and retry.
    var tagging: TaggingRecord?

    var id: String { clip.id }

    /// The folder holding everything this clip owns - audio, transcript,
    /// translations, summaries. The useful thing to hand an agent.
    var clipFolderPath: String {
        URL(fileURLWithPath: clip.path).deletingLastPathComponent().path
    }

    /// Derives the live per-step stage purely from persisted state plus
    /// whichever steps (if any) `TranscriptionPipeline` reports as actively
    /// running for this transcript right now - never a second/independent
    /// tracking mechanism. A set because translations run in parallel; the
    /// earliest-in-pipeline running step wins the row label.
    func stage(runningSteps: Set<PipelineStep>) -> LibraryTranscriptionStage {
        guard let transcript else { return .exportOnly }

        if runningSteps.contains(.transcribe) {
            return .transcribing
        }
        for step in runningSteps {
            if case .translate(let language) = step {
                return .translating(language: language)
            }
        }
        for step in runningSteps {
            if case .summarize = step {
                return .summarizing
            }
        }
        if runningSteps.contains(.tag) {
            return .tagging
        }

        if transcript.state == .failed {
            return .transcriptFailed(transcript.error ?? "Transcription failed.")
        }
        if transcript.state != .succeeded {
            return .exportOnly
        }
        if let failed = translations.first(where: { $0.state == .failed }) {
            return .translationFailed(language: failed.language, message: failed.error ?? "Translation failed.")
        }
        if translations.contains(where: { $0.state != .succeeded }) {
            return .exportOnly
        }
        if let failed = summaries.first(where: { $0.state == .failed }) {
            return .summaryFailed(failed.error ?? "Summary failed.")
        }
        if summaries.contains(where: { $0.state != .succeeded }) {
            return .exportOnly
        }
        // Tagging is last and optional: a clip with tagging switched off has
        // no row at all and is simply done, and a failed tagging shouldn't
        // read as a failed clip when everything else worked.
        if let tagging, tagging.state == .failed {
            return .tagFailed(tagging.error ?? "Tagging failed.")
        }
        if let tagging, tagging.state != .succeeded {
            return .exportOnly
        }
        return .done
    }
}
