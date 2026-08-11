import AVFoundation
import Combine
import Foundation

/// Load state for the currently-requested range, so the view can render
/// empty/loading/loaded distinctly per spec's acceptance bar ("empty state
/// handled... loading state handled").
enum RangeLoadState: Equatable {
    /// Nothing has ever been requested yet - the screen's true first-run
    /// state ("pick a preset above").
    case empty
    case loading
    case loaded
    /// A range WAS requested and the query genuinely came back with zero
    /// segments (e.g. no recording happened in that window) - distinct
    /// from `.empty` so the screen can say "nothing recorded in that
    /// range" instead of silently falling back to the generic first-run
    /// message, which reads as if the click did nothing at all.
    case emptyAfterSearch
}

/// Owns everything the Clip screen needs: the currently loaded virtual
/// range, the draggable selection, playback, and candidate suggestions.
/// Kept independent of any specific view so the waveform, handles, and
/// transport controls all read from one source of truth rather than each
/// tracking their own copy of "where is the playhead."
@MainActor
final class ClipScreenViewModel: ObservableObject {
    @Published private(set) var loadState: RangeLoadState = .empty
    @Published private(set) var loadedRange: LoadedRange?

    /// Selection, in seconds since range start. `selectionEnd` defaults to
    /// end-of-range ("now") when a range first loads, per spec.
    @Published var selectionStart: TimeInterval = 0
    @Published var selectionEnd: TimeInterval = 0

    @Published var playheadPosition: TimeInterval = 0
    @Published private(set) var isPlaying = false

    @Published private(set) var candidates: [StartCandidate] = []
    @Published var detectionParameters = CandidateDetectionParameters.default {
        didSet { recomputeCandidates() }
    }

    /// The candidate the selection start currently matches, if any - used
    /// to render a marker as "active" without the view re-deriving it.
    @Published private(set) var selectedCandidateOffset: TimeInterval?

    /// Named for when the clip's audio starts, not for when the user got
    /// around to creating it - see `defaultClipName`. Kept in sync with the
    /// selection until the user types something of their own, after which
    /// their words always win.
    @Published var clipName: String = "" {
        didSet {
            guard !isRewritingClipName, clipName != oldValue else { return }
            isClipNameUserEdited = true
        }
    }

    private var isClipNameUserEdited = false
    /// Set while the view model itself writes `clipName`, so its own updates
    /// don't register as the user having taken it over.
    private var isRewritingClipName = false

    @Published private(set) var isExporting = false
    @Published private(set) var exportError: String?
    /// Set on successful export so the view can hand off to the
    /// transcription pipeline (Priority 5) and select the new Library entry.
    @Published private(set) var lastExportedClipURL: URL?

    private var player: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var stitchedPlaybackURL: URL?

    /// Maps the wall-clock timeline the waveform draws onto positions in the
    /// exported preview file, which is compacted - see `ClipExporter`.
    private var playbackTimeline: ClipExporter.ExportTimeline?

    /// The `[start, end]` the current preview file was built from, so a range
    /// that has since grown can be noticed and rebuilt.
    private var preparedRange: (start: Date, end: Date)?

    /// Bumped on every prepare; one whose token is stale by the time it
    /// finishes throws its work away instead of installing a player for a
    /// range nobody is looking at any more.
    private var prepareGeneration = 0

    /// Set when the user asked to play during a prepare, so playback starts
    /// the moment it's ready rather than needing a second tap.
    private var startWhenPrepared = false

    /// True while the preview export runs. The transport shows this - a
    /// long-running prepare that looks identical to a dead button is the
    /// entire bug this flow used to have.
    @Published private(set) var isPreparingPlayback = false

    /// Playback's own error channel, separate from export's - they appear in
    /// different places on screen and mean completely different things.
    @Published private(set) var playbackError: String?

