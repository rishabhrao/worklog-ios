import Foundation

/// Retention tiers for raw `audio/` segments (spec `03-retention-and-storage.md`).
/// `.never` means the sweeper is a no-op - segments are kept indefinitely.
enum RetentionWindow: String, Codable, CaseIterable {
    case sevenDays
    case fourteenDays
    case thirtyDays
    case oneYear
    case never

    var timeInterval: TimeInterval? {
        switch self {
        case .sevenDays: return 7 * 24 * 60 * 60
        case .fourteenDays: return 14 * 24 * 60 * 60
        case .thirtyDays: return 30 * 24 * 60 * 60
        case .oneYear: return 365 * 24 * 60 * 60
        case .never: return nil
        }
    }

    var displayName: String {
        switch self {
        case .sevenDays: return "7 days"
        case .fourteenDays: return "14 days"
        case .thirtyDays: return "30 days"
        case .oneYear: return "1 year"
        case .never: return "Never"
        }
    }
}

/// Which physical key starts a dictation. Fn is the ergonomic default but
/// is genuinely contested on macOS (the system's own "Press 🌐 key to"
/// mapping and double-press Apple Dictation both live on it), so the
/// binding has to be swappable - a dictation feature whose only trigger can
/// be silently eaten by a System Settings default isn't shippable.
enum DictationHotkey: String, Codable, CaseIterable {
    case fn
    case rightCommand
    case rightOption
    case f13

    var displayName: String {
        switch self {
        case .fn: return "Fn (🌐)"
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        case .f13: return "F13"
        }
    }

    /// Virtual keycode of the physical key. Modifier bindings are detected
    /// from `.flagsChanged` events by keycode - never from the modifier mask
    /// alone, which is set by far more keys than the one the user picked
    /// (e.g. `.maskSecondaryFn` rides along with every arrow and F-key).
    var keyCode: Int64 {
        switch self {
        case .fn: return 63           // kVK_Function
        case .rightCommand: return 54 // kVK_RightCommand
        case .rightOption: return 61  // kVK_RightOption
        case .f13: return 105         // kVK_F13
        }
    }

    /// `true` for the modifier keys, which arrive as `.flagsChanged`;
    /// `false` for F13, which arrives as ordinary `.keyDown`/`.keyUp`.
    var isModifier: Bool {
        switch self {
        case .fn, .rightCommand, .rightOption: return true
        case .f13: return false
        }
    }

    /// The mask bit whose presence in a `.flagsChanged` event distinguishes
    /// "pressed" from "released" for this binding.
    var modifierMask: UInt64 {
        switch self {
        case .fn: return 0x800000          // kCGEventFlagMaskSecondaryFn
        case .rightCommand: return 0x100000 // kCGEventFlagMaskCommand
        case .rightOption: return 0x080000  // kCGEventFlagMaskAlternate
        case .f13: return 0
        }
    }
}

/// Which Scribe model transcribes dictations.
enum DictationModel: String, Codable, CaseIterable {
    /// Batch: the whole dictation is uploaded once you finish, and the text
    /// arrives (and is pasted) in one go.
    case scribeV2
    /// Streaming: audio goes up as you speak and committed text is typed
    /// into your field in phrase-sized chunks, without waiting for the end.
    case scribeV2Realtime

    var displayName: String {
        switch self {
        case .scribeV2: return "Scribe v2"
        case .scribeV2Realtime: return "Scribe v2 Realtime"
        }
    }

    var detail: String {
        switch self {
        case .scribeV2: return "Inserts everything when you finish speaking."
        case .scribeV2Realtime: return "Types as you speak, at natural pauses."
        }
    }

    /// The provider's model identifier - data recorded onto the dictation
    /// row at run time, never branched on.
    var modelID: String {
        switch self {
        case .scribeV2: return TranscriptionClient.defaultModel
        case .scribeV2Realtime: return RealtimeTranscriptionSession.modelID
        }
    }
}

/// Language hint sent to Scribe for dictations.
///
/// `auto` omits `language_code` from the request entirely - which is not the
/// same as sending a default. Omission is what makes the model detect the
/// language itself, and it's the right choice for code-switched speech
/// (the clip pipeline relies on exactly this, since its audio mixes Hindi
/// and English). Naming a language is worth it when you know you're
/// speaking only that one: it stops the model second-guessing accented
/// English as another language mid-sentence.
enum DictationLanguage: String, Codable, CaseIterable {
    case auto
    case english
    case hindi

