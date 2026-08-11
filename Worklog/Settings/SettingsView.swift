import SwiftUI
import CoreLocation

/// The Settings screen (spec `08-settings-and-onboarding.md`): a proper,
/// sectioned preferences page - Recording · Storage & Retention ·
/// Transcription Provider · LLM Provider · Appearance - each spacious,
/// native-feeling, and wired to real state so reopening the screen
/// reflects true current state. (Location tagging and launch-at-login are
/// always-on by design and have no Settings presence, per explicit user
/// request.)
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    @State private var installedLocalesExpanded = false
    @State private var downloadableLocalesExpanded = false

    var body: some View {
        ScrollView {
            // The trailing gutter keeps each card's right-hand controls -
            // toggles, Remove, Reveal in Finder - clear of the overlay
            // scrollbar, which draws over content rather than beside it.
            VStack(alignment: .leading, spacing: WorklogSpacing.xl) {
                recordingSection
                storageSection
                transcriptionProviderSection
                llmProviderSection
                translationSection
                summarySection
                tagsSection
                placesSection
                dictationSection
                speechPreviewsSection
                feedbackSection
                costsSection
            }
            .padding(.horizontal, WorklogSpacing.screenMargin)
            .padding(.top, WorklogSpacing.md)
            .padding(.bottom, WorklogSpacing.xxl)
            // Wide enough to read comfortably on an iPad without the cards
            // stretching into unreadable lines; on a phone it is simply the
            // screen width.
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.worklogBackground)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            viewModel.refreshDevices()
            viewModel.refreshDiskUsage()
            viewModel.refreshAccessibilityStatus()
            viewModel.refreshCosts()
        }
    }

    /// A per-step model override. Same shape everywhere it appears, so
    /// "blank means the provider's model" only has to be learned once.
    private func modelOverrideField(
        title: String,
        text: Binding<String>,
        commit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
            Text(title)
                .font(WorklogFont.bodyEmphasized)
                .foregroundStyle(Color.worklogTextPrimary)
            Text("Blank uses the LLM Provider model\(viewModel.anthropicModel.isEmpty ? " (\(LLMClient.defaultModel))" : " (\(viewModel.anthropicModel))").")
                .font(WorklogFont.caption)
                .foregroundStyle(Color.worklogTextTertiary)
            TextField(viewModel.anthropicModel.isEmpty ? LLMClient.defaultModel : viewModel.anthropicModel, text: text)
                .textFieldStyle(.roundedBorder)
                .font(WorklogFont.transcript)
                .onChange(of: text.wrappedValue) { _ in commit() }
        }
    }

    // MARK: - Speech Previews

    /// Keeping the screen on belongs with recording, not with previews: it is
    /// about watching a capture in progress.
    private var keepAwakeRow: some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
            WorklogToggle(
                label: "Keep the screen on",
                isOn: Binding(
                    get: { viewModel.keepAwakeEnabled },
                    set: { viewModel.setKeepAwakeEnabled($0) }
                )
            )
            Text("Stops the screen dimming and locking while Worklog is open. Recording carries on with the screen off either way - this is only for watching the waveform.")
                .font(WorklogFont.caption)
                .foregroundStyle(Color.worklogTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var speechPreviewsSection: some View {
        SettingsSection(title: "Speech Previews", systemImage: "captions.bubble") {
            VStack(alignment: .leading, spacing: WorklogSpacing.md) {
                WorklogToggle(
                    label: "On-device speech previews",
                    isOn: Binding(
                        get: { viewModel.speechPreviewsEnabled },
                        set: { viewModel.setSpeechPreviewsEnabled($0) }
                    )
                )
                Text("Transcribes as you record, on this iPhone. Nothing leaves the device and it costs nothing. Used for live dictation text, clip edges, and the transcript view.")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                speechPreviewStatusRow

                if viewModel.speechPreviewsEnabled {
                    speechPreviewLanguages
                }
            }
        }
        .onAppear { viewModel.refreshPreviewLanguages() }
    }

    /// Apple supports 30 locales here, so both lists are capped like the
    /// tags and places lists above - a settings pane shouldn't be mostly
    /// language rows.

    /// Which languages to listen in, and a way to fetch more.
    ///
    /// This transcriber takes one language per session, so the list is a
    /// preference order rather than a set to switch between - the first
    /// installed match wins. Hindi is deliberately absent from what Apple
    /// supports on-device today; that is a platform limit, not a bug here.
    @ViewBuilder
    private var speechPreviewLanguages: some View {
        if !viewModel.installedPreviewLocales.isEmpty || !viewModel.downloadablePreviewLocales.isEmpty {
            VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
                Text("Languages")
                    .font(WorklogFont.bodyEmphasized)
                    .foregroundStyle(Color.worklogTextPrimary)
                Text("Pick the languages you speak. The first installed match is used.")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)

                ForEach(viewModel.installedPreviewLocales.capped(to: ShowMoreButton.collapsedLimit, expanded: installedLocalesExpanded), id: \.self) { identifier in
                    WorklogToggle(
                        label: Self.languageLabel(identifier),
                        isOn: Binding(
                            get: { viewModel.selectedPreviewLocales.contains(identifier) },
                            set: { _ in viewModel.togglePreviewLocale(identifier) }
                        )
                    )
                }
                ShowMoreButton(
                    total: viewModel.installedPreviewLocales.count,
                    isExpanded: $installedLocalesExpanded
                )

                if !viewModel.downloadablePreviewLocales.isEmpty {
                    Text("Available to download")
                        .font(WorklogFont.caption)
                        .foregroundStyle(Color.worklogTextTertiary)
                        .padding(.top, WorklogSpacing.xs)
                    ForEach(viewModel.downloadablePreviewLocales.capped(to: ShowMoreButton.collapsedLimit, expanded: downloadableLocalesExpanded), id: \.self) { identifier in
                        HStack {
                            Text(Self.languageLabel(identifier))
                                .font(WorklogFont.body)
                                .foregroundStyle(Color.worklogTextSecondary)
                            Spacer()
                            Button(viewModel.downloadingPreviewLocale == identifier ? "Downloading..." : "Download") {
                                viewModel.downloadPreviewLocale(identifier)
                            }
                            .buttonStyle(.borderless)
                            .disabled(viewModel.downloadingPreviewLocale != nil)
                        }
                    }
                    ShowMoreButton(
                        total: viewModel.downloadablePreviewLocales.count,
                        isExpanded: $downloadableLocalesExpanded
                    )
                }
            }
        }
    }

    /// "en-IN" reads as "English (India)", which is what people recognise.
    private static func languageLabel(_ identifier: String) -> String {
        let locale = Locale(identifier: identifier)
        let name = Locale.current.localizedString(forIdentifier: identifier)
            ?? locale.identifier
        return "\(name) (\(identifier))"
    }

    /// One live line that answers "is it working?" - including the model
    /// download the first enable kicks off, which would otherwise be an
    /// invisible multi-hundred-megabyte wait.
    @ViewBuilder
    private var speechPreviewStatusRow: some View {
        switch viewModel.speechPreviewStatus {
        case .off:
            EmptyView()
        case .unavailable(let reason):
            HStack(spacing: WorklogSpacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.worklogWarning)
                Text(reason)
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .downloadingModel(let fraction):
            HStack(spacing: WorklogSpacing.sm) {
                if let fraction {
                    ProgressView(value: fraction)
                        .frame(width: 120)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(fraction.map { "Downloading the speech model… \(Int($0 * 100))%" } ?? "Downloading the speech model…")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextSecondary)
                    .contentTransition(.numericText())
            }
        case .idle:
            statusDotRow(color: Color.worklogTextTertiary, text: "Ready - previews start with the next recording.")
        case .listening:
            statusDotRow(color: Color.worklogSuccess, text: "Listening to the current recording.")
        }
    }

    private func statusDotRow(color: Color, text: String) -> some View {
        HStack(spacing: WorklogSpacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(WorklogFont.caption)
                .foregroundStyle(Color.worklogTextSecondary)
        }
    }

    // MARK: - Haptics & Sound

    /// Both switches demonstrate themselves the moment you turn them on -
    /// a preference about how something feels is the one kind you should
    /// not have to leave the page to evaluate.
    private var feedbackSection: some View {
        SettingsSection(title: "Haptics & Sound", systemImage: "hand.tap") {
            VStack(alignment: .leading, spacing: WorklogSpacing.md) {
                WorklogToggle(
                    label: "Haptics",
                    isOn: Binding(
                        get: { viewModel.hapticsEnabled },
                        set: { viewModel.setHapticsEnabled($0) }
                    )
                )
                Text("A tick under your finger on presses, selections, switches and slider stops. Follows the system's own haptics setting.")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(Color.worklogHairline)

                WorklogToggle(
                    label: "Dictation sounds",
                    isOn: Binding(
                        get: { viewModel.dictationSoundsEnabled },
                        set: { viewModel.setDictationSoundsEnabled($0) }
                    )
                )
                Text("Three short tones - rising when a dictation starts, falling when it ends, and lower still when one is cancelled. Useful when you are dictating from the keyboard in another app and not looking at Worklog. Worth turning off if you dictate on speakers, since the microphone will hear them too.")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Tags

    private var tagsSection: some View {
        SettingsSection(title: "Tags", systemImage: "tag") {
            VStack(alignment: .leading, spacing: WorklogSpacing.md) {
                WorklogToggle(
                    label: "Tag clips automatically",
                    isOn: Binding(
                        get: { viewModel.autoTaggingEnabled },
                        set: { viewModel.setAutoTaggingEnabled($0) }
                    )
                )
                Text("After a transcript lands, a model picks tags for the clip. You can always add or remove them by hand.")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if viewModel.autoTaggingEnabled {
                    WorklogToggle(
                        label: "Let it invent new tags",
                        isOn: Binding(
                            get: { viewModel.taggingAllowsNewTags },
                            set: { viewModel.setTaggingAllowsNewTags($0) }
                        )
                    )
                    Text("On, the vocabulary grows itself from an empty list. Off, it may only use tags you already have - turn this off once yours has settled.")
                        .font(WorklogFont.caption)
                        .foregroundStyle(Color.worklogTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    modelOverrideField(
                        title: "Tagging model",
                        text: $viewModel.taggingModel,
                        commit: { viewModel.commitStepModelOverrides() }
                    )
                }

                Divider().overlay(Color.worklogHairline)

                TagManagerView()
            }
        }
    }

    // MARK: - Places

    private var placesSection: some View {
        SettingsSection(title: "Places", systemImage: "mappin.and.ellipse") {
            VStack(alignment: .leading, spacing: WorklogSpacing.sm) {
                Text("Name the spots you record at and set how far each reaches. Click one to edit it - the same editor a clip's location opens.")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                PlacesSettingsView()
            }
        }
    }

    // MARK: - Costs

    private var costsSection: some View {
        SettingsSection(title: "Costs", systemImage: "dollarsign.circle") {
            VStack(alignment: .leading, spacing: WorklogSpacing.md) {
                if viewModel.costGroups.isEmpty {
                    Text("Nothing billable yet.")
                        .font(WorklogFont.body)
                        .foregroundStyle(Color.worklogTextSecondary)
                } else {
                    ForEach(viewModel.costGroups) { group in
                        VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
                            Text("\(group.title):")
                                .font(WorklogFont.bodyEmphasized)
                                .foregroundStyle(Color.worklogTextPrimary)

                            ForEach(group.totals) { total in
                                HStack(alignment: .firstTextBaseline, spacing: WorklogSpacing.sm) {
                                    Text(total.model)
                                        .font(WorklogFont.transcriptCaption)
                                        .foregroundStyle(Color.worklogTextSecondary)
                                    Text(total.calls == 1 ? "1 call" : "\(total.calls) calls")
                                        .font(WorklogFont.caption)
                                        .foregroundStyle(Color.worklogTextTertiary)
                                    // The usage the price was actually
                                    // charged on - audio minutes for
                                    // speech-to-text, tokens for LLM steps -
                                    // so a total can be checked against the
                                    // provider's own rate rather than taken
                                    // on faith.
                                    if let usage = total.usageSummary {
                                        Text("·")
                                            .font(WorklogFont.caption)
                                            .foregroundStyle(Color.worklogTextTertiary)
                                        Text(usage)
                                            .font(WorklogFont.caption)
                                            .foregroundStyle(Color.worklogTextTertiary)
                                    }
                                    Spacer(minLength: WorklogSpacing.md)
                                    Text(Pricing.label(costUSD: total.usd, source: total.isEstimated ? .estimated : .reported) ?? "")
                                        .font(WorklogFont.numeralRounded)
                                        .foregroundStyle(Color.worklogTextPrimary)
                                }
                            }
                        }
                    }

                    Divider().overlay(Color.worklogHairline).padding(.vertical, WorklogSpacing.xs)

                    HStack(alignment: .firstTextBaseline) {
                        Text("Total")
                            .font(WorklogFont.bodyEmphasized)
                            .foregroundStyle(Color.worklogTextPrimary)
                        Spacer()
                        Text(Pricing.label(costUSD: viewModel.totalCostUSD, source: viewModel.isAnyCostEstimated ? .estimated : .reported) ?? "")
                            .font(WorklogFont.headerRounded)
                            .foregroundStyle(Color.worklogTextPrimary)
                    }
                }
            }
        }
    }

    // MARK: - Dictation

    private var dictationSection: some View {
        SettingsSection(title: "Dictation", systemImage: "text.bubble") {
            VStack(alignment: .leading, spacing: WorklogSpacing.md) {
                WorklogToggle(
                    label: "Enable push-to-talk dictation",
                    isOn: Binding(
                        get: { viewModel.dictationEnabled },
                        set: { viewModel.setDictationEnabled($0) }
                    )
                )

                Text("Hold the mic button to talk, release to insert. Slide up while holding to stay hands-free; tap again to save.")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)

                if viewModel.dictationEnabled {
                    keyboardStatusRow

                    Divider().overlay(Color.worklogHairline).padding(.vertical, WorklogSpacing.xs)

                    Text("Model")
                        .font(WorklogFont.bodyEmphasized)
                        .foregroundStyle(Color.worklogTextPrimary)

                    Picker("", selection: Binding(
                        get: { viewModel.dictationModel },
                        set: { viewModel.setDictationModel($0) }
                    )) {
                        ForEach(DictationModel.allCases, id: \.self) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    Text(viewModel.dictationModel.detail)
                        .font(WorklogFont.caption)
                        .foregroundStyle(Color.worklogTextTertiary)

                    if viewModel.dictationModel == .scribeV2Realtime {
                        realtimeOptions
                    }

                    Divider().overlay(Color.worklogHairline).padding(.vertical, WorklogSpacing.xs)

                    Text("Language")
                        .font(WorklogFont.bodyEmphasized)
                        .foregroundStyle(Color.worklogTextPrimary)

                    Picker("", selection: Binding(
                        get: { viewModel.dictationLanguage },
                        set: { viewModel.setDictationLanguage($0) }
                    )) {
                        ForEach(DictationLanguage.allCases, id: \.self) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    Text(viewModel.dictationLanguage == .auto
                        ? "Best when you switch languages mid-sentence."
                        : "More accurate if you only speak \(viewModel.dictationLanguage.displayName) - but everything is heard as \(viewModel.dictationLanguage.displayName). Dictation only.")
                        .font(WorklogFont.caption)
                        .foregroundStyle(Color.worklogTextTertiary)

                    Divider().overlay(Color.worklogHairline).padding(.vertical, WorklogSpacing.xs)

                    WorklogToggle(
                        label: "Only insert if you're still in the same app",
                        isOn: Binding(
                            get: { viewModel.dictationInsertOnlyIfFocusUnchanged },
                            set: { viewModel.setDictationInsertOnlyIfFocusUnchanged($0) }
                        )
                    )

                    Text("Switch apps mid-dictation and the text is copied instead of typed.")
                        .font(WorklogFont.caption)
                        .foregroundStyle(Color.worklogTextTertiary)

                    Divider().overlay(Color.worklogHairline).padding(.vertical, WorklogSpacing.xs)

                    WorklogToggle(
                        label: "Remove sound labels",
                        isOn: Binding(
                            get: { viewModel.dictationRemoveSoundLabels },
                            set: { viewModel.setDictationRemoveSoundLabels($0) }
                        )
                    )

                    Text("Drops things the transcriber heard but nobody said - [clears throat], [laughter] - before the text lands in your field. Dictation only: a clip's transcript keeps them, because there they're part of the record.")
                        .font(WorklogFont.caption)
                        .foregroundStyle(Color.worklogTextTertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var realtimeOptions: some View {
        Text("Insertion")
            .font(WorklogFont.bodyEmphasized)
            .foregroundStyle(Color.worklogTextPrimary)
            .padding(.top, WorklogSpacing.xs)

        Picker("", selection: Binding(
            get: { viewModel.dictationRealtimeInsertion },
            set: { viewModel.setDictationRealtimeInsertion($0) }
        )) {
            ForEach(DictationRealtimeInsertion.allCases, id: \.self) { insertion in
                Text(insertion.displayName).tag(insertion)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)

        Text(viewModel.dictationRealtimeInsertion == .typeAsYouSpeak
            ? "Types directly. Switch to pasting if text arrives garbled in some apps."
            : "Pastes once at the end. Slower, but works anywhere \u{2318}V works.")
            .font(WorklogFont.caption)
            .foregroundStyle(Color.worklogTextTertiary)

        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
                HStack {
                    Text("Pause before committing")
                        .font(WorklogFont.body)
                        .foregroundStyle(Color.worklogTextPrimary)
                    Spacer()
                    Text(String(format: "%.1fs", viewModel.dictationVadSilenceSeconds))
                        .font(WorklogFont.caption)
                        .foregroundStyle(Color.worklogTextTertiary)
                }
                Slider(
                    value: Binding(
                        get: { viewModel.dictationVadSilenceSeconds },
                        set: { viewModel.setDictationVadSilenceSeconds($0) }
                    ),
                    in: 0.2...2.0,
                    step: 0.1
                )
                Text("Pause length before a phrase is locked in. Shorter is faster but choppier.")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)
            }
            .padding(.top, WorklogSpacing.xs)
        }
        .font(WorklogFont.caption)
        .foregroundStyle(Color.worklogTextSecondary)
    }

    /// The one piece of setup dictation needs on iOS, and the one the app
    /// cannot do for the user: enabling the Worklog keyboard. iOS gives no API
    /// to enable a keyboard or to prompt for it - it is a real trust decision,
    /// since a keyboard sees everything typed - so this says plainly what is
    /// needed and opens the right Settings screen.
    private var keyboardStatusRow: some View {
        HStack(alignment: .top, spacing: WorklogSpacing.sm) {
            Image(systemName: viewModel.isKeyboardEnabled ? "checkmark.circle.fill" : "keyboard")
                .foregroundStyle(viewModel.isKeyboardEnabled ? Color.worklogSuccess : Color.worklogWarning)

            VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
                Text(viewModel.isKeyboardEnabled ? "Worklog keyboard enabled" : "Worklog keyboard not enabled")
                    .font(WorklogFont.body)
                    .foregroundStyle(Color.worklogTextPrimary)
                Text(viewModel.isKeyboardEnabled
                    ? "Switch to it in any app with the 🌐 key to dictate straight into a field."
                    : "Dictating into other apps needs it. Settings › Worklog › Keyboards › Worklog. Dictating inside Worklog works either way.")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)

                if viewModel.isKeyboardEnabled && !WorklogKeyboardStatus.hasFullAccess {
                    // Without Full Access the keyboard can still recognise
                    // speech on-device and insert it, but it cannot reach the
                    // shared database or the network - so the dictation is
                    // never saved and cloud models are unavailable. Worth
                    // saying, because the symptom otherwise is "my dictations
                    // tab is empty" with no visible cause.
                    Text("Turn on Allow Full Access for dictations to be saved to the Dictations tab and for cloud models to work.")
                        .font(WorklogFont.caption)
                        .foregroundStyle(Color.worklogWarning)
                        .padding(.top, WorklogSpacing.xs)
                }
            }

            Spacer()

            WorklogButton(viewModel.isKeyboardEnabled ? "Settings" : "Set up\u{2026}", kind: .secondary) {
                viewModel.openKeyboardSettings()
            }
            .fixedSize()
        }
        .padding(WorklogSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: WorklogRadius.sm, style: .continuous).fill(Color.worklogSurface))
    }

    // MARK: - Recording

    private var recordingSection: some View {
        SettingsSection(title: "Recording", systemImage: "mic") {
            VStack(alignment: .leading, spacing: WorklogSpacing.md) {
                Text("Input device")
                    .font(WorklogFont.bodyEmphasized)
                    .foregroundStyle(Color.worklogTextPrimary)

                if viewModel.availableDevices.isEmpty {
                    Text("No microphone detected.")
                        .font(WorklogFont.body)
                        .foregroundStyle(Color.worklogTextSecondary)
                } else {
                    // A menu showing the current choice, not a bare picker.
                    // `labelsHidden()` + `.menu` renders as a lone chevron
                    // when nothing is selected yet, which is exactly the
                    // moment the control most needs to say what it is for.
                    Menu {
                        ForEach(viewModel.availableDevices) { device in
                            Button {
                                viewModel.selectDevice(uid: device.uid)
                            } label: {
                                if viewModel.pinnedDeviceUID == device.uid {
                                    Label(device.name, systemImage: "checkmark")
                                } else {
                                    Text(device.name)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: WorklogSpacing.xs) {
                            Text(viewModel.pinnedDeviceName ?? "Choose a microphone")
                                .font(WorklogFont.body)
                                .foregroundStyle(viewModel.pinnedDeviceName == nil ? Color.worklogTextTertiary : Color.worklogTextPrimary)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.worklogAccent)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, WorklogSpacing.md)
                        .frame(minHeight: 44)
                        .background(
                            RoundedRectangle(cornerRadius: WorklogRadius.md, style: .continuous)
                                .fill(Color.worklogSurface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: WorklogRadius.md, style: .continuous)
                                .strokeBorder(Color.worklogHairline, lineWidth: 1)
                        )
                    }
                }

                Text(deviceInfoLine)
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                keepAwakeRow
            }
        }
    }

    private var devicePickerBinding: Binding<String?> {
        Binding(
            get: { viewModel.pinnedDeviceUID },
            set: { if let uid = $0 { viewModel.selectDevice(uid: uid) } }
        )
    }

    private var deviceInfoLine: String {
        guard viewModel.pinnedDeviceName != nil else {
            return "Nothing pinned yet - recording needs a microphone chosen here."
        }
        return "Always records from this one, whatever else connects · mono · 48 kHz · ~64 kbps AAC"
    }

    // MARK: - Storage & Retention

    private var storageSection: some View {
        SettingsSection(title: "Storage & Retention", systemImage: "externaldrive") {
            VStack(alignment: .leading, spacing: WorklogSpacing.md) {
                Text("Retention window")
                    .font(WorklogFont.bodyEmphasized)
                    .foregroundStyle(Color.worklogTextPrimary)

                Picker("", selection: Binding(
                    get: { viewModel.retentionWindow },
                    set: { viewModel.setRetentionWindow($0) }
                )) {
                    ForEach(RetentionWindow.allCases, id: \.self) { window in
                        Text(window.displayName).tag(window)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Text("Raw recordings only - clips, dictations and transcripts are never auto-deleted.")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)

                Divider().overlay(Color.worklogHairline).padding(.vertical, WorklogSpacing.xs)

                VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
                    Label(viewModel.dataFolderLocation, systemImage: "folder")
                        .font(WorklogFont.body)
                        .foregroundStyle(Color.worklogTextPrimary)
                    Text(diskUsageLine)
                        .font(WorklogFont.caption)
                        .foregroundStyle(Color.worklogTextTertiary)
                    Text("Plain files and one SQLite database. Open the Files app to copy anything off the phone.")
                        .font(WorklogFont.caption)
                        .foregroundStyle(Color.worklogTextTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                WorklogButton("Purge raw audio now", kind: .destructive) {
                    viewModel.purgeRawAudioNow()
                }
                .fixedSize()
            }
        }
    }

    private var diskUsageLine: String {
        let usage = viewModel.diskUsage
        return "Total \(formatBytes(usage.totalBytes)) · recordings \(formatBytes(usage.audioBytes)) · clips \(formatBytes(usage.clipsBytes))"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Transcription Provider

    private var transcriptionProviderSection: some View {
        SettingsSection(title: "Transcription Provider", systemImage: "waveform") {
            VStack(alignment: .leading, spacing: WorklogSpacing.lg) {
                WorklogToggle(
                    label: "Enable transcription",
                    isOn: Binding(
                        get: { viewModel.elevenLabsEnabled },
                        set: { viewModel.setElevenLabsEnabled($0) }
                    )
                )

                Divider().overlay(Color.worklogHairline)

                apiKeyRow(
                    title: "API key",
                    helperText: "Used for the transcription step.",
                    hasKey: viewModel.hasElevenLabsKey,
                    draft: Binding(get: { viewModel.elevenLabsKeyDraft }, set: { viewModel.elevenLabsKeyDraft = $0 }),
                    error: viewModel.elevenLabsKeyError,
                    onSave: { viewModel.saveElevenLabsKey() },
                    onRemove: { viewModel.removeElevenLabsKey() }
                )

                Text("Stored in the iOS Keychain, readable only by Worklog. Only transcription needs it - recording and clipping work without.")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)

                Divider().overlay(Color.worklogHairline)

                VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
                    Text("Base URL")
                        .font(WorklogFont.bodyEmphasized)
                        .foregroundStyle(Color.worklogTextPrimary)
                    Text("For a proxy that forwards ElevenLabs' native API (e.g. a LiteLLM passthrough) - put that proxy's key above. Blank uses \(TranscriptionClient.defaultBaseURL). Realtime dictation always connects to ElevenLabs directly.")
                        .font(WorklogFont.caption)
                        .foregroundStyle(Color.worklogTextTertiary)
                    TextField(TranscriptionClient.defaultBaseURL, text: $viewModel.elevenLabsBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(WorklogFont.transcript)
                        .onChange(of: viewModel.elevenLabsBaseURL) { _ in viewModel.commitTranscriptionProviderSettings() }
                }

                VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
                    Text("Model")
                        .font(WorklogFont.bodyEmphasized)
                        .foregroundStyle(Color.worklogTextPrimary)
                    Text("Blank uses \(TranscriptionClient.defaultModel). A provider-prefixed id (e.g. elevenlabs/scribe_v2) calls the proxy's OpenAI-style /v1/audio/transcriptions route instead of ElevenLabs' native API - transcripts then arrive without speaker diarization.")
                        .font(WorklogFont.caption)
                        .foregroundStyle(Color.worklogTextTertiary)
                    TextField(TranscriptionClient.defaultModel, text: $viewModel.elevenLabsModel)
                        .textFieldStyle(.roundedBorder)
                        .font(WorklogFont.transcript)
                        .onChange(of: viewModel.elevenLabsModel) { _ in viewModel.commitTranscriptionProviderSettings() }
                }

                Divider().overlay(Color.worklogHairline)

                WorklogToggle(
                    label: "Disable logging (enterprise)",
                    isOn: Binding(
                        get: { viewModel.elevenLabsLoggingDisabled },
                        set: { viewModel.setElevenLabsLoggingDisabled($0) }
                    )
                )
                Text("Zero-retention mode. Enterprise keys only - standard keys reject it.")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)
            }
        }
    }

    // MARK: - LLM Provider

    private var llmProviderSection: some View {
        SettingsSection(title: "LLM Provider", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: WorklogSpacing.lg) {
                WorklogToggle(
                    label: "Enable LLM",
                    isOn: Binding(
                        get: { viewModel.anthropicEnabled },
                        set: { viewModel.setAnthropicEnabled($0) }
                    )
                )

                Divider().overlay(Color.worklogHairline)

                apiKeyRow(
                    title: "API key",
                    helperText: "Used for the translation and summary steps.",
                    hasKey: viewModel.hasAnthropicKey,
                    draft: Binding(get: { viewModel.anthropicKeyDraft }, set: { viewModel.anthropicKeyDraft = $0 }),
                    error: viewModel.anthropicKeyError,
                    onSave: { viewModel.saveAnthropicKey() },
                    onRemove: { viewModel.removeAnthropicKey() }
                )

                Divider().overlay(Color.worklogHairline)

                VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
                    Text("Base URL")
                        .font(WorklogFont.bodyEmphasized)
                        .foregroundStyle(Color.worklogTextPrimary)
                    Text("For an Anthropic-compatible proxy. Blank uses \(LLMClient.defaultBaseURL).")
                        .font(WorklogFont.caption)
                        .foregroundStyle(Color.worklogTextTertiary)
                    TextField(LLMClient.defaultBaseURL, text: $viewModel.anthropicBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(WorklogFont.transcript)
                        .onChange(of: viewModel.anthropicBaseURL) { _ in viewModel.commitLLMProviderSettings() }
                }

                VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
                    Text("Model")
                        .font(WorklogFont.bodyEmphasized)
                        .foregroundStyle(Color.worklogTextPrimary)
                    Text("Leave blank for the default (\(LLMClient.defaultModel)).")
                        .font(WorklogFont.caption)
                        .foregroundStyle(Color.worklogTextTertiary)
                    TextField(LLMClient.defaultModel, text: $viewModel.anthropicModel)
                        .textFieldStyle(.roundedBorder)
                        .font(WorklogFont.transcript)
                        .onChange(of: viewModel.anthropicModel) { _ in viewModel.commitLLMProviderSettings() }
                }

                VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
                    Text("Effort")
                        .font(WorklogFont.bodyEmphasized)
                        .foregroundStyle(Color.worklogTextPrimary)
                    Text("Blank omits the parameter - some models reject it. Otherwise \"low\", \"high\", etc.")
                        .font(WorklogFont.caption)
                        .foregroundStyle(Color.worklogTextTertiary)
                    TextField("Omitted", text: $viewModel.anthropicEffort)
                        .textFieldStyle(.roundedBorder)
                        .font(WorklogFont.transcript)
                        .onChange(of: viewModel.anthropicEffort) { _ in viewModel.commitLLMProviderSettings() }
                }

                Text("Stored in the iOS Keychain, readable only by Worklog. Base URL, model and effort are plain settings.")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)
            }
        }
    }

    // MARK: - Translation

    private var translationSection: some View {
        SettingsSection(title: "Translation", systemImage: "globe") {
            VStack(alignment: .leading, spacing: WorklogSpacing.md) {
                HStack {
                    Text("Translate to languages")
                        .font(WorklogFont.bodyEmphasized)
                        .foregroundStyle(Color.worklogTextPrimary)
                    Spacer()
                    languageMultiSelect
                }

                Text("Each new transcript is translated to every selected language.")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)

                Divider().overlay(Color.worklogHairline)

                modelOverrideField(
                    title: "Translation model",
                    text: $viewModel.translationModel,
                    commit: { viewModel.commitStepModelOverrides() }
                )
            }
        }
    }

    /// Multi-select as a `Menu` of checkmark rows - there is no native
    /// multi-select control on either platform; a menu that stays data-driven
    /// off the language catalog is the closest native-feeling equivalent.
    private var languageMultiSelect: some View {
        Menu {
            ForEach(WorklogSettings.availableTranslationLanguages, id: \.self) { language in
                Button {
                    viewModel.toggleTranslationLanguage(language)
                } label: {
                    if viewModel.translationLanguages.contains(language) {
                        Label(language.capitalized, systemImage: "checkmark")
                    } else {
                        Text(language.capitalized)
                    }
                }
            }
        } label: {
            Text(viewModel.translationLanguages.map(\.capitalized).joined(separator: ", "))
        }
        .fixedSize()
    }

    // MARK: - Summary

    private var summarySection: some View {
        SettingsSection(title: "Summary", systemImage: "text.alignleft") {
            VStack(alignment: .leading, spacing: WorklogSpacing.md) {
                WorklogToggle(
                    label: "Enable summaries",
                    isOn: Binding(
                        get: { viewModel.summariesEnabled },
                        set: { viewModel.setSummariesEnabled($0) }
                    )
                )

                if viewModel.summariesEnabled {
                    Divider().overlay(Color.worklogHairline)

                    HStack {
                        Text("Create summary from")
                            .font(WorklogFont.bodyEmphasized)
                            .foregroundStyle(Color.worklogTextPrimary)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { viewModel.summarySource },
                            set: { viewModel.setSummarySource($0) }
                        )) {
                            Text("Original").tag(WorklogSettings.originalSummarySource)
                            ForEach(viewModel.translationLanguages, id: \.self) { language in
                                Text(language.capitalized).tag(language)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }

                    Text("Original uses the raw transcript; a language uses that translation.")
                        .font(WorklogFont.caption)
                        .foregroundStyle(Color.worklogTextTertiary)

                    Divider().overlay(Color.worklogHairline)

                    modelOverrideField(
                        title: "Summary model",
                        text: $viewModel.summaryModel,
                        commit: { viewModel.commitStepModelOverrides() }
                    )

                    Divider().overlay(Color.worklogHairline)

                    Text("Also produce")
                        .font(WorklogFont.bodyEmphasized)
                        .foregroundStyle(Color.worklogTextPrimary)

                    VStack(alignment: .leading, spacing: WorklogSpacing.sm) {
                        ForEach(SummaryPreset.optional) { preset in
                            Toggle(isOn: Binding(
                                get: { viewModel.summaryPresets.contains(preset.rawValue) },
                                set: { _ in viewModel.toggleSummaryPreset(preset.rawValue) }
                            )) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(preset.displayName)
                                        .font(WorklogFont.body)
                                        .foregroundStyle(Color.worklogTextPrimary)
                                    Text(preset.summaryDescription)
                                        .font(WorklogFont.caption)
                                        .foregroundStyle(Color.worklogTextTertiary)
                                }
                            }
                        }
                    }

                    Text("Each is a separate document alongside the overview, and a separate LLM call - so each one adds to the per-clip cost. Applies to new clips; use retry on a clip to backfill one.")
                        .font(WorklogFont.caption)
                        .foregroundStyle(Color.worklogTextTertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func apiKeyRow(
        title: String,
        helperText: String,
        hasKey: Bool,
        draft: Binding<String>,
        error: String?,
        onSave: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
            Text(title)
                .font(WorklogFont.bodyEmphasized)
                .foregroundStyle(Color.worklogTextPrimary)
            Text(helperText)
                .font(WorklogFont.caption)
                .foregroundStyle(Color.worklogTextTertiary)

            if hasKey {
                HStack {
                    Text("Key saved")
                        .font(WorklogFont.body)
                        .foregroundStyle(Color.worklogSuccess)
                    Spacer()
                    WorklogButton("Remove", kind: .secondary, action: onRemove)
                        .fixedSize()
                }
            } else {
                HStack {
                    SecureField("Paste key…", text: draft)
                        .textFieldStyle(.roundedBorder)
                        .font(WorklogFont.transcript)
                    WorklogButton("Save", kind: .primary, action: onSave)
                        .fixedSize()
                        .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error {
                    HStack(spacing: WorklogSpacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(error)
                    }
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogError)
                }
            }
        }
    }

}

/// Shared section chrome: icon + title header above a `WorklogCard`, giving
/// every Settings section the same spacious, labeled hierarchy.
private struct SettingsSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.sm) {
            HStack(spacing: WorklogSpacing.sm) {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.worklogAccent)
                Text(title)
                    .font(WorklogFont.headline)
                    .foregroundStyle(Color.worklogTextPrimary)
            }

            WorklogCard {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
