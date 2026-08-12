import AVFoundation
import CoreMedia
import Foundation
import os
import Speech

let previewLog = Logger(subsystem: "com.rishabhrao.worklog", category: "preview")

/// The built-in engine: iOS 26's `SpeechAnalyzer` + `SpeechTranscriber`,
/// the same fully on-device long-form transcriber Notes uses. Chosen over
/// the older `SFSpeechRecognizer` because it is *designed* for exactly this
/// shape of work - continuous audio of unbounded length, volatile partial
/// results for live display, finalized results carrying per-run audio time
/// ranges - where SFSpeechRecognizer needs babysitting past a minute.
///
/// Audio never leaves the machine and no API key is involved, which is the
/// entire point: previews are the free, instant, rough layer underneath the
/// paid, accurate Scribe pass.
@available(iOS 26.0, macOS 26.0, *)
final class AppleSpeechPreviewTranscriber: PreviewTranscriber {
    let id = "apple_speech_analyzer"

    /// Capture hands buffers over synchronously on its write queue; this
    /// stream is the handoff into async land. Unbounded buffering is safe:
    /// the consumer converts and yields to the analyzer far faster than
    /// 48kHz real time arrives.
    private struct Feed {
        let buffer: AVAudioPCMBuffer
        let capturedAt: Date
    }

    private let lock = NSLock()
    private var feedContinuation: AsyncStream<Feed>.Continuation?
    private var supervisor: Task<Void, Never>?
    private var onEvent: ((PreviewTranscriberEvent) -> Void)?

    /// Progress of an asset download in flight, surfaced through
    /// `availability()` so Settings can show a percentage.
    private var downloadProgress: Progress?

    /// The locale currently reserved with `AssetInventory`, if any.
    private var reservedLocale: Locale?

    /// Set by `finish()` so the supervisor's failure backoff can give up
    /// waiting immediately instead of holding a teardown open for its full
    /// delay.
    private var stopRequested = false

    // MARK: - Availability / assets

