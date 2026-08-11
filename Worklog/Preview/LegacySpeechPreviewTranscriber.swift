import AVFoundation
import Foundation
import Speech
import os

/// The on-device preview engine for iOS 17 through 25, before
/// `SpeechAnalyzer` existed.
///
/// `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` is a genuine
/// local recognizer: no account, no network, nothing leaves the phone. It is
/// worse than `SpeechAnalyzer` in two ways that matter here, and both are
/// worked around rather than papered over:
///
/// - **It reports timings per segment, not per word.** A segment is usually a
///   word but can be a short phrase, so each segment's words are spread across
///   its window in proportion to their length. Approximate, and fine: the
///   window itself is real, so a word still lands within about a second of
///   where it was said. The same compromise the Android build makes for its
///   ML Kit engine.
///
/// - **A recognition task has a hard length limit** (around a minute in
///   practice, and it simply stops). An all-day recorder cannot live with
///   that, so tasks are rotated: a new one starts before the old one is
///   finished, and results are stitched onto one wall clock.
///
/// Crucially, it never opens the microphone. Audio arrives through
/// `SFSpeechAudioBufferRecognitionRequest.append`, which is what makes this
/// safe to run alongside the recording - unlike Android, where a recognizer
/// left to listen on its own silences the app's own capture to digital zero.
final class LegacySpeechPreviewTranscriber: PreviewTranscriber {
    let id = "apple_sfspeech"

    private let previewLog = Logger(subsystem: "com.rishabhrao.worklog", category: "preview")

    /// Tasks are rotated well before `SFSpeechRecognizer`'s own limit rather
    /// than waiting to be cut off mid-sentence.
    private static let taskRotateInterval: TimeInterval = 45
    /// A gap this long means the audio is no longer continuous, so the next
    /// buffer starts a fresh task and a fresh anchor.
    private static let rotateGap: TimeInterval = 1.5

    private let queue = DispatchQueue(label: "worklog.preview.sfspeech")

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var onEvent: ((PreviewTranscriberEvent) -> Void)?
    private var isRunning = false

    /// Wall-clock time of the first buffer in the current task. Results come
    /// back relative to the task, so this is what turns them into real times.
    private var sessionAnchor: Date?
    private var lastFedAt: Date?
    private var sessionStartedAt: Date?

    /// Words already emitted for the current task, so a revised result only
    /// emits the part that is new. `SFSpeechRecognizer` re-sends the whole
    /// transcription each time it refines it.
    private var emittedCount = 0

    /// Converts the capture format to the 16kHz mono the recognizer wants.
    private var converter: AVAudioConverter?
    private static let recognizerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    // MARK: - PreviewTranscriber

    func availability() async -> PreviewTranscriberAvailability {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        switch status {
        case .authorized:
            break
        case .denied, .restricted:
            return .unavailable("Speech recognition permission was denied. Grant it in Settings › Worklog.")
        case .notDetermined:
            return .unavailable("Speech recognition permission hasn't been granted yet.")
        @unknown default:
            return .unavailable("Speech recognition is unavailable.")
        }

        guard let recognizer = SFSpeechRecognizer(locale: Self.preferredLocale()) else {
            return .unavailable("No on-device recognizer for \(Self.preferredLocale().identifier).")
        }
        guard recognizer.isAvailable else {
            return .unavailable("The speech recognizer is temporarily unavailable.")
        }
        // The one that actually matters: without an installed on-device model
        // this recognizer would silently fall back to Apple's servers, and
        // sending a day of audio to a server is precisely what this feature
        // exists to avoid.
        guard recognizer.supportsOnDeviceRecognition else {
            return .unavailable("This device has no offline model for \(Self.preferredLocale().identifier). Add the language under Settings › General › Keyboard › Dictation Languages.")
        }
        return .ready
    }

    /// Nothing to fetch: the offline model arrives with the system language
    /// pack, which the app cannot trigger a download for. `availability()`
    /// says so in words instead.
    func prepareAssets() async throws {}

    func start(onEvent: @escaping (PreviewTranscriberEvent) -> Void) {
        queue.async {
            guard !self.isRunning else { return }
            self.onEvent = onEvent
            self.isRunning = true
            self.recognizer = SFSpeechRecognizer(locale: Self.preferredLocale())
            self.recognizer?.defaultTaskHint = .dictation
        }
    }

