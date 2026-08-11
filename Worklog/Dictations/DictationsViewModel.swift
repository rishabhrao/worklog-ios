import AVFoundation
import Combine
import Foundation

/// A dictation plus the text it produced, ready to render. The text is read
/// from disk once here rather than by the views, which re-render constantly.
struct DictationEntry: Identifiable {
    let dictation: DictationRecord
    /// Transcribed text, if any exists yet. Present *and* `state == .failed`
    /// means a realtime stream died partway: what it did produce is real and
    /// worth showing, but it is not the whole dictation.
    let text: String?

    var id: String { dictation.id }

    var isPartial: Bool {
        dictation.state == .failed && !(text ?? "").isEmpty
    }
}

struct PendingDictationDelete: Identifiable {
    let entry: DictationEntry
    var id: String { entry.id }
}

/// Owns the Dictations list, selection and row actions - the same
/// read/refresh-layer role `LibraryViewModel` plays for clips, over a
/// simpler model (one row, one transcript, no derived artifacts).
@MainActor
final class DictationsViewModel: ObservableObject {
    @Published private(set) var entries: [DictationEntry] = []
    @Published var searchQuery: String = ""
    @Published var selectedEntryID: String?
    @Published var pendingDelete: PendingDictationDelete?
    @Published var renamingEntryID: String?
    @Published var renameText: String = ""
    @Published private(set) var isPlayingEntryID: String?
    @Published private(set) var copyConfirmationEntryID: String?
    @Published private(set) var playheadPosition: TimeInterval = 0
    @Published private(set) var peaksByEntryID: [String: [Float]] = [:]

    /// Mirrors `DictationPipeline.runningIDs` so rows show live spinners the
    /// instant a transcription starts or finishes, without polling.
    @Published private(set) var runningIDs: Set<String> = []

    private var player: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    var selectedEntry: DictationEntry? {
        entries.first { $0.id == selectedEntryID }
    }

    init() {
        DictationPipeline.shared.$runningIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ids in
                self?.runningIDs = ids
                self?.reload()
            }
            .store(in: &cancellables)

        // A dictation is created by a global hotkey, which can fire while
        // this tab is already on screen - `onAppear` alone would leave the
        // list stale until the user navigated away and back.
        NotificationCenter.default.publisher(for: DictationController.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        // Same reason as the Library's: location is filtered live, so a
        // renamed or removed place has to re-run the filter.
        PlaceStore.shared.$places
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        PlaceStore.shared.$geocodes
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        reload()
    }

    func isRunning(_ entry: DictationEntry) -> Bool {
        runningIDs.contains(entry.id)
    }

    /// Transcript text by dictation ID, with the fingerprint it was read at.
    /// Reads used to happen inline in `reload()` - one synchronous file read
    /// per dictation, on the main thread, on every reload. `reload()` fires
    /// on every pipeline state change and every dictation created, so that
    /// cost scaled with the whole history each time.
    private var textCache: [String: String] = [:]
    private var textFingerprints: [String: String] = [:]

    private static func textFingerprint(_ dictation: DictationRecord) -> String {
        "\(dictation.textPath ?? "")|\(dictation.state.rawValue)"
    }

    func reload() {
        let dictations = WorklogDatabase.shared.allDictations()
        entries = dictations.map { DictationEntry(dictation: $0, text: textCache[$0.id]) }

        if let selectedEntryID, !entries.contains(where: { $0.id == selectedEntryID }) {
            self.selectedEntryID = nil
        }

        loadMissingText(for: dictations)
        refreshSearchIndex()
    }

    /// Reads only the transcripts whose file or state changed since the last
    /// pass, off the main actor, then folds them back in.
    private func loadMissingText(for dictations: [DictationRecord]) {
        let live = Set(dictations.map(\.id))
        textCache = textCache.filter { live.contains($0.key) }
        textFingerprints = textFingerprints.filter { live.contains($0.key) }

        let stale = dictations.filter { textFingerprints[$0.id] != Self.textFingerprint($0) }
        guard !stale.isEmpty else { return }

        Task.detached(priority: .utility) { [weak self] in
            var loaded: [String: String] = [:]
            for dictation in stale {
                guard let path = dictation.textPath,
                      let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
                else { continue }
                loaded[dictation.id] = text
            }
            guard let self else { return }
            await MainActor.run {
                for dictation in stale {
                    self.textFingerprints[dictation.id] = Self.textFingerprint(dictation)
                }
                for (id, text) in loaded {
                    self.textCache[id] = text
                }
                // Re-project the entries now that text has landed. Reads
                // straight from the cache rather than recursing into
                // `reload()`, which would re-query the database and could
                // ping-pong indefinitely.
                self.entries = self.entries.map {
                    DictationEntry(dictation: $0.dictation, text: self.textCache[$0.id])
                }
                self.refreshSearchIndex()
            }
        }
    }

