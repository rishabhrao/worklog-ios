import Foundation

enum LLMError: Error, LocalizedError {
    case missingAPIKey
    case disabled
    case invalidBaseURL(String)
    case networkError(Error)
    case apiError(statusCode: Int, body: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Anthropic API key is missing. Add it in Settings → LLM Provider."
        case .disabled:
            return "The LLM step is disabled. Re-enable Anthropic in Settings → LLM Provider."
        case .invalidBaseURL(let value):
            return "The LLM Provider base URL (\"\(value)\") isn't a valid URL. Check it in Settings → LLM Provider."
        case .networkError(let error):
            return "Network error contacting the LLM provider: \(error.localizedDescription)"
        case .apiError(let statusCode, let body):
            return "The LLM provider returned an error (\(statusCode)): \(body.prefix(200))"
        case .invalidResponse:
            return "The LLM provider returned an unreadable response."
        }
    }
}

/// What one LLM call consumed, and what it cost.
///
/// The Messages API returns token counts but no price. A LiteLLM-style proxy
/// in front of it *does* return a real, post-discount figure in the
/// `x-litellm-response-cost` response header - when that's present it's
/// authoritative and beats anything computed from a rate table, because it
/// reflects the actual billing arrangement rather than Anthropic list price.
struct LLMUsage {
    let inputTokens: Int
    let outputTokens: Int
    /// Input tokens served from the prompt cache rather than re-read. The
    /// number that proves caching is actually working - without it, "we send
    /// the header" is a claim rather than a measurement.
    var cachedInputTokens: Int = 0
    /// Input tokens written into the cache by this call (the first one pays a
    /// small premium for it).
    var cacheWriteTokens: Int = 0
    /// Provider-reported cost in USD, when the endpoint supplies one.
    let reportedCostUSD: Double?

    /// The cost to persist, preferring the provider's own figure and falling
    /// back to list-rate arithmetic. Returns `nil` when neither is available
    /// (an unknown model with no reporting proxy) - better to show nothing
    /// than a fabricated number.
    func resolvedCost(model: String) -> (usd: Double, source: CostSource)? {
        if let reportedCostUSD {
            return (reportedCostUSD, .reported)
        }
        guard let estimate = Pricing.llmCostUSD(model: model, inputTokens: inputTokens, outputTokens: outputTokens) else {
            return nil
        }
        return (estimate, .estimated)
    }
}

/// Thin Messages-API wrapper structured as a reusable "run this prompt
/// against this text" function (ticket §9 phase-2 headroom note), so a
/// future phase-2 summary/MoM/actionables step reuses this call path rather
/// than re-plumbing API access, keys, and request shape.
///
/// Base URL, model, and effort are user-overridable from Settings → LLM
/// Provider (`WorklogSettings.anthropicBaseURL`/`.anthropicModel`/
/// `.anthropicEffort`) so this can point at a self-hosted/proxied
/// Anthropic-compatible endpoint (e.g. a LiteLLM proxy) or a model that
/// doesn't support `output_config.effort` at all (e.g. Opus) - all three
/// default to the built-in behavior when unset, so existing installs behave
/// unchanged.
enum LLMClient {
    /// This adapter's factual identity - recorded as data on the
    /// translation row at run time, never branched on elsewhere in code.
    static let providerID = "anthropic"
    static let defaultBaseURL = "https://api.anthropic.com"
    /// Sonnet 5 is the current-generation Sonnet at time of writing (per the
    /// `claude-api` skill's model catalog) - the ticket's own suggested ID.
    static let defaultModel = "claude-sonnet-5"
    /// Default effort when the user hasn't overridden it - cheap mechanical
    /// transliteration doesn't need deep reasoning. An explicit empty
    /// override means "omit `output_config` entirely," for models (e.g.
    /// Opus at time of writing) that reject the parameter outright.
    static let defaultEffort = "low"