    func feed(buffer: AVAudioPCMBuffer, at capturedAt: Date) {
        guard let converted = convert(buffer) else { return }
        queue.async {
            guard self.isRunning else { return }

            // Rotate on a real gap in the audio, or on age. Either way the
            // next task re-anchors, so nothing drifts.
            if let last = self.lastFedAt, capturedAt.timeIntervalSince(last) > Self.rotateGap {
                self.rotateTask()
            } else if let started = self.sessionStartedAt, capturedAt.timeIntervalSince(started) > Self.taskRotateInterval {
                self.rotateTask()
            }

            if self.request == nil {
                self.beginTask(anchor: capturedAt)
            }
            self.lastFedAt = capturedAt
            self.request?.append(converted)
        }
    }

    func finish() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.isRunning = false
                self.endTask()
                self.recognizer = nil
                self.onEvent = nil
                continuation.resume()
            }
        }
    }

    // MARK: - Task lifecycle

    private func beginTask(anchor: Date) {
        guard let recognizer, recognizer.isAvailable else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }

        sessionAnchor = anchor
        sessionStartedAt = anchor
        emittedCount = 0
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.queue.async {
                if let result {
                    self.handle(result: result)
                }
                if error != nil {
                    // A task ending is routine here - it is how the length
                    // limit manifests. The next buffer opens a fresh one.
                    self.endTask()
                }
            }
        }
    }

    private func rotateTask() {
        endTask()
    }

    private func endTask() {
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil
        sessionAnchor = nil
        sessionStartedAt = nil
        emittedCount = 0
        converter = nil
    }

    private func handle(result: SFSpeechRecognitionResult) {
        guard let anchor = sessionAnchor else { return }
        let segments = result.bestTranscription.segments

        // The provisional tail: everything not yet finalized, shown live and
        // never persisted.
        if !result.isFinal {
            let tail = segments.dropFirst(emittedCount).map(\.substring).joined(separator: " ")
            onEvent?(.volatile(tail))
            return
        }

        onEvent?(.volatile(""))
        let fresh = segments.dropFirst(emittedCount)
        guard !fresh.isEmpty else { return }
        emittedCount = segments.count

        var words: [PreviewWord] = []
        for segment in fresh {
            let start = anchor.addingTimeInterval(segment.timestamp)
            let end = anchor.addingTimeInterval(segment.timestamp + segment.duration)
            // A segment is usually one word but can be a short phrase. Spread
            // its words across its window by length rather than reporting
            // them all at the same instant, which would stack them on one
            // pixel of the clip timeline.
            let tokens = segment.substring.split(separator: " ").map(String.init)
            guard tokens.count > 1 else {
                words.append(PreviewWord(start: start, end: end, text: segment.substring))
                continue
            }
            let totalChars = max(1, tokens.reduce(0) { $0 + $1.count })
            let span = max(0.05, end.timeIntervalSince(start))
            var cursor = 0.0
            for token in tokens {
                let fraction = Double(token.count) / Double(totalChars)
                let wordStart = start.addingTimeInterval(span * cursor)
                cursor += fraction
                let wordEnd = start.addingTimeInterval(span * min(cursor, 1.0))
                words.append(PreviewWord(start: wordStart, end: wordEnd, text: token))
            }
        }
        guard !words.isEmpty else { return }
        onEvent?(.words(words))
    }

    // MARK: - Format

    /// The recording's canonical 48kHz mono float down to the recognizer's
    /// 16kHz. Rebuilt whenever the delivered format changes.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let target = Self.recognizerFormat
        if buffer.format.sampleRate == target.sampleRate,
           buffer.format.channelCount == target.channelCount,
           buffer.format.commonFormat == target.commonFormat {
            return buffer
        }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return nil }

        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var served = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if served {
                status.pointee = .noDataNow
                return nil
            }
            served = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// The language the user picked in Settings, falling back to the device
    /// language. Same source of truth the iOS 26 engine reads.
    private static func preferredLocale() -> Locale {
        let settings = WorklogSettingsStore.load()
        if let tag = settings.preferredPreviewLocales.first, !tag.isEmpty {
            return Locale(identifier: tag)
        }
        return Locale.current
    }
}
