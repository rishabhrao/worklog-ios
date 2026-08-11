import SwiftUI

/// Formats a duration as `HH:MM:SS` for the live selection-length readout,
/// per spec's example (`00:14:37`).
private func formatDuration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    return String(format: "%02d:%02d:%02d", hours, minutes, secs)
}

/// The Clip screen: the app's signature surface (ticket §5.1). Composes the
/// range loader, waveform + selection + candidate markers, transport, and
/// clip naming / Transcribe action, all on Priority 3's design-system tokens
/// and motion primitives.
/// How the loaded range is projected for selection: as amplitude, or as
/// preview words. Two views of the same range state - switching never
/// touches the selection.
private enum RangeViewMode: String {
    case waveform
    case transcript
}

struct ClipScreenView: View {
    /// Owned by `AppShellCoordinator`, not this view - shared so Library's
    /// "re-clip from history" action can load a range into the same instance
    /// the Clip screen renders, per spec `06-library.md`.
    @ObservedObject var viewModel: ClipScreenViewModel
    @State private var hoverPosition: TimeInterval?

    /// A view preference, not a setting - remembered across launches
    /// (people who clip by words will resent re-choosing every time), but
    /// not something Settings needs a row for.
    @AppStorage("worklog.clipRangeViewMode") private var rangeViewModeRaw = RangeViewMode.waveform.rawValue

    /// Lifted out of `SelectionOverlay` so the words strip can brighten the
    /// edge being dragged.
    @State private var isDraggingStartHandle = false
    @State private var isDraggingEndHandle = false

