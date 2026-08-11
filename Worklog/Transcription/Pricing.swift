import Foundation

/// Where a cost figure came from. Displayed, not just stored: "what your
/// proxy actually billed" and "what this would cost at list price" are
/// different claims, and showing an estimate as if it were an invoice is the
/// one genuinely misleading thing this feature could do.
enum CostSource: String {
    /// Reported by the provider itself (a LiteLLM-style proxy returns the
    /// real, post-discount figure in a response header).
    case reported
    /// Computed here from usage × published list rates.
    case estimated
}

/// Cost estimation for the API calls this app makes.
///
/// Rates are hardcoded because neither provider returns a price with the
/// response: ElevenLabs returns none at all, and the Anthropic Messages API
/// returns token *usage* but no dollar figure. A proxy in front of Anthropic
/// may return a real cost, and when it does that always wins over anything
/// computed here - see `LLMUsage.reportedCostUSD`.
///
/// **These numbers will go stale.** They are a convenience for "roughly what
/// did that cost me", not an accounting record. Every figure derived from
/// them is stamped `.estimated` and labelled as such in the UI.
enum Pricing {
    // MARK: - Speech to text (ElevenLabs)

    /// USD per hour of audio, billed per audio minute.
    /// Source: elevenlabs.io/pricing/api, checked 2026-08-01.
    private static let scribeRatesPerHour: [String: Double] = [
        "scribe_v2": 0.22,
        "scribe_v2_realtime": 0.39,
    ]

    /// Cost of transcribing `seconds` of audio with `model`. `nil` for an
    /// unrecognised model - showing nothing is better than showing a number
    /// derived from a guess.
    static func transcriptionCostUSD(model: String?, seconds: Double) -> Double? {
        guard let model, let perHour = scribeRatesPerHour[model], seconds > 0 else { return nil }
        return perHour * (seconds / 3600.0)
    }

    // MARK: - LLM (Anthropic)

    struct LLMRate {
        /// USD per million input tokens.
        let input: Double
        /// USD per million output tokens.
        let output: Double
    }

    /// Base (non-cached, non-batch) rates per million tokens.
    /// Source: platform.claude.com/docs/en/about-claude/pricing, checked
    /// 2026-08-01. Keys are matched as substrings of the configured model ID,
    /// so dated IDs like `claude-haiku-4-5-20251001` resolve without needing
    /// an entry per snapshot.
    ///
    /// Longest key wins, so `claude-haiku-4-5` is preferred over a
    /// hypothetical `claude-haiku` - otherwise a shorter prefix could shadow
    /// the more specific rate.
    private static let llmRates: [String: LLMRate] = [
        "claude-fable-5": LLMRate(input: 10, output: 50),
        "claude-opus-5": LLMRate(input: 5, output: 25),
        "claude-opus-4-8": LLMRate(input: 5, output: 25),
        "claude-opus-4-7": LLMRate(input: 5, output: 25),
        "claude-opus-4-6": LLMRate(input: 5, output: 25),
        "claude-opus-4-5": LLMRate(input: 5, output: 25),
        "claude-opus-4-1": LLMRate(input: 15, output: 75),
        // Sonnet 5 is on introductory pricing ($2/$10) through 2026-08-31,
        // rising to $3/$15. Deliberately left at the introductory rate rather
        // than date-switching in code: a wrong-but-obvious number the user
        // can reason about beats a silent change on a date nobody remembers.
        "claude-sonnet-5": LLMRate(input: 2, output: 10),
        "claude-sonnet-4-6": LLMRate(input: 3, output: 15),
        "claude-sonnet-4-5": LLMRate(input: 3, output: 15),
        "claude-haiku-4-5": LLMRate(input: 1, output: 5),
        "claude-haiku-3-5": LLMRate(input: 0.8, output: 4),
    ]

    static func llmRate(for model: String?) -> LLMRate? {
        guard let model else { return nil }
        let normalized = model.lowercased()
        return llmRates
            .filter { normalized.contains($0.key) }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    static func llmCostUSD(model: String?, inputTokens: Int, outputTokens: Int) -> Double? {
        guard let rate = llmRate(for: model) else { return nil }
        let input = Double(inputTokens) / 1_000_000 * rate.input
        let output = Double(outputTokens) / 1_000_000 * rate.output
        return input + output
    }

    // MARK: - Formatting

    /// Formats a cost for display. Single-call costs here are routinely a
    /// small fraction of a cent, so a fixed 2-decimal currency format would
    /// render almost everything as "$0.00" - the precision scales with the
    /// magnitude instead, and anything genuinely tiny but nonzero is shown
    /// as `<$0.0001` rather than rounded away to nothing.
    static func format(_ usd: Double) -> String {
        if usd <= 0 { return "$0" }
        if usd < 0.0001 { return "<$0.0001" }
        if usd < 0.01 { return String(format: "$%.4f", usd) }
        if usd < 1 { return String(format: "$%.3f", usd) }
        return String(format: "$%.2f", usd)
    }

    /// The string shown next to a model ID, e.g. `~$0.0008 est.` or
    /// `$0.0007`. `nil` when there's nothing trustworthy to show.
    static func label(costUSD: Double?, source: CostSource?) -> String? {
        guard let costUSD else { return nil }
        let formatted = format(costUSD)
        guard source == .estimated else { return formatted }
        return "~\(formatted) est."
    }
}
