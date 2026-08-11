import Foundation

/// Everything about one entry that search looks at, already normalized.
///
/// Precomputed and cached, because the alternative is what this replaced:
/// normalizing the query and concatenating a full transcript onto a location
/// string, per entry, on every keystroke. With a few hundred clips that meant
/// copying megabytes of text between characters typed.
struct EntrySearchFields {
    var name: String = ""
    var dates: String = ""
    /// Transcript + translations + summaries, joined. Big, and the reason
    /// nothing else may be concatenated onto it.
    var content: String = ""
    /// The clip's place: the custom name, the OS-detected name, and locality.
    var places: [String] = []
    var tags: [String] = []
}

/// How well one entry matched, and - more importantly - *where*.
///
/// Ranking is the whole point. A clip recorded at a place called "office"
/// and a clip that merely says the word "office" somewhere in an hour of
/// transcript are not equally good answers to "office", and showing them
/// interleaved by date makes the search feel broken. Field beats recency;
/// recency only breaks ties within a field.
enum MatchTier: Int, Comparable {
    case none = 0
    /// The weakest signal: the query's letters appear in order in the clip's
    /// name. Catches typos, so it stays - but below everything real.
    case fuzzyName = 1
    case content = 2
    case date = 3
    case name = 4
    case tag = 5
    case place = 6

    static func < (lhs: MatchTier, rhs: MatchTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One entry's result: the tier it earned, plus a finer score for ordering
/// within a tier.
struct SearchResult {
    /// The *weakest* token's tier. An entry matching "work hiring" where
    /// "work" is a place and "hiring" is only in the transcript is a content
    /// match - it is only as good as its worst-matching word.
    let tier: MatchTier
    /// Sum of every token's best score, so a clip matching both words on
    /// strong fields outranks one that scraped by.
    let score: Int
}

enum LibrarySearch {
    /// Case- and diacritic-insensitive fold so "hinglish", "Hinglish", and
    /// accented variants all meet in the middle.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }

    /// Splits a query once, for the whole pass.
    static func tokenize(_ query: String) -> [String] {
        normalize(query).split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    /// `nil` when any token matches nothing - every word still has to land
    /// somewhere, which is what keeps a two-word query from behaving like an
    /// OR.
    static func match(tokens: [String], fields: EntrySearchFields) -> SearchResult? {
        guard !tokens.isEmpty else { return SearchResult(tier: .none, score: 0) }

        var weakest = MatchTier.place
        var total = 0

        for token in tokens {
            let best = bestMatch(token: token, fields: fields)
            guard best.tier != .none else { return nil }
            weakest = min(weakest, best.tier)
            total += best.score
        }
        return SearchResult(tier: weakest, score: total)
    }

    /// The strongest field this one token hits.
    ///
    /// Within a field, a whole-value match beats a prefix, which beats a
    /// substring - so searching "office" puts the place actually *called*
    /// office above one called "office park", above "backoffice road".
    private static func bestMatch(token: String, fields: EntrySearchFields) -> (tier: MatchTier, score: Int) {
        if let score = bestAcross(fields.places, token: token) {
            return (.place, 6000 + score)
        }
        if let score = bestAcross(fields.tags, token: token) {
            return (.tag, 5000 + score)
        }
        if let score = quality(of: fields.name, token: token) {
            return (.name, 4000 + score)
        }
        if fields.dates.contains(token) {
            return (.date, 3000)
        }
        if fields.content.contains(token) {
            return (.content, 2000)
        }
        // Last resort, and deliberately name-only: a fuzzy subsequence over
        // thousands of transcript characters matches almost any input, which
        // reads as broken search.
        if isFuzzySubsequence(token, of: fields.name) {
            return (.fuzzyName, 1000)
        }
        return (.none, 0)
    }

    private static func bestAcross(_ values: [String], token: String) -> Int? {
        values.compactMap { quality(of: $0, token: token) }.max()
    }

    /// 300 for the whole value, 200 for a word starting with it, 100 for
    /// anywhere inside.
    private static func quality(of value: String, token: String) -> Int? {
        guard !value.isEmpty, value.contains(token) else { return nil }
        if value == token { return 300 }
        if value.hasPrefix(token) { return 200 }
        // A word boundary inside a multi-word value ("morning standup"
        // matching "standup") is a prefix match too.
        if value.split(separator: " ").contains(where: { $0.hasPrefix(token) }) { return 200 }
        return 100
    }

    /// True when `needle`'s characters appear in `haystack` in order (not
    /// necessarily adjacent) - classic fuzzy-match, e.g. "cl449" → "clip
    /// 2026-07-10 4:49 pm".
    static func isFuzzySubsequence(_ needle: String, of haystack: String) -> Bool {
        var needleIndex = needle.startIndex
        for character in haystack {
            guard needleIndex < needle.endIndex else { return true }
            if character == needle[needleIndex] {
                needleIndex = needle.index(after: needleIndex)
            }
        }
        return needleIndex >= needle.endIndex
    }
}