    /// Runs a fixed system prompt against arbitrary input text and returns
    /// Claude's full text response plus the model that actually served it
    /// (the settings override or the built-in default, resolved at call
    /// time - persisted per-transcript so the Library can show what a
    /// given translation was produced with, even after Settings change).
    /// Single call, no streaming - sufficient for typical 10-15 min clip
    /// transcripts (long-transcript splitting is explicitly out of scope
    /// per spec `07-transcription-pipeline.md`).
    /// `modelOverride` lets one pipeline step run on a different model from
    /// the provider default - resolved here, at call time, and returned so
    /// the row records what actually served it.
    /// `cachedPrefix` is text that repeats across calls - for this app, the
    /// transcript, which every translation, summary and tagging call for one
    /// clip sends identically. It goes first, with a cache breakpoint, so
    /// calls two through eight read it instead of re-sending it.
    ///
    /// It has to sit ahead of the step's own instructions: a provider caches
    /// a *prefix*, so anything that differs per step must come after the
    /// breakpoint or nothing is shared. That is also why the step prompts
    /// themselves aren't the cached part - at 200-500 tokens they are all
    /// well under the 1024-token minimum a cache breakpoint requires, so
    /// marking them would cache nothing.
    static func runPrompt(
        system: String,
        input: String,
        cachedPrefix: String? = nil,
        modelOverride: String? = nil,
        maxTokens: Int = 16000
    ) async throws -> (text: String, model: String, usage: LLMUsage) {
        let settings = WorklogSettingsStore.load()
        // Checked before the key so a disabled provider reports "disabled,"
        // not "key missing" - the key is still saved, just paused.
        guard settings.isAnthropicEnabled else {
            throw LLMError.disabled
        }
        guard let apiKey = KeychainStore.read(.anthropicAPIKey), !apiKey.isEmpty else {
            throw LLMError.missingAPIKey
        }
        let baseURLString = settings.anthropicBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBase = (baseURLString?.isEmpty == false ? baseURLString! : defaultBaseURL)
        guard var components = URLComponents(string: resolvedBase) else {
            throw LLMError.invalidBaseURL(resolvedBase)
        }
        components.path = components.path.hasSuffix("/v1/messages") ? components.path : components.path + "/v1/messages"
        guard let endpoint = components.url else {
            throw LLMError.invalidBaseURL(resolvedBase)
        }

        // Step override first, then the provider-wide model, then the
        // built-in default.
        let override = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerModel = settings.anthropicModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = [override, providerModel].compactMap { $0 }.first { !$0.isEmpty } ?? defaultModel

        // The task goes in `system`, not glued onto the front of the user
        // turn. Concatenating them made the model read the whole request as
        // conversation and reply conversationally - "Sure, here's the
        // translation:" - which was then saved verbatim as the artifact.
        // Separating them leaves the user turn as pure content to act on.
        // System as content blocks rather than a bare string, so the shared
        // prefix can carry a cache breakpoint. With no prefix this is a
        // single block and behaves exactly like the string form.
        var systemBlocks: [[String: Any]] = []
        if let cachedPrefix, !cachedPrefix.isEmpty {
            systemBlocks.append([
                "type": "text",
                "text": cachedPrefix,
                "cache_control": ["type": "ephemeral"],
            ])
        }
        systemBlocks.append(["type": "text", "text": system])

        var requestBody: [String: Any] = [
            "model": resolvedModel,
            "max_tokens": maxTokens,
            "system": systemBlocks,
            "messages": [
                ["role": "user", "content": input],
            ],
        ]

        // Effort is genuinely optional at the API level (not just "use a
        // default value") - some models (e.g. Opus at time of writing)
        // reject `output_config` outright with a 400 if it's present at
        // all, so a blank override must omit the key entirely rather than
        // send an empty/default effort string.
        let effort = settings.anthropicEffort?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let effort, !effort.isEmpty {
            requestBody["output_config"] = ["effort": effort]
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // URLSession's default 60s request timeout is comfortably exceeded
        // by a full-length (10-15 min) clip's translation: large input plus
        // a slow, lengthy generation. Give it enough room instead of
        // failing mid-response on exactly the long clips this pipeline
        // exists for.
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LLMError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<unreadable>"
            throw LLMError.apiError(statusCode: httpResponse.statusCode, body: body)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]]
        else {
            throw LLMError.invalidResponse
        }

        let text = content.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined()

        guard !text.isEmpty else { throw LLMError.invalidResponse }

        let usageJSON = json["usage"] as? [String: Any]
        let usage = LLMUsage(
            inputTokens: usageJSON?["input_tokens"] as? Int ?? 0,
            outputTokens: usageJSON?["output_tokens"] as? Int ?? 0,
            cachedInputTokens: usageJSON?["cache_read_input_tokens"] as? Int ?? 0,
            cacheWriteTokens: usageJSON?["cache_creation_input_tokens"] as? Int ?? 0,
            reportedCostUSD: reportedCost(from: httpResponse, body: json)
        )
        return (text, resolvedModel, usage)
    }

    /// Digs a provider-reported cost out of the response, if there is one.
    ///
    /// LiteLLM puts the final (post-discount) figure in
    /// `x-litellm-response-cost` on non-streaming responses, which is what
    /// this client makes. The body key is checked too because some proxies
    /// surface it there instead, and header casing is normalized because
    /// header lookup is only case-insensitive on newer macOS.
    private static func reportedCost(from response: HTTPURLResponse, body: [String: Any]) -> Double? {
        let headerNames = ["x-litellm-response-cost", "x-response-cost"]
        for (key, value) in response.allHeaderFields {
            guard let name = (key as? String)?.lowercased(), headerNames.contains(name) else { continue }
            if let cost = Double("\(value)"), cost > 0 { return cost }
        }
        for key in ["_response_cost", "response_cost"] {
            if let cost = body[key] as? Double, cost > 0 { return cost }
        }
        return nil
    }
}
