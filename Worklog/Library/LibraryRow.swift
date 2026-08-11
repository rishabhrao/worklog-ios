import SwiftUI

/// One row in the Library list: display name, source date/time, duration,
/// speaker count, transcript preview, and a live per-step transcription
/// stage badge - per spec `06-library.md`'s list-view requirements.
struct LibraryRow: View {
    @ObservedObject var viewModel: LibraryViewModel
    let entry: LibraryEntry
    let runningSteps: Set<PipelineStep>
    let isSelected: Bool
    let action: () -> Void

    @ObservedObject private var places = PlaceStore.shared
    @ObservedObject private var tagStore = TagStore.shared

    private var stage: LibraryTranscriptionStage { entry.stage(runningSteps: runningSteps) }

    /// Drives a one-shot pop when this row's stage transitions *into*
    /// `.done` - distinguishes "just finished" from "was already done on
    /// a fresh Library load," so the animated success moment (spec
    /// `09-polish-and-future-headroom.md`) doesn't replay on every re-render.
    @State private var justCompletedPop = false

    var body: some View {
        WorklogListRow(isSelected: isSelected, action: action) {
            VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
                HStack(alignment: .center) {
                    Text(entry.clip.displayName)
                        .font(WorklogFont.bodyEmphasized)
                        .foregroundStyle(Color.worklogTextPrimary)
                        .lineLimit(1)

                    Spacer()

                    stageBadge
                }

                HStack(spacing: WorklogSpacing.sm) {
                    Text(formattedDateTime)
                    Text("·")
                    Text(formattedDuration)
                    if let speakerCount = entry.transcript?.speakerCount {
                        Text("·")
                        Text(speakerCount == 1 ? "1 speaker" : "\(speakerCount) speakers")
                    }
                }
                .font(WorklogFont.caption)
                .foregroundStyle(Color.worklogTextTertiary)

                // Where it was recorded, so a search for a place name shows
                // *why* each result matched rather than looking arbitrary.
                if let label = places.label(
                    latitude: entry.clip.locationLatitude,
                    longitude: entry.clip.locationLongitude
                ) {
                    LocationTagView(label: label)
                        .font(WorklogFont.caption)
                }

                // Tags on the row, so a search that matched one shows why.
                let tags = tagStore.tags(forClip: entry.clip.id)
                if !tags.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(tags) { tag in
                            TagChipView(tag: tag)
                        }
                    }
                    .padding(.top, 1)
                }
            }
        }
        // Rename/Delete live in a native right-click context menu on the
        // row (per explicit user request - the previous per-row `⋯` menu
        // button is gone entirely), matching standard macOS list behavior.
        // Export/Share mirror the Android detail menu, so both apps offer
        // the same actions per clip.
        // Rename/Delete live in a native right-click context menu on the row
        // (per explicit user request - the previous per-row `⋯` menu button
        // is gone entirely), matching standard macOS list behavior. The rest
        // mirrors the Android row menu item for item, so the same actions are
        // one gesture away on both apps.
        .contextMenu {
            Button("Rename") { viewModel.beginRename(entry) }
            if entry.transcript?.path != nil {
                Button("Copy Transcript") { viewModel.copyTranscript(for: entry) }
            }
            Button("Copy Folder Path") { viewModel.copyPath(entry.clipFolderPath, confirmationID: entry.id) }
            Divider()
            Button("Export Clip…") { viewModel.exportAndShareArchive(for: entry) }
            Button("Share Audio…") { viewModel.shareClipAudio(for: entry) }
            Divider()
            Button("Delete…", role: .destructive) { viewModel.requestDelete(entry) }
        }
        .onChange(of: stage) { newStage in
            guard case .done = newStage else { return }
            // The one deliberately bouncy moment in the app - a pipeline
            // just finished, which is worth a little celebration.
            withAnimation(MotionPrimitives.aware(MotionPrimitives.pop)) {
                justCompletedPop = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withAnimation(MotionPrimitives.aware(MotionPrimitives.interactive)) {
                    justCompletedPop = false
                }
            }
        }
    }

    private var stageBadge: some View {
        HStack(spacing: WorklogSpacing.xs) {
            if case .done = stage {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.worklogSuccess)
                    .scaleEffect(justCompletedPop ? 1.3 : 1.0)
            } else if stage.isFailed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.worklogError)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(stage.label)
                .font(WorklogFont.footnote)
                .foregroundStyle(stage.isFailed ? Color.worklogError : Color.worklogTextTertiary)
                // Stage labels ("Transcribing…" → "Translating…" → "Done")
                // crossfade as one live status rather than hard-swapping.
                .contentTransition(.opacity)
                .animation(MotionPrimitives.aware(MotionPrimitives.standard), value: stage.label)
        }
    }

    private var formattedDateTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: entry.clip.sourceStart)
    }

    private var formattedDuration: String {
        let total = Int(entry.clip.durationSeconds.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
