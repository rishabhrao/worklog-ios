import Foundation

/// Strips the bracketed sound labels a transcriber adds for things it heard
/// but nobody said - `[clears throat]`, `[laughter]`, `[door closes]`.
///
/// Dictation only, and off unless asked for. In a clip's transcript those
/// labels are part of the record of what happened in the room. In a dictation
/// they are not: the text goes straight into whatever field the user was
/// typing in, and nobody means to type "[clears throat]".
///
/// Deliberately identical to the Android implementation - the same dictation
/// must come out the same on both.
enum SoundLabels {
    /// A bracketed label, kept short so a genuine bracketed aside survives.
    private static let label = try? NSRegularExpression(pattern: "\\[[^\\]\\n]{1,40}\\]")
    private static let spaceBeforePunctuation = try? NSRegularExpression(pattern: "\\s+([,.;:!?])")
    private static let repeatedSpaces = try? NSRegularExpression(pattern: "[ \\t]{2,}")
    private static let spaceAroundNewline = try? NSRegularExpression(pattern: "[ \\t]*\\n[ \\t]*")

    /// Trims, and strips labels when the user has asked for it.
    static func applyingSetting(to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WorklogSettingsStore.load().isDictationRemoveSoundLabels else { return trimmed }
        return strip(trimmed)
    }

    static func strip(_ text: String) -> String {
        var result = replacing(text, label, with: " ")
        result = replacing(result, spaceBeforePunctuation, with: "$1")
        result = replacing(result, repeatedSpaces, with: " ")
        result = replacing(result, spaceAroundNewline, with: "\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(_ text: String, _ expression: NSRegularExpression?, with template: String) -> String {
        guard let expression else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