    var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .english: return "English"
        case .hindi: return "Hindi"
        }
    }

    /// ISO 639-1, as the API expects. `nil` means "send nothing at all."
    var code: String? {
        switch self {
        case .auto: return nil
        case .english: return "en"
        case .hindi: return "hi"
        }
    }
}

/// How realtime-transcribed text reaches the focused app.
enum DictationRealtimeInsertion: String, Codable, CaseIterable {
    /// Synthesize the text directly as it commits. Leaves the clipboard
    /// untouched, but a handful of apps (some Electron/Java/terminal
    /// configurations) mishandle synthesized Unicode input.
    case typeAsYouSpeak
    /// Buffer everything and use the batch path's single paste at the end -
    /// gives up the latency win, keeps realtime's accuracy, and works
    /// anywhere ⌘V works.
    case pasteAtEnd

    var displayName: String {
        switch self {
        case .typeAsYouSpeak: return "Type as you speak"
        case .pasteAtEnd: return "Paste when finished"
        }
    }
}

/// Contents of `~/worklog/settings.json`. Deliberately excludes API keys -
/// those live only in the Keychain (ticket §4.9, §6.F). `pinnedDeviceUID` is
/// mirrored here from `RecordingController`'s `UserDefaults`-backed value so
/// `~/worklog` remains a self-contained, human-browsable record of app
/// state; `RecordingController` remains the runtime source of truth during
/// a session.
struct WorklogSettings: Codable {
    var pinnedDeviceUID: String?
    var retentionWindow: RetentionWindow
    var launchAtLogin: Bool
    var locationTaggingEnabled: Bool

    /// Overrides for the Hinglish-formatting LLM call (Settings' "LLM
    /// Provider" section). Plain config, not secrets, so they live here
    /// rather than the Keychain. Lets the user point at a self-hosted/
    /// proxied Anthropic-compatible endpoint (e.g. a LiteLLM proxy) and/or
    /// pick a different model, without needing a rebuild.
    /// `nil`/blank means "use the built-in default" for base URL and model.
    var anthropicBaseURL: String?
    var anthropicModel: String?
    /// Blank means "omit `output_config.effort` from the request entirely"
    /// - not "use a default effort." Some models (e.g. Opus at time of
    /// writing) reject the parameter outright, so this has to be a real
    /// omission, not a fallback value, per explicit user request. Defaults
    /// to `"low"` for a fresh install (matching the app's prior hardcoded
    /// behavior - cheap mechanical transliteration doesn't need deep
    /// reasoning by default); the user can blank it in Settings to get true
    /// omission for a model that doesn't support it.
    var anthropicEffort: String?

    /// Per-provider kill switches (Settings' provider sections): pause the
    /// Scribe / Hinglish steps without removing the saved API key. Optional
    /// so a settings.json written before these existed still decodes -
    /// missing means enabled, matching prior behavior. When off, the
    /// client fails the step exactly like a missing key would, but with an
    /// honest "disabled in Settings" message instead of "key is missing."
    var elevenLabsEnabled: Bool?
    var anthropicEnabled: Bool?

    var isElevenLabsEnabled: Bool { elevenLabsEnabled ?? true }
    var isAnthropicEnabled: Bool { anthropicEnabled ?? true }

    /// Overrides the transcription endpoint origin - set to a LiteLLM-style
    /// proxy that forwards ElevenLabs' native API. nil = api.elevenlabs.io.
    var elevenLabsBaseURL: String?

    /// Overrides the model_id sent to the transcription endpoint. nil =
    /// the client's default.
    var elevenLabsModel: String?

    /// Opts Scribe calls out of ElevenLabs' own request/response logging
    /// (`enable_logging=false`, zero-retention mode). Enterprise-gated on
    /// ElevenLabs' side - standard keys reject the parameter - so this is
    /// opt-in, default off.
    var elevenLabsLoggingDisabled: Bool?

    var isElevenLabsLoggingDisabled: Bool { elevenLabsLoggingDisabled ?? false }

    /// Target languages every new transcript gets translation rows for
    /// (Settings' "Translation" section). Pure data - languages are never
    /// code-level concepts; the pipeline just iterates whatever's here.
    /// Optional so settings persisted before this existed still decode.
    var translationLanguages: [String]?

    /// Summary step (Settings' "Summary" section): off by default;
    /// `summarySource` is either `Self.originalSummarySource` (summarize
    /// the raw transcript) or one of the enabled translation languages
    /// (summarize that translation's output).
    var summariesEnabled: Bool?
    var summarySource: String?
    /// Extra summaries to produce alongside the overview, by preset ID. Each
    /// one is another LLM call per clip, which is why they're opt-in.
    /// Optional so settings persisted before this existed still decode.
    var summaryPresets: [String]?

