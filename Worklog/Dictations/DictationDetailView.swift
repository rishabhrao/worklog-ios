import SwiftUI

/// Detail pane for the selected dictation: header with location, seekable
/// player, and the transcribed text with copy / reveal / retry.
///
/// Simpler than `LibraryDetailView` by construction - a dictation has one
/// artifact, not a transcript plus N translations plus a summary - so there
/// is a single collapsible Text section rather than one per artifact.
struct DictationDetailView: View {
    @ObservedObject var viewModel: DictationsViewModel
    let entry: DictationEntry

    /// Place names and the reverse-geocode cache are shared app-wide, so a
    /// place renamed anywhere re-labels this header immediately.
    @ObservedObject private var places = PlaceStore.shared

    /// Collapsed by default, matching the Library's transcript sections -
    /// the list rows already show a two-line preview of every dictation, so
    /// the detail pane opening collapsed isn't hiding anything you can't
    /// already read.
    @State private var isTextExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.lg) {
            header
            if viewModel.hasAudio(entry) {
                playerArea
            }
            Divider().overlay(Color.worklogHairline)
            ScrollView {
                textSection
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Same reason as the Library's: the overlay scrollbar
                    // draws over the content, not beside it.
                    .padding(.trailing, WorklogSpacing.scrollbarGutter)
            }
        }
        .padding(WorklogSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
            if viewModel.renamingEntryID == entry.id {
                HStack {
                    TextField("Dictation name", text: $viewModel.renameText)
                        .textFieldStyle(.plain)
                        .font(WorklogFont.title)
                        .padding(.horizontal, WorklogSpacing.sm)
                        .padding(.vertical, WorklogSpacing.xs)
                        .background(RoundedRectangle(cornerRadius: WorklogRadius.sm).fill(Color.worklogSurface))
                        .onSubmit { viewModel.commitRename() }
                    WorklogButton("Save", kind: .secondary) { viewModel.commitRename() }
                        .fixedSize()
                    WorklogButton("Cancel", kind: .secondary) { viewModel.cancelRename() }
                        .fixedSize()
                }
            } else {
                HStack(spacing: WorklogSpacing.xs) {
                    Text(entry.dictation.displayName)
                        .font(WorklogFont.title)
                        .kerning(WorklogFont.titleTracking)
                        .foregroundStyle(Color.worklogTextPrimary)
                    Spacer()
                    if viewModel.hasAudio(entry) {
                        iconButton(systemName: "square.and.arrow.up", label: "Share dictation audio") {
                            viewModel.shareAudio(for: entry)
                        }
                        iconButton(systemName: "shippingbox", label: "Share every file for this dictation") {
                            viewModel.revealFileInFinder(atPath: entry.dictation.path)
                        }
                    }
                }
            }

            // Just when and how long, matching the clip header. How it was
            // captured and what produced it live in the Text section's own
            // provenance line, the same way a clip's model sits under its
            // Transcript header rather than up here.
            Text("\(formattedDateTime) · \(formattedDuration)")
                .font(WorklogFont.caption)
                .foregroundStyle(Color.worklogTextTertiary)

            if let label = places.label(
                latitude: entry.dictation.locationLatitude,
                longitude: entry.dictation.locationLongitude
            ) {
                LocationChipView(label: label)
                    .padding(.leading, -WorklogSpacing.xs)
            }
        }
    }

    // MARK: - Player

    private var playerArea: some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.sm) {
            ClipWaveformView(
                peaks: viewModel.peaksByEntryID[entry.id],
                duration: entry.dictation.durationSeconds,
                playheadPosition: isPlayingThisEntry ? viewModel.playheadPosition : 0,
                onSeek: { offset in viewModel.seek(to: offset, for: entry) }
            )

            PlayerBar(
                isPlaying: isPlayingThisEntry,
                position: isPlayingThisEntry ? viewModel.playheadPosition : 0,
                duration: entry.dictation.durationSeconds,
                onToggle: { viewModel.togglePlayback(for: entry) }
            )
        }
    }

    private var isPlayingThisEntry: Bool {
        viewModel.isPlayingEntryID == entry.id
    }

    // MARK: - Text

    private var isRunning: Bool {
        viewModel.isRunning(entry) || entry.dictation.state == .running
    }

    /// What produced this text and what it cost - the dictation's
    /// equivalent of the clip Transcript section's model subtitle. Shown
    /// only while expanded, so the collapsed row stays minimal.
    private var provenance: String? {
        var parts = [entry.dictation.mode.displayName]
        // Which engine actually ran: a realtime dictation later retried
        // reads `scribe_v2`, because that's what genuinely produced the text.
        if let model = entry.dictation.model { parts.append(model) }
        if let cost = entry.dictation.cost.label { parts.append(cost) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var textSection: some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.sm) {
            HStack(spacing: WorklogSpacing.xs) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.worklogTextTertiary)
                    .rotationEffect(.degrees(isTextExpanded ? 90 : 0))
                    .animation(MotionPrimitives.aware(MotionPrimitives.interactive), value: isTextExpanded)

                Text("Text")
                    .font(WorklogFont.bodyEmphasized)
                    .foregroundStyle(Color.worklogTextPrimary)

                if entry.isPartial {
                    // A realtime stream that died partway. Saying so is the
                    // difference between "the model heard half of it" and
                    // "the model got it wrong."
                    Text("partial")
                        .font(WorklogFont.footnote)
                        .foregroundStyle(Color.worklogWarning)
                }

                Spacer()

                if let text = entry.text, !text.isEmpty {
                    let isConfirming = viewModel.copyConfirmationEntryID == entry.id
                    iconButton(
                        systemName: isConfirming ? "checkmark" : "doc.on.doc",
                        label: "Copy text",
                        tint: isConfirming ? Color.worklogSuccess : nil
                    ) {
                        viewModel.copyToPasteboard(text, confirmationID: entry.id)
                    }
                }
                if let textPath = entry.dictation.textPath {
                    let isConfirming = viewModel.copyConfirmationEntryID == "\(entry.id)-path"
                    iconButton(
                        systemName: isConfirming ? "checkmark" : "link",
                        label: "Copy path to text",
                        tint: isConfirming ? Color.worklogSuccess : nil
                    ) {
                        viewModel.copyPath(textPath, confirmationID: entry.id)
                    }
                }
                if entry.dictation.textPath != nil {
                    // Same set as the Library's artifact sections, and the
                    // same set the Android dictation screen offers.
                    iconButton(systemName: "square.and.arrow.up", label: "Share text") {
                        viewModel.shareText(for: entry)
                    }
                }
                iconButton(systemName: "arrow.clockwise", label: "Retry transcription") {
                    confirmRetry()
                }
                .disabled(!viewModel.hasAudio(entry) || isRunning)
                .opacity(!viewModel.hasAudio(entry) || isRunning ? 0.4 : 1)
            }
            // Same construction as the Library's collapsible sections: the
            // whole header row is the toggle target, and the action buttons
            // inside it take priority over the container's tap gesture.
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(MotionPrimitives.aware(MotionPrimitives.standard)) {
                    isTextExpanded.toggle()
                }
            }

            if isTextExpanded {
                Group {
                    if let provenance {
                        Text(provenance)
                            .font(WorklogFont.caption)
                            .foregroundStyle(Color.worklogTextTertiary)
                    }
                    content
                }
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isRunning {
            VStack(alignment: .leading, spacing: WorklogSpacing.sm) {
                onDeviceProvenanceLine
                previewPrimary
            }
        } else if let text = entry.text, !text.isEmpty {
            VStack(alignment: .leading, spacing: WorklogSpacing.sm) {
                LazyLongText(text)

                if entry.isPartial, let error = entry.dictation.error {
                    placeholder(
                        icon: "exclamationmark.triangle.fill",
                        message: "This dictation stopped early",
                        detail: "\(error) Retry to transcribe the full recording.",
                        isError: true
                    )
                }

                // Scribe's text is the accurate one and reads first; the
                // preview stays underneath it rather than being thrown away
                // once the real transcript lands.
                previewCompanion
            }
        } else {
            // No Scribe text - off, unconfigured, failed, or still running.
            // The on-device words become this dictation's transcript rather
            // than decoration under a placeholder: dictation has to work for
            // someone who never links a Scribe account at all.
            VStack(alignment: .leading, spacing: WorklogSpacing.sm) {
                onDeviceProvenanceLine
                previewPrimary

                if entry.dictation.state == .failed {
                    placeholder(
                        icon: "exclamationmark.triangle.fill",
                        message: "Scribe transcription failed",
                        detail: entry.dictation.error ?? "Transcription failed.",
                        isError: true
                    )
                }
            }
        }
    }

    /// Says where the standing-in text came from, directly above it -
    /// on-device transcription is a first-class path here, not a stopgap, so
    /// it is labelled honestly rather than apologetically.
    private var onDeviceProvenanceLine: some View {
        Text(onDeviceProvenance)
            .font(WorklogFont.caption)
            .foregroundStyle(Color.worklogTextTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var onDeviceProvenance: String {
        let settings = WorklogSettingsStore.load()
        guard settings.isSpeechPreviewsEnabled else {
            return "No transcription. Turn on on-device speech in Settings."
        }
        let origin = "On-device speech, stays on this iPhone."
        switch entry.dictation.state {
        case .running:
            return "\(origin) Scribe is still running."
        case .failed:
            return "\(origin) Scribe failed, retry above."
        default:
            return settings.isElevenLabsEnabled
                ? "\(origin) Scribe hasn't run yet."
                : "\(origin) Scribe is off in Settings."
        }
    }

    /// The on-device words rendered *as* this dictation's text.
    private var previewPrimary: some View {
        PreviewTranscriptFallback(
            start: entry.dictation.sourceStart,
            end: entry.dictation.sourceEnd,
            owner: .dictation(entry.dictation.id),
            role: .primary
        )
    }

    /// Kept alongside the finished text rather than discarded by it - the
    /// snapshot travels with the dictation and survives raw-audio retention.
    private var previewCompanion: some View {
        PreviewTranscriptFallback(
            start: entry.dictation.sourceStart,
            end: entry.dictation.sourceEnd,
            owner: .dictation(entry.dictation.id),
            role: .companion
        )
    }

    /// A retry costs real API money, so it asks first.
    private func confirmRetry() {
        Platform.confirm(
            title: "Retry transcription?",
            message: "This re-transcribes the saved audio with Scribe v2 and replaces the current text. It won't insert anywhere.",
            confirmTitle: "Retry"
        ) { viewModel.retryTranscription(for: entry) }
    }

    private func iconButton(systemName: String, label: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        WorklogIconButton(systemName: systemName, label: label, tint: tint, style: .bare, action: action)
    }

    private func placeholder(icon: String, message: String, detail: String?, isError: Bool = false, showsSpinner: Bool = false) -> some View {
        HStack(alignment: .top, spacing: WorklogSpacing.sm) {
            if showsSpinner {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: icon)
                    .foregroundStyle(isError ? Color.worklogError : Color.worklogTextTertiary)
            }
            VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
                Text(message)
                    .font(WorklogFont.body)
                    .foregroundStyle(isError ? Color.worklogError : Color.worklogTextSecondary)
                if let detail {
                    Text(detail)
                        .font(WorklogFont.caption)
                        .foregroundStyle(Color.worklogTextTertiary)
                }
            }
        }
        .padding(WorklogSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: WorklogRadius.sm, style: .continuous).fill(Color.worklogSurface))
    }

    private var formattedDateTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy · h:mm a"
        return formatter.string(from: entry.dictation.sourceStart)
    }

    private var formattedDuration: String {
        let total = Int(entry.dictation.durationSeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
