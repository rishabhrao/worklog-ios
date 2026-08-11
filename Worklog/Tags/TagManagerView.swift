import SwiftUI

/// The tag vocabulary, in one place: create, rename, recolour, delete, and
/// see what each one is actually being used on.
///
/// Lives in Settings rather than getting its own tab, because browsing *by*
/// tag is what the Library's search already does - a tab would show the same
/// clips grouped differently. What has no home elsewhere is the vocabulary
/// itself, and that's what this is.
struct TagManagerView: View {
    @ObservedObject private var store = TagStore.shared

    @State private var newTagName = ""
    @State private var editingTagID: String?
    @State private var editingName = ""
    @State private var nameClash = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.sm) {
            HStack {
                Text("Your tags")
                    .font(WorklogFont.bodyEmphasized)
                    .foregroundStyle(Color.worklogTextPrimary)
                Spacer()
                Text(store.tags.isEmpty ? "" : "\(store.tags.count)")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)
            }

            HStack(spacing: WorklogSpacing.sm) {
                TextField("New tag…", text: $newTagName)
                    .textFieldStyle(.roundedBorder)
                    .font(WorklogFont.body)
                    .onSubmit(createTag)
                WorklogButton("Add", kind: .secondary, action: createTag)
                    .fixedSize()
                    .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if nameClash {
                Text("A tag with that name already exists.")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogError)
            }

            if store.tags.isEmpty {
                Text("No tags yet. Add one here, or let auto-tagging propose them as clips come in.")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let visible = store.tags.capped(to: ShowMoreButton.collapsedLimit, expanded: isExpanded)
                VStack(spacing: 0) {
                    ForEach(visible) { tag in
                        tagRow(tag)
                        if tag.id != visible.last?.id {
                            Divider().overlay(Color.worklogHairline)
                        }
                    }
                    // Inside the same surface as the rows, below a divider,
                    // so it reads as the end of the list rather than as a
                    // separate control sitting under it.
                    if store.tags.count > ShowMoreButton.collapsedLimit {
                        Divider().overlay(Color.worklogHairline)
                        ShowMoreButton(total: store.tags.count, isExpanded: $isExpanded)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: WorklogRadius.sm, style: .continuous)
                        .fill(Color.worklogSurface)
                )
            }
        }
    }

    @ViewBuilder
    private func tagRow(_ tag: TagRecord) -> some View {
        HStack(spacing: WorklogSpacing.sm) {
            if editingTagID == tag.id {
                TextField("Tag name", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .font(WorklogFont.body)
                    .onSubmit { commitRename(tag) }
                WorklogButton("Save", kind: .secondary) { commitRename(tag) }
                    .fixedSize()
                WorklogButton("Cancel", kind: .secondary) { editingTagID = nil; nameClash = false }
                    .fixedSize()
            } else {
                TagChipView(tag: tag)

                // The palette, inline. Seven swatches take less room than a
                // menu to open one, and picking a colour is a glance-and-
                // click decision, not a considered one.
                HStack(spacing: 3) {
                    ForEach(TagColor.allCases) { color in
                        Button { store.setColor(color, for: tag) } label: {
                            Circle()
                                .fill(color.foreground)
                                .frame(width: 9, height: 9)
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.worklogTextPrimary.opacity(tag.color == color ? 0.7 : 0), lineWidth: 1.5)
                                        .padding(-2)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(color.displayName)
                    }
                }
                .padding(.leading, WorklogSpacing.xs)

                Spacer()

                if tag.isAutoCreated {
                    Text("auto")
                        .font(WorklogFont.footnote)
                        .foregroundStyle(Color.worklogTextTertiary)
                        .help("Proposed by auto-tagging. Renaming it makes it yours.")
                }

                Text(usageLabel(tag))
                    .font(WorklogFont.footnote)
                    .foregroundStyle(Color.worklogTextTertiary)

                WorklogIconButton(systemName: "pencil", label: "Rename “\(tag.name)”") {
                    editingTagID = tag.id
                    editingName = tag.name
                    nameClash = false
                }
                WorklogIconButton(systemName: "trash", label: "Delete “\(tag.name)”", tint: Color.worklogError) {
                    confirmDelete(tag)
                }
            }
        }
        .padding(.horizontal, WorklogSpacing.sm)
        .padding(.vertical, WorklogSpacing.xs)
    }

    private func usageLabel(_ tag: TagRecord) -> String {
        let count = store.usage[tag.id] ?? 0
        return count == 1 ? "1 clip" : "\(count) clips"
    }

    private func createTag() {
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if store.tags.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            nameClash = true
            return
        }
        nameClash = false
        store.createTag(name: name)
        newTagName = ""
    }

    private func commitRename(_ tag: TagRecord) {
        guard store.rename(tag, to: editingName) else {
            nameClash = true
            return
        }
        nameClash = false
        editingTagID = nil
    }

    /// Deleting a tag unassigns it from every clip, which is not obvious from
    /// the button - so the count says exactly how much is about to change.
    private func confirmDelete(_ tag: TagRecord) {
        let count = store.usage[tag.id] ?? 0
        Platform.confirm(
            title: "Delete the tag “\(tag.name)”?",
            message: count == 0
                ? "It isn't on any clips."
                : "It will be removed from \(count == 1 ? "1 clip" : "\(count) clips"). The clips themselves are untouched.",
            confirmTitle: "Delete",
            isDestructive: true
        ) { store.delete(tag) }
    }
}