    private var cancellables: Set<AnyCancellable> = []
    /// Re-loads the same range on a short interval while it's "live" (its
    /// requested end was open-ended/"now" at load time) - otherwise a
    /// waveform loaded via a preset while recording is active never grows
    /// to show newly-recorded audio until the user re-clicks the same
    /// preset or hits Refresh. Per explicit user request: the app should
    /// stay live/event-driven, not need a manual hack to see fresh state.
    private var liveRangeTimer: Timer?
    private var isLoadedRangeLive = false

    init() {
        // StartupReconciliation's periodic background pass (and the manual
        // Refresh button) can index a segment this screen doesn't know
        // about yet - re-load whatever's currently on screen whenever it
        // completes, the same way Library already auto-refreshes off
        // TranscriptionPipeline's published state.
        StartupReconciliation.didRun
            .sink { [weak self] in self?.reloadLastRequestedRangeIfAny() }
            .store(in: &cancellables)
    }

    var totalDuration: TimeInterval { loadedRange?.totalDuration ?? 0 }

    // MARK: - Range loading

    /// Loads "last N minutes" - the quick-preset / free-form-field path.
    /// Marked live: while this range stays on screen, it keeps re-loading
    /// with a fresh `end = Date()` on a short timer, so newly-recorded
    /// audio (including the currently-open segment, per `RangeLoader`)
    /// shows up without the user re-clicking the same preset.
    func loadLastMinutes(_ minutes: Double) {
        let end = Date()
        let start = end.addingTimeInterval(-minutes * 60)
        loadRange(start: start, end: end, isLive: true)
    }

    /// Loads an arbitrary historical `[start, end]` - the date/time range
    /// picker path. Presents as one continuous waveform regardless of how
    /// many segment files it spans. Not live - a historical range's end is
    /// fixed, there's nothing new to appear.
    func loadRange(start: Date, end: Date) {
        loadRange(start: start, end: end, isLive: false)
    }

    /// Clears the loaded range and everything hanging off it - selection,
    /// candidates, playback, clip name draft, export error, and the live
    /// re-load timer - returning the screen to its pristine unloaded state.
    /// The X button next to the range-loading controls.
    /// Clicking Clip in the sidebar puts it back to "No range loaded" -
    /// the same thing the ✕ does, so the tab and the button agree.
    func resetToCleanState() {
        clearLoadedRange()
    }

    func clearLoadedRange() {
        stopPlayback()
        loadedRange = nil
        loadState = .empty
        candidates = []
        selectedCandidateOffset = nil
        selectionStart = 0
        selectionEnd = 0
        playheadPosition = 0
        setClipName("")
        isClipNameUserEdited = false
        exportError = nil
        lastRequestedRange = nil
        isLoadedRangeLive = false
        updateLiveRangeTimer()
    }

    private func loadRange(start: Date, end: Date, isLive: Bool) {
        loadState = .loading
        // A user-initiated load must show the loading state, not the
        // previous request's waveform - the view only shows the spinner
        // while loadedRange is nil, so a stale range here flashed the old
        // waveform briefly before an empty result's "nothing recorded"
        // message replaced it.
        stopPlayback()
        loadedRange = nil
        candidates = []
        lastRequestedRange = (start, end)
        isLoadedRangeLive = isLive
        updateLiveRangeTimer()
        Task.detached(priority: .userInitiated) { [weak self] in
            let range = RangeLoader.load(start: start, end: end)
            await self?.applyLoadedRange(range)
        }
    }

    /// The most recently requested `[start, end]`, so the live timer/
    /// reconciliation callback can re-run the same query without the user
    /// re-picking a preset. `nil` until a range has been requested at
    /// least once.
    private var lastRequestedRange: (start: Date, end: Date)?

