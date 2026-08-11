import AVFoundation
import Foundation

/// Server → client message shapes for ElevenLabs Scribe v2 Realtime.
/// Decoded loosely (every payload field optional beyond `message_type`)
/// because the wire format carries several variants - with and without
/// timestamps, plus typed errors - through one channel, and an unknown or
/// newly-added variant must be ignored rather than kill a live dictation.
private struct RealtimeEnvelope: Decodable {
    let messageType: String
    let text: String?
    let error: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case messageType = "message_type"
        case text, error, message
    }
}

enum RealtimeTranscriptionError: Error, LocalizedError {
    case missingAPIKey
    case disabled
    case connectionFailed(Error)
    case server(type: String, detail: String?)
    case closedUnexpectedly

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "ElevenLabs API key is missing. Add it in Settings → API Keys."
        case .disabled:
            return "Transcription is disabled. Re-enable ElevenLabs in Settings → Transcription Provider."
        case .connectionFailed(let error):
            return "Couldn't reach ElevenLabs Realtime: \(error.localizedDescription)"
        case .server(let type, let detail):
            if let detail, !detail.isEmpty {
                return "ElevenLabs Realtime error (\(type)): \(detail)"
            }
            return "ElevenLabs Realtime error (\(type))."
        case .closedUnexpectedly:
            return "The ElevenLabs Realtime connection closed mid-dictation."
        }
    }

    /// Session-length ceilings are a normal outcome of a long hands-free
    /// dictation, not a fault - the caller treats them as "finish on the
    /// batch path" rather than surfacing an error the user can't act on.
    var isSessionLimit: Bool {
        if case .server(let type, _) = self { return type == "session_time_limit_exceeded" }
        return false
    }
}

/// Streams live microphone audio to ElevenLabs Scribe v2 Realtime and
/// reports transcripts back as they arrive.
///
/// Built on `URLSessionWebSocketTask` - the app ships zero third-party
/// dependencies and this keeps it that way.
///
/// The important distinction this type enforces is **partial vs committed**.
/// Partials are provisional and get revised as more audio arrives; committed
/// text is locked. Only committed text is ever handed onward for insertion
/// into the user's text field, which is what makes streaming insertion
/// append-only and removes any need to reach back into an app we don't own
/// and rewrite text we already typed.
final class RealtimeTranscriptionSession {
    /// This adapter's factual identity - recorded as data on the dictation
    /// row at run time, never branched on in code.
    static let providerID = "elevenlabs"
    static let modelID = "scribe_v2_realtime"

    private static let endpoint = "wss://api.elevenlabs.io/v1/speech-to-text/realtime"

    /// Audio is streamed at the writer's own canonical rate. `SegmentWriter`
    /// already normalizes everything to 48kHz mono float32, so the streamer
    /// is a pure float32 → int16 conversion with no resampler and no second
    /// `AVAudioConverter` to keep correct. Bandwidth (~96 KB/s raw) is not a
    /// constraint for a local push-to-talk.
    private static let sampleRate = 48_000

    /// ~50ms of audio per message: ≈4.8KB raw, ≈6.4KB base64, inside the
    /// 4-8KB per-chunk guidance in ElevenLabs' streaming docs.
    private static let framesPerChunk = 2_400

    /// How long to wait after the final flush for the tail to come back
    /// committed before giving up and closing.
    private static let flushTimeout: TimeInterval = 1.5

    enum Event {
        /// The socket is up and the server accepted the config. Insertion is
        /// only armed after this.
        case started
        /// Provisional text - for display only, never inserted.
        case partial(String)
        /// Locked text. This is the only thing that reaches the keyboard.
        case committed(String)
        case failed(RealtimeTranscriptionError)
    }

