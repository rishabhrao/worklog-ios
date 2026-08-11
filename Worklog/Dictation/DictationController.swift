import AVFoundation
import Combine
import Foundation
import os

/// Dictation-path diagnostics, readable via:
/// `log show --predicate 'subsystem == "com.rishabhrao.worklog"' --last 10m`
let dictationLog = Logger(subsystem: "com.rishabhrao.worklog", category: "dictation")

/// Owns push-to-talk dictation end to end: the state machine, the capture it
/// borrows, the transcription engine it routes to, the text it inserts, and
/// the bubble it shows while doing it.
///
/// The state machine is the macOS build's, with the trigger swapped. There is
/// no global hotkey on iOS - no app can watch the keyboard system-wide - so
/// the transitions are driven by whatever surface is in front of the user:
/// the mic button on the Clip screen, or the Worklog keyboard's own button.
/// Press and hold to dictate; slide up (or tap the latch) to go hands-free.
///
/// ```
/// idle     ──press────►  holding    (start capture, show bubble, open socket)
/// holding  ──latch────►  handsFree  (recording continues untethered)
/// holding  ──release──►  save
/// holding  ──cancel───►  discard
/// handsFree──press────►  save
/// handsFree──cancel───►  discard
/// ```
@MainActor
final class DictationController: ObservableObject {
    private enum Phase {
        case idle
        case holding
        case handsFree
    }

    private enum Outcome {
        case save
        case discard
    }

    /// Audio is padded slightly on both ends: people start speaking a
    /// fraction before the key lands and trail off after they let go, and
    /// clipping either end reads as the transcription being bad.
    private static let leadInPad: TimeInterval = 0.3
    private static let leadOutPad: TimeInterval = 0.3

    /// Anything shorter than this was a brush against the key, not a
    /// dictation. Discarded silently - no row, no file, no notification.
    private static let minimumHold: TimeInterval = 0.3

    private let recordingController: RecordingController
    let inserter = DictationInserter()
    let overlay = DictationOverlayController()

    private var phase: Phase = .idle
    private var startedAt: Date?

    /// Settings frozen at the start of each dictation. Read once instead of
    /// per committed phrase - every read is a SQLite round-trip on the main
    /// thread - and it keeps a mid-dictation Settings change from switching
    /// engines or insertion modes underneath a dictation in progress.
    private var activeModel: DictationModel = .scribeV2
    private var activeInsertion: DictationRealtimeInsertion = .typeAsYouSpeak

    private var realtime: RealtimeTranscriptionSession?
    private var realtimeFailure: String?

    /// Live on-device preview → bubble text, for the engines that have
    /// nothing else to show while you speak (batch, or a realtime session
    /// that fell over). Realtime's own partials always win the slot when
    /// they're flowing - they are the text that will actually be inserted.
    private var previewFeed: AnyCancellable?
    /// Whether previews were enabled when this dictation began - frozen
    /// with the other settings so a mid-dictation Settings flip can't
    /// half-attach a feed.
    private var isPreviewFeedEligible = false

    /// True when a dictation is mid-teardown, so a hotkey press arriving
    /// during the export/transcribe tail can't interleave with it.
    private var isFinishing = false

    @Published private(set) var isMonitoring = false

    /// Posted when a dictation row is created or updated, so the Dictations
    /// tab refreshes without polling the database.
    static let didChangeNotification = Notification.Name("worklog.dictationsDidChange")

    init(recordingController: RecordingController) {
        self.recordingController = recordingController
    }

    // MARK: - Availability

    /// Whether dictation is switched on. Called by Settings on every change
    /// and by the app at launch. There is nothing to install on iOS - the
    /// trigger is a button, not a system-wide tap - so this only reflects the
    /// setting, but the name and call sites match the macOS build.
    func syncWithSettings() {
        isMonitoring = WorklogSettingsStore.load().isDictationEnabled
    }

    // MARK: - Trigger events

    /// The dictation button went down, or - in hands-free - was tapped again
    /// to finish.
    func press() {
        switch phase {
        case .handsFree:
            finish(.save)
        case .holding:
            break
        case .idle:
            begin()
        }
    }

