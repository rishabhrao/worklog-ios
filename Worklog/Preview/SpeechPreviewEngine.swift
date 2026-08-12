import AVFoundation
import Combine
import Foundation
import UIKit

/// Where the speech-preview feature currently stands - one value that
/// Settings renders directly.
enum SpeechPreviewStatus: Equatable {
    /// The setting is off.
    case off
    /// On, but this machine/OS can't run any engine. The string says why.
    case unavailable(String)
    /// On, and the engine's model is being fetched. 0...1 when known.
    case downloadingModel(Double?)
    /// On and ready; transcription starts with the next recording.
    case idle
    /// Transcribing the live recording right now.
    case listening
}

/// Owns on-device speech previews end to end: watches the recording state
/// and the Settings toggle, feeds capture audio to a `PreviewTranscriber`,
/// stores finalized words, and publishes the live volatile tail for UI.
///
/// Runs whenever recording runs - including capture a dictation briefly
/// switches on - and only then. There is deliberately no separate "preview
/// capture": the words describe the recording, so they come from the same
/// buffers the recording is made of.
@MainActor
final class SpeechPreviewEngine: ObservableObject {
    static let shared = SpeechPreviewEngine()

    @Published private(set) var status: SpeechPreviewStatus = .off

    /// The recognizer's current provisional tail - live display only.
    @Published private(set) var volatileText: String = ""

    /// The most recently finalized words, newest last - enough for the
    /// dictation bubble's trailing line without a database round-trip.
    @Published private(set) var recentWords: [PreviewWord] = []

    /// Bumped after each batch of words lands in the database - the clip
    /// screen's strip and transcript view refresh off this instead of
    /// polling.
    @Published private(set) var wordsStoredTick: Int = 0

    private var transcriber: PreviewTranscriber?
    private var recordingController: RecordingController?
    private var cancellables: Set<AnyCancellable> = []

    /// True between start and finish of the transcriber - distinct from
    /// `status` which also tracks availability.
    private var isListening = false
    /// Serializes evaluate()'s async work so a rapid toggle/start/stop
    /// sequence can't interleave two transitions.
    private var transitionTask: Task<Void, Never>?

    /// A re-check queued after a transition that couldn't reach a working
    /// state.
    ///
    /// Previews must never stay broken until the app is relaunched. Every
    /// failure below this line is something that comes back on its own: a
    /// language whose assets were reclaimed, a speech daemon that wasn't up
    /// yet, the unsettled moments after a media-services reset. Left alone,
    /// a single bad answer used to stick forever, because the only things
    /// that ever re-ran a transition were the recording state changing and
    /// the Settings toggle - so the app looked fine, said previews were on,
    /// and quietly recorded nothing but audio.
    private var recheckTask: Task<Void, Never>?
    private var recheckAttempt = 0
    /// Quick twice, then back off - a reset settles in seconds, a missing
    /// model may take a while.
    private static let recheckDelays: [TimeInterval] = [5, 15, 60, 300]

    private static let recentWordsLimit = 80

    private init() {}

