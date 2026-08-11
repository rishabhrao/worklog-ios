import AVFoundation
import Foundation

/// One recognized word from the on-device preview transcriber, positioned on
/// the same absolute wall-clock timeline everything else in the app uses
/// (segments, clips, dictations). Words, not utterances, because the two
/// consumers both ask word-sized questions: "what is said right at this
/// selection edge" and "select from this word to that word."
struct PreviewWord: Equatable {
    let start: Date
    let end: Date
    let text: String
}

/// What a preview engine can currently do, for the Settings status line.
enum PreviewTranscriberAvailability: Equatable {
    case ready
    /// Supported, but the speech model needs downloading first.
    case needsDownload
    /// Download in flight. 0...1, or nil when the OS doesn't say.
    case downloading(Double?)
    case unavailable(String)
}

enum PreviewTranscriberEvent {
    /// The current provisional tail - replaced wholesale as the recognizer
    /// revises it. Display only; never persisted.
    case volatile(String)
    /// Words the recognizer has finalized. Persisted; never revised.
    case words([PreviewWord])
}

/// A source of live on-device speech previews.
///
/// This is deliberately a seam, not a class: the shipped implementation is
/// the platform's built-in transcriber, and on iOS there are already two of
/// them - `AppleSpeechPreviewTranscriber` (iOS 26's SpeechAnalyzer, with word
/// timings and downloadable locales) and `LegacySpeechPreviewTranscriber`
/// (`SFSpeechRecognizer`, for everything older) - with the door explicitly
/// open for other local models later (e.g. a bundled Parakeet).
/// Adding one means implementing this protocol and returning it from
/// `SpeechPreviewEngine.makeTranscriber()` - nothing else in the app knows
/// which engine produced a word beyond the `id` string stored beside it.
///
/// Contract:
/// - `feed` is called on the capture write queue and must not block: copy,
///   convert, hand off.
/// - Events may arrive on any thread.
/// - Implementations own their internal recognition-session lifecycle
///   (restarts on errors, re-anchoring across capture gaps); callers only
///   ever start, feed, and finish.
protocol PreviewTranscriber: AnyObject {
    /// Stable identity recorded on every word this engine produces - data,
    /// never branched on.
    var id: String { get }

    func availability() async -> PreviewTranscriberAvailability

    /// Downloads whatever the engine needs (models, assets). Progress is
    /// observable through `availability()`. No-op when already ready.
    func prepareAssets() async throws

    /// Starts delivering events. Idempotent while running.
    func start(onEvent: @escaping (PreviewTranscriberEvent) -> Void)

    /// One capture buffer, in the writer's canonical format (48kHz mono
    /// float32), stamped with the wall-clock time it was captured.
    func feed(buffer: AVAudioPCMBuffer, at capturedAt: Date)

    /// Flushes any tail words and stops. The engine can be `start`ed again.
    func finish() async
}
