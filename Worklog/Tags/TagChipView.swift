import SwiftUI

/// One tag, as a chip.
///
/// The colour lives in the label and only tints the fill, so a row of chips
/// stays legible against the app's warm neutrals instead of turning into a
/// row of buttons competing for attention.
///
/// Removal is always drawn on a removable chip, dimmed until you point at
/// it. It used to appear only on hover, which changed the chip's width and
/// so reflowed the whole wrapping row - chips shuffled and jumped lines
/// under the pointer, and the one you were reaching for moved. Reserving the
/// space invisibly would have cost the same width for nothing; showing it
/// faintly costs the same width and also answers "can I remove this?"
/// without having to hover every chip to find out. Matches Android, which
/// has no hover and always drew it.
struct TagChipView: View {
    let tag: TagRecord
    /// Present only where removal makes sense (a clip's own tag list).
    var onRemove: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(tag.name)
                .font(WorklogFont.footnote)
                .foregroundStyle(tag.color.foreground)
                .lineLimit(1)
            if let onRemove {
                Button {
                    WorklogHaptics.play(.tap)
                    onRemove()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        // Only the opacity changes on hover - nothing that
                        // affects layout, or the row reflows under the
                        // pointer again.
                        .foregroundStyle(tag.color.foreground.opacity(isHovering ? 0.9 : 0.45))
                }
                .buttonStyle(.plain)
                .help("Remove “\(tag.name)”")
            }
        }
        .padding(.leading, WorklogSpacing.sm)
        // Tightened when the glyph is there, so a removable chip doesn't read
        // as lopsided - the same trade Android's chip makes.
        .padding(.trailing, onRemove == nil ? WorklogSpacing.sm : 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(tag.color.background))
        .overlay(Capsule().strokeBorder(tag.color.foreground.opacity(isHovering ? 0.35 : 0.16), lineWidth: 1))
        .onHover { hovering in
            guard onRemove != nil else { return }
            withAnimation(MotionPrimitives.aware(MotionPrimitives.hover)) { isHovering = hovering }
        }
    }
}

/// Adds a tag to a clip: type to filter the vocabulary, Return to apply, and
/// create a new tag from the same field when nothing matches.
///
/// One field rather than a picker plus a separate "new tag" flow - at the
/// moment you want a tag you either know its name or you're inventing it,
/// and both start by typing it.
struct TagPickerView: View {
    let clipID: String
    let assigned: [TagRecord]
    var onClose: () -> Void = {}

    @ObservedObject private var store = TagStore.shared
    @State private var query = ""
    @FocusState private var isFieldFocused: Bool

    private var trimmed: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var assignedIDs: Set<String> { Set(assigned.map(\.id)) }

    private static let rowHeight: CGFloat = 24
    private static let maxVisibleRows = 6

    /// Sized to the rows actually there, so a two-tag list is a short
    /// popover rather than a mostly-empty tall one.
    private var listHeight: CGFloat {
        let rows = min(matches.count, Self.maxVisibleRows)
        return CGFloat(rows) * Self.rowHeight + CGFloat(max(rows - 1, 0)) * WorklogSpacing.xs
    }

    /// Unassigned tags matching what's typed. Assigned ones are hidden
    /// rather than shown disabled - this list is "what you can add", and a
    /// tag already on the clip isn't.
    private var matches: [TagRecord] {
        store.tags.filter { tag in
            guard !assignedIDs.contains(tag.id) else { return false }
            guard !trimmed.isEmpty else { return true }
            return tag.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// True when what's typed isn't already a tag - the field then doubles
    /// as "create this".
    private var canCreate: Bool {
        !trimmed.isEmpty && !store.tags.contains { $0.name.lowercased() == trimmed.lowercased() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.sm) {
            TextField("Find or create a tag…", text: $query)
                .textFieldStyle(.plain)
                .font(WorklogFont.body)
                .foregroundStyle(Color.worklogTextPrimary)
                .focused($isFieldFocused)
                .padding(.horizontal, WorklogSpacing.sm)
                .padding(.vertical, WorklogSpacing.xs)
                .background(RoundedRectangle(cornerRadius: WorklogRadius.sm, style: .continuous).fill(Color.worklogSurface))
                .overlay(RoundedRectangle(cornerRadius: WorklogRadius.sm, style: .continuous).strokeBorder(Color.worklogHairline, lineWidth: 1))
                .onSubmit(applyFirst)

            if matches.isEmpty && !canCreate {
                Text(store.tags.isEmpty ? "No tags yet - type a name to make the first one." : "Every tag is already on this clip.")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if canCreate {
                Button(action: applyFirst) {
                    HStack(spacing: WorklogSpacing.xs) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 11))
                        Text("Create “\(trimmed)”")
                            .font(WorklogFont.footnote)
                    }
                    .foregroundStyle(Color.worklogAccent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !matches.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
                        ForEach(matches) { tag in
                            Button { apply(tag) } label: {
                                HStack {
                                    TagChipView(tag: tag)
                                    Spacer()
                                    Text(store.usage[tag.id].map { "\($0)" } ?? "0")
                                        .font(WorklogFont.footnote)
                                        .foregroundStyle(Color.worklogTextTertiary)
                                }
                                .frame(height: Self.rowHeight)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                // An explicit height, not `maxHeight`. A ScrollView has no
                // intrinsic content size, so inside a popover - which sizes
                // itself to its content - it collapsed to almost nothing and
                // clipped the first row in half.
                .frame(height: listHeight)
            }
        }
        .padding(WorklogSpacing.md)
        .frame(width: 260)
        .onAppear { isFieldFocused = true }
    }

    /// Return applies the top match, or creates what's typed when there
    /// isn't one - so the whole interaction can be type-and-Return.
    private func applyFirst() {
        if let first = matches.first, !canCreate {
            apply(first)
        } else if canCreate, let created = store.createTag(name: trimmed) {
            store.assign(created, toClip: clipID)
            // A new word entering the vocabulary is a bigger deal than
            // reusing one, and it happens far less often - so it is allowed
            // the heavier pattern.
            WorklogHaptics.play(.success)
            query = ""
        }
    }

    private func apply(_ tag: TagRecord) {
        store.assign(tag, toClip: clipID)
        WorklogHaptics.play(.select)
        query = ""
    }
}