    // MARK: - Search

    /// Same ranked search as the Library, over what a dictation has: its
    /// name, when it was spoken, where, and the text itself. No tags - a
    /// dictation is one short utterance, and tagging it would be more
    /// bookkeeping than the thing is worth.
    var visibleEntries: [DictationEntry] {
        let tokens = LibrarySearch.tokenize(searchQuery)
        guard !tokens.isEmpty else { return entries }

        return entries
            .enumerated()
            .compactMap { index, entry -> (entry: DictationEntry, result: SearchResult, index: Int)? in
                guard let fields = searchFields[entry.id],
                      let result = LibrarySearch.match(tokens: tokens, fields: fields) else { return nil }
                return (entry, result, index)
            }
            .sorted { left, right in
                if left.result.tier != right.result.tier { return left.result.tier > right.result.tier }
                if left.result.score != right.result.score { return left.result.score > right.result.score }
                return left.index < right.index
            }
            .map(\.entry)
    }

    /// Everything search compares against, per dictation, already normalized.
    /// Cheaper to build than the Library's - a dictation's text is one short
    /// plain string already in memory, not files on disk - so this recomputes
    /// wholesale rather than fingerprinting.
    @Published private(set) var searchFields: [String: EntrySearchFields] = [:]

    private func refreshSearchIndex() {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd"

        var fields: [String: EntrySearchFields] = [:]
        for entry in entries {
            var entryFields = EntrySearchFields()
            entryFields.name = LibrarySearch.normalize(entry.dictation.displayName)
            entryFields.dates = LibrarySearch.normalize(
                "\(formatter.string(from: entry.dictation.sourceStart)) \(isoFormatter.string(from: entry.dictation.sourceStart))"
            )
            entryFields.content = LibrarySearch.normalize(entry.text ?? "")
            if let label = PlaceStore.shared.label(
                latitude: entry.dictation.locationLatitude,
                longitude: entry.dictation.locationLongitude
            ) {
                entryFields.places = [label.place?.name, label.detectedName, label.detectedContext]
                    .compactMap { $0 }
                    .map(LibrarySearch.normalize)
            }
            fields[entry.id] = entryFields
        }
        searchFields = fields
    }

    // MARK: - Selection / playback

    func select(_ entry: DictationEntry) {
        if selectedEntryID != entry.id {
            stopPlayback()
        }
        selectedEntryID = entry.id
        loadPeaksIfNeeded(for: entry)
    }

    func focusEntry(dictationID: String) {
        reload()
        guard let entry = entries.first(where: { $0.id == dictationID }) else { return }
        select(entry)
    }

    /// Page-switch hook - this view model outlives the screen (it's owned by
    /// the shell coordinator), so audio must be stopped explicitly when the
    /// user navigates away.
    /// Same contract as the Library's: clicking Dictations gives you the
    /// page as it first opens.
    func resetToCleanState() {
        stopPlayback()
        searchQuery = ""
        selectedEntryID = nil
        pendingDelete = nil
        renamingEntryID = nil
        renameText = ""
    }

    func stopPlaybackOnNavigate() {
        stopPlayback()
    }

    /// Shares the dictation's audio file - the same action Android offers
    /// as "Share audio" on a dictation.
    /// Puts a file's path on the pasteboard - see `LibraryViewModel.copyPath`.
    func copyPath(_ path: String, confirmationID: String) {
        copyToPasteboard(path, confirmationID: "\(confirmationID)-path")
    }

    func shareAudio(for entry: DictationEntry) {
        Platform.share([URL(fileURLWithPath: entry.dictation.path)])
    }

    /// Shares the committed transcript text file - Android's "Share text".
    func shareText(for entry: DictationEntry) {
        guard let path = entry.dictation.textPath else { return }
        Platform.share([URL(fileURLWithPath: path)])
    }

    private func loadPeaksIfNeeded(for entry: DictationEntry) {
        guard peaksByEntryID[entry.id] == nil else { return }
        let path = entry.dictation.path
        guard FileManager.default.fileExists(atPath: path) else { return }
        let entryID = entry.id
        Task.detached(priority: .userInitiated) { [weak self] in
            let peaks = PeakComputer.computePeaks(for: URL(fileURLWithPath: path))
            guard let self else { return }
            await MainActor.run {
                self.peaksByEntryID[entryID] = peaks
            }
        }
    }