    /// The dictation button was released. Ends a hold; ignored once latched.
    func release() {
        guard phase == .holding else { return }
        finish(.save)
    }

    /// Latch hands-free, so the button can be let go.
    func latch() {
        guard phase == .holding else { return }
        // Latching is the one transition with no visible consequence in the
        // app the user is actually looking at, and the whole point of it is
        // that they are about to take their hand off the keyboard. It has to
        // be confirmed, and it has to be confirmed as a *modifier* rather
        // than as a new dictation - hence one tick, not a two-note figure.
        DictationSounds.play(.latch)
        WorklogHaptics.play(.dictationLatch)
        phase = .handsFree
        overlay.state.stage = .handsFree
        overlay.refreshLayout()
    }

    /// Throw the dictation away - nothing saved, nothing inserted.
    func cancel() {
        guard phase == .holding || phase == .handsFree else { return }
        finish(.discard)
    }

    /// True while a dictation is running, for the button's own appearance.
    var isDictating: Bool { phase != .idle }
    var isHandsFree: Bool { phase == .handsFree }

    // MARK: - Begin

    private func begin() {
        guard !isFinishing else { return }

        if case .unavailable(let reason) = recordingController.beginDictationCapture() {
            WorklogNotifier.dictationUnavailable(reason: reason)
            // The notification may be a while arriving, and the user is
            // holding a key waiting for something to happen. Say "no" in the
            // hand immediately.
            WorklogHaptics.play(.failure)
            return
        }

        // Before anything else that could take a millisecond. This is the
        // moment the user is listening for - everything below is setup they
        // neither see nor hear.
        DictationSounds.play(.start)
        WorklogHaptics.play(.dictationStart)

        let settings = WorklogSettingsStore.load()
        activeModel = settings.effectiveDictationModel
        activeInsertion = settings.effectiveDictationRealtimeInsertion
        isPreviewFeedEligible = settings.isSpeechPreviewsEnabled

        startedAt = Date().addingTimeInterval(-Self.leadInPad)
        phase = .holding

        // Recorded before the bubble appears, and the bubble is a
        // non-activating panel, so this stays the app the user was typing in.
        inserter.beginSession(guardsFocus: settings.isDictationInsertOnlyIfFocusUnchanged)
        overlay.show()

        if activeModel == .scribeV2Realtime {
            startRealtime()
        } else {
            // Batch uploads nothing until the end - the on-device preview
            // is the only live text this dictation can have.
            beginPreviewFeedIfAvailable()
        }
    }

