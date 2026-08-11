import SwiftUI

/// Resolves a clip id to its entry and shows the detail view.
///
/// The indirection exists because navigation happens by id, not by value: the
/// Clip screen pushes straight to a clip it has only just created, and the
/// Library's own reload is asynchronous. Popping back when the entry is
/// momentarily absent would make "Create clip" bounce the user straight back
/// to where they started - a bug the Android build shipped and had to fix, so
/// this one waits instead.
struct LibraryDetailScreen: View {
    @ObservedObject var viewModel: LibraryViewModel
    let clipID: String

    @Environment(\.dismiss) private var dismiss
    @State private var didGiveUp = false

    private var entry: LibraryEntry? {
        viewModel.entries.first { $0.id == clipID }
    }

    var body: some View {
        Group {
            if let entry {
                LibraryDetailView(viewModel: viewModel, entry: entry)
                    // Forces SwiftUI to treat each entry as a genuinely
                    // distinct view identity rather than reusing the same
                    // instance and diffing its @State - without this, cached
                    // transcript text from the previous clip was observed
                    // surviving onto the next one.
                    .id(entry.id)
            } else if didGiveUp {
                WorklogEmptyState(
                    icon: "questionmark.folder",
                    title: "Clip not found",
                    message: "It may have been deleted."
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.worklogBackground)
            }
        }
        .task(id: clipID) {
            guard entry == nil else { return }
            viewModel.reload()
            // Give the reload a beat to land before concluding the clip is
            // genuinely gone.
            for _ in 0..<40 {
                if entry != nil { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            didGiveUp = entry == nil
        }
    }
}

/// The same resolution, for dictations.
struct DictationDetailScreen: View {
    @ObservedObject var viewModel: DictationsViewModel
    let dictationID: String

    @State private var didGiveUp = false

    private var entry: DictationEntry? {
        viewModel.entries.first { $0.id == dictationID }
    }

    var body: some View {
        Group {
            if let entry {
                DictationDetailView(viewModel: viewModel, entry: entry)
                    .id(entry.id)
            } else if didGiveUp {
                WorklogEmptyState(
                    icon: "questionmark.folder",
                    title: "Dictation not found",
                    message: "It may have been deleted."
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.worklogBackground)
            }
        }
        .task(id: dictationID) {
            guard entry == nil else { return }
            viewModel.reload()
            for _ in 0..<40 {
                if entry != nil { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            didGiveUp = entry == nil
        }
    }
}
