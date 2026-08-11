import SwiftUI

/// Detail pane for the selected Library entry: seekable clip player, both
/// transcript stages (raw Scribe + Hinglish) shown independently as soon as
/// each becomes available, retry, and per-file actions - per spec
/// `06-library.md`'s row-actions section, extended per explicit user
/// request: always surface whatever data actually exists rather than
/// collapsing to a single all-or-nothing state, and put copy/reveal
/// actions as small icon buttons next to each file's own section rather
/// than a single shared action bar (Rename/Delete moved to the row's `⋯`
/// menu in `LibraryRow`; "Re-clip from history" removed entirely - the
/// Clip screen already covers that).
struct LibraryDetailView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let entry: LibraryEntry

    @State private var renderedTranscript: String?
    /// Loaded translation markdown, keyed by translation row ID.
    @State private var translationTexts: [String: String] = [:]
    /// Loaded summary markdown.
    @State private var summaryTexts: [String: String] = [:]
    /// True from the moment `loadTranscripts()` kicks off its background
    /// read until it lands - distinguishes "still loading, don't know yet"
    /// from "loaded and genuinely empty/unreadable" so a transcript marked
    /// `.succeeded` doesn't flash a "file couldn't be read" error message
    /// during the async read window before the real content arrives.
    @State private var isLoadingTranscripts = false
    /// Monotonic token for `loadTranscripts` - several loads can be in
    /// flight at once (state changes fire it repeatedly as pipeline steps
    /// finish), and an older load landing after a newer one used to clobber
    /// just-loaded content back to nil (seen as "Summary missing - marked
    /// done, but the file couldn't be read" right after generation, until
    /// the page was revisited). Only the newest load may write results.
    @State private var loadGeneration = 0
    // Collapsed by default - a full transcript can run very long, and
    // per explicit user request the detail pane shouldn't force scrolling
    // through it just to see the player/retry controls.
    @State private var isTranscriptExpanded = false
    @State private var expandedTranslationIDs: Set<String> = []
    @State private var expandedSummaries: Set<String> = []
    /// Names, place membership, and the reverse-geocode cache all live in
    /// `PlaceStore` - observed here so renaming a place (from this popover
    /// or from the Places tab) updates this header immediately.
    @ObservedObject private var places = PlaceStore.shared
    @ObservedObject private var tagStore = TagStore.shared
    @State private var isTagPickerPresented = false
    /// Expanded by default, unlike the artifact sections: its content is one
    /// line of chips, and collapsing that hides the most glanceable thing
    /// about a clip to save no space at all.
    @State private var isTagsExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.lg) {
            header
            playerArea
            Divider().overlay(Color.worklogHairline)
            ScrollView {
                VStack(alignment: .leading, spacing: WorklogSpacing.lg) {
                    tagsSectionView
                    Divider().overlay(Color.worklogHairline)
                    transcriptSectionView
                    ForEach(entry.translations, id: \.id) { translation in
                        Divider().overlay(Color.worklogHairline)
                        translationSection(translation)
                    }
                    ForEach(entry.summaries, id: \.id) { summary in
                        Divider().overlay(Color.worklogHairline)
                        summarySection(summary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Keeps each section's trailing retry icon clear of the
                // overlay scrollbar, which draws over the content.
                .padding(.trailing, WorklogSpacing.scrollbarGutter)
            }
        }
        .padding(WorklogSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            loadTranscripts()
        }
        // IMPORTANT: these use the macOS 14 zero-parameter onChange form,
        // never the deprecated `{ _ in … }` one - the deprecated form runs
        // its action against the view's PRE-change value, so
        // `loadTranscripts()` inside it captured the OLD `entry` (e.g. a
        // summary path still nil) and loaded nothing. Seen live as
        // "Summary missing" right after generation until the entry was
        // re-selected. The zero-parameter form runs with the updated view.
        .onChange(of: entry.id) {
            loadTranscripts()
        }
        .onChange(of: entry.transcript?.state) { loadTranscripts() }
        .onChange(of: entry.translations.map(\.state)) { loadTranscripts() }
        .onChange(of: entry.summaries.map(\.state)) { loadTranscripts() }
        // A retry that re-lands on the SAME persisted state (e.g.
        // .succeeded -> .succeeded, if a prior attempt already marked the
        // step done despite a stale error string, or the step was simply
        // retried after already succeeding) does not fire the state-based
        // .onChange hooks above, since the value never actually changes -
        // SwiftUI's onChange only fires on a real transition. Watching
        // runningSteps instead catches every "a step just finished running"
        // moment regardless of whether the persisted state value itself
        // moved, since each step always passes through absent -> present ->
        // absent in the set on each retry.
        .onChange(of: runningSteps) { loadTranscripts() }
    }

    /// Retries cost real API money and replace existing output, so a stray
    /// tap must not fire one silently - and a phone is far easier to tap by
    /// accident than a trackpad is to click.
    private func confirmRetry(label: String, informative: String, action: @escaping () -> Void) {
        Platform.confirm(
            title: "Retry \(label)?",
            message: informative,
            confirmTitle: "Retry",
            action: action
        )
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
            if viewModel.renamingEntryID == entry.id {
                HStack {
                    TextField("Clip name", text: $viewModel.renameText)
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
                    Text(entry.clip.displayName)
                        .font(WorklogFont.title)
                        .kerning(WorklogFont.titleTracking)
                        .foregroundStyle(Color.worklogTextPrimary)
                    Spacer()
                    // Exports the whole clip - audio, transcript,
                    // translations, summaries - as a portable .worklog.zip
                    // and hands it to the native share picker.
                    iconButton(systemName: "shippingbox", label: "Export as a Worklog archive") {
                        viewModel.exportAndShareArchive(for: entry)
                    }
                    iconButton(systemName: "square.and.arrow.up", label: "Share the audio") {
                        viewModel.shareClipAudio(for: entry)
                    }
                }
            }

            Text("\(formattedDateTime) · \(formattedDuration)")
                .font(WorklogFont.caption)
                .foregroundStyle(Color.worklogTextTertiary)

            // Naming this spot, opening it in Maps, and seeing what the Mac
            // detected all live in the chip's popover - one affordance
            // instead of a click that only ever did one of the three.
            if let label = places.label(
                latitude: entry.clip.locationLatitude,
                longitude: entry.clip.locationLongitude
            ) {
                LocationChipView(label: label)
                    .padding(.leading, -WorklogSpacing.xs)
            }
        }
    }

    // MARK: - Player (always available - the clip audio itself never
    // depends on Scribe/Hinglish succeeding)

    private var playerArea: some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.sm) {
            ClipWaveformView(
                peaks: viewModel.peaksByEntryID[entry.id],
                duration: entry.clip.durationSeconds,
                playheadPosition: viewModel.isPlayingEntryID == entry.id ? viewModel.playheadPosition : 0,
                onSeek: { offset in viewModel.seek(to: offset, for: entry) }
            )

            PlayerBar(
                isPlaying: isPlayingThisEntry,
                position: isPlayingThisEntry ? viewModel.playheadPosition : 0,
                duration: entry.clip.durationSeconds,
                onToggle: { viewModel.togglePlayback(for: entry) }
            )
        }
    }

    private var isPlayingThisEntry: Bool {
        viewModel.isPlayingEntryID == entry.id
    }

    private var runningSteps: Set<PipelineStep> {
        viewModel.runningSteps(for: entry)
    }

    // MARK: - Transcript + translation sections - each shown independently,
    // never collapsed behind a single error/loading takeover. Per explicit
    // user request: show whatever's actually available, and when a step's
    // output is missing, say exactly which step and why - not a generic
    // error screen. Translations render one section per row: adding a
    // language adds a section, no view changes.

    /// Tags sit first and open: they're the fastest way to know what a clip
    /// is, and unlike a transcript there is nothing to scroll past.
    @ViewBuilder
    private var tagsSectionView: some View {
        let tags = tagStore.tags(forClip: entry.clip.id)
        transcriptSection(
            title: "Tags",
            subtitle: provenance(model: entry.tagging?.model, cost: entry.tagging?.cost),
            isExpanded: $isTagsExpanded,
            onRetry: {
                confirmRetry(
                    label: "auto-tagging",
                    informative: "This asks the model to pick tags for this clip again. Tags you added yourself are kept; ones it chose before are replaced."
                ) { viewModel.retryTagging(for: entry) }
            },
            retryDisabled: entry.transcript?.state != .succeeded || runningSteps.contains(.tag)
        ) {
            VStack(alignment: .leading, spacing: WorklogSpacing.sm) {
                FlowLayout(spacing: WorklogSpacing.xs) {
                    ForEach(tags) { tag in
                        TagChipView(tag: tag, onRemove: { tagStore.unassign(tag, fromClip: entry.clip.id) })
                    }
                    Button { isTagPickerPresented = true } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: 8, weight: .bold))
                            Text(tags.isEmpty ? "Add tag" : "Add")
                                .font(WorklogFont.footnote)
                        }
                        .foregroundStyle(Color.worklogTextSecondary)
                        .padding(.horizontal, WorklogSpacing.sm)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.worklogSurface))
                        .overlay(Capsule().strokeBorder(Color.worklogHairline, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $isTagPickerPresented, arrowEdge: .bottom) {
                        TagPickerView(clipID: entry.clip.id, assigned: tags)
                    }
                }

                if let status = tagStatus {
                    Text(status)
                        .font(WorklogFont.caption)
                        .foregroundStyle(entry.tagging?.state == .failed ? Color.worklogError : Color.worklogTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Only says something when there is something to say - a clip with tags
    /// and a finished run needs no commentary underneath it.
    private var tagStatus: String? {
        if runningSteps.contains(.tag) { return "Picking tags…" }
        switch entry.tagging?.state {
        case .failed: return entry.tagging?.error ?? "Tagging failed."
        case .running: return "Picking tags…"
        case .succeeded, .pending, .none:
            let hasTags = !tagStore.tags(forClip: entry.clip.id).isEmpty
            if hasTags { return nil }
            if entry.transcript?.state != .succeeded { return "Tags are picked once the transcript is ready." }
            // Read, not inferred from a missing row: a clip transcribed
            // before tagging existed has no row either, and telling the user
            // the feature is off when it isn't sends them to a switch that
            // is already on.
            if !WorklogSettingsStore.load().isAutoTaggingEnabled {
                return "Auto-tagging is off - add tags by hand, or switch it on in Settings → Tags."
            }
            if entry.tagging == nil { return "Not tagged yet - use retry to tag this clip." }
            return "No tags yet."
        }
    }

    @ViewBuilder
    private var transcriptSectionView: some View {
        let copyID = "\(entry.id)-transcript"
        transcriptSection(
            title: "Transcript",
            subtitle: transcriptProvenance,
            isExpanded: expansionBinding(forTranscript: true),
            onCopy: renderedTranscript.map { text in { viewModel.copyToPasteboard(text, confirmationID: copyID) } },
            copyConfirmationID: copyID,
            onCopyPath: entry.transcript?.path.map { path in { viewModel.copyPath(path, confirmationID: copyID) } },
            onShare: entry.transcript?.path.map { path in { viewModel.shareFile(atPath: path) } },
            onRetry: {
                confirmRetry(
                    label: "transcription",
                    informative: "Everything on this clip is rebuilt from the new transcript: every translation, every summary, and its tags. Each is a paid call."
                ) { viewModel.retryTranscription(for: entry) }
            },
            retryDisabled: entry.transcript == nil || runningSteps.contains(.transcribe)
        ) {
            // Whenever Scribe isn't the answer - off, unconfigured, failed,
            // or still running - the on-device words take the section over
            // as the transcript rather than sitting under a "missing"
            // placeholder. Someone who never links a Scribe account gets a
            // real transcript here, and the subtitle above says where it
            // came from.
            switch entry.transcript?.state {
            case .succeeded:
                if let renderedTranscript {
                    transcriptText(renderedTranscript)
                    // Kept, not replaced: this is what the device itself
                    // heard, and it outlives the raw audio Scribe read.
                    previewCompanion
                } else if isLoadingTranscripts {
                    transcriptPlaceholder(icon: "clock", message: "Loading…", detail: nil, showsSpinner: true)
                } else {
                    transcriptPlaceholder(icon: "doc.text", message: "Transcript missing", detail: "Marked done, but the file couldn't be read.")
                    previewPrimary
                }
            case .running, .pending, .none:
                previewPrimary
            case .failed:
                previewPrimary
                // The failure still has to be diagnosable - but underneath
                // the text, not in front of it.
                transcriptPlaceholder(
                    icon: "exclamationmark.triangle.fill",
                    message: "Scribe transcription failed",
                    detail: entry.transcript?.error ?? "Transcription failed.",
                    isError: true
                )
            }
        }
    }

    /// What the section's provenance line should say: Scribe's model when
    /// Scribe produced the text, and where the on-device words came from -
    /// plus why they're standing in - whenever they did.
    private var transcriptProvenance: String? {
        if entry.transcript?.state == .succeeded, renderedTranscript != nil {
            return provenance(model: entry.transcript?.model, cost: entry.transcript?.cost)
        }
        return onDeviceProvenance
    }

    private var onDeviceProvenance: String {
        let settings = WorklogSettingsStore.load()
        guard settings.isSpeechPreviewsEnabled else {
            return "No transcription. Turn on on-device speech in Settings."
        }
        let origin = "On-device speech, stays on this iPhone."
        switch entry.transcript?.state {
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

    /// The on-device words rendered *as* this clip's transcript.
    private var previewPrimary: some View {
        PreviewTranscriptFallback(
            start: entry.clip.sourceStart,
            end: entry.clip.sourceEnd,
            owner: .clip(entry.clip.id),
            role: .primary
        )
    }

    /// The same words, kept beneath Scribe's finished transcript rather than
    /// replaced by it. They are what this clip's own preview timeline was
    /// built from, and - because they were snapshotted onto the clip when it
    /// was cut - they remain readable long after the raw audio they describe
    /// has aged out of retention.
    private var previewCompanion: some View {
        PreviewTranscriptFallback(
            start: entry.clip.sourceStart,
            end: entry.clip.sourceEnd,
            owner: .clip(entry.clip.id),
            role: .companion
        )
    }

    @ViewBuilder
    private func translationSection(_ translation: TranslationRecord) -> some View {
        let copyID = "\(entry.id)-\(translation.id)"
        let title = "Translation - \(translation.language.capitalized)"
        let isTranslating = runningSteps.contains(.translate(language: translation.language))
        transcriptSection(
            title: title,
            subtitle: translationSubtitle(translation),
            isExpanded: expansionBinding(forTranslationID: translation.id),
            onCopy: translationTexts[translation.id].map { text in { viewModel.copyToPasteboard(text, confirmationID: copyID) } },
            copyConfirmationID: copyID,
            onCopyPath: translation.path.map { path in { viewModel.copyPath(path, confirmationID: copyID) } },
            onShare: translation.path.map { path in { viewModel.shareFile(atPath: path) } },
            onRetry: {
                confirmRetry(
                    label: "\(translation.language.capitalized) translation",
                    informative: "This re-runs the \(translation.language.capitalized) translation for this clip and replaces its current output."
                ) { viewModel.retryTranslation(translation) }
            },
            retryDisabled: entry.transcript?.state != .succeeded || isTranslating
        ) {
            switch translation.state {
            case .succeeded:
                if let text = translationTexts[translation.id] {
                    transcriptText(text)
                } else if isLoadingTranscripts {
                    transcriptPlaceholder(icon: "clock", message: "Loading…", detail: nil, showsSpinner: true)
                } else {
                    transcriptPlaceholder(icon: "doc.text", message: "Translation missing", detail: "Marked done, but the file couldn't be read.")
                }
            case .running:
                transcriptPlaceholder(icon: "clock", message: "Translating…", detail: nil, showsSpinner: true)
            case .failed:
                transcriptPlaceholder(
                    icon: "exclamationmark.triangle.fill",
                    message: "Translation missing",
                    detail: translation.error ?? "Translation failed.",
                    isError: true
                )
            case .pending:
                if isTranslating {
                    transcriptPlaceholder(icon: "clock", message: "Translating…", detail: nil, showsSpinner: true)
                } else if entry.transcript?.state == .succeeded {
                    transcriptPlaceholder(icon: "doc.text", message: "Translation missing", detail: "Not run yet - use the retry icon above.")
                } else {
                    transcriptPlaceholder(icon: "doc.text", message: "Translation missing", detail: "Waiting on the transcript first.")
                }
            }
        }
    }

    /// Which provider/model produced THIS translation - stored on the
    /// translation row at run time, deliberately not read from current
    /// Settings (which the user may have changed since). nil (no subtitle)
    /// for translations from before this metadata existed.
    // Just the model that produced it: the provider column can name a
    // proxy's default, not what actually served the call, now that
    // everything can route through LiteLLM.
    private func translationSubtitle(_ translation: TranslationRecord) -> String? {
        provenance(model: translation.model, cost: translation.cost)
    }

    @ViewBuilder
    private func summarySection(_ summary: SummaryRecord) -> some View {
        let copyID = "\(entry.id)-\(summary.id)"
        let isSummarizing = runningSteps.contains(.summarize(preset: summary.preset))
        let summaryText = summaryTexts[summary.id]
        let isExpanded = Binding<Bool>(
            get: { expandedSummaries.contains(summary.id) },
            set: { expanded in
                if expanded { expandedSummaries.insert(summary.id) }
                else { expandedSummaries.remove(summary.id) }
            }
        )
        return transcriptSection(
            // The overview keeps the plain heading it has always had; the
            // optional presets name themselves, since several can be on at
            // once.
            title: summary.preset.isDefault ? "Summary" : "Summary · \(summary.preset.displayName)",
            subtitle: summarySubtitle(summary),
            isExpanded: isExpanded,
            onCopy: summaryText.map { text in { viewModel.copyToPasteboard(text, confirmationID: copyID) } },
            copyConfirmationID: copyID,
            onCopyPath: summary.path.map { path in { viewModel.copyPath(path, confirmationID: copyID) } },
            onShare: summary.path.map { path in { viewModel.shareFile(atPath: path) } },
            onRetry: {
                confirmRetry(
                    label: summary.preset.isDefault ? "summary" : "\(summary.preset.displayName.lowercased()) summary",
                    informative: "This re-runs this summary for the clip (from the source selected in Settings) and replaces its current output."
                ) { viewModel.retrySummary(for: entry, preset: summary.preset) }
            },
            retryDisabled: entry.transcript?.state != .succeeded || isSummarizing
        ) {
            switch summary.state {
            case .succeeded:
                if let summaryText {
                    transcriptText(summaryText)
                } else if isLoadingTranscripts {
                    transcriptPlaceholder(icon: "clock", message: "Loading…", detail: nil, showsSpinner: true)
                } else {
                    transcriptPlaceholder(icon: "doc.text", message: "Summary missing", detail: "Marked done, but the file couldn't be read.")
                }
            case .running:
                transcriptPlaceholder(icon: "clock", message: "Summarizing…", detail: nil, showsSpinner: true)
            case .failed:
                transcriptPlaceholder(
                    icon: "exclamationmark.triangle.fill",
                    message: "Summary missing",
                    detail: summary.error ?? "Summary failed.",
                    isError: true
                )
            case .pending:
                if isSummarizing {
                    transcriptPlaceholder(icon: "clock", message: "Summarizing…", detail: nil, showsSpinner: true)
                } else if entry.transcript?.state == .succeeded {
                    transcriptPlaceholder(icon: "doc.text", message: "Summary missing", detail: "Not run yet - use the retry icon above.")
                } else {
                    transcriptPlaceholder(icon: "doc.text", message: "Summary missing", detail: "Waiting on the transcript first.")
                }
            }
        }
    }

    /// Which provider/model produced THIS summary - same run-time
    /// provenance rule as transcripts and translations.
    private func summarySubtitle(_ summary: SummaryRecord) -> String? {
        provenance(model: summary.model, cost: summary.cost)
    }

    /// Provenance line for a step: what produced it, and what it cost.
    /// Both halves are optional - an unrecognised model has no rate to price
    /// against, and showing nothing beats showing a made-up number.
    private func provenance(model: String?, cost: CostRecord?) -> String? {
        guard let model else { return nil }
        return append(cost: cost, to: model)
    }

    private func append(cost: CostRecord?, to text: String) -> String {
        guard let label = cost?.label else { return text }
        return "\(text) · \(label)"
    }

    private func expansionBinding(forTranscript: Bool) -> Binding<Bool> {
        Binding(
            get: { isTranscriptExpanded },
            set: { isTranscriptExpanded = $0 }
        )
    }

    private func expansionBinding(forTranslationID id: String) -> Binding<Bool> {
        Binding(
            get: { expandedTranslationIDs.contains(id) },
            set: { expanded in
                if expanded { expandedTranslationIDs.insert(id) } else { expandedTranslationIDs.remove(id) }
            }
        )
    }

    /// `copyConfirmationID` is the exact ID `viewModel.copyConfirmationEntryID`
    /// will briefly hold after `onCopy` fires - used only to flip the icon
    /// to a checkmark for that same brief confirmation window, so both
    /// sections' copy affordances feel consistent. `onCopy` is
    /// both `nil` until there's a real file/text to act on - no point
    /// showing a button that would do nothing.
    private func transcriptSection<Content: View>(
        title: String,
        subtitle: String? = nil,
        isExpanded: Binding<Bool>,
        onCopy: (() -> Void)? = nil,
        copyConfirmationID: String? = nil,
        onCopyPath: (() -> Void)? = nil,
        onShare: (() -> Void)? = nil,
        onRetry: (() -> Void)? = nil,
        retryDisabled: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.sm) {
            HStack(spacing: WorklogSpacing.xs) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.worklogTextTertiary)
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    .animation(MotionPrimitives.aware(MotionPrimitives.interactive), value: isExpanded.wrappedValue)
                Text(title)
                    .font(WorklogFont.bodyEmphasized)
                    .foregroundStyle(Color.worklogTextPrimary)
                Spacer()
                if let onCopy {
                    let isConfirming = copyConfirmationID != nil && viewModel.copyConfirmationEntryID == copyConfirmationID
                    iconButton(systemName: isConfirming ? "checkmark" : "doc.on.doc", label: "Copy \(title.lowercased())", tint: isConfirming ? Color.worklogSuccess : nil, action: onCopy)
                }
                if let onCopyPath {
                    // The file's path, for pasting somewhere that can open it
                    // - an agent, a terminal, a message to yourself.
                    let isConfirming = copyConfirmationID != nil
                        && viewModel.copyConfirmationEntryID == "\(copyConfirmationID!)-path"
                    iconButton(
                        systemName: isConfirming ? "checkmark" : "link",
                        label: "Copy path to \(title.lowercased())",
                        tint: isConfirming ? Color.worklogSuccess : nil,
                        action: onCopyPath
                    )
                }
                if let onShare {
                    iconButton(systemName: "square.and.arrow.up", label: "Share \(title.lowercased())", action: onShare)
                }
                if let onRetry {
                    iconButton(systemName: "arrow.clockwise", label: "Retry \(title.lowercased())", action: onRetry)
                        .disabled(retryDisabled)
                        .opacity(retryDisabled ? 0.4 : 1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(MotionPrimitives.aware(MotionPrimitives.standard)) {
                    isExpanded.wrappedValue.toggle()
                }
            }

            if isExpanded.wrappedValue {
                // Provenance subtitle (which model/provider actually
                // produced this output) - shown only while expanded, so the
                // collapsed rows stay minimal.
                Group {
                    if let subtitle {
                        Text(subtitle)
                            .font(WorklogFont.caption)
                            .foregroundStyle(Color.worklogTextTertiary)
                    }
                    content()
                }
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
    }

    private func iconButton(systemName: String, label: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        WorklogIconButton(systemName: systemName, label: label, tint: tint, style: .bare, action: action)
    }

    /// Lazily rendered - a full transcript is tens of thousands of
    /// characters and a single `Text` lays all of it out at once. See
    /// `LazyLongText`.
    private func transcriptText(_ text: String) -> some View {
        LazyLongText(text)
    }

    private func transcriptPlaceholder(icon: String, message: String, detail: String?, isError: Bool = false, showsSpinner: Bool = false) -> some View {
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

    /// Reads and decodes the transcript JSON and every translation markdown
    /// off the main actor - the transcript JSON is word-level (one entry per
    /// spoken word), so for a longer multi-speaker clip decoding it plus
    /// formatting the display string is expensive enough to visibly stall
    /// selection/navigation if done inline on every `entry.id`/state change.
    private func loadTranscripts() {
        let transcriptPath = entry.transcript?.path
        let translationPaths: [(id: String, path: String)] = entry.translations.compactMap { translation in
            translation.path.map { (translation.id, $0) }
        }
        let summaryPaths: [(id: String, path: String)] = entry.summaries.compactMap { summary in
            summary.path.map { (summary.id, $0) }
        }
        let entryID = entry.id

        isLoadingTranscripts = true
        loadGeneration += 1
        let generation = loadGeneration

        Task.detached(priority: .userInitiated) {
            let rendered: String? = transcriptPath
                .flatMap { FileManager.default.contents(atPath: $0) }
                .flatMap { try? JSONDecoder().decode(TranscriptResponse.self, from: $0) }
                .map { TranscriptFormatter.displayTranscript($0) }

            var texts: [String: String] = [:]
            for (id, path) in translationPaths {
                if let data = FileManager.default.contents(atPath: path),
                   let text = String(data: data, encoding: .utf8) {
                    texts[id] = text
                }
            }

            var summaryContents: [String: String] = [:]
            for (id, path) in summaryPaths {
                if let data = FileManager.default.contents(atPath: path),
                   let text = String(data: data, encoding: .utf8) {
                    summaryContents[id] = text
                }
            }

            await MainActor.run {
                // The user may have switched to a different entry while
                // this was in flight, or a newer load may have started (and
                // possibly finished) for fresher pipeline state - a stale
                // load must never overwrite what's now showing.
                guard entryID == self.entry.id, generation == self.loadGeneration else { return }
                self.renderedTranscript = rendered
                self.translationTexts = texts
                self.summaryTexts = summaryContents
                self.isLoadingTranscripts = false
            }
        }
    }

    private var formattedDateTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy · h:mm a"
        return formatter.string(from: entry.clip.sourceStart)
    }

    private var formattedDuration: String {
        let total = Int(entry.clip.durationSeconds.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
