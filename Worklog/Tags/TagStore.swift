import Foundation
import SwiftUI
import UIKit

/// The colours a tag can take.
///
/// A closed palette, not a colour picker. Tags are scanned in peripheral
/// vision - six distinguishable hues do that job, and an open picker only
/// buys the chance to choose two that look alike. Every hue is desaturated
/// toward the app's warm neutral ramp so a row of chips reads as part of the
/// interface rather than as confetti.
enum TagColor: String, CaseIterable, Identifiable {
    case slate
    case rust
    case amber
    case moss
    case teal
    case indigo
    case plum

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .slate: return "Slate"
        case .rust: return "Rust"
        case .amber: return "Amber"
        case .moss: return "Moss"
        case .teal: return "Teal"
        case .indigo: return "Indigo"
        case .plum: return "Plum"
        }
    }

    /// Hue and saturation per colour; lightness comes from the appearance,
    /// so the same tag reads at the same weight in both themes instead of
    /// glowing in one and vanishing in the other.
    private var hue: Double {
        switch self {
        case .slate: return 0.58
        case .rust: return 0.03
        case .amber: return 0.10
        case .moss: return 0.28
        case .teal: return 0.47
        case .indigo: return 0.66
        case .plum: return 0.82
        }
    }

    private var saturation: Double {
        self == .slate ? 0.16 : 0.42
    }

    /// Chip text.
    var foreground: Color {
        Color(UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            return UIColor(
                hue: self.hue,
                saturation: self.saturation * (isDark ? 0.85 : 1.0),
                brightness: isDark ? 0.86 : 0.42,
                alpha: 1
            )
        })
    }

    /// Chip fill - the same hue at a fraction of the strength, so the label
    /// carries the colour and the fill only hints at it.
    var background: Color {
        Color(UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            return UIColor(
                hue: self.hue,
                saturation: self.saturation * (isDark ? 0.55 : 0.30),
                brightness: isDark ? 0.30 : 0.95,
                alpha: 1
            )
        })
    }

    /// A stable colour for a tag that hasn't been given one. Derived from the
    /// name so it never shifts, and so a fresh vocabulary comes out varied
    /// without anyone picking anything.
    static func derived(from name: String) -> TagColor {
        let hash = name.lowercased().unicodeScalars.reduce(into: UInt64(5381)) { result, scalar in
            result = result &* 33 &+ UInt64(scalar.value)
        }
        return allCases[Int(hash % UInt64(allCases.count))]
    }

    static func resolve(_ key: String?, name: String) -> TagColor {
        key.flatMap(TagColor.init(rawValue:)) ?? derived(from: name)
    }
}

extension TagRecord {
    var color: TagColor { TagColor.resolve(colorKey, name: name) }
}

/// Owns the tag vocabulary and every clip's assignments.
///
/// Like `PlaceStore`, this is the single in-memory mirror of a small table
/// that the whole UI reads from - so renaming a tag re-labels it everywhere
/// at once, and search over tags needs no index to rebuild.
@MainActor
final class TagStore: ObservableObject {
    static let shared = TagStore()

    @Published private(set) var tags: [TagRecord] = []
    /// Tag IDs by clip ID.
    @Published private(set) var assignments: [String: [String]] = [:]
    /// Clip counts by tag ID, for the manager.
    @Published private(set) var usage: [String: Int] = [:]

    private init() {
        reload()
    }

    func reload() {
        tags = WorklogDatabase.shared.allTags()
        assignments = WorklogDatabase.shared.allClipTagIDs()
        usage = WorklogDatabase.shared.tagUsageCounts()
    }

    // MARK: - Reading

    func tag(id: String) -> TagRecord? { tags.first { $0.id == id } }

    /// A clip's tags, in the vocabulary's own order so a clip's chips don't
    /// reshuffle between renders.
    func tags(forClip clipID: String) -> [TagRecord] {
        let ids = Set(assignments[clipID] ?? [])
        return tags.filter { ids.contains($0.id) }
    }

    /// Everything a search should match for one clip.
    func searchText(forClip clipID: String) -> String? {
        let names = tags(forClip: clipID).map(\.name)
        return names.isEmpty ? nil : names.joined(separator: " ")
    }

    // MARK: - Editing

    @discardableResult
    func createTag(name: String, color: TagColor? = nil) -> TagRecord? {
        let created = WorklogDatabase.shared.upsertTag(name: name, colorKey: color?.rawValue)
        reload()
        return created
    }

    /// `false` when another tag already owns the name - the caller says so
    /// rather than the edit vanishing.
    @discardableResult
    func rename(_ tag: TagRecord, to name: String) -> Bool {
        let renamed = WorklogDatabase.shared.renameTag(id: tag.id, name: name)
        if renamed { reload() }
        return renamed
    }

    func setColor(_ color: TagColor, for tag: TagRecord) {
        WorklogDatabase.shared.updateTagColor(id: tag.id, colorKey: color.rawValue)
        reload()
    }

    func delete(_ tag: TagRecord) {
        WorklogDatabase.shared.deleteTag(id: tag.id)
        reload()
    }

    func assign(_ tag: TagRecord, toClip clipID: String, source: TagSource = .manual) {
        WorklogDatabase.shared.assignTag(clipID: clipID, tagID: tag.id, source: source)
        reload()
    }

    func unassign(_ tag: TagRecord, fromClip clipID: String) {
        WorklogDatabase.shared.unassignTag(clipID: clipID, tagID: tag.id)
        reload()
    }

    /// Replaces exactly what the tagging model previously chose for a clip.
    /// Anything assigned by hand is left alone - that's the difference the
    /// `source` column exists to record.
    func replaceAutoTags(clipID: String, with names: [String], allowNewTags: Bool) {
        WorklogDatabase.shared.clearAutoTags(clipID: clipID)
        for name in names {
            let existing = WorklogDatabase.shared.tag(named: name)
            guard let tag = existing ?? (allowNewTags
                ? WorklogDatabase.shared.upsertTag(name: name, isAutoCreated: true)
                : nil) else { continue }
            WorklogDatabase.shared.assignTag(clipID: clipID, tagID: tag.id, source: .auto)
        }
        reload()
    }
}
