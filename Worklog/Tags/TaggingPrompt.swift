import Foundation

/// The prompt and the parsing for auto-tagging.
///
/// The system prompt is a **constant**. Nothing about the clip, the current
/// vocabulary, or the settings goes into it, because a system prompt that
/// changes per call is a cache prefix that never repeats - and this step runs
/// once per clip, forever. Everything variable goes in the user turn, after
/// the cacheable part.
enum TaggingPrompt {
    /// A ceiling, not a target. The model is told to use what the recording
    /// warrants; this only stops a confused response from assigning forty.
    static let maxTagsPerClip = 8

    /// Static by construction - see the type's note. Do not interpolate.
    static let systemPrompt = """
    You tag recordings of real conversations and work sessions so they can be found again months later.

    You will be given a transcript, then the tags already in use. Reply with a JSON array of tag names and nothing else - no prose, no explanation, no code fences.

    What makes a good tag:
    - It names something a person would actually search for later: a project, a product area, a topic, a recurring kind of session, a company or team.
    - It holds up across recordings. "hiring" is a tag; "the Tuesday call about the invoice" is not.
    - It describes what the recording is about, not every subject that got mentioned once.

    How to choose them:
    - Reuse a tag from the list whenever it genuinely fits, copied exactly as written. A consistent vocabulary is what makes tags worth having.
    - Create a new tag whenever the recording is about something the list doesn't already cover. Do not strain to reuse a tag that only nearly fits, and do not leave a recording under-described because the right tag doesn't exist yet - a missing tag is worse than a new one.
    - Cover the recording properly. Two to five tags is usual; use more when it genuinely spans more, fewer when it is about one thing.
    - Tag the substance, and where it is useful also tag the kind of session (for example: standup, interview, planning, debugging, one on one).

    Format:
    - Lowercase.
    - One or two words, three at most.
    - No punctuation, no hashes, no dates.
    - No names of individual people unless the recording is genuinely about that person.

    Reply with the JSON array only.
    """

    /// The variable half: the current vocabulary and any constraint. The
    /// transcript is *not* here - it goes in the cached prefix ahead of the
    /// system prompt, because every other call for the same clip sends it
    /// too. The vocabulary belongs after that breakpoint since it grows as
    /// tags are created.
    static func userMessage(existingTags: [String], allowNewTags: Bool) -> String {
        var sections: [String] = []

        if existingTags.isEmpty {
            sections.append("Tags already in use: none yet. You are starting this vocabulary, so choose names worth reusing.")
        } else {
            sections.append("Tags already in use:\n" + existingTags.sorted().map { "- \($0)" }.joined(separator: "\n"))
        }

        if !allowNewTags {
            sections.append("Constraint for this request: do not invent new tags. Use only names from the list above, and reply with an empty array if none of them fit.")
        }

        sections.append("Reply with the JSON array of tags for the transcript above.")
        return sections.joined(separator: "\n\n")
    }

    /// Pulls the tag list out of whatever the model actually returned.
    ///
    /// Deliberately forgiving: models wrap JSON in code fences, prefix it
    /// with "Here are the tags:", or return a bare newline-separated list.
    /// Failing the step over punctuation would mean a retry that costs money
    /// to fix something already sitting in the response.
    static func parse(_ text: String) -> [String] {
        let names = parseJSONArray(text) ?? parseLooseList(text)
        var seen = Set<String>()
        return names
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\"'#.,;-")).lowercased() }
            .filter { !$0.isEmpty && $0.count <= 40 }
            .filter { seen.insert($0).inserted }
            .prefix(maxTagsPerClip)
            .map { $0 }
    }

    private static func parseJSONArray(_ text: String) -> [String]? {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        return parsed.compactMap { $0 as? String }
    }

    /// Last resort: a plain list, one per line or comma-separated.
    private static func parseLooseList(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { String($0) }
    }
}