    /// Called on the main queue for every event.
    var onEvent: ((Event) -> Void)?

    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)

    /// Guards everything below it - touched from the capture write queue
    /// (audio in), the URLSession delegate queue (messages out), and the
    /// main queue (lifecycle).
    private let lock = NSLock()
    private var pendingSamples: [Int16] = []
    private var isOpen = false
    private var isFinished = false
    /// Every committed message, in order - persisted verbatim so a realtime
    /// dictation keeps the same "raw provider output is on disk" property
    /// the batch path has.
    private var committedMessages: [String] = []

    private var flushContinuation: CheckedContinuation<Void, Never>?
    private var flushTimeoutWork: DispatchWorkItem?

    // MARK: - Lifecycle

    /// Opens the socket. Called at hotkey-down so the handshake happens
    /// while the user is drawing breath, not in the latency path after they
    /// have already started speaking.
    func start() throws {
        let settings = WorklogSettingsStore.load()
        // Checked before the key so a disabled provider reports "disabled,"
        // not "key missing" - same ordering as the batch client.
        guard settings.isElevenLabsEnabled else { throw RealtimeTranscriptionError.disabled }
        guard let apiKey = KeychainStore.read(.elevenLabsAPIKey), !apiKey.isEmpty else {
            throw RealtimeTranscriptionError.missingAPIKey
        }

        var components = URLComponents(string: Self.endpoint)!
        var query: [URLQueryItem] = [
            URLQueryItem(name: "model_id", value: Self.modelID),
            URLQueryItem(name: "audio_format", value: "pcm_\(Self.sampleRate)"),
            // VAD commits at natural pauses, which is exactly the cadence
            // dictation wants: text lands phrase by phrase as the speaker
            // breathes, rather than all at once at the end.
            URLQueryItem(name: "commit_strategy", value: "vad"),
            URLQueryItem(name: "vad_silence_threshold_secs", value: String(settings.effectiveDictationVadSilenceSeconds)),
        ]
        // Only sent when the user picked a specific language - omitting it
        // is what makes the model auto-detect, so "auto" has to be an absent
        // parameter rather than any particular value.
        if let languageCode = settings.effectiveDictationLanguage.code {
            query.append(URLQueryItem(name: "language_code", value: languageCode))
        }
        if settings.isElevenLabsLoggingDisabled {
            query.append(URLQueryItem(name: "enable_logging", value: "false"))
        }
        components.queryItems = query

        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveNext()
    }

    /// Stops streaming and tears the socket down. Safe to call repeatedly.
    func cancel() {
        lock.lock()
        isFinished = true
        isOpen = false
        lock.unlock()
        resumeFlushWaiter()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Flushes the tail and waits (briefly) for it to come back committed.
    ///
    /// The final chunk is sent with `commit: true`. Under
    /// `commit_strategy=vad` the docs define automatic commits and are
    /// silent on whether an explicit commit is also honoured, so this
    /// deliberately does not *depend* on it: the dictation's trailing
    /// silence will trip the VAD threshold on its own, and either route
    /// lands the same trailing `committed_transcript` inside the timeout.
    /// Whichever mechanism fires first, we stop waiting and close.
    func finishAndFlush() async {
        // The lock is only ever taken inside these synchronous helpers,
        // never held across the `await` below - a lock spanning a suspension
        // point can be released on a different thread than took it.
        let pending = drainPendingForFlush()
        guard !pending.wasAlreadyFinished else { return }

        send(samples: pending.samples, commit: true)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard storeFlushWaiter(continuation) else {
                continuation.resume()
                return
            }
            let work = DispatchWorkItem { [weak self] in self?.resumeFlushWaiter() }
            flushTimeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushTimeout, execute: work)
        }

        cancel()
    }

    private func drainPendingForFlush() -> (wasAlreadyFinished: Bool, samples: [Int16]) {
        lock.lock()
        defer { lock.unlock() }
        let samples = pendingSamples
        pendingSamples = []
        return (isFinished, samples)
    }

    /// Returns `false` when the session already finished, so the caller
    /// resumes immediately rather than waiting for a tail that will never
    /// arrive.
    private func storeFlushWaiter(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return false }
        flushContinuation = continuation
        return true
    }

    /// Everything the server committed, joined the way it will be inserted.
    var committedText: String {
        lock.lock()
        defer { lock.unlock() }
        return committedMessages.joined(separator: " ")
    }

    /// The committed messages as a JSON array, for `transcript.json`.
    var rawTranscriptJSON: Data? {
        lock.lock()
        let messages = committedMessages
        lock.unlock()
        return try? JSONSerialization.data(withJSONObject: messages, options: [.prettyPrinted])
    }

    // MARK: - Audio in

    /// Converts one canonical capture buffer to int16 and queues it. Called
    /// on `SegmentWriter`'s write queue, which also drives disk writes for
    /// the always-on recording - this does a bounded conversion and returns,
    /// never any network work.
    func append(buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        var converted = [Int16](repeating: 0, count: frames)
        for index in 0..<frames {
            // Clamp before scaling: capture floats are nominally [-1, 1] but
            // a hot mic can overshoot, and wrapping that into int16 turns a
            // loud syllable into a burst of noise the model then has to
            // transcribe.
            let sample = max(-1, min(1, channel[index]))
            converted[index] = Int16(sample * Float(Int16.max))
        }

        lock.lock()
        guard isOpen, !isFinished else {
            lock.unlock()
            return
        }
        pendingSamples.append(contentsOf: converted)
        var chunks: [[Int16]] = []
        while pendingSamples.count >= Self.framesPerChunk {
            chunks.append(Array(pendingSamples.prefix(Self.framesPerChunk)))
            pendingSamples.removeFirst(Self.framesPerChunk)
        }
        lock.unlock()

        for chunk in chunks {
            send(samples: chunk, commit: false)
        }
    }

    private func send(samples: [Int16], commit: Bool) {
        guard let task else { return }
        // An empty final flush still has to go out - `commit` is the signal,
        // not the audio - but empty non-final chunks are pure overhead.
        guard !samples.isEmpty || commit else { return }

        var littleEndian = samples.map { $0.littleEndian }
        let data = littleEndian.withUnsafeBufferPointer { Data(buffer: $0) }
        littleEndian.removeAll()

        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": data.base64EncodedString(),
            "sample_rate": Self.sampleRate,
            "commit": commit,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: json, encoding: .utf8) else { return }

        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            self?.fail(.connectionFailed(error))
        }
    }

    // MARK: - Messages out

    private func receiveNext() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.lock.lock()
                let finished = self.isFinished
                self.lock.unlock()
                // A cancel we initiated surfaces here as an error too;
                // that's an ordinary shutdown, not a dictation failure.
                if !finished { self.fail(.connectionFailed(error)) }
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handle(text: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { self.handle(text: text) }
                @unknown default:
                    break
                }
                self.receiveNext()
            }
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(RealtimeEnvelope.self, from: data) else { return }

        switch envelope.messageType {
        case "session_started":
            lock.lock()
            isOpen = true
            lock.unlock()
            emit(.started)

        case "partial_transcript":
            guard let text = envelope.text, !text.isEmpty else { return }
            emit(.partial(text))

        case "committed_transcript", "committed_transcript_with_timestamps":
            guard let text = envelope.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            lock.lock()
            committedMessages.append(text)
            lock.unlock()
            emit(.committed(text))
            // The tail we were waiting on after the final flush has landed;
            // no reason to sit out the rest of the timeout.
            resumeFlushWaiter()

        case "final_transcript", "final_transcript_with_timestamps":
            // Complete but not yet locked. The commit for the same span
            // normally follows immediately, and taking both would duplicate
            // the text, so this is deliberately not accumulated here.
            break

        default:
            // Everything else on this channel is a typed error.
            if envelope.messageType.hasSuffix("error") || envelope.error != nil {
                fail(.server(type: envelope.messageType, detail: envelope.error ?? envelope.message))
            }
        }
    }

    private func fail(_ error: RealtimeTranscriptionError) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        isOpen = false
        lock.unlock()

        resumeFlushWaiter()
        emit(.failed(error))
    }

    private func resumeFlushWaiter() {
        lock.lock()
        let continuation = flushContinuation
        flushContinuation = nil
        lock.unlock()

        flushTimeoutWork?.cancel()
        flushTimeoutWork = nil
        continuation?.resume()
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }
}