    private static func resolveLocale() async -> Locale? {
        // An explicit choice in Settings wins. Otherwise the system locale's
        // best supported equivalent, and failing that English, which is a
        // better rough preview than nothing. Note this transcriber takes one
        // locale per session - unlike Android it has no language-switching
        // mode, so a mixed-language sentence is transcribed in whichever
        // language is chosen here, and Scribe sorts it out on the accurate
        // pass.
        for identifier in WorklogSettingsStore.load().preferredPreviewLocales {
            if let match = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: identifier)
            ) {
                return match
            }
        }
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return match
        }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
    }

    /// Every locale this device can transcribe, and which of them are already
    /// downloaded. Drives the Settings language list.
    static func languageCatalog() async -> (supported: [String], installed: [String]) {
        let supported = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        return (supported.sorted(), installed.sorted())
    }

    /// Whether this language's model is physically on the device.
    ///
    /// This - not `AssetInventory.status(forModules:)` - is the question
    /// "can we transcribe right now". See `availability()` for why the
    /// distinction is the difference between previews that survive being
    /// backgrounded and previews that don't.
    private static func isInstalled(_ locale: Locale) async -> Bool {
        let want = locale.identifier(.bcp47).lowercased()
        return await SpeechTranscriber.installedLocales.contains {
            $0.identifier(.bcp47).lowercased() == want
        }
    }

    /// Fetches one language's assets on demand, for the Settings list.
    static func downloadLanguage(_ identifier: String) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: identifier)
        ) else { return }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) else { return }
        previewLog.info("downloading assets for \(identifier, privacy: .public)")
        try await request.downloadAndInstall()
    }

    func availability() async -> PreviewTranscriberAvailability {
        guard SpeechTranscriber.isAvailable else {
            return .unavailable("This device can't run the on-device transcriber.")
        }
        guard let locale = await Self.resolveLocale() else {
            return .unavailable("No supported preview language for this system.")
        }
        // Installed on device means ready, full stop.
        //
        // `AssetInventory.status(forModules:)` answers a different question
        // than it appears to: not "are this language's assets present" but
        // "are they present *and* is the locale currently reserved". Those
        // reservations are a small global pool - five, shared across every
        // app - and the system takes them back on its own. So a device with
        // the model sitting right there reports `.supported`, the app
        // dutifully "downloads" it in milliseconds, nothing changes, and the
        // re-check says `.supported` again, leaving previews parked on a
        // failed-download message until the app is relaunched.
        //
        // Verified against the live API: with the locale unreserved and
        // status reporting `.supported`, both `SpeechAnalyzer.start` and
        // `finalizeAndFinishThroughEndOfInput` succeed. The reservation is a
        // courtesy to the OS (see `reserveIfNeeded`), never a prerequisite.
        if await Self.isInstalled(locale) { return .ready }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return .ready
        case .downloading:
            return .downloading(currentDownloadFraction())
        case .supported:
            return .needsDownload
        case .unsupported:
            return .unavailable("On-device transcription doesn't support \(locale.identifier).")
        @unknown default:
            return .unavailable("On-device transcription is unavailable.")
        }
    }

    func prepareAssets() async throws {
        guard let locale = await Self.resolveLocale() else { return }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return // Nothing to download - already installed.
        }
        setDownloadProgress(request.progress)
        defer { setDownloadProgress(nil) }
        previewLog.info("downloading speech model assets for \(locale.identifier, privacy: .public)")
        try await request.downloadAndInstall()
        previewLog.info("speech model assets installed")
    }

    /// Tells the OS this app is using `locale`, so its assets aren't
    /// reclaimed while previews run.
    ///
    /// Best effort by design. The reservation pool is global and holds five
    /// locales, so it can legitimately be full, and being refused costs us
    /// nothing: transcription works unreserved. We hold at most one and give
    /// it back when previews stop.
    private func reserveIfNeeded(_ locale: Locale) async {
        if currentReservation() == locale { return }
        await releaseReservation()
        do {
            try await AssetInventory.reserve(locale: locale)
            setReservation(locale)
        } catch {
            previewLog.info("no asset reservation for \(locale.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func releaseReservation() async {
        guard let locale = currentReservation() else { return }
        setReservation(nil)
        await AssetInventory.release(reservedLocale: locale)
    }

    private func currentReservation() -> Locale? {
        lock.lock()
        defer { lock.unlock() }
        return reservedLocale
    }

    private func setReservation(_ locale: Locale?) {
        lock.lock()
        reservedLocale = locale
        lock.unlock()
    }

    private func setStopRequested(_ requested: Bool) {
        lock.lock()
        stopRequested = requested
        lock.unlock()
    }

    private func isStopRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    private func setDownloadProgress(_ progress: Progress?) {
        lock.lock()
        downloadProgress = progress
        lock.unlock()
    }

    private func currentDownloadFraction() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return downloadProgress?.fractionCompleted
    }

    // MARK: - Lifecycle

    func start(onEvent: @escaping (PreviewTranscriberEvent) -> Void) {
        lock.lock()
        guard supervisor == nil else {
            lock.unlock()
            return
        }
        self.onEvent = onEvent
        stopRequested = false
        let (stream, continuation) = AsyncStream.makeStream(of: Feed.self)
        feedContinuation = continuation
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.run(stream)
        }
        supervisor = task
        lock.unlock()
    }

    func feed(buffer: AVAudioPCMBuffer, at capturedAt: Date) {
        lock.lock()
        let continuation = feedContinuation
        lock.unlock()
        continuation?.yield(Feed(buffer: buffer, capturedAt: capturedAt))
    }

    func finish() async {
        setStopRequested(true)
        let (continuation, task) = takeFeed()
        // Ending the feed stream is what lets the supervisor finalize the
        // analyzer and flush tail words - then wait for it so callers know
        // every word is in the database when this returns. The stop flag
        // above keeps that wait short when the supervisor is parked in its
        // failure backoff, which has nothing to flush anyway.
        continuation?.finish()
        await task?.value
        await releaseReservation()
        clearEventHandler()
    }

    private func takeFeed() -> (AsyncStream<Feed>.Continuation?, Task<Void, Never>?) {
        lock.lock()
        defer { lock.unlock() }
        let result = (feedContinuation, supervisor)
        feedContinuation = nil
        supervisor = nil
        return result
    }

    private func clearEventHandler() {
        lock.lock()
        onEvent = nil
        lock.unlock()
    }

    private func emit(_ event: PreviewTranscriberEvent) {
        lock.lock()
        let handler = onEvent
        lock.unlock()
        handler?(event)
    }

    // MARK: - Sessions

    /// The analyzer's result timeline is simply "seconds of audio fed this
    /// session" - supplying explicit per-buffer timestamps instead was
    /// tried and rejected by the OS (`SFSpeechErrorDomain 2: "Audio input
    /// timestamp overlaps or precedes prior audio input"`, because the
    /// converter's padding makes each converted buffer nominally overlap
    /// the next). So each session records the wall-clock moment its first
    /// sample was captured, and words map to absolute time as
    /// `anchor + range.seconds`.
    private var sessionAnchor: Date?

    private func setSessionAnchor(_ date: Date?) {
        lock.lock()
        sessionAnchor = date
        lock.unlock()
    }

    private func currentSessionAnchor() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return sessionAnchor
    }

    /// A capture gap longer than this ends the current analyzer session and
    /// starts a fresh one on the far side. Has to be tight, not generous:
    /// the anchor+cumulative mapping above is only truthful while the fed
    /// audio is contiguous - a swallowed gap would silently shift every
    /// later word by the gap's length. The segment writer already treats
    /// >2s delivery gaps as real discontinuities; previews follow suit.
    private static let gapRestartThreshold: TimeInterval = 2.5

    /// Sessions also rotate at the first natural pause after this age -
    /// insurance against unbounded recognizer state on an all-day
    /// recording, at a moment (≥1s of silence) where nothing is mid-word.
    private static let sessionRotationAge: TimeInterval = 30 * 60

    private enum SessionEnd {
        case feedEnded
        case gap
        case failed(Error)
    }

    private func run(_ feed: AsyncStream<Feed>) async {
        var iterator = feed.makeAsyncIterator()
        // A buffer read from the stream but belonging to the *next* session
        // (the one whose arrival revealed the gap).
        var carried: Feed?
        var consecutiveFailures = 0

        while true {
            let end = await runSession(iterator: &iterator, carried: &carried)
            switch end {
            case .feedEnded:
                return
            case .gap:
                consecutiveFailures = 0
                continue
            case .failed(let error):
                consecutiveFailures += 1
                previewLog.error("preview session failed (#\(consecutiveFailures)): \(error.localizedDescription, privacy: .public)")
                // Backoff so a persistently broken engine (asset yanked
                // mid-run, OS refusing sessions) doesn't spin: 2s, 10s,
                // then every 30s. Real audio keeps flowing into the stream
                // meanwhile; it is deliberately drained and dropped by the
                // sleep - previews of the past are not worth a backlog.
                let delay: TimeInterval = [2, 10][min(consecutiveFailures - 1, 1)] + (consecutiveFailures >= 3 ? 30 : 0)
                // Slept in slices so `finish()` isn't held open for the full
                // backoff - stopping previews has to be prompt even when the
                // engine underneath is unwell.
                let deadline = Date().addingTimeInterval(delay)
                while Date() < deadline, !isStopRequested() {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if isStopRequested() { return }
                while let next = await iterator.next() {
                    // Drop the backlog; keep the newest as the next
                    // session's first buffer. A bounded peek: stop draining
                    // the moment we're within one buffer of real time.
                    carried = next
                    if Date().timeIntervalSince(next.capturedAt) < 0.2 { break }
                }
                if carried == nil { return } // Stream ended while draining.
            }
        }
    }

    /// Runs one analyzer session until the feed ends, a capture gap demands
    /// a fresh session, or the analyzer fails.
    private func runSession(iterator: inout AsyncStream<Feed>.AsyncIterator, carried: inout Feed?) async -> SessionEnd {
        guard let locale = await Self.resolveLocale() else {
            return .failed(PreviewEngineError.noSupportedLocale)
        }
        await reserveIfNeeded(locale)

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            return .failed(PreviewEngineError.noAudioFormat)
        }

        let (inputStream, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        setSessionAnchor(nil)

        // Words arrive on this task while audio is still being fed below.
        // Results can only follow fed audio, so the session anchor is set
        // (by the feed loop, from the first buffer) before any result
        // could need it.
        let resultsTask = Task<Error?, Never> { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.handle(result)
                }
                return nil
            } catch {
                return error
            }
        }

        do {
            try await analyzer.start(inputSequence: inputStream)
        } catch {
            inputContinuation.finish()
            resultsTask.cancel()
            return .failed(error)
        }

        var converter: AVAudioConverter?
        var lastCapturedAt: Date?
        let sessionStartedAt = Date()
        var sessionEnd: SessionEnd = .feedEnded

        while true {
            let next: Feed?
            if let c = carried {
                carried = nil
                next = c
            } else {
                next = await iterator.next()
            }
            guard let next else {
                sessionEnd = .feedEnded
                break
            }

            if let last = lastCapturedAt {
                let gap = next.capturedAt.timeIntervalSince(last)
                let rotationDue = Date().timeIntervalSince(sessionStartedAt) > Self.sessionRotationAge
                if gap > Self.gapRestartThreshold || (rotationDue && gap > 1.0) {
                    carried = next
                    sessionEnd = .gap
                    break
                }
            }
            lastCapturedAt = next.capturedAt

            if converter == nil || converter?.inputFormat != next.buffer.format {
                converter = AVAudioConverter(from: next.buffer.format, to: analyzerFormat)
            }
            guard let converted = Self.convert(next.buffer, with: converter, to: analyzerFormat) else { continue }

            // Anchor: the wall-clock moment this session's audio began.
            // Capture stamps a buffer on arrival - i.e. at its *end* - so
            // the anchor backs off by one buffer length.
            if currentSessionAnchor() == nil {
                let bufferDuration = Double(next.buffer.frameLength) / next.buffer.format.sampleRate
                setSessionAnchor(next.capturedAt.addingTimeInterval(-bufferDuration))
            }
            inputContinuation.yield(AnalyzerInput(buffer: converted))
        }

        inputContinuation.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            resultsTask.cancel()
            if case .failed = sessionEnd { } else { sessionEnd = .failed(error) }
            return sessionEnd
        }
        if let resultsError = await resultsTask.value {
            return .failed(resultsError)
        }
        // A session ending always clears the provisional tail - whatever it
        // was going to say is either finalized by now or gone.
        emit(.volatile(""))
        return sessionEnd
    }

    // MARK: - Results

    private func handle(_ result: SpeechTranscriber.Result) {
        let text = result.text
        if !result.isFinal {
            emit(.volatile(String(text.characters)))
            return
        }

        // Result ranges are seconds-of-audio-fed-this-session; the anchor
        // turns them into wall-clock. No anchor means no audio was fed,
        // which means there is nothing this result could describe.
        guard let anchor = currentSessionAnchor() else { return }

        var words: [PreviewWord] = []
        for run in text.runs {
            guard let timeRange = run.audioTimeRange else { continue }
            let runText = String(text[run.range].characters)
            words.append(contentsOf: Self.splitIntoWords(
                runText,
                start: anchor.addingTimeInterval(timeRange.start.seconds),
                end: anchor.addingTimeInterval(timeRange.end.seconds)
            ))
        }
        guard !words.isEmpty else { return }
        emit(.words(words))
    }

    /// A run is usually one word, but nothing guarantees it - a multi-word
    /// run gets its words spread across the run's time range in proportion
    /// to their length. Approximate, and fine: these are previews.
    private static func splitIntoWords(_ text: String, start: Date, end: Date) -> [PreviewWord] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        if tokens.count == 1 {
            return [PreviewWord(start: start, end: end, text: tokens[0])]
        }
        let total = Double(tokens.reduce(0) { $0 + $1.count })
        let duration = end.timeIntervalSince(start)
        var cursor = 0.0
        return tokens.map { token in
            let fraction = Double(token.count) / max(total, 1)
            let wordStart = start.addingTimeInterval(duration * cursor)
            cursor += fraction
            let wordEnd = start.addingTimeInterval(duration * min(cursor, 1))
            return PreviewWord(start: wordStart, end: wordEnd, text: token)
        }
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter?,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 256
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var served = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            if served {
                inputStatus.pointee = .noDataNow
                return nil
            }
            served = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, converted.frameLength > 0 else { return nil }
        return converted
    }
}

enum PreviewEngineError: LocalizedError {
    case noSupportedLocale
    case noAudioFormat

    var errorDescription: String? {
        switch self {
        case .noSupportedLocale: return "No supported preview language."
        case .noAudioFormat: return "The transcriber offered no usable audio format."
        }
    }
}
