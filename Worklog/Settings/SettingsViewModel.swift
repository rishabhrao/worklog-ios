import Combine
import CoreLocation
import Speech
import Foundation

/// Backs the Settings screen (spec `08-settings-and-onboarding.md`). Owns no
/// state of its own beyond what's needed for live UI binding - every value
/// reads from and writes through the real source of truth (`RecordingController`
/// for the pinned device, `WorklogSettingsStore` for `settings.json`,
/// `KeychainStore` for API keys, `ThemeManager` for appearance,
/// `LoginItemManager` for launch-at-login), so reopening Settings always
/// reflects true current state rather than a stale local copy.
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var availableDevices: [AudioInputDevice] = []
    @Published var pinnedDeviceUID: String?

    @Published var retentionWindow: RetentionWindow

    @Published var elevenLabsKeyDraft: String = ""
    @Published var anthropicKeyDraft: String = ""
    @Published private(set) var hasElevenLabsKey: Bool
    @Published private(set) var hasAnthropicKey: Bool
    @Published var elevenLabsKeyError: String?
    @Published var anthropicKeyError: String?

    /// LLM Provider overrides (plain config, not secrets - live in
    /// `settings.json` via `WorklogSettingsStore`, not the Keychain). Empty
    /// string means "use the built-in default" for base URL/model.
    @Published var anthropicBaseURL: String
    @Published var elevenLabsBaseURL: String
    @Published var elevenLabsModel: String
    @Published var anthropicModel: String
    /// Empty string means "omit `output_config.effort` from the request
    /// entirely" - some models reject the parameter outright. Distinct from
    /// base URL/model, where empty means "use the built-in default value."
    @Published var anthropicEffort: String

    /// Per-provider kill switches: pause the transcription / LLM steps
    /// without removing the saved key. See `WorklogSettings`.
    @Published var elevenLabsEnabled: Bool
    @Published var anthropicEnabled: Bool
    /// ElevenLabs zero-retention mode (`enable_logging=false`) - opt-in,
    /// enterprise keys only.
    @Published var elevenLabsLoggingDisabled: Bool

    /// Translation + Summary sections. Languages are data (see
    /// `WorklogSettings.availableTranslationLanguages` for the UI catalog);
    /// `summarySource` is a language or `WorklogSettings.originalSummarySource`.
    @Published var translationLanguages: [String]
    @Published var summariesEnabled: Bool
    @Published var summarySource: String
    /// Per-step model overrides. Empty string means "use the provider's
    /// model" - the same convention every other override field here uses.
    @Published var translationModel: String
    @Published var summaryModel: String
    @Published var taggingModel: String
    @Published var autoTaggingEnabled: Bool
    @Published var taggingAllowsNewTags: Bool
    /// IDs of the optional presets, each producing a summary in addition to
    /// the overview.
    @Published var summaryPresets: [String]

    /// Dictation section. `isKeyboardEnabled` is re-read rather than cached
    /// because the user can turn the keyboard on and off in iOS Settings
    /// while this app is still in memory, and coming back to a stale answer
    /// would leave the setup row lying about what is set up.
    @Published var dictationEnabled: Bool
    @Published var dictationHotkey: DictationHotkey
    @Published var dictationModel: DictationModel
    @Published var dictationLanguage: DictationLanguage
    @Published var dictationRealtimeInsertion: DictationRealtimeInsertion
    @Published var dictationVadSilenceSeconds: Double
    @Published var dictationInsertOnlyIfFocusUnchanged: Bool
    @Published var dictationRemoveSoundLabels: Bool
    @Published var hapticsEnabled: Bool
    @Published var dictationSoundsEnabled: Bool

    /// Speech Previews section. The status mirrors the engine's published
    /// state so the row shows the model download progressing and the
    /// listening state flipping live, not a snapshot from when Settings
    /// opened.
    @Published var keepAwakeEnabled: Bool
    @Published var speechPreviewsEnabled: Bool
    @Published private(set) var speechPreviewStatus: SpeechPreviewStatus = .off

    /// Whether the Worklog keyboard has been enabled in iOS Settings. A
    /// custom keyboard is the only supported way to put text into another
    /// app's field on iOS - the same constraint the Android build works
    /// under, and the reason neither platform has the Mac's global hotkey.
    @Published private(set) var isKeyboardEnabled: Bool

    @Published private(set) var diskUsage: WorklogDiskUsage = WorklogDiskUsageCalculator.current()

    /// Spend so far, grouped by artifact kind and model. Recomputed when the
    /// screen appears rather than observed continuously - it's a summary of
    /// completed work, and a pipeline finishing while Settings happens to be
    /// open isn't worth a live subscription.
    @Published private(set) var costGroups: [WorklogDatabase.CostGroup] = []

    var totalCostUSD: Double { costGroups.reduce(0) { $0 + $1.usd } }
    var isAnyCostEstimated: Bool { costGroups.contains(where: \.isEstimated) }

    private let recordingController: RecordingController
    private let locationTagger: LocationTagger
    private let dictationController: DictationController
    private var cancellables: Set<AnyCancellable> = []

    init(recordingController: RecordingController, locationTagger: LocationTagger, dictationController: DictationController) {
        self.recordingController = recordingController
        self.locationTagger = locationTagger
        self.dictationController = dictationController

        let settings = WorklogSettingsStore.load()
        pinnedDeviceUID = recordingController.pinnedDeviceUID
        retentionWindow = settings.retentionWindow
        hasElevenLabsKey = KeychainStore.read(.elevenLabsAPIKey) != nil
        hasAnthropicKey = KeychainStore.read(.anthropicAPIKey) != nil
        anthropicBaseURL = settings.anthropicBaseURL ?? ""
        elevenLabsBaseURL = settings.elevenLabsBaseURL ?? ""
        elevenLabsModel = settings.elevenLabsModel ?? ""
        anthropicModel = settings.anthropicModel ?? ""
        translationModel = settings.translationModel ?? ""
        summaryModel = settings.summaryModel ?? ""
        taggingModel = settings.taggingModel ?? ""
        autoTaggingEnabled = settings.isAutoTaggingEnabled
        taggingAllowsNewTags = settings.isTaggingAllowedToCreateTags
        anthropicEffort = settings.anthropicEffort ?? ""
        elevenLabsEnabled = settings.isElevenLabsEnabled
        anthropicEnabled = settings.isAnthropicEnabled
        elevenLabsLoggingDisabled = settings.isElevenLabsLoggingDisabled
        translationLanguages = settings.enabledTranslationLanguages
        summariesEnabled = settings.isSummariesEnabled
        summarySource = settings.effectiveSummarySource
        summaryPresets = settings.summaryPresets ?? []
        dictationEnabled = settings.isDictationEnabled
        dictationHotkey = settings.effectiveDictationHotkey
        dictationModel = settings.effectiveDictationModel
        dictationLanguage = settings.effectiveDictationLanguage
        dictationRealtimeInsertion = settings.effectiveDictationRealtimeInsertion
        dictationVadSilenceSeconds = settings.effectiveDictationVadSilenceSeconds
        dictationInsertOnlyIfFocusUnchanged = settings.isDictationInsertOnlyIfFocusUnchanged
        dictationRemoveSoundLabels = settings.isDictationRemoveSoundLabels
        hapticsEnabled = settings.areHapticsEnabled
        dictationSoundsEnabled = settings.areDictationSoundsEnabled
        keepAwakeEnabled = settings.isKeepAwakeEnabled
        speechPreviewsEnabled = settings.isSpeechPreviewsEnabled
        isKeyboardEnabled = WorklogKeyboardStatus.isEnabled

        speechPreviewStatus = SpeechPreviewEngine.shared.status
        SpeechPreviewEngine.shared.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.speechPreviewStatus = status }
            .store(in: &cancellables)

        refreshDevices()
    }

    func refreshDevices() {
        availableDevices = AudioDeviceRegistry.inputDevices()
    }

    func refreshDiskUsage() {
        diskUsage = WorklogDiskUsageCalculator.current()
    }

    func refreshCosts() {
        costGroups = WorklogDatabase.shared.costSummary()
    }

    // MARK: Recording - device

    func selectDevice(uid: String) {
        pinnedDeviceUID = uid
        recordingController.selectDevice(uid: uid)
        persistSettings()
    }

    var pinnedDeviceName: String? {
        guard let uid = pinnedDeviceUID else { return nil }
        return AudioDeviceRegistry.resolve(uid: uid)?.name
    }

    // MARK: Storage & Retention

    func setRetentionWindow(_ window: RetentionWindow) {
        retentionWindow = window
        persistSettings()
    }

    /// Where the data lives, in words. iOS has no "reveal in Finder": the
    /// folder is browsable in the Files app (that is what
    /// `UIFileSharingEnabled` buys) but no API opens Files at a path, so
    /// Settings shows the location rather than offering a button that
    /// cannot work.
    var dataFolderLocation: String { WorklogFinderReveal.browsableLocation }

    func purgeRawAudioNow() {
        RetentionSweeper.purge(window: retentionWindow)
        refreshDiskUsage()
    }

    // MARK: API Keys

    func saveElevenLabsKey() {
        let trimmed = elevenLabsKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard KeychainStore.write(trimmed, for: .elevenLabsAPIKey) else {
            elevenLabsKeyError = "Couldn't save the key to the Keychain. Try again."
            return
        }
        elevenLabsKeyError = nil
        hasElevenLabsKey = true
        elevenLabsKeyDraft = ""
    }

    func removeElevenLabsKey() {
        KeychainStore.delete(.elevenLabsAPIKey)
        hasElevenLabsKey = false
        elevenLabsKeyError = nil
    }

    func saveAnthropicKey() {
        let trimmed = anthropicKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard KeychainStore.write(trimmed, for: .anthropicAPIKey) else {
            anthropicKeyError = "Couldn't save the key to the Keychain. Try again."
            return
        }
        anthropicKeyError = nil
        hasAnthropicKey = true
        anthropicKeyDraft = ""
    }

    func removeAnthropicKey() {
        KeychainStore.delete(.anthropicAPIKey)
        hasAnthropicKey = false
        anthropicKeyError = nil
    }

    // MARK: LLM Provider (base URL / model overrides)

    /// Commits the current draft base URL/model to `settings.json`. Called
    /// on field commit (`.onSubmit`/loss of focus) rather than per-keystroke
    /// - these aren't validated live, just persisted as free text; a bad
    /// value surfaces as a real error next time `LLMClient.runPrompt`
    /// actually tries to use it (`LLMError.invalidBaseURL`).
    func commitLLMProviderSettings() {
        persistSettings()
    }

    func commitTranscriptionProviderSettings() {
        persistSettings()
    }

    // MARK: Provider kill switches

    func setElevenLabsEnabled(_ enabled: Bool) {
        elevenLabsEnabled = enabled
        persistSettings()
    }

    func setElevenLabsLoggingDisabled(_ disabled: Bool) {
        elevenLabsLoggingDisabled = disabled
        persistSettings()
    }

    func setAnthropicEnabled(_ enabled: Bool) {
        anthropicEnabled = enabled
        persistSettings()
    }

    // MARK: Translation & Summary

    /// Multi-select behavior: toggling a language in or out, except
    /// deselecting the last one - at least one language stays enabled.
    func toggleTranslationLanguage(_ language: String) {
        if translationLanguages.contains(language) {
            guard translationLanguages.count > 1 else { return }
            translationLanguages.removeAll { $0 == language }
            // A summary sourced from a now-disabled language degrades to
            // the original transcript, visibly, not just at run time.
            if summarySource == language {
                summarySource = WorklogSettings.originalSummarySource
            }
        } else {
            // Preserve the catalog's order regardless of click order.
            translationLanguages = WorklogSettings.availableTranslationLanguages.filter {
                translationLanguages.contains($0) || $0 == language
            }
        }
        persistSettings()
    }

    func setSummariesEnabled(_ enabled: Bool) {
        summariesEnabled = enabled
        persistSettings()
    }

    func setSummarySource(_ source: String) {
        summarySource = source
        persistSettings()
    }

    /// Turning a preset on doesn't backfill: clips already summarized keep
    /// what they have, and the new preset applies to whatever comes next (or
    /// to an explicit retry). Re-summarizing the whole library on a toggle
    /// would be a surprising amount of spend for a checkbox.
    func toggleSummaryPreset(_ presetID: String) {
        if let index = summaryPresets.firstIndex(of: presetID) {
            summaryPresets.remove(at: index)
        } else {
            summaryPresets.append(presetID)
        }
        persistSettings()
    }

    // MARK: Dictation

    /// Every dictation setting funnels through here, because all of them
    /// can change whether (or how) the global hotkey should be installed -
    /// persisting without re-syncing would leave the tap watching for the
    /// old key, or running when the feature was just turned off.
    private func applyDictationChange() {
        persistSettings()
        isKeyboardEnabled = WorklogKeyboardStatus.isEnabled
        dictationController.syncWithSettings()
    }

    func setDictationEnabled(_ enabled: Bool) {
        dictationEnabled = enabled
        applyDictationChange()
    }

    func setDictationHotkey(_ hotkey: DictationHotkey) {
        dictationHotkey = hotkey
        applyDictationChange()
    }

    func setDictationModel(_ model: DictationModel) {
        dictationModel = model
        applyDictationChange()
    }

    func setDictationLanguage(_ language: DictationLanguage) {
        dictationLanguage = language
        applyDictationChange()
    }

    func setDictationRealtimeInsertion(_ insertion: DictationRealtimeInsertion) {
        dictationRealtimeInsertion = insertion
        applyDictationChange()
    }

    func setDictationVadSilenceSeconds(_ seconds: Double) {
        dictationVadSilenceSeconds = seconds
        applyDictationChange()
    }

    func setDictationInsertOnlyIfFocusUnchanged(_ enabled: Bool) {
        dictationInsertOnlyIfFocusUnchanged = enabled
        applyDictationChange()
    }

    func setDictationRemoveSoundLabels(_ enabled: Bool) {
        dictationRemoveSoundLabels = enabled
        applyDictationChange()
    }

    func setHapticsEnabled(_ enabled: Bool) {
        hapticsEnabled = enabled
        persistSettings()
        // Demonstrate what was just switched on, in the switch itself. A
        // preference about how something feels is the one kind you should
        // not have to go elsewhere to evaluate.
        if enabled { WorklogHaptics.play(.success) }
    }

    func setDictationSoundsEnabled(_ enabled: Bool) {
        dictationSoundsEnabled = enabled
        persistSettings()
        if enabled { DictationSounds.play(.start) }
    }

    // MARK: Speech previews

    // MARK: - Speech preview languages

    @Published private(set) var installedPreviewLocales: [String] = []
    @Published private(set) var downloadablePreviewLocales: [String] = []
    @Published private(set) var downloadingPreviewLocale: String?
    @Published private(set) var selectedPreviewLocales: [String] = []

    /// True when the device can fetch new speech models on demand. Only the
    /// iOS 26 engine can; below that the offline models arrive with the
    /// system language packs, so the download column is hidden rather than
    /// shown as a button that does nothing.
    var canDownloadPreviewLanguages: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    func refreshPreviewLanguages() {
        Task { @MainActor in
            if #available(iOS 26.0, *) {
                let catalog = await AppleSpeechPreviewTranscriber.languageCatalog()
                installedPreviewLocales = catalog.installed
                downloadablePreviewLocales = catalog.supported.filter { !catalog.installed.contains($0) }
            } else {
                // The older engine has no catalog and no downloads - what is
                // installed is whatever the system has, and it is discovered
                // by asking each supported locale whether it can run offline.
                let supported = SFSpeechRecognizer.supportedLocales()
                    .map(\.identifier)
                    .filter { SFSpeechRecognizer(locale: Locale(identifier: $0))?.supportsOnDeviceRecognition == true }
                    .sorted()
                installedPreviewLocales = supported
                downloadablePreviewLocales = []
            }
            selectedPreviewLocales = WorklogSettingsStore.load().preferredPreviewLocales
        }
    }

    /// Turning them all off is allowed: the engine then falls back to the
    /// system locale, which is the sensible default anyway.
    func togglePreviewLocale(_ identifier: String) {
        var current = selectedPreviewLocales
        if let index = current.firstIndex(of: identifier) {
            current.remove(at: index)
        } else {
            current.append(identifier)
        }
        selectedPreviewLocales = current
        var settings = WorklogSettingsStore.load()
        settings.previewLocales = current
        WorklogSettingsStore.save(settings)
        SpeechPreviewEngine.shared.settingsDidChange()
    }

    func downloadPreviewLocale(_ identifier: String) {
        guard downloadingPreviewLocale == nil else { return }
        downloadingPreviewLocale = identifier
        Task { @MainActor in
            guard #available(iOS 26.0, *) else {
                downloadingPreviewLocale = nil
                return
            }
            do {
                try await AppleSpeechPreviewTranscriber.downloadLanguage(identifier)
                if !selectedPreviewLocales.contains(identifier) {
                    togglePreviewLocale(identifier)
                }
            } catch {
                previewLog.warning("language download failed: \(String(describing: error), privacy: .public)")
            }
            downloadingPreviewLocale = nil
            refreshPreviewLanguages()
        }
    }

    func setKeepAwakeEnabled(_ enabled: Bool) {
        keepAwakeEnabled = enabled
        persistSettings()
        // Applies immediately: sync() re-reads the setting and lets the idle
        // timer come back when it is off.
        ScreenWakeLock.sync()
    }

    func setSpeechPreviewsEnabled(_ enabled: Bool) {
        speechPreviewsEnabled = enabled
        // persistSettings() already notifies the engine, which - on first
        // enable - kicks off the model download and reports it through
        // `speechPreviewStatus`.
        persistSettings()
    }

    /// Sends the user to this app's page in iOS Settings, where the keyboard
    /// is enabled. There is no API to enable it for them and no prompt to
    /// trigger - it is several taps deep under Keyboards, so the least the
    /// app can do is open the right screen.
    func openKeyboardSettings() {
        Platform.openAppSettings()
    }

    /// Called when the Settings screen appears - picks up a change the user
    /// just made in iOS Settings without needing a relaunch.
    func refreshAccessibilityStatus() {
        isKeyboardEnabled = WorklogKeyboardStatus.isEnabled
        dictationController.syncWithSettings()
    }

    var isDictationHotkeyActive: Bool {
        dictationController.isMonitoring
    }

    // MARK: - Tags

    func setAutoTaggingEnabled(_ enabled: Bool) {
        autoTaggingEnabled = enabled
        persistSettings()
    }

    func setTaggingAllowsNewTags(_ allowed: Bool) {
        taggingAllowsNewTags = allowed
        persistSettings()
    }

    /// Committed on every keystroke like the other override fields - these
    /// are plain config, and a "save" button for a text field the user has
    /// already finished typing into is one more thing to forget.
    func commitStepModelOverrides() {
        persistSettings()
    }

    // MARK: - Persistence

    private func trimmedOrNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func persistSettings() {
        let trimmedBaseURL = anthropicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedElevenLabsBaseURL = elevenLabsBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedElevenLabsModel = elevenLabsModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = anthropicModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEffort = anthropicEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        WorklogSettingsStore.save(WorklogSettings(
            pinnedDeviceUID: pinnedDeviceUID,
            retentionWindow: retentionWindow,
            // Always-on by design (per explicit user request, both Settings
            // toggles were removed): launch-at-login and location tagging
            // are enforced at every app boot, not user-configurable.
            launchAtLogin: true,
            locationTaggingEnabled: true,
            anthropicBaseURL: trimmedBaseURL.isEmpty ? nil : trimmedBaseURL,
            anthropicModel: trimmedModel.isEmpty ? nil : trimmedModel,
            anthropicEffort: trimmedEffort.isEmpty ? nil : trimmedEffort,
            elevenLabsEnabled: elevenLabsEnabled,
            anthropicEnabled: anthropicEnabled,
            elevenLabsBaseURL: trimmedElevenLabsBaseURL.isEmpty ? nil : trimmedElevenLabsBaseURL,
            elevenLabsModel: trimmedElevenLabsModel.isEmpty ? nil : trimmedElevenLabsModel,
            elevenLabsLoggingDisabled: elevenLabsLoggingDisabled,
            translationLanguages: translationLanguages,
            summariesEnabled: summariesEnabled,
            summarySource: summarySource,
            summaryPresets: summaryPresets,
            translationModel: trimmedOrNil(translationModel),
            summaryModel: trimmedOrNil(summaryModel),
            taggingModel: trimmedOrNil(taggingModel),
            autoTaggingEnabled: autoTaggingEnabled,
            taggingAllowsNewTags: taggingAllowsNewTags,
            dictationEnabled: dictationEnabled,
            dictationHotkey: dictationHotkey,
            dictationModel: dictationModel,
            dictationLanguage: dictationLanguage,
            dictationRealtimeInsertion: dictationRealtimeInsertion,
            dictationVadSilenceSeconds: dictationVadSilenceSeconds,
            dictationInsertOnlyIfFocusUnchanged: dictationInsertOnlyIfFocusUnchanged,
            dictationRemoveSoundLabels: dictationRemoveSoundLabels,
            hapticsEnabled: hapticsEnabled,
            dictationSoundsEnabled: dictationSoundsEnabled,
            speechPreviewsEnabled: speechPreviewsEnabled
        ))

        // All are read on hot paths (every pointer-down, every hotkey
        // press) or cache their own view of settings, so the write has to
        // tell them it happened.
        WorklogHaptics.settingsDidChange()
        DictationSounds.settingsDidChange()
        SpeechPreviewEngine.shared.settingsDidChange()
    }
}
