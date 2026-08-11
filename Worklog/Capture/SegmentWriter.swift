import Accelerate
import AVFoundation
import Foundation
import os

/// Capture-path diagnostics, readable via:
/// `log show --predicate 'subsystem == "com.rishabhrao.worklog"' --last 10m`
let captureLog = Logger(subsystem: "com.rishabhrao.worklog", category: "capture")

enum SegmentWriterError: Error {
    case deviceNotFound
    case engineConfigurationFailed(Error)
    case sessionFailedToStart
}

/// Captures audio from the pinned input and writes rolling 5-minute `.m4a`
/// (AAC, mono, ~64kbps) segments with no gap between files.
///
/// Capture substrate: `AVAudioEngine` with an input tap, and the pin
/// expressed through `AVAudioSession.setPreferredInput`. This is the exact
/// opposite of the macOS build, which had to use `AVCaptureSession` because
/// there the engine's input node chases the system default device and fights
/// any attempt to hold it. On iOS the audio session *is* the routing
/// authority: a preferred input set on the shared session is honoured for the
/// whole app, the engine's input node follows it, and a headset connecting
/// raises a route-change notification the session handles deliberately rather
/// than a silent switch. `AVCaptureSession` would additionally be the wrong
/// tool here - it is not guaranteed to keep running once the app leaves the
/// foreground, and an all-day recorder that stops when the screen locks is
/// worthless.
///
/// Gapless rollover strategy: segment N+1's `AVAudioFile` is opened and
/// ready *before* segment N is closed. The tap callback keeps writing into
/// whichever file is currently "active"; rollover swaps the active file
/// reference and closes the old one, so no audio buffer is ever dropped
/// between files.
final class SegmentWriter {
    private let segmentDuration: TimeInterval = 5 * 60

    private let engine = AVAudioEngine()
    private let writeQueue = DispatchQueue(label: "worklog.segmentwriter.write")

    private var activeFile: AVAudioFile?
    private var activeFileURL: URL?
    private var segmentStartedAt: Date?
    private var rolloverTimer: DispatchSourceTimer?
    private var isRunning = false

    /// Every segment file is written in this one canonical format,
    /// regardless of what the hardware delivers - device formats (e.g.
    /// Bluetooth-era re-clocked rates) must never leak into files.
    private static let canonicalFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!

    /// Converts delivered buffers to `canonicalFormat` when they differ;
    /// rebuilt whenever the delivered format changes. Only touched on
    /// `writeQueue`.
    private var inputConverter: AVAudioConverter?

    /// The device this writer is pinned to - capture binds to it by UID
    /// and never follows the system default.
    private var pinnedDevice: AudioInputDevice?

    /// Watchdog state: the tap timestamps every buffer and every buffer
    /// containing actual signal (a live mic always has a nonzero noise
    /// floor). Sustained starvation or pure digital silence escalates to a
    /// full writer replacement. All on `writeQueue`.
    private var watchdogTimer: DispatchSourceTimer?
    private var lastBufferAt = Date()
    private var lastSignalAt = Date()
    private var lastEscalationAt = Date.distantPast

    private var observers: [NSObjectProtocol] = []

    /// Fired on the main queue when capture is wedged (sustained buffer
    /// starvation or digital silence) - the session responds by discarding
    /// this writer and starting a fresh one on the pinned device.
    var onEngineWedged: (() -> Void)?

    private let locationTagger: LocationTagger?

    /// Called on the main queue whenever a segment closes, with the URL and
    /// the location tag captured at close time (nil if location was
    /// unavailable) - used by `RecordingSession` to persist segment
    /// bookkeeping.
    var onSegmentClosed: ((URL, SegmentLocationTag?) -> Void)?

    /// Called on the main queue the moment a new segment file is opened
    /// (before any audio has been written to it) - lets `RecordingSession`
    /// index it immediately with a NULL `ended_at`, so the
    /// currently-recording segment is queryable right away.
    var onSegmentOpened: ((URL, Date) -> Void)?

    /// Called on the main queue on capture runtime errors - the recording
    /// session catches this and auto-restarts per spec.
    var onCaptureError: ((Error) -> Void)?