    /// Per-step model overrides. The LLM Provider section sets the model
    /// every LLM call uses; these let one step differ from it - a cheap fast
    /// model for tagging, a stronger one for summaries - without splitting
    /// the provider config three ways. Blank/nil means "use the provider's
    /// model", which is what makes leaving all three empty the simple case.
    var translationModel: String?
    var summaryModel: String?
    var taggingModel: String?

    /// Auto-tagging (Settings' "Tags" section): after a transcript lands, an
    /// LLM picks tags for the clip from the vocabulary. On by default - it's
    /// one small call per clip and the feature is inert without it - but a
    /// kill switch, like every other paid step.
    var autoTaggingEnabled: Bool?
    /// Whether that model may invent tags that don't exist yet. On, so the
    /// vocabulary bootstraps itself from an empty list; off pins it to
    /// exactly the tags you made, for when it has started sprawling.
    var taggingAllowsNewTags: Bool?

    var isAutoTaggingEnabled: Bool { autoTaggingEnabled ?? true }
    var isTaggingAllowedToCreateTags: Bool { taggingAllowsNewTags ?? true }

    /// Dictation (Settings' "Dictation" section). Every field is optional so
    /// settings written before the feature existed still decode; the
    /// computed accessors below carry the defaults. Off by default because
    /// the feature needs an Accessibility grant the user hasn't been asked
    /// for yet - silently installing a global event tap on upgrade would be
    /// the wrong default.
    var dictationEnabled: Bool?
    var dictationHotkey: DictationHotkey?
    var dictationModel: DictationModel?
    var dictationLanguage: DictationLanguage?
    var dictationRealtimeInsertion: DictationRealtimeInsertion?
    /// Seconds of silence before the realtime VAD commits a segment. Lower
    /// gets text on screen sooner but fragments sentences; higher reads more
    /// naturally but lags. Advanced knob, rarely touched.
    var dictationVadSilenceSeconds: Double?
    /// Refuse to insert when the frontmost app changed since the dictation
    /// started. Pasting into whatever window happens to be focused seconds
    /// later is worse than not pasting at all, so this defaults on.
    var dictationInsertOnlyIfFocusUnchanged: Bool?
    /// Drop bracketed sound labels - `[clears throat]`, `[laughter]` - from
    /// dictated text before it's inserted and saved.
    ///
    /// Dictation only. A clip's transcript is a record of what happened in
    /// the room and those labels are part of it; a dictation is text you
    /// meant to type, and nobody means to type "[clears throat]".
    ///
    /// Off by default: it removes something the transcriber genuinely heard.
    var dictationRemoveSoundLabels: Bool?

    /// Trackpad haptics on presses, selections, toggles and slider detents.
    /// On by default - the feedback is the point, and macOS already gives
    /// people a system-wide switch for turning haptics off entirely, which
    /// this one sits underneath rather than duplicating.
    var hapticsEnabled: Bool?

    /// The three sounds dictation makes when it starts, finishes and is
    /// cancelled. On by default: dictation is used with the window out of
    /// sight, so sound is the only feedback that reliably arrives. Worth
    /// turning off if you dictate on speakers into a live recording and
    /// would rather the cues weren't in it.
    var dictationSoundsEnabled: Bool?

    /// On-device speech previews: rough live transcription of whatever is
    /// being recorded, entirely local. Powers the live text in the
    /// dictation bubble, the words at the clip selection's edges, and the
    /// transcript view of the clip range picker. Off by default - it
    /// downloads a speech model and spends CPU all day, which is a choice
    /// the user should make, not inherit.
    /// Whether Worklog holds the Mac awake while it runs. On by default:
    /// a recorder that sleeps mid-day loses the thing it exists to capture.
    var keepAwakeEnabled: Bool?
    var speechPreviewsEnabled: Bool?
    /// BCP-47 identifiers the on-device transcriber should prefer. Empty or
    /// absent means "follow the system locale", which is right for anyone
    /// who never opens this screen.
    var previewLocales: [String]?

    var areHapticsEnabled: Bool { hapticsEnabled ?? true }
    var areDictationSoundsEnabled: Bool { dictationSoundsEnabled ?? true }
    var isKeepAwakeEnabled: Bool { keepAwakeEnabled ?? true }
    var isSpeechPreviewsEnabled: Bool { speechPreviewsEnabled ?? false }
    var preferredPreviewLocales: [String] { previewLocales ?? [] }

