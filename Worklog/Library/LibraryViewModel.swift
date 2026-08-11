import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

/// Which files a pending delete confirmation will remove - spec requires
/// the confirmation dialog be unambiguous about this, since a clip usually
/// (but not always, if Scribe/Hinglish never succeeded) has a transcript
/// riding along with it.
struct PendingDelete: Identifiable {
    let entry: LibraryEntry
    var id: String { entry.id }

    var willRemoveTranscript: Bool { entry.transcript != nil }
}

/// Owns the Library's list, selection, and row actions. Reads `worklog.db`
/// directly (`allClips()`/`transcript(clipID:)`) rather than duplicating
/// state - this view model is a read/refresh layer plus the actions spec
/// `06-library.md` calls for, not a second source of truth.
@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var entries: [LibraryEntry] = []
    @Published var searchQuery: String = ""
    @Published var selectedEntryID: String?
    @Published var pendingDelete: PendingDelete?
    /// Set when something went wrong that the user has to be told about.
    /// The screen binds an `.alert` to it; see `AlertMessage`.
    @Published var alertMessage: AlertMessage?
    @Published var renamingEntryID: String?
    @Published var renameText: String = ""
    @Published private(set) var isPlayingEntryID: String?
    @Published private(set) var copyConfirmationEntryID: String?
    @Published private(set) var playheadPosition: TimeInterval = 0
    /// Peaks for whichever entry is currently selected, keyed by clip ID -
    /// computed once per entry (clips are short; no DB cache needed the way
    /// raw all-day segments have one) and reused across re-renders so
    /// switching back to a previously-viewed entry doesn't redecode.
    @Published private(set) var peaksByEntryID: [String: [Float]] = [:]

    /// Live "which steps are running right now" for entries whose pipeline
    /// is actively in flight in this process - mirrors
    /// `TranscriptionPipeline.shared.runningSteps` via Combine so the list
    /// re-renders the instant a step starts/finishes, without polling. A
    /// set per transcript because translations run in parallel.
    @Published private var runningSteps: [String: Set<PipelineStep>] = [:]

    private var player: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    var selectedEntry: LibraryEntry? {
        entries.first { $0.id == selectedEntryID }
    }

    init() {
        TranscriptionPipeline.shared.$runningSteps
            .receive(on: DispatchQueue.main)
            .sink { [weak self] steps in
                self?.runningSteps = steps
                // A step just finished or started for an entry currently
                // shown - refresh so scribe/hinglish state (and the preview
                // snippet, once Hinglish completes) reflect the latest DB
                // write immediately rather than waiting for the next reload.
                self?.reload()
            }
            .store(in: &cancellables)
        // Place names are resolved live rather than indexed, so a rename has
        // to re-run the location filter - otherwise searching "work" would
        // keep showing the pre-rename result set until the next keystroke.
        PlaceStore.shared.$places
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        PlaceStore.shared.$geocodes
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Same rule for tags: assigning, renaming or deleting one has to
        // re-render the rows and re-run the filter.
        TagStore.shared.$assignments
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        TagStore.shared.$tags
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        reload()
    }

    /// `TranscriptionPipeline.runningSteps` is keyed by transcript ID (its
    /// own identity), never by clip ID - a mismatch that previously made
    /// this lookup always miss, since `LibraryEntry.id` is `clip.id`. Takes
    /// the full entry (rather than a bare ID) specifically so callers can't
    /// accidentally pass the wrong ID again.
    func runningSteps(for entry: LibraryEntry) -> Set<PipelineStep> {
        guard let transcriptID = entry.transcript?.id else { return [] }
        return runningSteps[transcriptID] ?? []
    }

    /// Rebuilds the list from `worklog.db` - newest first (per spec), each
    /// clip joined with its transcript, that transcript's translations,
    /// and its summary.
    func reload() {
        let clips = WorklogDatabase.shared.allClips()
        // One query for every clip's tagging row rather than one per clip:
        // this runs on every pipeline state change.
        let taggings = WorklogDatabase.shared.allTaggings()
        entries = clips.map { clip in
            let transcript = WorklogDatabase.shared.transcript(clipID: clip.id)
            let translations = transcript.map { WorklogDatabase.shared.translations(transcriptID: $0.id) } ?? []
            let summaries = transcript.map { WorklogDatabase.shared.summaries(transcriptID: $0.id) } ?? []
            return LibraryEntry(
                clip: clip,
                transcript: transcript,
                translations: translations,
                summaries: summaries,
                tagging: transcript.flatMap { taggings[$0.id] }
            )
        }

        if let selectedEntryID, !entries.contains(where: { $0.id == selectedEntryID }) {
            self.selectedEntryID = nil
        }

        refreshSearchIndex()
    }

    // MARK: - Search

    /// The entries the list actually shows, best match first.
    ///
    /// Ranked, not just filtered. Field priority beats recency - a clip
    /// recorded at a place called "office" outranks one that merely says
    /// "office" somewhere in an hour of transcript, which is the whole
    /// reason this isn't a `filter`.
    ///
    /// Cheap per keystroke by construction: the query is tokenized once, and
    /// every field it's compared against was normalized when the data
    /// changed, not now.
    var visibleEntries: [LibraryEntry] {
        let tokens = LibrarySearch.tokenize(searchQuery)
        guard !tokens.isEmpty else { return entries }

        return entries
            .enumerated()
            .compactMap { index, entry -> (entry: LibraryEntry, result: SearchResult, index: Int)? in
                guard let fields = searchFields[entry.id],
                      let result = LibrarySearch.match(tokens: tokens, fields: fields) else { return nil }
                return (entry, result, index)
            }
            .sorted { left, right in
                if left.result.tier != right.result.tier { return left.result.tier > right.result.tier }
                if left.result.score != right.result.score { return left.result.score > right.result.score }
                // `entries` is already newest-first, so the original index is
                // the recency tie-break.
                return left.index < right.index
            }
            .map(\.entry)
    }

    /// Everything search compares against, per clip, already normalized.
    ///
    /// Rebuilt when the data changes - never per keystroke. The content half
    /// (transcripts, translations, summaries) is read off disk in the
    /// background and only for entries whose artifacts actually changed; the
    /// cheap half (name, dates, tags, place) is recomputed inline, which is
    /// what lets a tag or place rename re-rank the list immediately.
    @Published private(set) var searchFields: [String: EntrySearchFields] = [:]
    private var searchFingerprints: [String: String] = [:]

    private struct SearchIndexJob {
        let id: String
        let fingerprint: String
        let transcriptPath: String?
        let markdownPaths: [String]
    }

    /// Rebuilds the cheap fields for every entry, then kicks off a
    /// background pass for the expensive ones.
    private func refreshSearchIndex() {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd"

        var fields: [String: EntrySearchFields] = [:]
        var jobs: [SearchIndexJob] = []

        for entry in entries {
            var entryFields = searchFields[entry.id] ?? EntrySearchFields()
            entryFields.name = LibrarySearch.normalize(entry.clip.displayName)
            entryFields.dates = LibrarySearch.normalize(
                "\(formatter.string(from: entry.clip.sourceStart)) \(isoFormatter.string(from: entry.clip.sourceStart))"
            )
            entryFields.tags = TagStore.shared.tags(forClip: entry.clip.id).map { LibrarySearch.normalize($0.name) }
            if let label = PlaceStore.shared.label(
                latitude: entry.clip.locationLatitude,
                longitude: entry.clip.locationLongitude
            ) {
                entryFields.places = [label.place?.name, label.detectedName, label.detectedContext]
                    .compactMap { $0 }
                    .map(LibrarySearch.normalize)
            } else {
                entryFields.places = []
            }
            fields[entry.id] = entryFields

            let artifactPaths = [entry.transcript?.path].compactMap { $0 }
                + entry.summaries.compactMap(\.path)
                + entry.translations.compactMap(\.path)
            let states = [entry.transcript?.state.rawValue].compactMap { $0 }
                + entry.summaries.map(\.state.rawValue)
                + entry.translations.map(\.state.rawValue)
            jobs.append(SearchIndexJob(
                id: entry.id,
                fingerprint: "\(artifactPaths.joined(separator: ","))|\(states.joined(separator: ","))",
                transcriptPath: entry.transcript?.path,
                markdownPaths: entry.summaries.compactMap(\.path) + entry.translations.compactMap(\.path)
            ))
        }

        searchFields = fields
        let liveIDs = Set(jobs.map(\.id))
        searchFingerprints = searchFingerprints.filter { liveIDs.contains($0.key) }

        let stale = jobs.filter { searchFingerprints[$0.id] != $0.fingerprint }
        guard !stale.isEmpty else { return }

        Task.detached(priority: .utility) {
            var built: [String: String] = [:]
            for job in stale {
                var parts: [String] = []
                if let transcriptPath = job.transcriptPath,
                   let data = FileManager.default.contents(atPath: transcriptPath),
                   let parsed = try? JSONDecoder().decode(TranscriptResponse.self, from: data) {
                    parts.append(TranscriptFormatter.displayTranscript(parsed))
                }
                for path in job.markdownPaths {
                    if let data = FileManager.default.contents(atPath: path),
                       let text = String(data: data, encoding: .utf8) {
                        parts.append(text)
                    }
                }
                built[job.id] = LibrarySearch.normalize(parts.joined(separator: "\n"))
            }
            await MainActor.run { [built] in
                for job in stale {
                    self.searchFingerprints[job.id] = job.fingerprint
                }
                for (id, content) in built {
                    self.searchFields[id]?.content = content
                }
            }
        }
    }

    // MARK: - Selection / playback

    func select(_ entry: LibraryEntry) {
        // Switching to a different clip silences the previous one - audio
        // from a clip that's no longer on screen must never keep playing.
        if selectedEntryID != entry.id {
            stopPlayback()
        }
        selectedEntryID = entry.id
        loadPeaksIfNeeded(for: entry)
    }

    func retryTagging(for entry: LibraryEntry) {
        guard let transcriptID = entry.transcript?.id else { return }
        TranscriptionPipeline.shared.retryTagging(transcriptID: transcriptID)
    }

    /// Reloads and selects a specific clip - used by the shell when a
    /// freshly created clip should land the user in the Library with the
    /// new entry focused.
    func focusEntry(clipID: String) {
        reload()
        guard let entry = entries.first(where: { $0.id == clipID }) else { return }
        select(entry)
    }

    /// Clicking Library in the sidebar returns it to how it opens fresh:
    /// no search, no selection, nothing half-renamed or mid-confirmation.
    /// The shell owns this view model, so none of that clears on its own -
    /// a search typed yesterday would still be filtering the list today.
    func resetToCleanState() {
        stopPlayback()
        searchQuery = ""
        selectedEntryID = nil
        pendingDelete = nil
        renamingEntryID = nil
        renameText = ""
    }

    /// Page-switch hook: this view model is owned by the shell coordinator
    /// (so Library selection survives navigation), which means playback
    /// must be stopped explicitly when the user leaves the page.
    func stopPlaybackOnNavigate() {
        stopPlayback()
    }

    /// Computes and caches peaks for `entry`'s clip file, off the main
    /// actor - clips are short (typically well under an hour) so this is
    /// cheap enough to redo per-entry without a persistent cache, unlike the
    /// raw-segment peak cache in `worklog.db`.
    private func loadPeaksIfNeeded(for entry: LibraryEntry) {
        guard peaksByEntryID[entry.id] == nil else { return }
        let path = entry.clip.path
        let entryID = entry.id
        Task.detached(priority: .userInitiated) { [weak self] in
            let peaks = PeakComputer.computePeaks(for: URL(fileURLWithPath: path))
            await MainActor.run {
                self?.peaksByEntryID[entryID] = peaks
            }
        }
    }

    func togglePlayback(for entry: LibraryEntry) {
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

    private func startPlayback(for entry: LibraryEntry) {
        stopPlayback()
        do {
            let url = URL(fileURLWithPath: entry.clip.path)
            let newPlayer = try AVAudioPlayer(contentsOf: url)
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

    /// Click/drag-to-seek on the Library detail waveform.
    func seek(to offset: TimeInterval, for entry: LibraryEntry) {
        if isPlayingEntryID != entry.id {
            startPlayback(for: entry)
            pausePlayback()
        }
        let clamped = max(0, min(offset, entry.clip.durationSeconds))
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

    // MARK: - Rename (index-only, never touches on-disk filename)

    func beginRename(_ entry: LibraryEntry) {
        renamingEntryID = entry.id
        renameText = entry.clip.displayName
    }

    func commitRename() {
        guard let renamingEntryID else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            WorklogDatabase.shared.renameClip(id: renamingEntryID, displayName: trimmed)
        }
        self.renamingEntryID = nil
        reload()
    }

    func cancelRename() {
        renamingEntryID = nil
    }

    // MARK: - Copy transcript

    /// Copies arbitrary already-loaded text (transcript or translation,
    /// which `LibraryDetailView` reads once into local state rather than
    /// re-reading the file on every copy) - with a brief "Copied"
    /// confirmation window keyed by whatever ID the caller wants the
    /// confirmation to show against.
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

    // MARK: - Share files

    /// Hands every file belonging to this clip to the share sheet. The macOS
    /// build revealed them in Finder; iOS has no equivalent, and sharing is
    /// what you actually want from this button on a phone.
    func revealInFinder(_ entry: LibraryEntry) {
        var urls = [URL(fileURLWithPath: entry.clip.path)]
        if let transcriptPath = entry.transcript?.path {
            urls.append(URL(fileURLWithPath: transcriptPath))
        }
        for translation in entry.translations {
            if let path = translation.path {
                urls.append(URL(fileURLWithPath: path))
            }
        }
        for summary in entry.summaries {
            if let summaryPath = summary.path {
                urls.append(URL(fileURLWithPath: summaryPath))
            }
        }
        Platform.share(urls)
    }

    /// Shares a single file - the per-section icons (clip audio, transcript
    /// JSON, translation markdown) each call this with just their own file,
    /// distinct from `revealInFinder(_:)`'s "everything at once" behavior.
    func revealFileInFinder(atPath path: String) {
        Platform.share([URL(fileURLWithPath: path)])
    }

    /// Puts a file's path on the pasteboard.
    ///
    /// The contents are one thing; where the file lives is another, and it's
    /// what you need when the next step is handing it to something that can
    /// open it - an agent, a terminal, a note to yourself.
    func copyPath(_ path: String, confirmationID: String) {
        copyToPasteboard(path, confirmationID: "\(confirmationID)-path")
    }

    /// Hands a single artifact - a transcript, a translation, a summary - to
    /// the system share sheet. The Android app has offered this per section
    /// from the start; sending someone one summary shouldn't mean exporting
    /// the entire clip archive or hunting the file down in Finder first.
    func shareFile(atPath path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        Platform.share([url])
    }

    /// Puts a whole artifact on the pasteboard from the Library list, without
    /// having to open the entry first. Reads the file off the main thread -
    /// a transcript is tens of thousands of characters.
    func copyTranscript(for entry: LibraryEntry) {
        guard let path = entry.transcript?.path else { return }
        let entryID = entry.id
        Task.detached(priority: .userInitiated) {
            guard let data = FileManager.default.contents(atPath: path),
                  let response = try? JSONDecoder().decode(TranscriptResponse.self, from: data) else { return }
            let text = TranscriptFormatter.displayTranscript(response)
            await MainActor.run {
                self.copyToPasteboard(text, confirmationID: entryID)
            }
        }
    }

    // MARK: - Import / export archives

    /// The Library header's import affordance: audio files (any format
    /// AVFoundation reads) and `.worklog.zip` clip exports, multi-select.
    /// Drives the SwiftUI `.fileImporter` on the Library header. A view
    /// model cannot present a picker on iOS the way `NSOpenPanel` let it on
    /// macOS, so the flag is the whole mechanism.
    @Published var isPresentingImporter = false

    func presentImportPanel() {
        isPresentingImporter = true
    }

    /// Files currently being imported - the Library header shows a live
    /// importing indicator while this is above zero, because a large file
    /// can transcode for minutes and silence reads as "nothing happened".
    @Published private(set) var importingCount = 0

    func importFiles(at urls: [URL]) {
        Task {
            importingCount += urls.count
            defer { importingCount -= urls.count }
            let outcomes = await ClipImporter.importFiles(at: urls)
            reload()
            let importedIDs = outcomes.compactMap { outcome -> String? in
                if case .imported(let clipID, _) = outcome { return clipID }
                return nil
            }
            // Landing selected on the newest import IS the success feedback;
            // only duplicates and failures need words.
            if let last = importedIDs.last { selectedEntryID = last }
            if importedIDs.count != outcomes.count {
                alertMessage = AlertMessage(title: "Import", body: ClipImporter.summaryMessage(outcomes))
            }
        }
    }

    /// Builds the clip's portable `.worklog.zip` - audio, transcript,
    /// translations, summaries - then hands it to the native share picker.
    func exportAndShareArchive(for entry: LibraryEntry) {
        Task {
            do {
                let archive = try await ClipArchiveExporter.export(clipID: entry.id)
                Platform.share([archive])
            } catch {
                alertMessage = AlertMessage(
                    title: "Couldn't export this clip",
                    body: (error as? ClipArchiveError)?.message ?? error.localizedDescription
                )
            }
        }
    }

    /// Shares just the clip's audio file - the same action Android offers
    /// as "Share clip audio".
    func shareClipAudio(for entry: LibraryEntry) {
        Platform.share([URL(fileURLWithPath: entry.clip.path)])
    }

    // MARK: - Retry (always available - even for an already-succeeded step,
    // per the user's explicit "I need retry buttons for everything at all
    // times" request, not just as a failure-recovery action)

    /// Re-runs the transcription (and, since a fresh transcript invalidates
    /// everything derived from it, all translations) for `entry`.
    func retryTranscription(for entry: LibraryEntry) {
        guard let transcript = entry.transcript else { return }
        TranscriptionPipeline.shared.retryTranscription(transcriptID: transcript.id, clipPath: entry.clip.path)
    }

    /// Re-runs a single translation for `entry`.
    func retryTranslation(_ translation: TranslationRecord) {
        TranscriptionPipeline.shared.retryTranslation(translationID: translation.id)
    }

    /// Re-runs the summary for `entry` (source resolved from current
    /// Settings at run time).
    func retrySummary(for entry: LibraryEntry, preset: SummaryPreset) {
        guard let transcript = entry.transcript else { return }
        TranscriptionPipeline.shared.retrySummary(transcriptID: transcript.id, preset: preset)
    }

    // MARK: - Delete (manual, confirmed, never touched by retention)

    func requestDelete(_ entry: LibraryEntry) {
        pendingDelete = PendingDelete(entry: entry)
    }

    func cancelDelete() {
        pendingDelete = nil
    }

    /// Removes the clip row (and its transcript + translation rows, via
    /// `WorklogDatabase.deleteClip`'s cascade) plus every on-disk file that
    /// belongs to this entry - the clip `.m4a`, the transcript JSON, and
    /// every translation markdown. Never called by the retention sweeper;
    /// this is the Library's own user-confirmed action only.
    func confirmDelete() {
        guard let entry = pendingDelete?.entry else { return }

        if isPlayingEntryID == entry.id {
            stopPlayback()
        }
        peaksByEntryID[entry.id] = nil

        WorklogDatabase.shared.deleteClip(id: entry.clip.id)

        // Every artifact of a clip (audio, transcript, translations) lives
        // in its own clips/<clipID>/ folder - one remove covers them all.
        try? FileManager.default.removeItem(at: WorklogPaths.clipFolder(clipID: entry.clip.id))

        pendingDelete = nil
        reload()
    }
}
