import Foundation

/// Raw response shape from ElevenLabs Scribe v2 (ticket Appendix A) - stored
/// verbatim to disk, never remodeled, so the saved JSON is byte-identical to
/// what the API returned.
struct TranscriptWord: Codable {
    let text: String
    let start: Double?
    let end: Double?
    let type: String
    let speakerID: String?

    enum CodingKeys: String, CodingKey {
        case text, start, end, type
        case speakerID = "speaker_id"
    }

    private enum DecodingKeys: String, CodingKey {
        case text, word, start, end, type
        case speakerID = "speaker_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        // Native Scribe words carry "text"; the OpenAI-compatible shape (a
        // LiteLLM proxy) calls the same thing "word" and omits type/speaker.
        text = try container.decodeIfPresent(String.self, forKey: .text)
            ?? container.decodeIfPresent(String.self, forKey: .word) ?? ""
        start = try container.decodeIfPresent(Double.self, forKey: .start)
        end = try container.decodeIfPresent(Double.self, forKey: .end)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "word"
        speakerID = try container.decodeIfPresent(String.self, forKey: .speakerID)
    }
}

struct TranscriptResponse: Codable {
    let text: String
    let words: [TranscriptWord]
    let audioDurationSecs: Double?

    enum CodingKeys: String, CodingKey {
        case text, words
        case audioDurationSecs = "audio_duration_secs"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        // Absent on OpenAI-shape responses that carry text only.
        words = try container.decodeIfPresent([TranscriptWord].self, forKey: .words) ?? []
        audioDurationSecs = try container.decodeIfPresent(Double.self, forKey: .audioDurationSecs)
    }
}

enum TranscriptionError: Error, LocalizedError {
    case missingAPIKey
    case disabled
    case networkError(Error)
    case apiError(statusCode: Int, body: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "ElevenLabs API key is missing. Add it in Settings → API Keys."
        case .disabled:
            return "Transcription is disabled. Re-enable ElevenLabs in Settings → Transcription Provider."
        case .networkError(let error):
            return "Network error contacting ElevenLabs: \(error.localizedDescription)"
        case .apiError(let statusCode, let body):
            return "ElevenLabs Scribe returned an error (\(statusCode)): \(body.prefix(200))"
        case .invalidResponse:
            return "ElevenLabs Scribe returned an unreadable response."
        }
    }
}

/// Calls ElevenLabs Scribe v2 (spec `07-transcription-pipeline.md`). Sends
/// the whole clip in a single multipart request regardless of length - no
/// chunking, per the ticket's explicit "keep this path dead simple" note.
enum TranscriptionClient {
    static let defaultBaseURL = "https://api.elevenlabs.io"

    /// `enable_logging=false` opts the call out of ElevenLabs' own
    /// request/response logging (zero-retention mode) - but the parameter
    /// is enterprise-gated and fails outright on standard API keys, so it
    /// only rides along when the Settings toggle is on (default off). A
    /// native-API knob: the unified route has no equivalent.
    ///
    /// The origin is swappable; the path per API shape is not. An override
    /// that doesn't parse as a URL falls back to the official endpoint
    /// rather than crashing.
    private static func endpoint(for settings: WorklogSettings, openAiCompatible: Bool) -> URL {
        var origin = settings.elevenLabsBaseURL?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        while origin.hasSuffix("/") { origin.removeLast() }
        if origin.isEmpty { origin = defaultBaseURL }
        let path = openAiCompatible ? "/v1/audio/transcriptions" : "/v1/speech-to-text"
        let query = (!openAiCompatible && settings.isElevenLabsLoggingDisabled) ? "?enable_logging=false" : ""
        return URL(string: origin + path + query)
            ?? URL(string: defaultBaseURL + path + query)!
    }

    /// This adapter's factual identity - recorded as data on the transcript
    /// row at run time (shown in the Library detail's section subtitle),
    /// never branched on elsewhere in code.
    static let providerID = "elevenlabs"
    static let defaultModel = "scribe_v2"