    init(locationTagger: LocationTagger?) {
        self.locationTagger = locationTagger
    }

    /// Starts capture bound to the given resolved device. Throws if the
    /// session can't be configured; never falls back to another device.
    func start(device: AudioInputDevice) throws {
        stop()

        pinnedDevice = device

        let session = AVAudioSession.sharedInstance()
        do {
            // `.mixWithOthers` matters for an app that records all day: the
            // user's music or podcast must not stop the moment Worklog starts.
            // `.defaultToSpeaker` keeps playback out of the earpiece, which
            // `.playAndRecord` would otherwise choose.
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
            )
            try session.setActive(true, options: [])
            try AudioDeviceRegistry.applyPreferredInput(device)
        } catch {
            throw SegmentWriterError.engineConfigurationFailed(error)
        }

        // Read the format only after the preferred input has been applied -
        // before that the input node can still be describing the previous
        // route, and a tap installed with a stale format silently delivers
        // nothing.
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            captureLog.error("input node reported an unusable format: \(hardwareFormat, privacy: .public)")
            throw SegmentWriterError.deviceNotFound
        }

        do {
            try openNewSegment(format: Self.canonicalFormat)
        } catch {
            throw SegmentWriterError.engineConfigurationFailed(error)
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            // The tap runs on a realtime audio thread. Copy off it and get
            // out: file writes and database work must never happen here.
            guard let copy = Self.copy(buffer) else { return }
            self?.writeQueue.async { self?.write(buffer: copy) }
        }

        installObservers()

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            writeQueue.sync { closeActiveFile() }
            throw SegmentWriterError.engineConfigurationFailed(error)
        }

        captureLog.info("capture engine started: device \(device.name, privacy: .public) uid \(device.uid, privacy: .public) hardware \(hardwareFormat.sampleRate, privacy: .public)Hz ch\(hardwareFormat.channelCount) → canonical \(Self.canonicalFormat.sampleRate, privacy: .public)Hz mono")

        isRunning = true
        writeQueue.async { [weak self] in
            let now = Date()
            self?.lastBufferAt = now
            self?.lastSignalAt = now
        }
        scheduleRollover()
        scheduleWatchdog()
    }

    /// Stops capture and closes the current segment cleanly. Safe to call
    /// even if not running.
    func stop() {
        rolloverTimer?.cancel()
        rolloverTimer = nil
        watchdogTimer?.cancel()
        watchdogTimer = nil
        removeObservers()

        guard isRunning else { return }
        isRunning = false

        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }

        writeQueue.sync {
            closeActiveFile()
        }
    }

    deinit {
        removeObservers()
    }

    /// The tap's buffer is owned by the audio thread and reused; anything
    /// handed to another queue has to be a copy.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for channel in 0..<channels {
                memcpy(dst[channel], src[channel], frames * MemoryLayout<Float>.size)
            }
            return copy
        }
        if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for channel in 0..<channels {
                memcpy(dst[channel], src[channel], frames * MemoryLayout<Int16>.size)
            }
            return copy
        }
        return nil
    }

    // MARK: - Resilience

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        // A route change that the session did not ask for (the pinned device
        // being unplugged, a call ending on a different route) can leave the
        // engine running against nothing. Re-assert the pin; if the device is
        // genuinely gone the recording session's own watcher handles it.
        observers.append(
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.isRunning, let device = self.pinnedDevice else { return }
                try? AudioDeviceRegistry.applyPreferredInput(device)
            }
        )

        // The engine has been reconfigured underneath us (sample rate change,
        // hardware swap). The tap's format no longer matches, so the only
        // reliable recovery is a full writer replacement - the same escalation
        // the watchdog uses.
        observers.append(
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                guard let self, self.isRunning else { return }
                captureLog.info("engine configuration changed - replacing writer")
                self.onEngineWedged?()
            }
        )

        // Phone calls, Siri, alarms. `.began` is a hard stop imposed by the
        // system; `.ended` with `.shouldResume` is our cue to come back. This
        // is the iOS analogue of the macOS build's sleep/wake pause, and like
        // it, it is silent - the user did not do anything wrong.
        observers.append(
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, self.isRunning else { return }
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    captureLog.info("audio session interrupted")
                    self.onInterruptionBegan?()
                case .ended:
                    let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:))
                    captureLog.info("audio session interruption ended (shouldResume=\(options?.contains(.shouldResume) ?? false))")
                    self.onInterruptionEnded?()
                @unknown default:
                    break
                }
            }
        )
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    /// Called on the main queue when the system takes the microphone away
    /// (a phone call) and hands it back.
    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: (() -> Void)?

    /// Last-resort escalation - full writer replacement by the session.
    /// Runs on `writeQueue`.
    private func escalateWedge() {
        guard isRunning else { return }
        guard Date().timeIntervalSince(lastEscalationAt) > 15 else { return }
        lastEscalationAt = Date()
        DispatchQueue.main.async { [weak self] in
            self?.onEngineWedged?()
        }
    }

    /// Buffers absent for 10s, or pure digital silence for 10s (a real mic
    /// always has a nonzero noise floor), escalate. This is the net that
    /// catches wedges nothing else names - on iOS the common one is another
    /// app grabbing the input and leaving our tap alive but mute.
    private func scheduleWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: writeQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else { return }
            let now = Date()
            let starved = now.timeIntervalSince(self.lastBufferAt) > 10
            let allZeros = now.timeIntervalSince(self.lastSignalAt) > 10
            if starved || allZeros {
                captureLog.error("watchdog escalation: starved=\(starved) allZeros=\(allZeros) engineRunning=\(self.engine.isRunning) sinceBuffer=\(now.timeIntervalSince(self.lastBufferAt), format: .fixed(precision: 1))s sinceSignal=\(now.timeIntervalSince(self.lastSignalAt), format: .fixed(precision: 1))s")
                self.escalateWedge()
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    // MARK: - Segment lifecycle

    private func scheduleRollover() {
        let timer = DispatchSource.makeTimerSource(queue: writeQueue)
        timer.schedule(deadline: .now() + segmentDuration, repeating: segmentDuration)
        timer.setEventHandler { [weak self] in
            self?.rollover()
        }
        timer.resume()
        rolloverTimer = timer
    }

    /// Opens the next segment file before closing the current one, so the
    /// tap callback never has a moment with no valid file to write into.
    private func rollover() {
        guard let format = activeFile?.processingFormat else { return }
        let previousFile = activeFile
        let previousURL = activeFileURL

        do {
            try openNewSegment(format: format)
        } catch {
            reportError(error)
            return
        }

        if let previousFile, let previousURL {
            finalizeSegment(previousFile, url: previousURL)
        }
    }

    /// Opens a new segment file and makes it the active write target.
    private func openNewSegment(format: AVAudioFormat) throws {
        let startedAt = Date()
        try WorklogPaths.ensureRecordingsRootExists()
        let dayFolder = WorklogPaths.dayFolder(for: startedAt)
        try FileManager.default.createDirectory(at: dayFolder, withIntermediateDirectories: true)

        let fileName = WorklogPaths.segmentFileName(for: startedAt)
        let url = dayFolder.appendingPathComponent(fileName)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]

        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)

        activeFile = file
        activeFileURL = url
        segmentStartedAt = startedAt
        LivePeakStore.shared.beginSegment(path: url.path, sampleRate: format.sampleRate)

        DispatchQueue.main.async { [weak self] in
            self?.onSegmentOpened?(url, startedAt)
        }
    }

    private func write(buffer: AVAudioPCMBuffer) {
        let now = Date()
        // A real delivery gap must become an inter-segment gap: segments
        // are positioned on the timeline by their start time, so writing
        // post-gap audio into the pre-gap file would silently compress the
        // dead time out of the timeline.
        if now.timeIntervalSince(lastBufferAt) > 2 {
            captureLog.info("buffer gap of \(now.timeIntervalSince(self.lastBufferAt), format: .fixed(precision: 1))s - rolling to a fresh segment")
            rollover()
        }
        lastBufferAt = now
        if bufferHasSignal(buffer) {
            lastSignalAt = now
        }

        guard let file = activeFile else { return }
        guard let canonical = convertToCanonical(buffer) else { return }

        // Broadcast before the file write, not after: a live transcription is
        // consuming this audio, and a disk error must not also silence the
        // user's dictation mid-sentence. The two consumers are independent;
        // neither should be able to starve the other.
        if LiveAudioTap.shared.isActive {
            LiveAudioTap.shared.broadcast(canonical)
        }

        do {
            try file.write(from: canonical)
            // Feed the live waveform straight from the tap - the on-disk
            // file's header is only updated occasionally by the writer, so
            // readers can't see fresh audio there.
            LivePeakStore.shared.append(buffer: canonical)
        } catch {
            reportError(error)
        }
    }

    /// Fast-path pass-through when the delivered buffer already matches
    /// the canonical format; conversion otherwise. On iOS the hardware
    /// commonly delivers 48kHz mono float already, so the fast path is the
    /// steady state - but a Bluetooth HFP route drops to 16kHz, and that
    /// must not change the format of files on disk.
    /// Runs on `writeQueue`.
    private func convertToCanonical(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let canonical = Self.canonicalFormat
        if buffer.format.sampleRate == canonical.sampleRate,
           buffer.format.channelCount == canonical.channelCount,
           buffer.format.commonFormat == canonical.commonFormat {
            return buffer
        }

        if inputConverter?.inputFormat != buffer.format {
            inputConverter = AVAudioConverter(from: buffer.format, to: canonical)
            captureLog.info("input converter (re)built: \(buffer.format.sampleRate, privacy: .public)Hz ch\(buffer.format.channelCount) → canonical")
        }
        guard let converter = inputConverter else { return nil }

        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * canonical.sampleRate / buffer.format.sampleRate) + 256
        guard let converted = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: capacity) else { return nil }
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

    /// True if any sample in channel 0 is nonzero. A live microphone's
    /// noise floor guarantees signal; sustained exact zeros mean the
    /// device is feeding us nothing (see the watchdog). Treats non-float
    /// buffers as having signal rather than risking false wedge detection.
    private func bufferHasSignal(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return true }
        var peak: Float = 0
        vDSP_maxmgv(channels[0], 1, &peak, vDSP_Length(buffer.frameLength))
        return peak > 0
    }

    private func closeActiveFile() {
        guard let file = activeFile, let url = activeFileURL else { return }
        finalizeSegment(file, url: url)
        activeFile = nil
        activeFileURL = nil
    }

    private func finalizeSegment(_ file: AVAudioFile, url: URL) {
        LivePeakStore.shared.endSegment(path: url.path)
        let tag = locationTagger?.currentTag()
        // Strong `self` on purpose. `RecordingSession.stop()` calls
        // `writer.stop()` and then immediately drops its reference, so a
        // `[weak self]` capture here is already nil by the time the main
        // queue runs this - the close callback never fires and the segment's
        // row is left with `ended_at IS NULL` forever (until the next
        // launch's reconciliation quietly repairs it). That went unnoticed
        // while it only affected the last segment of a long recording;
        // dictation stops capture after every few seconds, so it leaked a
        // permanently-open row per dictation.
        //
        // This retains the writer only until the block runs on the next main
        // queue turn, and the block isn't stored anywhere, so there's no cycle.
        DispatchQueue.main.async {
            self.onSegmentClosed?(url, tag)
        }
    }

    /// Closes the current segment and immediately opens the next one, on
    /// demand - same gapless mechanism as the periodic 5-minute rollover.
    /// Used before playing back or exporting a range that includes the
    /// currently-recording segment. `completion` fires on the main queue
    /// after the old segment has been finalized and handed to
    /// `onSegmentClosed`.
    func forceRollover(completion: @escaping () -> Void) {
        writeQueue.async { [weak self] in
            guard let self, self.isRunning else {
                DispatchQueue.main.async(execute: completion)
                return
            }
            self.rollover()
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func reportError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onCaptureError?(error)
        }
    }
}