    /// Attaches the on-device preview to the bubble's text slot. The words
    /// come from `SpeechPreviewEngine`, which is already transcribing this
    /// very audio (recording runs during a dictation, and the engine runs
    /// whenever recording does) - this is just a view over it, filtered to
    /// what was said since the hotkey went down.
    private func beginPreviewFeedIfAvailable() {
        guard isPreviewFeedEligible, previewFeed == nil else { return }
        let engine = SpeechPreviewEngine.shared
        previewFeed = engine.objectWillChange
            // Defers to the next main-queue turn, after the engine's
            // published values have actually changed - objectWillChange
            // fires *before* they do.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self, self.phase != .idle, let startedAt = self.startedAt else { return }
                let line = engine.liveTranscript(since: startedAt)
                guard self.overlay.state.partialText != line else { return }
                self.overlay.state.partialText = line
                self.overlay.refreshLayout()
            }
    }

    private func startRealtime() {
        let session = RealtimeTranscriptionSession()
        realtime = session
        realtimeFailure = nil

        session.onEvent = { [weak self] event in
            self?.handleRealtimeEvent(event)
        }

        do {
            try session.start()
            // The sink is installed immediately, but the session itself
            // holds buffers back until the server sends `session_started` -
            // audio pushed into a socket that hasn't agreed a config yet
            // would just be discarded.
            LiveAudioTap.shared.setSink(for: .dictation) { [weak session] buffer in
                session?.append(buffer: buffer)
            }
        } catch {
            // The dictation is not lost - audio is still being recorded, and
            // the batch engine will transcribe it at the end. Say so on the
            // bubble so a slow result reads as a fallback, not a hang.
            realtime = nil
            realtimeFailure = error.localizedDescription
            overlay.state.didFallBackToBatch = true
            dictationLog.error("realtime dictation unavailable, falling back to batch: \(error.localizedDescription, privacy: .public)")
            beginPreviewFeedIfAvailable()
        }
    }

    private func handleRealtimeEvent(_ event: RealtimeTranscriptionSession.Event) {
        switch event {
        case .started:
            break

        case .partial(let text):
            // Provisional - shown, never typed. See
            // RealtimeTranscriptionSession for why this line matters.
            overlay.state.partialText = text
            overlay.refreshLayout()

        case .committed(let text):
            overlay.state.partialText = ""
            overlay.refreshLayout()
            guard activeInsertion == .typeAsYouSpeak else { return }
            inserter.insertStreaming(segment: text)

        case .failed(let error):
            LiveAudioTap.shared.removeSink(for: .dictation)
            realtimeFailure = error.localizedDescription
            // The stream died; the words stop. If the on-device previewer
            // is running, hand the bubble's text line over to it so the
            // fallback keeps showing *something* live.
            beginPreviewFeedIfAvailable()
            // A session-length ceiling on a long hands-free dictation isn't
            // a fault the user can act on - finish it on the batch path
            // instead of reporting an error for a dictation that worked.
            overlay.state.didFallBackToBatch = true
            dictationLog.error("realtime dictation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Finish

    private func finish(_ outcome: Outcome) {
        guard phase != .idle, !isFinishing else { return }
        guard let startedAt else { return }

        let mode: DictationMode = phase == .handsFree ? .handsFree : .hold
        let heldFor = Date().timeIntervalSince(startedAt) - Self.leadInPad

        isFinishing = true
        phase = .idle

        // A brush against the key in hold mode isn't a dictation. Hands-free
        // is always deliberate - you had to press a second key to get there
        // - so it never gets discarded for being short.
        if outcome == .discard || (mode == .hold && heldFor < Self.minimumHold) {
            abandon(undoInsertedText: outcome == .discard)
            return
        }

        // The mirror of the start cue, and the last thing the user will
        // reliably notice: the window is elsewhere, transcription happens
        // in the background, and the text simply appears some time later.
        DictationSounds.play(.stop)
        WorklogHaptics.play(.dictationStop)

        previewFeed = nil
        overlay.state.stage = .transcribing
        overlay.state.partialText = ""
        overlay.refreshLayout()

        Task { await completeSave(mode: mode, startedAt: startedAt) }
    }

    /// Tears everything down without producing a dictation: no row, no
    /// file, nothing left on the pasteboard.
    private func abandon(undoInsertedText: Bool) {
        // Covers both ways a dictation ends with nothing: Escape, and a hold
        // too short to have been meant. The second is the one that matters -
        // a brush against the hotkey already played the start cue, and
        // silence after it would leave the user believing a dictation is
        // still running.
        DictationSounds.play(.cancel)
        WorklogHaptics.play(.dictationCancel)

        LiveAudioTap.shared.removeSink(for: .dictation)
        realtime?.cancel()
        realtime = nil

        if undoInsertedText {
            inserter.undoStreamingInsertion()
        }

        // Deliberately NOT `endDictationCapture` - nothing is going to read
        // this audio, so forcing the user's ongoing recording to roll over
        // to a fresh segment would leave a stray file behind for a dictation
        // that no longer exists. Only capture the dictation itself switched
        // on gets switched back off.
        recordingController.abandonDictationCapture()
        overlay.dismiss()
        reset()
    }

    private func completeSave(mode: DictationMode, startedAt: Date) async {
        let dictationID = UUID().uuidString

        // 1. Stop feeding the socket at the exact moment the user finished.
        //    This has to happen before the flush, not after: otherwise
        //    buffers keep arriving during the flush wait and get sent
        //    *after* the commit that was supposed to close the stream.
        LiveAudioTap.shared.removeSink(for: .dictation)

        // 2. Close out the realtime stream - the only part the user is still
        //    waiting on, and independent of the audio export below.
        var realtimeText = ""
        if let realtime {
            await realtime.finishAndFlush()
            realtimeText = realtime.committedText
            insertRemainingRealtimeText(realtimeText)
        }

        // 3. Wait out the lead-out pad so trailing words are actually on
        //    disk before the segment is closed, then make the audio readable.
        try? await Task.sleep(nanoseconds: UInt64(Self.leadOutPad * 1_000_000_000))
        let endedAt = Date()
        await closeCapture()

        // 4. Export the window. Failure here is not fatal to a realtime
        //    dictation - the text is the artifact, and it already exists.
        let export = await exportAudio(dictationID: dictationID, start: startedAt, end: endedAt)

        if export == nil && realtimeText.isEmpty {
            // Nothing recorded and nothing transcribed: there is no
            // dictation to save, only a reason to say why.
            WorklogNotifier.dictationFailed(reason: "No audio was recorded for that dictation.")
            overlay.state.stage = .failed("No audio")
            overlay.dismiss(after: 1.2)
            reset()
            return
        }

        // 5. Persist the row. Always before any further network work, so a
        //    dictation exists and is visible even if everything after fails.
        insertRow(dictationID: dictationID, mode: mode, start: startedAt, end: endedAt, export: export)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: dictationID)

        if realtime != nil || !realtimeText.isEmpty {
            await finishRealtime(dictationID: dictationID, text: realtimeText, canFallBack: export != nil)
        } else {
            await finishBatch(dictationID: dictationID)
        }

        reset()
    }

    // MARK: - Engine completion

    private func finishRealtime(dictationID: String, text: String, canFallBack: Bool) async {
        let raw = realtime?.rawTranscriptJSON
        let failure = realtimeFailure
        realtime?.cancel()
        realtime = nil

        DictationPipeline.shared.recordRealtimeResult(
            dictationID: dictationID,
            text: text,
            rawJSON: raw,
            error: failure
        )
        markInsertion(dictationID: dictationID, insertedAnything: !text.isEmpty)

        // The stream died partway and the audio survived: re-run it properly
        // on the batch engine rather than leaving the user with half a
        // sentence they'd have to notice and retry themselves.
        if failure != nil, canFallBack {
            overlay.state.stage = .transcribing
            overlay.state.didFallBackToBatch = true
            await finishBatch(dictationID: dictationID, replacingPartialText: !text.isEmpty)
            return
        }

        if failure != nil {
            WorklogHaptics.play(.failure)
            overlay.state.stage = .failed("Transcription failed")
            overlay.dismiss(after: 1.2)
        } else if text.isEmpty {
            // Nothing was said. Copying "" here would quietly wipe whatever
            // the user had on their clipboard.
            overlay.state.stage = .nothingHeard
            overlay.dismiss(after: 0.8)
        } else {
            // Streaming insertion types directly and never touches the
            // clipboard while running, so the finished dictation is put
            // there now - every dictation ends up recoverable with ⌘V
            // regardless of which engine produced it.
            inserter.copyToPasteboard(text)
            overlay.dismiss()
        }
    }

    private func finishBatch(dictationID: String, replacingPartialText: Bool = false) async {
        let text = await DictationPipeline.shared.run(dictationID: dictationID)

        // Nil means the attempt itself failed - no network, bad key, a
        // refusal from the API - and that is worth interrupting someone for,
        // because it needs them to do something about it.
        guard let text else {
            let reason = WorklogDatabase.shared.dictation(id: dictationID)?.error
                ?? "Transcription returned nothing."
            WorklogNotifier.dictationFailed(reason: reason)
            WorklogHaptics.play(.failure)
            overlay.state.stage = .failed("Transcription failed")
            overlay.dismiss(after: 1.2)
            return
        }

        // Empty means it worked and there was nothing to hear: the key was
        // held and nobody spoke. That is not an error and shouldn't look or
        // sound like one - no notification, no red, just a quiet dismissal.
        // The dictation is kept, so a retry is still possible if the silence
        // was the transcriber's mistake rather than the user's intent.
        guard !text.isEmpty else {
            overlay.state.stage = .nothingHeard
            overlay.dismiss(after: 0.8)
            return
        }

        // A realtime dictation that already typed part of itself must not
        // now paste the whole thing on top - the user would get the opening
        // phrase twice. The saved row holds the complete text; the Dictations
        // tab is where they copy it from.
        if replacingPartialText {
            // Not re-typed, but the batch pass produced the *complete* text
            // where the stream only managed part of it - so put that on the
            // clipboard, ready to replace what was typed if the user wants.
            inserter.copyToPasteboard(text)
            overlay.dismiss()
            return
        }

        switch inserter.pasteAll(text) {
        case .pasted:
            markInsertion(dictationID: dictationID, insertedAnything: true)
        case .copiedOnly:
            // It worked, but not where the user was expecting it - the text
            // is on the clipboard and they have to go get it. Felt, because
            // otherwise the only sign is a notification they may not see
            // until after they've retyped the sentence.
            WorklogNotifier.dictationCopiedNotPasted()
            WorklogHaptics.play(.warning)
            markInsertion(dictationID: dictationID, insertedAnything: false)
        case .nothingToInsert:
            break
        }
        overlay.dismiss()
    }

    /// Handles the two realtime cases where text exists but was not typed as
    /// it arrived: `.pasteAtEnd` mode, and focus having moved mid-dictation.
    private func insertRemainingRealtimeText(_ text: String) {
        if activeInsertion == .pasteAtEnd {
            if inserter.pasteAll(text) == .copiedOnly {
                WorklogNotifier.dictationCopiedNotPasted()
            }
            return
        }

        // Streaming insertion stopped when the user switched apps. What was
        // typed stays where it landed; the rest goes to the clipboard.
        guard inserter.didLoseTarget, !inserter.bufferedText.isEmpty else { return }
        if inserter.pasteAll(inserter.bufferedText) == .copiedOnly {
            WorklogNotifier.dictationCopiedNotPasted()
        }
    }

    private func markInsertion(dictationID: String, insertedAnything: Bool) {
        let insertion: DictationInsertion
        if !insertedAnything {
            insertion = .none
        } else if inserter.didLoseTarget {
            insertion = .partial
        } else {
            insertion = .full
        }
        WorklogDatabase.shared.markDictationInserted(id: dictationID, insertion: insertion)
    }

    // MARK: - Capture + export

    private func closeCapture() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            recordingController.endDictationCapture {
                continuation.resume()
            }
        }
    }

    private func exportAudio(dictationID: String, start: Date, end: Date) async -> ClipExporter.ExportResult? {
        let destination = WorklogPaths.dictationAudioURL(dictationID: dictationID)
        do {
            return try await Task.detached(priority: .userInitiated) {
                try ClipExporter.export(start: start, end: end, destination: destination)
            }.value
        } catch {
            dictationLog.error("dictation audio export failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func insertRow(
        dictationID: String,
        mode: DictationMode,
        start: Date,
        end: Date,
        export: ClipExporter.ExportResult?
    ) {
        // Named for when it was spoken, not for when transcription happened
        // to finish - the same rule clips follow.
        let name = Self.defaultDictationName(for: start)
        WorklogDatabase.shared.insertDictation(DictationRecord(
            id: dictationID,
            path: WorklogPaths.dictationAudioURL(dictationID: dictationID).path,
            defaultName: name,
            displayName: name,
            sourceStart: start,
            sourceEnd: end,
            // The audio that actually exists, never the requested window -
            // same guardrail the clip path carries.
            durationSeconds: export?.actualDurationSeconds ?? 0,
            createdAt: Date(),
            mode: mode,
            locationLatitude: export?.locationLatitude,
            locationLongitude: export?.locationLongitude,
            deviceUID: export?.deviceUID,
            state: .pending,
            error: export == nil ? "The audio for this dictation couldn't be saved." : nil,
            provider: nil,
            model: nil,
            textPath: nil,
            rawPath: nil,
            insertion: .none
        ))
    }

    // MARK: - Reset

    private func reset() {
        previewFeed = nil
        isPreviewFeedEligible = false
        startedAt = nil
        realtimeFailure = nil
        isFinishing = false
        phase = .idle
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    static func defaultDictationName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd h:mm a"
        formatter.timeZone = .current
        return "Dictation \(formatter.string(from: date))"
    }
}