    /// The model actually sent (and recorded on rows): the Settings
    /// override, or the default.
    static func effectiveModel(for settings: WorklogSettings) -> String {
        let trimmed = settings.elevenLabsModel?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    static func effectiveModel() -> String {
        effectiveModel(for: WorklogSettingsStore.load())
    }

    /// Returns the raw response body (stored verbatim) alongside the parsed
    /// struct, so the caller can persist the exact bytes ElevenLabs sent.
    ///
    /// `diarize` is off for dictations: speaker labels are meaningless when
    /// it's one person talking into their own mic, and asking for them is a
    /// needless cost on every push-to-talk.
    ///
    /// `languageCode` defaults to `nil`, which omits the parameter entirely
    /// so the model auto-detects - the clip pipeline depends on that, since
    /// its audio mixes Hindi and English. Dictation can pin a language when
    /// the user knows they only speak one.
    static func transcribe(clipURL: URL, diarize: Bool = true, languageCode: String? = nil) async throws -> (raw: Data, parsed: TranscriptResponse) {
        // Checked before the key so a disabled provider reports "disabled,"
        // not "key missing" - the key is still saved, just paused.
        let settings = WorklogSettingsStore.load()
        guard settings.isElevenLabsEnabled else {
            throw TranscriptionError.disabled
        }
        guard let apiKey = KeychainStore.read(.elevenLabsAPIKey), !apiKey.isEmpty else {
            throw TranscriptionError.missingAPIKey
        }

        // A provider-prefixed model ("elevenlabs/scribe_v2") is LiteLLM's
        // unified naming - those deployments expose transcription on the
        // OpenAI-style /v1/audio/transcriptions route, not ElevenLabs'
        // native one. A bare id keeps the native route. This is what lets a
        // plain LiteLLM proxy work with no passthrough config at all - at
        // the documented cost of diarization, which LiteLLM's response
        // transformation drops before it reaches us.
        let model = Self.effectiveModel(for: settings)
        let openAiCompatible = model.contains("/")

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint(for: settings, openAiCompatible: openAiCompatible))
        request.httpMethod = "POST"
        // URLSession's default 60s request timeout is easily exceeded by
        // uploading and transcribing a full-length clip - give it enough
        // room instead of failing on exactly the long clips this pipeline
        // exists for.
        request.timeoutInterval = 600
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        // A base-URL override means a LiteLLM-style proxy, which
        // authenticates its own virtual keys via the standard Authorization
        // header before injecting the real provider key upstream. Only sent
        // for overrides - ElevenLabs itself reads xi-api-key alone.
        let baseOverride = settings.elevenLabsBaseURL?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !baseOverride.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let clipData = try Data(contentsOf: clipURL)
        request.httpBody = try buildMultipartBody(boundary: boundary, clipData: clipData, filename: clipURL.lastPathComponent, model: model, diarize: diarize, languageCode: languageCode, openAiCompatible: openAiCompatible)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TranscriptionError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<unreadable>"
            throw TranscriptionError.apiError(statusCode: httpResponse.statusCode, body: body)
        }

        do {
            let parsed = try JSONDecoder().decode(TranscriptResponse.self, from: data)
            return (data, parsed)
        } catch {
            throw TranscriptionError.invalidResponse
        }
    }

    private static func buildMultipartBody(boundary: String, clipData: Data, filename: String, model: String, diarize: Bool, languageCode: String?, openAiCompatible: Bool) throws -> Data {
        var body = Data()

        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        // model_id + diarize are required per spec; num_speakers omitted
        // entirely so the model decides speaker count. tag_audio_events left
        // at its API default (true) by omission. no_verbatim intentionally
        // never sent - the ticket requires verbatim transcription with filler
        // words included.
        //
        // language_code is only appended when the caller names one. Sending
        // nothing is what triggers auto-detection, and that has to stay the
        // default: clip audio mixes Hindi and English, so pinning a language
        // there would actively hurt. Dictation opts in explicitly.
        if openAiCompatible {
            appendField(name: "model", value: model)
            // Asked for even though today's LiteLLM strips the speaker
            // labels out of the response (verified live: words come back as
            // word/start/end only) - Scribe bills per minute either way,
            // and the decoder already reads speaker_id, so a proxy that
            // starts preserving it lights up diarization with no app change.
            appendField(name: "diarize", value: diarize ? "true" : "false")
            // The unified route's OpenAI-named parameter; the proxy maps it
            // to language_code.
            if let languageCode, !languageCode.isEmpty {
                appendField(name: "language", value: languageCode)
            }
        } else {
            appendField(name: "model_id", value: model)
            appendField(name: "diarize", value: diarize ? "true" : "false")
            if let languageCode, !languageCode.isEmpty {
                appendField(name: "language_code", value: languageCode)
            }
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(clipData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}
