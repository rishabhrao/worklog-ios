import AVFoundation
import Foundation

/// Wraps `SegmentWriter` with everything the spec calls "session model":
/// interruption pause-resume (silent), auto-restart on capture error
/// (notifying), and pinned-device loss/restore handling (stop + warning,
/// then auto-resume - never falling back to another device).
///
/// This is an implementation detail of `RecordingController`; nothing
/// outside `Capture/` should talk to it directly.
final class RecordingSession {
    enum Phase {
        case stopped
        case active
        /// The system took the microphone away - a phone call, Siri, an
        /// alarm. The iOS counterpart of the macOS build's sleep pause: not
        /// an error, not the user's doing, and resumed automatically.
        case pausedForInterruption
        case warningDeviceUnavailable
        case warningMicPermissionDenied
    }

    private(set) var phase: Phase = .stopped
    private(set) var pinnedDeviceUID: String?

    /// Last-known display name of the pinned device, captured while it was
    /// still connected. `AudioDeviceRegistry.resolve` can't supply a name
    /// once the device has genuinely disconnected, so the loss notification
    /// needs this cached separately from the live lookup.
    private var pinnedDeviceLastKnownName: String?

    private var writer: SegmentWriter?
    private let locationTagger: LocationTagger
    private let deviceWatcher = AudioDeviceListWatcher()

    var onPhaseChanged: ((Phase) -> Void)?

    init(locationTagger: LocationTagger) {
        self.locationTagger = locationTagger
        deviceWatcher.start { [weak self] in self?.handleDeviceListChanged() }
    }

    /// Starts (or resumes) a session pinned to the given device UID. Persists
    /// recording-state truth eagerly, before doing anything else, so a crash
    /// immediately after this call still leaves an accurate crash-recovery
    /// trail.
    ///
    /// `persistsState: false` is for capture the user did not ask to *keep*
    /// running - today only a dictation briefly powering the mic on. Writing
    /// `isRecording: true` for those would make a crash mid-dictation
    /// auto-resume a full all-day recording on the next launch, complete
    /// with the "resumed after a crash" notification, for a session the user
    /// never started. The persisted flag must keep describing the user's
    /// actual recording intent, not a two-second mic borrow.
    func start(pinnedDeviceUID uid: String, persistsState: Bool = true) {
        self.pinnedDeviceUID = uid
        if persistsState {
            RecordingStateStore.save(isRecording: true, pinnedDeviceUID: uid)
        }
        beginCaptureOnPinnedDevice()
    }

    /// Explicit user stop (or Quit). Persists state before tearing down
    /// capture, same reasoning as `start`. `persistsState: false` pairs with
    /// the same flag on `start` - a dictation-owned session leaves the
    /// user's persisted recording intent exactly as it found it.
    func stop(persistsState: Bool = true) {
        if persistsState {
            RecordingStateStore.save(isRecording: false, pinnedDeviceUID: pinnedDeviceUID)
        }
        writer?.stop()
        writer = nil
        setPhase(.stopped)
    }

    // MARK: - Capture lifecycle

