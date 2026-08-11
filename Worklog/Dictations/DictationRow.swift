import SwiftUI

/// One row in the Dictations list: name, when it was spoken, how long, how
/// it was delimited, and its transcription state - the Library row's shape,
/// over a model with one step instead of four.
struct DictationRow: View {
    @ObservedObject var viewModel: DictationsViewModel
    let entry: DictationEntry
    let isRunning: Bool
    let isSelected: Bool
    let action: () -> Void

    @ObservedObject private var places = PlaceStore.shared

    var body: some View {
        WorklogListRow(isSelected: isSelected, action: action) {
            VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
                HStack(alignment: .center) {
                    Text(entry.dictation.displayName)
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
                    if entry.dictation.mode == .handsFree {
                        Text("·")
                        Text("Hands-free")
                    }
                }
                .font(WorklogFont.caption)
                .foregroundStyle(Color.worklogTextTertiary)

                if let label = places.label(
                    latitude: entry.dictation.locationLatitude,
                    longitude: entry.dictation.locationLongitude
                ) {
                    LocationTagView(label: label)
                        .font(WorklogFont.caption)
                }

                if let text = entry.text, !text.isEmpty {
                    Text(text)
                        .font(WorklogFont.caption)
                        .foregroundStyle(Color.worklogTextSecondary)
                        .lineLimit(2)
                }
            }
        }
        .contextMenu {
            Button("Rename") { viewModel.beginRename(entry) }
            if let text = entry.text, !text.isEmpty {
                Button("Copy Text") { viewModel.copyToPasteboard(text, confirmationID: entry.id) }
            }
            if let textPath = entry.dictation.textPath {
                Button("Copy Text Path") { viewModel.copyPath(textPath, confirmationID: entry.id) }
            }
            // Share mirrors the Android dictation menu, so both apps offer
            // the same actions per dictation.
            if FileManager.default.fileExists(atPath: entry.dictation.path) {
                Button("Share Audio…") { viewModel.shareAudio(for: entry) }
            }
            if let textPath = entry.dictation.textPath, FileManager.default.fileExists(atPath: textPath) {
                Button("Share Text…") { viewModel.shareText(for: entry) }
            }
            Button("Delete…", role: .destructive) { viewModel.requestDelete(entry) }
        }
    }

    private var stageBadge: some View {
        HStack(spacing: WorklogSpacing.xs) {
            if isRunning || entry.dictation.state == .running {
                ProgressView().controlSize(.mini)
            } else {
                switch entry.dictation.state {
                case .succeeded:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.worklogSuccess)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.worklogError)
                case .pending:
                    Image(systemName: "clock")
                        .foregroundStyle(Color.worklogTextTertiary)
                case .running:
                    ProgressView().controlSize(.mini)
                }
            }

            Text(label)
                .font(WorklogFont.footnote)
                .foregroundStyle(entry.dictation.state == .failed ? Color.worklogError : Color.worklogTextTertiary)
                .contentTransition(.opacity)
                .animation(MotionPrimitives.aware(MotionPrimitives.standard), value: label)
        }
    }

    private var label: String {
        if isRunning || entry.dictation.state == .running { return "Transcribing…" }
        switch entry.dictation.state {
        case .pending: return "Queued"
        case .running: return "Transcribing…"
        case .succeeded: return "Done"
        // A realtime stream that died partway leaves real text behind. Say
        // it's partial rather than showing it as if it were the whole thing.
        case .failed: return entry.isPartial ? "Partial" : "Failed"
        }
    }

    private var formattedDateTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: entry.dictation.sourceStart)
    }

    private var formattedDuration: String {
        let total = Int(entry.dictation.durationSeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