    /// A dictation whose audio export failed still has a row (and possibly
    /// text) but nothing to play - the player and Retry both key off this.
    func hasAudio(_ entry: DictationEntry) -> Bool {
        FileManager.default.fileExists(atPath: entry.dictation.path)
    }

    func togglePlayback(for entry: DictationEntry) {
        if isPlayingEntryID == entry.id {
            if player?.isPlaying == true {
                pausePlayback()
            } else {
                resumePlayback()
            }
            return
        }
        startPlayback(for: entry)
    }

    private func startPlayback(for entry: DictationEntry) {
        stopPlayback()
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: entry.dictation.path))
            newPlayer.play()
            player = newPlayer
            isPlayingEntryID = entry.id
            playheadPosition = 0
            startPlaybackTimer()
        } catch {
            player = nil
            isPlayingEntryID = nil
        }
    }

    private func resumePlayback() {
        player?.play()
        startPlaybackTimer()
    }

    private func pausePlayback() {
        player?.pause()
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        isPlayingEntryID = nil
        playheadPosition = 0
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    func seek(to offset: TimeInterval, for entry: DictationEntry) {
        if isPlayingEntryID != entry.id {
            startPlayback(for: entry)
            pausePlayback()
        }
        let clamped = max(0, min(offset, entry.dictation.durationSeconds))
        playheadPosition = clamped
        player?.currentTime = clamped
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
        guard let player else { return }
        playheadPosition = player.currentTime
        if !player.isPlaying, player.currentTime >= player.duration - 0.05 {
            stopPlayback()
        }
    }

    // MARK: - Rename (index-only, never touches the on-disk filename)

    func beginRename(_ entry: DictationEntry) {
        renamingEntryID = entry.id
        renameText = entry.dictation.displayName
    }

    func commitRename() {
        guard let renamingEntryID else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            WorklogDatabase.shared.renameDictation(id: renamingEntryID, displayName: trimmed)
        }
        self.renamingEntryID = nil
        reload()
    }

    func cancelRename() {
        renamingEntryID = nil
    }

    // MARK: - Copy / reveal

    func copyToPasteboard(_ text: String, confirmationID: String) {
        Platform.copyToClipboard(text)

        copyConfirmationEntryID = confirmationID
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if self.copyConfirmationEntryID == confirmationID {
                self.copyConfirmationEntryID = nil
            }
        }
    }

    /// Hands the dictation's files to the share sheet - see the note on
    /// `LibraryViewModel.revealInFinder(_:)` for why this is sharing and not
    /// a reveal.
    func revealInFinder(_ entry: DictationEntry) {
        var urls: [URL] = []
        if FileManager.default.fileExists(atPath: entry.dictation.path) {
            urls.append(URL(fileURLWithPath: entry.dictation.path))
        }
        for path in [entry.dictation.textPath, entry.dictation.rawPath].compactMap({ $0 }) {
            urls.append(URL(fileURLWithPath: path))
        }
        guard !urls.isEmpty else { return }
        Platform.share(urls)
    }

    func revealFileInFinder(atPath path: String) {
        Platform.share([URL(fileURLWithPath: path)])
    }

    // MARK: - Retry

    /// Always re-runs the batch engine, whatever produced the row
    /// originally - see `DictationPipeline.retry`. Requires the audio to
    /// still be on disk, which it always is unless the export itself failed.
    func retryTranscription(for entry: DictationEntry) {
        guard hasAudio(entry) else { return }
        DictationPipeline.shared.retry(dictationID: entry.id)
    }

    // MARK: - Delete (manual, confirmed, never touched by retention)

    func requestDelete(_ entry: DictationEntry) {
        pendingDelete = PendingDictationDelete(entry: entry)
    }

    func cancelDelete() {
        pendingDelete = nil
    }

    func confirmDelete() {
        guard let entry = pendingDelete?.entry else { return }

        if isPlayingEntryID == entry.id {
            stopPlayback()
        }
        peaksByEntryID[entry.id] = nil

        WorklogDatabase.shared.deleteDictation(id: entry.id)
        // Every artifact lives in the one dictations/<id>/ folder.
        try? FileManager.default.removeItem(at: WorklogPaths.dictationFolder(dictationID: entry.id))

        pendingDelete = nil
        reload()
    }
}