    /// Picks the best on-device engine this device can run.
    ///
    /// `SpeechAnalyzer` is strictly better where it exists - it reports real
    /// per-word timings, which is what makes a preview word land on the right
    /// second of a clip, and its locales can be downloaded on demand. Below
    /// iOS 26 there is `SFSpeechRecognizer`, which is on-device from iOS 13 and
    /// still gives per-segment timings; the words inside a segment get spread
    /// across it, which is approximate but positions them within a second or
    /// so. Both run entirely on the phone with no account and no network.
    ///
    /// Deliberately not a cloud recognizer as a third rung: the whole promise
    /// of this feature is that nothing leaves the device until the user wires
    /// up a provider themselves.
    private static func makeTranscriber() -> PreviewTranscriber? {
        if #available(iOS 26.0, *) {
            return AppleSpeechPreviewTranscriber()
        }
        return LegacySpeechPreviewTranscriber()
    }

    /// Wires the engine to the app. Called once at launch, after the
    /// recording controller exists.
    func activate(recordingController: RecordingController) {
        guard self.recordingController == nil else { return }
        self.recordingController = recordingController
        transcriber = Self.makeTranscriber()
        recordingController.$state
            .removeDuplicates()
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)
        observeSystemRecovery()
        evaluate()
    }

    /// The two moments where the ground moves under a running transcriber.
    ///
    /// A media-services reset tears down every audio object the app owns and
    /// takes the speech stack with it; coming back to the foreground is
    /// where anything concluded while suspended deserves a fresh look. The
    /// delay is for the OS: asked the instant a notification lands, the
    /// speech asset APIs answer for a system that hasn't finished settling.
    private func observeSystemRecovery() {
        let center = NotificationCenter.default
        for name in [
            AVAudioSession.mediaServicesWereResetNotification,
            UIApplication.didBecomeActiveNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self?.evaluate()
                }
            }
        }
    }

    /// Same pattern as `WorklogHaptics`/`DictationSounds`: Settings calls
    /// this after persisting, and the engine re-reads what it needs.
    func settingsDidChange() {
        evaluate()
    }

    /// The bubble's live line: finalized words spoken since `since`, with
    /// the provisional tail on the end.
    func liveTranscript(since: Date) -> String {
        var parts = recentWords.filter { $0.end >= since }.map(\.text)
        if !volatileText.isEmpty {
            parts.append(volatileText)
        }
        return parts.joined(separator: " ")
    }

    // MARK: - State machine

    private func evaluate() {
        let previous = transitionTask
        transitionTask = Task { [weak self] in
            await previous?.value
            await self?.transition()
        }
    }

    private func transition() async {
        let settings = WorklogSettingsStore.load()
        guard settings.isSpeechPreviewsEnabled else {
            await stopListeningIfNeeded()
            cancelRecheck()
            status = .off
            return
        }

        guard let transcriber else {
            await stopListeningIfNeeded()
            status = .unavailable("On-device speech recognition isn't available on this device.")
            scheduleRecheck()
            return
        }

        // Availability first - turning the toggle on is what kicks off the
        // model download, with progress surfaced through `status`.
        switch await transcriber.availability() {
        case .unavailable(let reason):
            await stopListeningIfNeeded()
            status = .unavailable(reason)
            scheduleRecheck()
            return
        case .needsDownload, .downloading:
            await stopListeningIfNeeded()
            await downloadAssets(with: transcriber)
            // Re-check: the download finished (or failed) - fall through to
            // a fresh availability read below.
            guard case .ready = await transcriber.availability() else {
                if case .downloadingModel = status {
                    status = .unavailable("The speech model didn't finish downloading. Trying again shortly.")
                }
                scheduleRecheck()
                return
            }
        case .ready:
            break
        }

        // Ready. Listen exactly while recording runs.
        cancelRecheck()
        if recordingController?.state == .recording {
            startListeningIfNeeded(with: transcriber)
            status = .listening
        } else {
            await stopListeningIfNeeded()
            status = .idle
        }

        prune(with: settings)
    }

    private func scheduleRecheck() {
        recheckTask?.cancel()
        let delay = Self.recheckDelays[min(recheckAttempt, Self.recheckDelays.count - 1)]
        recheckAttempt += 1
        previewLog.info("previews not ready; re-checking in \(Int(delay), privacy: .public)s")
        recheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }

    private func cancelRecheck() {
        recheckTask?.cancel()
        recheckTask = nil
        recheckAttempt = 0
    }

    private func downloadAssets(with transcriber: PreviewTranscriber) async {
        status = .downloadingModel(nil)
        // Progress ticker: availability() reports the live fraction while
        // the install request runs.
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if case .downloading(let fraction) = await transcriber.availability() {
                    await MainActor.run { self?.status = .downloadingModel(fraction) }
                }
            }
        }
        defer { ticker.cancel() }
        do {
            try await transcriber.prepareAssets()
        } catch {
            previewLog.error("speech model download failed: \(error.localizedDescription, privacy: .public)")
            status = .unavailable("Couldn't download the speech model: \(error.localizedDescription)")
        }
    }

    /// Held while previews run, so App Nap can't throttle the analyzer in a
    /// window-less app. Released the moment they stop.
    private var activity: NSObjectProtocol?

    private func startListeningIfNeeded(with transcriber: PreviewTranscriber) {
        guard !isListening else { return }
        isListening = true
        previewLog.info("speech previews listening (engine \(transcriber.id, privacy: .public))")

        // This is a menu-bar-only app, so it spends its whole life with no
        // visible window - exactly the shape App Nap throttles. Capture
        // itself survives that, but the analyzer is ordinary background
        // work and can be slowed to uselessness. Holding an activity for as
        // long as previews run says plainly that this is not idle time.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Transcribing speech on-device while recording"
        )

        transcriber.start { [weak self] event in
            self?.handle(event)
        }
        // The sink runs on the capture write queue. feed() only copies a
        // reference and yields into an async stream, honoring the tap's
        // must-not-block contract.
        LiveAudioTap.shared.setSink(for: .preview) { [weak transcriber] buffer in
            transcriber?.feed(buffer: buffer, at: Date())
        }
    }

    private func stopListeningIfNeeded() async {
        guard isListening, let transcriber else { return }
        isListening = false
        LiveAudioTap.shared.removeSink(for: .preview)
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        await transcriber.finish()
        volatileText = ""
        previewLog.info("speech previews stopped")
    }

    // MARK: - Events

    private nonisolated func handle(_ event: PreviewTranscriberEvent) {
        switch event {
        case .volatile(let text):
            Task { @MainActor [weak self] in
                self?.volatileText = text
            }
        case .words(let words):
            // Persist off the main actor - the database serializes
            // internally - then tell the UI.
            WorklogDatabase.shared.insertPreviewWords(words, engine: SpeechPreviewEngine.engineID)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recentWords.append(contentsOf: words)
                if self.recentWords.count > Self.recentWordsLimit {
                    self.recentWords.removeFirst(self.recentWords.count - Self.recentWordsLimit)
                }
                self.wordsStoredTick &+= 1
            }
        }
    }

    private nonisolated static var engineID: String {
        if #available(iOS 26.0, *) { return "apple_speech_analyzer" }
        return "apple_sfspeech"
        return "unknown"
    }

    // MARK: - Retention

    /// Preview words live exactly as long as the audio they describe:
    /// pruned on the same retention window as raw segments. (The sweeper
    /// also calls this hourly - this one covers the enable-after-a-while
    /// case without waiting for it.)
    private func prune(with settings: WorklogSettings) {
        guard let interval = settings.retentionWindow.timeInterval else { return }
        WorklogDatabase.shared.prunePreviewWords(olderThan: Date(timeIntervalSinceNow: -interval))
    }
}