    var isDictationEnabled: Bool { dictationEnabled ?? false }
    var effectiveDictationHotkey: DictationHotkey { dictationHotkey ?? .fn }
    var effectiveDictationModel: DictationModel { dictationModel ?? .scribeV2 }
    var effectiveDictationLanguage: DictationLanguage { dictationLanguage ?? .auto }
    var effectiveDictationRealtimeInsertion: DictationRealtimeInsertion { dictationRealtimeInsertion ?? .typeAsYouSpeak }
    var effectiveDictationVadSilenceSeconds: Double { dictationVadSilenceSeconds ?? 0.6 }
    var isDictationInsertOnlyIfFocusUnchanged: Bool { dictationInsertOnlyIfFocusUnchanged ?? true }
    var isDictationRemoveSoundLabels: Bool { dictationRemoveSoundLabels ?? false }

    /// The languages offered in Settings' multi-select - UI catalog data,
    /// not a constraint anywhere else in the pipeline.
    static let availableTranslationLanguages = ["hinglish", "english"]
    static let defaultTranslationLanguages = ["hinglish"]
    /// Sentinel `summarySource` value meaning "summarize the raw transcript
    /// itself, not any translation."
    static let originalSummarySource = "original"

    /// At least one language is always enabled - an empty/missing list
    /// (pre-feature settings, or a bad hand-edit) falls back to the default.
    var enabledTranslationLanguages: [String] {
        let languages = translationLanguages ?? Self.defaultTranslationLanguages
        return languages.isEmpty ? Self.defaultTranslationLanguages : languages
    }

    var isSummariesEnabled: Bool { summariesEnabled ?? false }

    /// Every summary a new transcript should get: the overview always, plus
    /// whichever presets are switched on. Unknown IDs - a preset removed in a
    /// later build - drop out here rather than at the point of use.
    var enabledSummaryPresets: [SummaryPreset] {
        let selected = summaryPresets ?? []
        return [.overview] + SummaryPreset.optional.filter { selected.contains($0.rawValue) }
    }

    /// The summary source actually usable right now: a selected language
    /// that has since been disabled in the Translation section degrades to
    /// the original transcript rather than a dead reference.
    var effectiveSummarySource: String {
        guard let summarySource, enabledTranslationLanguages.contains(summarySource) else {
            return Self.originalSummarySource
        }
        return summarySource
    }

    static let `default` = WorklogSettings(
        pinnedDeviceUID: nil,
        retentionWindow: .thirtyDays,
        launchAtLogin: false,
        locationTaggingEnabled: false,
        anthropicBaseURL: nil,
        anthropicModel: nil,
        anthropicEffort: LLMClient.defaultEffort,
        elevenLabsEnabled: true,
        anthropicEnabled: true,
        elevenLabsBaseURL: nil,
        elevenLabsModel: nil,
        elevenLabsLoggingDisabled: false,
        translationLanguages: defaultTranslationLanguages,
        summariesEnabled: false,
        summarySource: originalSummarySource,
        summaryPresets: [],
        translationModel: nil,
        summaryModel: nil,
        taggingModel: nil,
        autoTaggingEnabled: true,
        taggingAllowsNewTags: true,
        dictationEnabled: false,
        dictationHotkey: .fn,
        dictationModel: .scribeV2,
        dictationLanguage: .auto,
        dictationRealtimeInsertion: .typeAsYouSpeak,
        dictationVadSilenceSeconds: 0.6,
        dictationInsertOnlyIfFocusUnchanged: true,
        dictationRemoveSoundLabels: false,
        hapticsEnabled: true,
        dictationSoundsEnabled: true,
        keepAwakeEnabled: true,
        speechPreviewsEnabled: false,
        previewLocales: nil
    )
}

/// Backed by `worklog.db`'s `app_state` key-value table - everything lives
/// in one database, per explicit user request (previously its own
/// `settings.json` sidecar file, migrated in by `FileLayoutMigration`).
enum WorklogSettingsStore {
    private static let key = "settings"

    static func load() -> WorklogSettings {
        guard let json = WorklogDatabase.shared.appStateValue(forKey: key),
              let data = json.data(using: .utf8),
              let settings = try? JSONDecoder().decode(WorklogSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    static func save(_ settings: WorklogSettings) {
        guard let data = try? JSONEncoder().encode(settings),
              let json = String(data: data, encoding: .utf8) else { return }
        WorklogDatabase.shared.setAppStateValue(json, forKey: key)
    }
}
