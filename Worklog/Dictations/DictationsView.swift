import SwiftUI

/// The Dictations screen: every dictation, newest first, with its text,
/// audio, and per-row transcription state. Built the same way as the Library
/// - same rows, same search, same push-to-detail - so the two histories feel
/// like one app.
struct DictationsView: View {
    @ObservedObject var viewModel: DictationsViewModel
    let onOpenEntry: (String) -> Void

    var body: some View {
        Group {
            if viewModel.entries.isEmpty {
                listEmptyState
            } else if viewModel.visibleEntries.isEmpty {
                searchEmptyState
            } else {
                list
            }
        }
        .background(Color.worklogBackground)
        .navigationTitle("Dictations")
        .navigationBarTitleDisplayMode(.large)
        .searchable(
            text: $viewModel.searchQuery,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search dictations"
        )
        .refreshable { viewModel.reload() }
        .onAppear { viewModel.reload() }
        .alert(item: $viewModel.pendingDelete) { pending in
            Alert(
                title: Text("Delete \u{201c}\(pending.entry.dictation.displayName)\u{201d}?"),
                message: Text("This deletes the dictation audio and its text. This can't be undone."),
                primaryButton: .destructive(Text("Delete"), action: { viewModel.confirmDelete() }),
                secondaryButton: .cancel(Text("Cancel"), action: { viewModel.cancelDelete() })
            )
        }
        .worklogRenameDialog(
            isPresented: Binding(
                get: { viewModel.renamingEntryID != nil },
                set: { if !$0 { viewModel.cancelRename() } }
            ),
            title: "Rename dictation",
            text: $viewModel.renameText,
            onCommit: { viewModel.commitRename() }
        )
    }

    private var list: some View {
        List {
            ForEach(viewModel.visibleEntries) { entry in
                DictationRow(
                    viewModel: viewModel,
                    entry: entry,
                    isRunning: viewModel.isRunning(entry),
                    isSelected: false,
                    action: {
                        WorklogHaptics.play(.select)
                        onOpenEntry(entry.id)
                    }
                )
                .listRowInsets(EdgeInsets(top: 2, leading: WorklogSpacing.md, bottom: 2, trailing: WorklogSpacing.md))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        viewModel.requestDelete(entry)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        viewModel.beginRename(entry)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(Color.worklogAccent)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        viewModel.shareText(for: entry)
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .tint(Color.worklogSuccess)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(MotionPrimitives.aware(MotionPrimitives.standard), value: viewModel.visibleEntries.map(\.id))
    }

    private var searchEmptyState: some View {
        WorklogEmptyState(
            icon: "text.magnifyingglass",
            title: "No matches",
            message: "No dictation matches \u{201c}\(viewModel.searchQuery)\u{201d}."
        )
    }

    private var listEmptyState: some View {
        WorklogEmptyState(
            icon: "mic",
            title: "No dictations yet",
            message: "Hold the mic button on the Clip screen, or use the Worklog keyboard in any app, and what you say lands here."
        )
    }
}
