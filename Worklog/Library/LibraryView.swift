import SwiftUI
import UniformTypeIdentifiers

/// The Library screen: every saved clip and transcript, newest first, with
/// live per-step transcription state and re-clip-from-history.
///
/// Where the macOS build is a two-column split (list on the left, detail on
/// the right), a phone gets a list that pushes a detail screen - the shape the
/// Android build uses, and the only one that works at this width. The rows,
/// the search, and the pipeline state badges are the same code.
struct LibraryView: View {
    @ObservedObject var viewModel: LibraryViewModel
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
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.large)
        .searchable(
            text: $viewModel.searchQuery,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Clips, transcripts, tags, places"
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if viewModel.importingCount > 0 {
                    ProgressView()
                } else {
                    Button {
                        viewModel.presentImportPanel()
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                }
            }
        }
        // Import lands audio files and .worklog.zip exports alike; dispatch by
        // content happens in ClipImporter.
        .fileImporter(
            isPresented: $viewModel.isPresentingImporter,
            allowedContentTypes: ClipImporter.importableTypes,
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            viewModel.importFiles(at: urls)
        }
        .refreshable { viewModel.reload() }
        // The view model is shared and long-lived, so refresh from the DB on
        // every visit rather than only when it is first created.
        .onAppear { viewModel.reload() }
        .alert(item: $viewModel.pendingDelete) { pending in
            Alert(
                title: Text("Delete \"\(pending.entry.clip.displayName)\"?"),
                message: Text(pending.willRemoveTranscript
                    ? "This deletes the clip audio and its transcript. This can't be undone."
                    : "This deletes the clip audio. No transcript exists yet. This can't be undone."),
                primaryButton: .destructive(Text("Delete"), action: { viewModel.confirmDelete() }),
                secondaryButton: .cancel(Text("Cancel"), action: { viewModel.cancelDelete() })
            )
        }
        .alert(item: $viewModel.alertMessage) { message in
            Alert(title: Text(message.title), message: Text(message.body), dismissButton: .default(Text("OK")))
        }
        .worklogRenameDialog(
            isPresented: Binding(
                get: { viewModel.renamingEntryID != nil },
                set: { if !$0 { viewModel.cancelRename() } }
            ),
            title: "Rename clip",
            text: $viewModel.renameText,
            onCommit: { viewModel.commitRename() }
        )
    }

    private var list: some View {
        List {
            ForEach(viewModel.visibleEntries) { entry in
                LibraryRow(
                    viewModel: viewModel,
                    entry: entry,
                    runningSteps: viewModel.runningSteps(for: entry),
                    isSelected: false,
                    action: {
                        WorklogHaptics.play(.select)
                        onOpenEntry(entry.id)
                    }
                )
                .listRowInsets(EdgeInsets(top: 2, leading: WorklogSpacing.md, bottom: 2, trailing: WorklogSpacing.md))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                // Swipe actions rather than the macOS build's right-click
                // menu. Delete is trailing and destructive - the side and the
                // colour iOS has trained everyone to expect - and still asks
                // before it does anything.
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
                        viewModel.shareClipAudio(for: entry)
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
            message: "Nothing in your clips, transcripts, translations, summaries, tags, or places matches \u{201c}\(viewModel.searchQuery)\u{201d}."
        )
    }

    private var listEmptyState: some View {
        WorklogEmptyState(
            icon: "tray",
            title: "No clips yet",
            message: "Clips you create on the Clip screen show up here. You can also import audio or a Worklog export with the button above."
        )
    }
}

/// The one empty state used everywhere, so "nothing here" always looks the
/// same wherever you meet it.
struct WorklogEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: WorklogSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.worklogTextTertiary)
            Text(title)
                .font(WorklogFont.headline)
                .foregroundStyle(Color.worklogTextPrimary)
            Text(message)
                .font(WorklogFont.body)
                .foregroundStyle(Color.worklogTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(WorklogSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.worklogBackground)
        .gentleEntrance()
    }
}