    /// Starts/stops the periodic live re-load depending on whether the
    /// current range is both "live" and still the most useful thing to
    /// keep fresh (no point polling a range the user has since navigated
    /// away from - `ClipScreenView`/`AppShellView` keep this view model
    /// alive across screen switches, so the timer must be stopped
    /// explicitly rather than relying on view teardown). 1s cadence is
    /// fine now that a live reload costs almost nothing: the open
    /// segment's peaks come straight from LivePeakStore (in memory, fed by
    /// the audio tap) and every closed segment reads from the peaks cache.
    private func updateLiveRangeTimer() {
        liveRangeTimer?.invalidate()
        liveRangeTimer = nil
        guard isLoadedRangeLive else { return }
        liveRangeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadLastRequestedRangeIfAny() }
        }
    }

    private func reloadLastRequestedRangeIfAny() {
        guard let lastRequestedRange else { return }
        // A live range keeps its START anchored where the user loaded it
        // and only extends its END to "now" - the waveform grows at the
        // tail as new audio arrives. (Sliding the whole window forward
        // instead would silently shift the user's selection relative to
        // the audio underneath it on every tick.) The end only advances
        // while recording is actually running - otherwise the range would
        // grow an ever-longer empty tail after Stop Recording.
        let start = lastRequestedRange.start
        let recordingNow = isRecordingActive?() ?? false
        let end = (isLoadedRangeLive && recordingNow) ? Date() : lastRequestedRange.end
        self.lastRequestedRange = (start, end)
        Task.detached(priority: .utility) { [weak self] in
            let range = RangeLoader.load(start: start, end: end)
            await self?.applyLoadedRange(range, resetSelection: false)
        }
    }

    /// `resetSelection` is false for a background live-refresh reload (the
    /// periodic "keep a live range fresh" timer, or a
    /// `StartupReconciliation.didRun` re-load) - those must update the
    /// waveform/candidates with newly-appeared audio without yanking the
    /// selection, playhead, clip name, or interrupting playback the user is
    /// actively mid-way through. `true` (the default) is every
    /// user-initiated load - preset click, historical range, manual
    /// Refresh - where resetting to a fresh full-range selection is the
    /// expected, current behavior.
    private func applyLoadedRange(_ range: LoadedRange, resetSelection: Bool = true) {
        // Read against the range still on screen - once `loadedRange` is
        // replaced, the new (longer) duration makes every selection look like
        // it stops short.
        let selectionRanToEnd = selectionEndWasAtEndOfAudio()
        let previousStart = loadedRange?.requestedStart
        loadedRange = range
        // A range whose start moved shifts every offset underneath the
        // selection; keep it anchored to the same wall-clock instant.
        if let previousStart, previousStart != range.requestedStart, !resetSelection {
            let shift = previousStart.timeIntervalSince(range.requestedStart)
            selectionStart = min(max(0, selectionStart + shift), range.totalDuration)
            selectionEnd = min(max(selectionStart, selectionEnd + shift), range.totalDuration)
            playheadPosition = min(max(0, playheadPosition + shift), range.totalDuration)
            selectedCandidateOffset = selectedCandidateOffset.map { $0 + shift }
        }
        if range.isEmpty {
            guard resetSelection else { return }
            loadState = .emptyAfterSearch
            selectionStart = 0
            selectionEnd = 0
            candidates = []
            return
        }

        loadState = range.isFullyPeaked ? .loaded : .loading

        guard resetSelection else {
            // A live range grows at the tail. A selection that ran to the end
            // of the audio means "up to now" and must keep meaning that as
            // new audio arrives.
            if selectionRanToEnd { selectionEnd = range.totalDuration }
            refreshDefaultClipName()
            recomputeCandidates()
            invalidatePreparedPlayerIfRangeGrew(range)
            if !range.isFullyPeaked {
                schedulePeakPollIfNeeded(for: range)
            }
            return
        }

        stopPlayback()
        selectionStart = 0
        selectionEnd = range.totalDuration
        playheadPosition = 0
        selectedCandidateOffset = nil
        isClipNameUserEdited = false
        refreshDefaultClipName()
        recomputeCandidates()

        // If peaks are still filling in (cold cache), poll briefly rather
        // than blocking - the per-segment cold-path fallback in
        // `RangeLoader` computes synchronously, so a re-load will pick up
        // whatever finished since.
        if !range.isFullyPeaked {
            schedulePeakPollIfNeeded(for: range)
        }
    }

    private func schedulePeakPollIfNeeded(for range: LoadedRange) {
        Task { [weak self] in
            let refreshed = await Task.detached(priority: .utility) {
                RangeLoader.load(start: range.requestedStart, end: range.requestedEnd)
            }.value
            guard let self, self.loadedRange?.requestedStart == range.requestedStart else { return }
            self.loadedRange = refreshed
            self.loadState = refreshed.isFullyPeaked ? .loaded : .loading
            self.recomputeCandidates()
        }
    }

    // MARK: - Candidate detection (suggestion only - never auto-commits)

    /// Detects candidates and nothing else.
    ///
    /// They used to pre-select themselves, moving the start handle to
    /// whichever had the longest preceding silence. That makes picking "Last
    /// 30 min" not actually select the last 30 minutes - the range you asked
    /// for silently became a shorter one starting somewhere you didn't
    /// choose. Candidates are markers to jump to, so the selection stays
    /// spanning the whole window until a tap moves it.
    private func recomputeCandidates() {
        guard let loadedRange else {
            candidates = []
            return
        }
        candidates = CandidateDetector.detectCandidates(in: loadedRange, parameters: detectionParameters)
    }

    /// User picked a candidate marker: the clip starts there and runs to the
    /// end of the audio.
    ///
    /// Moving only the start would leave whatever end the previous selection
    /// happened to have, so picking a start point could silently produce a
    /// clip that stops in the middle of the conversation you were pointing
    /// at. A candidate answers "where does this start?" - the end is always
    /// the end of what's loaded, which for a live range is now.
    func selectCandidate(_ candidate: StartCandidate) {
        selectionStart = min(max(0, candidate.offsetSeconds), totalDuration)
        selectionEnd = totalDuration
        selectedCandidateOffset = candidate.offsetSeconds
        refreshDefaultClipName()
    }

    /// Any manual handle drag fully overrides candidate pre-selection - per
    /// spec's hard constraint, nothing ever snaps back on its own.
    func userDraggedStartHandle(to offset: TimeInterval) {
        selectionStart = max(0, min(offset, selectionEnd))
        if selectionStart != selectedCandidateOffset {
            selectedCandidateOffset = nil
        }
        refreshDefaultClipName()
    }

    func userDraggedEndHandle(to offset: TimeInterval) {
        selectionEnd = max(selectionStart, min(offset, totalDuration))
    }

    /// Whether the selection runs to the end of the loaded audio, within a
    /// tolerance wide enough to survive a live range's tail moving.
    private func selectionEndWasAtEndOfAudio() -> Bool {
        guard let loadedRange else { return true }
        return loadedRange.totalDuration - selectionEnd <= Self.liveEndTolerance
    }

    /// The clip's name follows its start time until the user overrides it.
    private func refreshDefaultClipName() {
        guard !isClipNameUserEdited else { return }
        setClipName(Self.defaultClipName(for: selectionStartDate))
    }

    /// Writes `clipName` without marking it user-edited.
    private func setClipName(_ value: String) {
        isRewritingClipName = true
        clipName = value
        isRewritingClipName = false
    }

    /// Wall-clock time the current selection begins at.
    private var selectionStartDate: Date {
        (loadedRange?.requestedStart ?? Date()).addingTimeInterval(selectionStart)
    }

    private static let liveEndTolerance: TimeInterval = 2

    /// How far a live range may outgrow its prepared preview before the
    /// preview counts as stale.
    private static let previewStaleTolerance: TimeInterval = 2

    // MARK: - Playback

    /// Preview playback over a loaded range.
    ///
    /// A range is not one file - it is however many 5-minute segments the
    /// window happens to span - so playing it means exporting it first.
    /// Everything here exists to keep that fact from leaking into the
    /// interaction: one state machine owns the prepare, the intent to play is
    /// recorded rather than discarded when a prepare is already running, the
    /// transport says "Preparing…" while it happens, and a prepare that has
    /// been overtaken is discarded by generation rather than racing the one
    /// that replaced it. (The Android app runs the identical model.)
    func togglePlayback() {
        if isPlaying {
            pausePlayback()
            return
        }
        playbackError = nil
        if player != nil {
            startPlaybackNow()
            return
        }
        startWhenPrepared = true
        preparePlayer()
    }

    /// Wired by the coordinator to `RecordingController.forceRollover` -
    /// closes the currently-recording segment (gaplessly opening the next)
    /// so its audio becomes fully readable on disk. Playback and export of
    /// a live range call through this first: the open segment's on-disk
    /// header lags real audio by a long way, so without a rollover, "play/
    /// clip the thing I said 10 seconds ago" reads a file that doesn't
    /// contain those 10 seconds yet. Completion fires on the main queue.
    var requestSegmentRollover: ((@escaping () -> Void) -> Void)?

    /// Wired by the coordinator to read `RecordingController.state` - a
    /// live range only extends its end toward "now" while recording is
    /// actually running. Without this, a live range kept growing an empty
    /// tail after Stop Recording, inviting selections over time where
    /// nothing was recorded (and then a confusing "wasn't available"
    /// shortfall on export).
    var isRecordingActive: (() -> Bool)?

    /// Runs `then` after force-rolling the current segment if (and only if)
    /// the on-screen range is live - historical ranges never need it.
    private func withFreshAudioIfLive(_ then: @escaping @MainActor () -> Void) {
        guard isLoadedRangeLive, let requestSegmentRollover else {
            then()
            return
        }
        requestSegmentRollover {
            Task { @MainActor in then() }
        }
    }

    /// Builds the preview file and player in the background, then honors
    /// whatever the user asked for while it was running. Never blocks a drag
    /// gesture's callback: a scrub stays as responsive as Library's, which
    /// needs no preparation at all.
    private func preparePlayer() {
        guard let loadedRange, !loadedRange.isEmpty else {
            if startWhenPrepared { playbackError = "Load a range first." }
            startWhenPrepared = false
            return
        }
        // A prepare is already running for this range: the intent to play has
        // been recorded and will be honored when it lands. A second export
        // would only make the first one slower.
        guard !isPreparingPlayback else { return }

        let start = loadedRange.requestedStart
        let end = loadedRange.requestedEnd
        prepareGeneration += 1
        let generation = prepareGeneration
        isPreparingPlayback = true

        withFreshAudioIfLive { [weak self] in
            Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    try? ClipExporter.export(
                        start: start,
                        end: end,
                        destination: FileManager.default.temporaryDirectory
                            .appendingPathComponent("worklog-preview-\(UUID().uuidString).m4a")
                    )
                }.value
                guard let self else { return }
                // Overtaken while exporting - a newer range is on screen, and
                // installing this player would play the wrong audio.
                guard generation == self.prepareGeneration else {
                    if let result { try? FileManager.default.removeItem(at: result.url) }
                    return
                }
                defer {
                    self.isPreparingPlayback = false
                    self.startWhenPrepared = false
                }
                guard let result, let newPlayer = try? AVAudioPlayer(contentsOf: result.url) else {
                    if self.startWhenPrepared {
                        self.playbackError = "Couldn't prepare playback for that range."
                    }
                    return
                }
                self.releasePlayerOnly()
                newPlayer.prepareToPlay()
                self.stitchedPlaybackURL = result.url
                self.playbackTimeline = result.timeline
                self.preparedRange = (start, end)
                self.player = newPlayer
                newPlayer.currentTime = self.filePosition(for: self.playheadPosition)
                if self.startWhenPrepared { self.startPlaybackNow() }
            }
        }
    }

    /// A live range grows while it's on screen, so a preview built a minute
    /// ago stops at a minute ago. Rebuilding every tick would be absurd;
    /// instead the stale player is dropped while nothing is playing, and the
    /// next play or seek rebuilds from the current extent. Playback actually
    /// running is left alone - yanking the file out from under someone
    /// listening is worse than a slightly short preview.
    private func invalidatePreparedPlayerIfRangeGrew(_ range: LoadedRange) {
        guard let preparedRange else { return }
        guard range.requestedEnd.timeIntervalSince(preparedRange.end) > Self.previewStaleTolerance else { return }
        guard !isPlaying, !isPreparingPlayback else { return }
        stopPlayback()
    }

    /// Where `rangeTime` lives in the exported preview file.
    private func filePosition(for rangeTime: TimeInterval) -> TimeInterval {
        playbackTimeline?.fileTime(rangeTime) ?? rangeTime
    }

    private func startPlaybackNow() {
        guard let player else { return }
        // Resume from wherever the playhead currently sits (a prior seek, or
        // a paused position).
        player.currentTime = filePosition(for: playheadPosition)
        player.play()
        isPlaying = true
        startPlaybackTimer()
    }

    private func pausePlayback() {
        player?.pause()
        isPlaying = false
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    /// Tears down the player and its file without touching the transport
    /// state - used when swapping in a freshly prepared one.
    private func releasePlayerOnly() {
        player?.stop()
        player = nil
        if let stitchedPlaybackURL {
            try? FileManager.default.removeItem(at: stitchedPlaybackURL)
        }
        stitchedPlaybackURL = nil
        playbackTimeline = nil
        preparedRange = nil
    }

    private func stopPlayback() {
        prepareGeneration += 1
        isPreparingPlayback = false
        startWhenPrepared = false
        releasePlayerOnly()
        isPlaying = false
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    /// Click/drag-to-seek anywhere on the waveform. Updates the visible
    /// playhead immediately and unconditionally - never waits on export - so
    /// scrubbing feels exactly as responsive as Library's (a `.onChanged`
    /// drag calls this on every pixel of movement; blocking any of those
    /// calls on a real export, even briefly, is what made this feel "flaky"
    /// before). If a player already exists, also moves its actual playback
    /// position; if not, kicks off preparation in the background (without
    /// starting playback) so the position is honored once ready.
    func seek(to offset: TimeInterval) {
        let clamped = max(0, min(offset, totalDuration))
        // Dropping the playhead into a stretch that was never recorded gives
        // the user nothing to hear and no way to tell playback from a hang.
        // Land on the nearest edge of real audio instead.
        playheadPosition = loadedRange?.nearestRecordedOffset(clamped) ?? clamped

        guard let player else {
            preparePlayer()
            return
        }
        player.currentTime = filePosition(for: playheadPosition)
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickPlayback()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackTimer = timer
    }

    private func tickPlayback() {
        guard let player, isPlaying else { return }
        // The file is compacted, so a hole in the range takes no time to
        // cross: the playhead simply lands on the far side of it, which is
        // exactly what someone listening expects to hear.
        playheadPosition = playbackTimeline?.rangeTime(player.currentTime) ?? player.currentTime
        // Stop at the end of the whole clip, not the export selection - the
        // waveform's playhead/scrub is independent of what's currently
        // selected for Create (the user should be able to scrub and listen
        // anywhere in the loaded range, not just inside the selection).
        // Deliberately no `!player.isPlaying` check: AVAudioPlayer can report
        // a momentary false right after `.play()` returns, which caused an
        // immediate pause-and-snap on some plays.
        if playheadPosition >= totalDuration {
            pausePlayback()
            playheadPosition = totalDuration
        }
    }

    // MARK: - Export / Transcribe

    /// Exports the current selection to `clips/`, inserts the `clips` +
    /// `transcripts` rows, then hands off to `TranscriptionPipeline` (Priority
    /// 5) to run Scribe + Hinglish in the background. Export itself stays
    /// synchronous here (it's fast and the UI wants the new clip immediately);
    /// the pipeline runs detached and never blocks this call from returning.
    /// Fired (on the main actor) with the new clip's ID once Create has
    /// exported the clip and kicked off its pipeline - the shell uses this
    /// to jump to the Library with the new entry focused.
    var onClipCreated: ((String) -> Void)?

    /// Page-switch hook: preview playback must stop the instant the user
    /// navigates away from the Clip screen - this view model outlives the
    /// screen (it's owned by the shell coordinator), so the audio would
    /// otherwise keep playing under another page.
    func stopPlaybackOnNavigate() {
        stopPlayback()
    }

    func transcribe() {
        guard let loadedRange else { return }
        let start = loadedRange.requestedStart.addingTimeInterval(selectionStart)
        let end = loadedRange.requestedStart.addingTimeInterval(selectionEnd)
        let name = clipName.isEmpty ? Self.defaultClipName(for: start) : clipName

        isExporting = true
        exportError = nil
        withFreshAudioIfLive { [weak self] in
            self?.runExport(start: start, end: end, name: name)
        }
    }

    private func runExport(start: Date, end: Date, name: String) {
        // Clip ID minted up front - the audio lands directly in the clip's
        // own folder (clips/<clipID>/audio.m4a), per explicit user request.
        let clipID = UUID().uuidString
        Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ClipExporter.export(start: start, end: end, destination: WorklogPaths.clipAudioURL(clipID: clipID))
                }.value
                guard let self else { return }
                self.isExporting = false
                self.lastExportedClipURL = result.url
                // The actual exported audio, not the requested selection
                // length - they can differ if part of the selected range
                // fell on an unreadable segment (see `ClipExporter`'s
                // `ExportResult` doc and the corresponding guardrail sign:
                // never persist a "how long we asked for" duration as if it
                // were "how long the file actually is").
                let durationSeconds = result.actualDurationSeconds
                let requestedSeconds = end.timeIntervalSince(start)
                if durationSeconds < requestedSeconds - 1 {
                    // The shortfall is almost always a genuine stretch of
                    // the selection where recording simply wasn't running
                    // (stopped, paused, or between sessions) - say that
                    // plainly instead of a technical "unavailable" that
                    // reads like data loss.
                    self.exportError = "Clip saved with \(Self.formatShortDuration(durationSeconds)) of audio - the rest of your \(Self.formatShortDuration(requestedSeconds)) selection had no recording (recording was off during that time)."
                }
                WorklogDatabase.shared.insertClip(ClipRecord(
                    id: clipID,
                    path: result.url.path,
                    defaultName: name,
                    displayName: name,
                    sourceStart: start,
                    sourceEnd: end,
                    durationSeconds: durationSeconds,
                    createdAt: Date(),
                    locationLatitude: result.locationLatitude,
                    locationLongitude: result.locationLongitude,
                    deviceUID: result.deviceUID
                ))

                let transcriptID = UUID().uuidString
                WorklogDatabase.shared.insertTranscript(TranscriptRecord(
                    id: transcriptID,
                    clipID: clipID,
                    state: .pending,
                    error: nil,
                    provider: nil,
                    model: nil,
                    path: nil,
                    speakerCount: nil,
                    createdAt: Date()
                ))

                TranscriptionPipeline.shared.run(transcriptID: transcriptID, clipPath: result.url.path)
                self.onClipCreated?(clipID)
            } catch {
                guard let self else { return }
                self.isExporting = false
                // ClipExportError already carries complete user-facing copy
                // (e.g. "recording was off during that time") - don't wrap
                // it in a generic "Export failed:" prefix.
                if error is ClipExportError {
                    self.exportError = error.localizedDescription
                } else {
                    self.exportError = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    static func defaultClipName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd h:mm a"
        formatter.timeZone = .current
        return "Clip \(formatter.string(from: date))"
    }

    private static func formatShortDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