    private var rangeViewMode: RangeViewMode {
        RangeViewMode(rawValue: rangeViewModeRaw) ?? .waveform
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorklogSpacing.lg) {
                RangeLoaderView(viewModel: viewModel)

                content
                    // A fixed height rather than the Mac's "fill the window":
                    // inside a ScrollView an unbounded child collapses to
                    // nothing, and the waveform needs a stable canvas to drag
                    // handles across anyway.
                    .frame(maxWidth: .infinity, minHeight: waveformHeight)
                    .animation(MotionPrimitives.aware(MotionPrimitives.screenTransition), value: viewModel.loadState)

                if let range = viewModel.loadedRange, !range.isEmpty {
                    CandidateParametersDisclosure(parameters: $viewModel.detectionParameters)
                    clipNamingAndTranscribe
                }
            }
            .padding(WorklogSpacing.screenMargin)
        }
        .background(Color.worklogBackground)
        .navigationTitle("Clip")
        .navigationBarTitleDisplayMode(.large)
        // Loads a range on launch so a screenshot run lands on a real
        // waveform without anyone driving the UI. Same escape hatch, and same
        // reason, as `WORKLOG_DATA_ROOT`: documentation shots have to be
        // reproducible.
        .task {
            guard let raw = ProcessInfo.processInfo.environment["WORKLOG_AUTOLOAD_MINUTES"],
                  let minutes = Double(raw), minutes > 0,
                  viewModel.loadedRange == nil else { return }
            viewModel.loadLastMinutes(minutes)
        }
        // The waveform is the one thing on this screen that genuinely wants
        // width, so landscape and iPad get a taller canvas rather than the
        // same letterbox stretched out.
        .scrollDismissesKeyboard(.interactively)
    }

    /// Tall enough to drag a selection handle accurately with a thumb, short
    /// enough that the transport and the name field are still on screen under
    /// it on the smallest phone.
    private var waveformHeight: CGFloat { 260 }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .empty:
            emptyState
                .transition(.opacity)
        case .emptyAfterSearch:
            emptyAfterSearchState
                .transition(.opacity)
        case .loading where viewModel.loadedRange == nil:
            loadingState
                .transition(.opacity)
        case .loading, .loaded:
            waveformArea
                .transition(.opacity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: WorklogSpacing.md) {
            Image(systemName: "waveform")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.worklogTextTertiary)
            Text("No range loaded")
                .font(WorklogFont.headline)
                .foregroundStyle(Color.worklogTextPrimary)
            Text("Pick a preset above, or load a historical range, to see the waveform.")
                .font(WorklogFont.body)
                .foregroundStyle(Color.worklogTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .gentleEntrance()
    }

    /// Distinct from `emptyState`: a range WAS requested and genuinely
    /// found nothing (e.g. recording wasn't running in that window) -
    /// without this, the screen falls back to the same "No range loaded"
    /// message shown before anything was ever tried, which reads as if the
    /// preset click silently did nothing.
    private var emptyAfterSearchState: some View {
        VStack(spacing: WorklogSpacing.md) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.worklogTextTertiary)
            Text("Nothing recorded in that range")
                .font(WorklogFont.headline)
                .foregroundStyle(Color.worklogTextPrimary)
            Text("No audio was recorded during the requested time window. Try a different range, or check that recording was running then.")
                .font(WorklogFont.body)
                .foregroundStyle(Color.worklogTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .gentleEntrance()
    }

    private var loadingState: some View {
        VStack(spacing: WorklogSpacing.md) {
            ProgressView()
            Text("Loading range…")
                .font(WorklogFont.body)
                .foregroundStyle(Color.worklogTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var waveformArea: some View {
        if let range = viewModel.loadedRange {
            VStack(alignment: .leading, spacing: WorklogSpacing.sm) {
                selectionReadout

                if rangeViewMode == .transcript {
                    TranscriptRangePicker(
                        range: range,
                        selectionStart: viewModel.selectionStart,
                        selectionEnd: viewModel.selectionEnd,
                        onStartDragged: viewModel.userDraggedStartHandle,
                        onEndDragged: viewModel.userDraggedEndHandle
                    )
                    .background(Color.worklogSurface)
                    .clipShape(RoundedRectangle(cornerRadius: WorklogRadius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: WorklogRadius.md, style: .continuous)
                            .strokeBorder(Color.worklogHairline, lineWidth: 1)
                    )
                    // Text wants more room than peaks: grow into whatever
                    // the screen has, never below the waveform's height.
                    .frame(minHeight: 160, maxHeight: .infinity)
                    .transition(.opacity)
                } else {
                    waveformCard(range)
                        .transition(.opacity)
                }

                if viewModel.loadState == .loading {
                    HStack(spacing: WorklogSpacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Computing peaks for part of this range…")
                            .font(WorklogFont.caption)
                            .foregroundStyle(Color.worklogTextTertiary)
                    }
                }

                transportBar
            }
            .animation(MotionPrimitives.aware(MotionPrimitives.standard), value: rangeViewModeRaw)
        }
    }

    @ViewBuilder
    private func waveformCard(_ range: LoadedRange) -> some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.sm) {
                ZStack(alignment: .topLeading) {
                    WaveformView(
                        range: range,
                        selectionStart: viewModel.selectionStart,
                        selectionEnd: viewModel.selectionEnd
                    )
                    .background(Color.worklogSurface)
                    .clipShape(RoundedRectangle(cornerRadius: WorklogRadius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: WorklogRadius.md, style: .continuous)
                            .strokeBorder(Color.worklogHairline, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let width = max(1, geometryWidthCache)
                                let offset = Double(value.location.x / width) * range.totalDuration
                                viewModel.seek(to: offset)
                                waveformScrub.update(time: offset, duration: range.totalDuration, width: width)
                            }
                            .onEnded { _ in waveformScrub.end() }
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            let width = max(1, geometryWidthCache)
                            hoverPosition = Double(point.x / width) * range.totalDuration
                        case .ended:
                            hoverPosition = nil
                        }
                    }
                    .background(WidthReader { geometryWidthCache = $0 })

                    HoverPreviewView(totalDuration: range.totalDuration, hoverPosition: hoverPosition)

                    SelectionOverlay(
                        totalDuration: range.totalDuration,
                        selectionStart: $viewModel.selectionStart,
                        selectionEnd: $viewModel.selectionEnd,
                        onStartDragged: viewModel.userDraggedStartHandle,
                        onEndDragged: viewModel.userDraggedEndHandle,
                        isDraggingStart: $isDraggingStartHandle,
                        isDraggingEnd: $isDraggingEndHandle
                    )

                    PlayheadView(totalDuration: range.totalDuration, position: viewModel.playheadPosition)

                    CandidateMarkersView(
                        totalDuration: range.totalDuration,
                        candidates: viewModel.candidates,
                        selectedOffset: viewModel.selectedCandidateOffset,
                        rangeStart: range.requestedStart,
                        onSelect: viewModel.selectCandidate,
                        onAudition: { candidate in viewModel.seek(to: candidate.offsetSeconds) }
                    )
                }
                .frame(height: 160)

                RangeWordsStrip(
                    range: range,
                    selectionStart: viewModel.selectionStart,
                    selectionEnd: viewModel.selectionEnd,
                    isDraggingStart: isDraggingStartHandle,
                    isDraggingEnd: isDraggingEndHandle
                )
        }
    }

    @State private var geometryWidthCache: CGFloat = 1
    /// The ruler under a scrub of the loaded range. Separate from the two
    /// handles' - this drag moves the playhead, not the selection.
    @State private var waveformScrub = ScrubHaptics()

    private var selectionReadout: some View {
        HStack {
            Text(formatDuration(viewModel.selectionEnd - viewModel.selectionStart))
                .font(WorklogFont.numeralRounded)
                .foregroundStyle(Color.worklogTextPrimary)
                // Digits roll to their new values as the selection grows
                // or the handles drag - the readout reads as one live
                // counter, not text being replaced.
                .contentTransition(.numericText())
                .animation(MotionPrimitives.aware(MotionPrimitives.standard), value: viewModel.selectionEnd - viewModel.selectionStart)
            Spacer()
            if let range = viewModel.loadedRange {
                Text("\(formatClockTime(range.requestedStart)) - \(formatClockTime(range.requestedEnd))")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)
            }
            viewModeToggle
        }
    }

    /// Waveform ⇄ transcript. A tiny segmented capsule rather than a menu:
    /// two states, both always one click away.
    private var viewModeToggle: some View {
        HStack(spacing: 2) {
            viewModeButton(.waveform, icon: "waveform", help: "Select on the waveform")
            viewModeButton(.transcript, icon: "text.alignleft", help: "Select on the transcript")
        }
        .padding(2)
        .background(Capsule().fill(Color.worklogSurface))
        .overlay(Capsule().strokeBorder(Color.worklogHairline, lineWidth: 1))
    }

    private func viewModeButton(_ mode: RangeViewMode, icon: String, help: String) -> some View {
        Button {
            guard rangeViewMode != mode else { return }
            WorklogHaptics.play(.select)
            rangeViewModeRaw = mode.rawValue
        } label: {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(rangeViewMode == mode ? Color.worklogOnAccent : Color.worklogTextSecondary)
                .frame(width: 30, height: 18)
                .background(Capsule().fill(rangeViewMode == mode ? Color.worklogAccent : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var transportBar: some View {
        HStack(spacing: WorklogSpacing.md) {
            PlayerBar(
                isPlaying: viewModel.isPlaying,
                position: viewModel.playheadPosition,
                duration: viewModel.totalDuration,
                onToggle: { viewModel.togglePlayback() },
                isPreparing: viewModel.isPreparingPlayback
            )
            // Playback's own problems belong next to the transport, not down
            // by the Create button where an export error lives.
            if let error = viewModel.playbackError {
                Text(error)
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogError)
            }
            Spacer()
        }
    }

    private var clipNamingAndTranscribe: some View {
        VStack(alignment: .trailing, spacing: WorklogSpacing.xs) {
            // Input and button as one joined control row: same height (the
            // input matches the button's own padding metrics), tight
            // spacing, button hugging the field's trailing edge.
            HStack(spacing: WorklogSpacing.xs) {
                TextField("Clip name", text: $viewModel.clipName)
                    .textFieldStyle(.plain)
                    .font(WorklogFont.body)
                    .padding(.horizontal, WorklogSpacing.md)
                    .padding(.vertical, WorklogSpacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: WorklogRadius.md, style: .continuous)
                            .fill(Color.worklogSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: WorklogRadius.md, style: .continuous)
                            .strokeBorder(Color.worklogHairline, lineWidth: 1)
                    )

                WorklogButton(viewModel.isExporting ? "Exporting…" : "Create") {
                    viewModel.transcribe()
                }
                .fixedSize()
                .disabled(viewModel.isExporting)
            }

            if let error = viewModel.exportError {
                Text(error)
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogError)
            }
        }
    }

    private func formatClockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }
}

/// Reads the width of its container into a callback - used so the waveform
/// area's tap/hover gestures can convert an x-coordinate into a time offset
/// without threading a `GeometryReader` through every overlay layer.
private struct WidthReader: View {
    let onChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear { onChange(geometry.size.width) }
                .onChange(of: geometry.size.width) { onChange($0) }
        }
    }
}