    private func beginCaptureOnPinnedDevice() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginCaptureOnAuthorizedPinnedDevice()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard granted else {
                        self.setPhase(.warningMicPermissionDenied)
                        WorklogNotifier.micPermissionDenied()
                        return
                    }
                    self.beginCaptureOnPinnedDevice()
                }
            }
        case .denied, .restricted:
            // Recording cannot proceed without mic permission. Distinct from
            // `.warningDeviceUnavailable` (a connectivity problem the app can
            // auto-resume from) - this needs the user to act in System
            // Settings, so it gets its own phase/notification rather than
            // silently staying idle (see guardrails: this was a real,
            // user-facing silent-failure gap found during Priority 8's audit).
            setPhase(.warningMicPermissionDenied)
            WorklogNotifier.micPermissionDenied()
        @unknown default:
            return
        }
    }

    private func beginCaptureOnAuthorizedPinnedDevice() {
        guard let uid = pinnedDeviceUID else { return }
        guard let device = AudioDeviceRegistry.resolve(uid: uid) else {
            // Pinned device not currently connected - enter warning, keep
            // pinnedDeviceUID set so the device-watcher can auto-resume the
            // instant it reappears.
            writer?.stop()
            writer = nil
            setPhase(.warningDeviceUnavailable)
            return
        }

        let newWriter = SegmentWriter(locationTagger: locationTagger)
        newWriter.onSegmentOpened = { [weak self] url, startedAt in
            self?.handleSegmentOpened(url, startedAt: startedAt)
        }
        newWriter.onSegmentClosed = { [weak self] url, locationTag in
            self?.handleSegmentClosed(url, locationTag: locationTag)
        }
        newWriter.onCaptureError = { [weak self] error in
            self?.handleCaptureError(error)
        }
        newWriter.onEngineWedged = { [weak self] in
            self?.handleEngineWedged()
        }
        newWriter.onInterruptionBegan = { [weak self] in
            self?.handleInterruptionBegan()
        }
        newWriter.onInterruptionEnded = { [weak self] in
            self?.handleInterruptionEnded()
        }

        do {
            try newWriter.start(device: device)
            writer = newWriter
            pinnedDeviceLastKnownName = device.name
            setPhase(.active)
        } catch {
            // Engine-configuration failure on a device that IS connected is
            // the "capture session itself errors" case - auto-restart, not
            // a device-loss warning.
            handleCaptureError(error)
        }
    }

    /// Closes the current segment and opens the next, gaplessly, on demand
    /// - so a playback/export that includes the currently-recording audio
    /// can read a finalized file instead of one with a stale header.
    /// Calls `completion` on the main queue (immediately if not recording).
    func forceRollover(completion: @escaping () -> Void) {
        guard let writer else {
            DispatchQueue.main.async(execute: completion)
            return
        }
        writer.forceRollover(completion: completion)
    }

    private func handleSegmentOpened(_ url: URL, startedAt: Date) {
        guard let uid = pinnedDeviceUID else { return }
        WorklogDatabase.shared.recordSegmentOpened(path: url, startedAt: startedAt, deviceUID: uid)
        // Stamp the location at open too, not only at close - a clip cut
        // from the currently-recording segment reads this row before the
        // segment ever closes, and the close-time upsert COALESCEs so an
        // open-stamp always survives.
        if let tag = locationTagger.currentTag() {
            WorklogDatabase.shared.updateSegmentLocationIfMissing(path: url.path, latitude: tag.latitude, longitude: tag.longitude)
        }
    }

    private func handleSegmentClosed(_ url: URL, locationTag: SegmentLocationTag?) {
        guard let uid = pinnedDeviceUID else { return }
        let startedAt = segmentStartTime(from: url) ?? Date()
        WorklogDatabase.shared.recordSegmentClosed(
            path: url,
            startedAt: startedAt,
            endedAt: Date(),
            deviceUID: uid,
            location: locationTag
        )

        // Peak-cache: compute once, right when the segment is finalized
        // (spec's own suggested approach), off the main queue since decoding
        // a 5-min file - while cheap - still shouldn't block capture setup.
        DispatchQueue.global(qos: .utility).async {
            let peaks = PeakComputer.computePeaks(for: url)
            guard !peaks.isEmpty else { return }
            WorklogDatabase.shared.storeSegmentPeaks(segmentPath: url.path, peaksPerSecond: PeakComputer.peaksPerSecond, peaks: peaks)
        }
    }

    /// Parses the segment's start time back out of its filename
    /// (`audio/YYYY-MM-DD/HHmm_ss.m4a`) rather than trusting wall-clock
    /// `Date()` at index-write time, which lags the true segment start by
    /// up to one rollover interval.
    private func segmentStartTime(from url: URL) -> Date? {
        let dayName = url.deletingLastPathComponent().lastPathComponent
        let stem = url.deletingPathExtension().lastPathComponent
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm_ss"
        formatter.timeZone = .current
        return formatter.date(from: "\(dayName) \(stem)")
    }

    // MARK: - Error auto-restart

    private var lastErrorNotifiedAt = Date.distantPast

    private func handleCaptureError(_ error: Error) {
        captureLog.error("capture error: \(error.localizedDescription, privacy: .public)")
        writer?.stop()
        writer = nil
        // Rate-limited: an error loop (e.g. engine refusing to start while
        // a route change is mid-flight) must not turn into notification
        // spam - one per 10 minutes tells the user everything spam would.
        if Date().timeIntervalSince(lastErrorNotifiedAt) > 600 {
            lastErrorNotifiedAt = Date()
            WorklogNotifier.errorAutoRestart()
        }
        // Retry immediately; if the device itself vanished between the
        // error and this retry, beginCaptureOnPinnedDevice will correctly
        // fall into the warning path instead of looping on a broken engine.
        beginCaptureOnPinnedDevice()
    }

    /// A route change (typically Bluetooth connect/disconnect) wedged the
    /// engine - the tap stopped delivering audio while everything still
    /// looked live. The only recovery that reliably works is a full writer
    /// replacement with a brand-new `AVAudioEngine` (an in-place rebuild of
    /// the same engine was tried and stayed silent). Routine and silent -
    /// per spec, Bluetooth events must never disturb the pinned session,
    /// so a sub-second self-heal doesn't notify. But if silence SURVIVES
    /// repeated replacements (something is holding the input hostage), the
    /// user gets one loud notification: the app must never eat audio
    /// quietly.
    private var lastWedgeRestartAt = Date.distantPast
    private var consecutiveWedgeRestarts = 0
    private var lastWedgeNotifiedAt = Date.distantPast

    private func handleEngineWedged() {
        guard phase == .active else { return }

        // Exponential backoff: if a replacement doesn't cure the silence
        // (something is genuinely holding the input hostage), retry on a
        // slowing cadence - 5s, 15s, 45s, then every 90s - instead of
        // churning writers/segments every few seconds. A quiet stretch of
        // 3+ minutes since the last wedge means the last recovery held, so
        // the backoff resets.
        let now = Date()
        if now.timeIntervalSince(lastWedgeRestartAt) > 180 {
            consecutiveWedgeRestarts = 0
        }
        let requiredGap: TimeInterval = [0, 5, 15, 45][min(consecutiveWedgeRestarts, 3)] + (consecutiveWedgeRestarts >= 4 ? 90 : 0)
        guard now.timeIntervalSince(lastWedgeRestartAt) >= requiredGap else { return }
        lastWedgeRestartAt = now
        consecutiveWedgeRestarts += 1

        captureLog.error("engine wedged (restart #\(self.consecutiveWedgeRestarts)) - replacing writer with a fresh engine")

        writer?.stop()
        writer = nil

        if consecutiveWedgeRestarts >= 3, now.timeIntervalSince(lastWedgeNotifiedAt) > 600 {
            lastWedgeNotifiedAt = now
            WorklogNotifier.inputWentSilent(deviceName: pinnedDeviceLastKnownName ?? "the pinned microphone")
        }

        beginCaptureOnPinnedDevice()
    }

    // MARK: - Pinned-device loss / restore

    private func handleDeviceListChanged() {
        guard let uid = pinnedDeviceUID else { return }
        let stillConnected = AudioDeviceRegistry.isConnected(uid: uid)

        switch (phase, stillConnected) {
        case (.active, false):
            let lostName = pinnedDeviceLastKnownName ?? "input device"
            writer?.stop()
            writer = nil
            setPhase(.warningDeviceUnavailable)
            WorklogNotifier.pinnedDeviceLost(deviceName: lostName)

        case (.warningDeviceUnavailable, true):
            // Device is authorized already (we were actively recording on it
            // before it disconnected), so this resolves synchronously.
            let restoredName = AudioDeviceRegistry.resolve(uid: uid)?.name ?? "input device"
            beginCaptureOnPinnedDevice()
            if phase == .active {
                WorklogNotifier.pinnedDeviceRestored(deviceName: restoredName)
            }

        default:
            // Some other device connected/disconnected - per spec this must
            // never affect a session bound to the pinned UID.
            break
        }
    }

    // MARK: - Interruption (silent - never notify)

    /// A phone call, Siri, or an alarm has taken the input. The system has
    /// already stopped delivering audio, so the writer is torn down to close
    /// the segment cleanly rather than leaving a file that stops mid-header.
    private func handleInterruptionBegan() {
        guard phase == .active else { return }
        writer?.stop()
        writer = nil
        setPhase(.pausedForInterruption)
    }

    /// The call ended. Come back on the same pinned device.
    ///
    /// The retry loop exists because iOS frequently refuses to reactivate the
    /// session on the first attempt - the previous owner has not finished
    /// releasing it, and `setActive` fails with `!act`. Giving up there would
    /// silently end an all-day recording at the first incoming call, which is
    /// exactly the "stops silently" failure the app exists to prevent.
    private func handleInterruptionEnded(attempt: Int = 0) {
        guard phase == .pausedForInterruption else { return }
        beginCaptureOnPinnedDevice()
        guard phase != .active, attempt < 6 else { return }
        let delay = pow(2.0, Double(attempt)) * 0.25
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.handleInterruptionEnded(attempt: attempt + 1)
        }
    }

    /// Called when the app returns to the foreground. Recording is supposed
    /// to survive backgrounding outright, but if anything did knock it over
    /// while we could not see it, this is the moment to notice and recover.
    func resumeIfInterrupted() {
        guard phase == .pausedForInterruption else { return }
        handleInterruptionEnded()
    }

    private func setPhase(_ newPhase: Phase) {
        phase = newPhase
        onPhaseChanged?(newPhase)
    }

    deinit {
        deviceWatcher.stop()
    }
}
