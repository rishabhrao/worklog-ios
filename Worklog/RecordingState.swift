import AVFoundation
import Foundation

/// Published state of the recording controller. The status bar above the tab
/// bar, the Clip screen's controls, and the notification all read from this
/// single source of truth - never let two components independently track
/// "are we recording."
enum RecordingState {
    case idle
    case recording
    case warningDeviceUnavailable
    case warningMicPermissionDenied
    case paused
}

/// Extensible trigger-source enum. `manual`, `crashRecovery` and
/// `dictation` are wired today; `timeBased`/`locationBased`/`wifiBased` are
/// future sources the architecture must not block (ticket §9) - adding one
/// later means adding a case and a call site, not reshaping the controller.
enum TriggerSource {
    case manual
    case crashRecovery
    /// A push-to-talk dictation briefly powering the mic on because the
    /// user held the dictation hotkey while recording was idle.
    case dictation
}

/// Outcome of a dictation asking for capture. Distinguishes "capture was
/// already running" from "we turned it on for you" because only the latter
/// has to be turned back off when the dictation ends - and separates both
/// from the refusals, which carry copy the user can act on rather than
/// failing silently.
enum DictationCaptureStart {
    /// The user was already recording; the dictation just reads from it.
    case alreadyRecording
    /// Capture was idle and has been started solely for this dictation.
    case startedForDictation
    /// Capture cannot run right now. The string is user-facing.
    case unavailable(String)
}

/// The single source of truth for "should we be recording right now."
/// All start/stop flows through this object; it owns a `RecordingSession`
/// (sleep/wake, error-restart, device-loss handling) and the pinned-device
/// UID, and publishes `state` for the menu bar and any in-window indicator.
final class RecordingController: ObservableObject {
    @Published private(set) var state: RecordingState = .idle

    /// When the current run of capture began, for the elapsed readout in the
    /// status bar. Survives a segment rollover and an interruption pause -
    /// what it measures is "how long have you been recording", not "how old
    /// is this file".
    @Published private(set) var sessionStartedAt: Date?

    private let session: RecordingSession

    /// Exposed (not private) so Settings can read authorization status and
    /// toggle updates from the one instance actually feeding raw-segment
    /// tags - never a second `LocationTagger` instance.
    let locationTagger = LocationTagger()

    /// Persisted pinned device UID. Onboarding/Settings (Priority 7) write
    /// this; Priority 1 only needs to read and act on it.
    var pinnedDeviceUID: String? {
        didSet { UserDefaults.standard.set(pinnedDeviceUID, forKey: Self.pinnedDeviceDefaultsKey) }
    }

    private static let pinnedDeviceDefaultsKey = "worklog.pinnedDeviceUID"

    init() {
        pinnedDeviceUID = UserDefaults.standard.string(forKey: Self.pinnedDeviceDefaultsKey)
        session = RecordingSession(locationTagger: locationTagger)

        session.onPhaseChanged = { [weak self] phase in
            guard let self else { return }
            let newState = Self.mapPhase(phase)
            switch newState {
            case .recording, .paused:
                if self.sessionStartedAt == nil { self.sessionStartedAt = Date() }
            case .idle:
                self.sessionStartedAt = nil
            case .warningDeviceUnavailable, .warningMicPermissionDenied:
                // A warning is still an active session as far as the user is
                // concerned - it resumes on its own - so the clock keeps running.
                break
            }
            self.state = newState
        }

        WorklogNotifier.requestAuthorizationIfNeeded()
        // Per explicit user request, ask for microphone and location
        // permission at app launch too, alongside notifications - no
        // longer deferred to the first "Start Recording"/Settings-toggle
        // interaction. Both underlying APIs are no-ops once authorization
        // has already been decided (granted/denied), so this is safe to
        // call unconditionally on every launch, not just the first.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        locationTagger.requestPermissionIfNeeded()
        locationTagger.startUpdatingIfAuthorized()
        // A fix can arrive minutes after launch - stamp it onto the segment
        // being recorded right now, so even the first post-launch segments
        // get tagged instead of only ones that open after the fix landed.
        locationTagger.onFix = { tag in
            guard let activePath = LivePeakStore.shared.currentActivePath else { return }
            WorklogDatabase.shared.updateSegmentLocationIfMissing(path: activePath, latitude: tag.latitude, longitude: tag.longitude)
        }
        // Enumerating inputs needs a configured session, and Settings and
        // onboarding both list devices before anything has recorded.
        AudioDeviceRegistry.prepareSession()

        attemptCrashRecovery()
    }

    /// The app came back to the foreground. iOS can knock capture over while
    /// the app is not watching (a call that ends in another app, a media
    /// services reset); this is the first moment we can notice and repair it.
    func applicationDidBecomeActive() {
        session.resumeIfInterrupted()
    }

    /// Toggle from a given trigger source. `crashRecovery` is only ever
    /// invoked internally at launch (see `attemptCrashRecovery`); menu-bar
    /// clicks always pass `.manual`.
    func toggle(source: TriggerSource = .manual) {
        switch state {
        case .recording, .paused, .warningDeviceUnavailable, .warningMicPermissionDenied:
            // Manual stop is self-evident to the user - RecordingSession.stop()
            // never notifies, which is correct for both manual and this path.
            session.stop()
        case .idle:
            guard let uid = pinnedDeviceUID else { return }
            // Re-arm location updates on every recording start, not just
            // once at app launch - CLLocationManager updates were observed
            // to silently stop arriving after a long-running session (no
            // location tags captured for 11+ hours despite permission
            // granted, the Settings toggle on, and repeated app relaunches
            // in between), so start is the moment it actually matters most
            // to have a fresh fix, not just app-launch time.
            locationTagger.startUpdatingIfAuthorized()
            session.start(pinnedDeviceUID: uid)
        }
    }

    /// Called by Settings/onboarding's device picker. Persists the new
    /// pinned UID immediately (so it's honored on the next Start even if
    /// currently idle) and, if a session is already active/warning, restarts
    /// capture onto the new device right away rather than silently
    /// continuing on the old one until the next manual stop/start.
    func selectDevice(uid: String) {
        pinnedDeviceUID = uid
        switch state {
        case .recording, .warningDeviceUnavailable, .warningMicPermissionDenied:
            session.stop()
            session.start(pinnedDeviceUID: uid)
        case .paused, .idle:
            break
        }
    }

    // MARK: - Dictation capture

    /// True while capture is running *only* because a dictation asked for
    /// it - the flag that decides whether ending a dictation stops the mic
    /// or merely rolls the segment over.
    private var isDictationOwnedCapture = false

    /// Ensures the mic is live for a dictation that is starting right now.
    ///
    /// When the user is already recording this is a no-op and the dictation
    /// simply reads out of the ongoing recording. When idle, capture starts
    /// for the dictation alone - deliberately without persisting
    /// "isRecording", so a crash mid-dictation can't resurrect a full
    /// recording session the user never asked for (see
    /// `RecordingSession.start(pinnedDeviceUID:persistsState:)`).
    func beginDictationCapture() -> DictationCaptureStart {
        switch state {
        case .recording:
            return .alreadyRecording
        case .warningDeviceUnavailable:
            return .unavailable("Your pinned microphone isn't connected. Reconnect it or pick another in Settings.")
        case .warningMicPermissionDenied:
            return .unavailable("Worklog doesn't have microphone access. Grant it in Settings › Worklog › Microphone.")
        case .paused:
            return .unavailable("Recording is paused - something else is using the microphone.")
        case .idle:
            guard let uid = pinnedDeviceUID else {
                return .unavailable("No microphone is pinned yet. Choose one in Settings.")
            }
            locationTagger.startUpdatingIfAuthorized()
            isDictationOwnedCapture = true
            session.start(pinnedDeviceUID: uid, persistsState: false)
            // `session.start` can land in a warning phase (device vanished
            // between the check above and the actual open), in which case
            // nothing is capturing and the dictation must not proceed.
            guard state == .recording else {
                isDictationOwnedCapture = false
                session.stop(persistsState: false)
                return .unavailable("Couldn't start the microphone for dictation.")
            }
            return .startedForDictation
        }
    }

    /// Makes the dictation's audio readable on disk and hands control back.
    ///
    /// If the dictation owns capture, stopping the session finalizes the
    /// segment. Otherwise the user's recording continues and only needs a
    /// gapless rollover so the just-spoken audio is in a closed file. Either
    /// way `completion` fires on the main queue once the audio is readable.
    func endDictationCapture(completion: @escaping () -> Void) {
        if isDictationOwnedCapture {
            isDictationOwnedCapture = false
            session.stop(persistsState: false)
            DispatchQueue.main.async(execute: completion)
        } else {
            forceRollover(completion: completion)
        }
    }

    /// Ends dictation-owned capture without making its audio readable -
    /// for a discarded dictation, where nothing will ever read it. A user
    /// recording that was already running is left completely untouched: no
    /// rollover, no extra segment file for audio nobody asked to keep.
    func abandonDictationCapture() {
        guard isDictationOwnedCapture else { return }
        isDictationOwnedCapture = false
        session.stop(persistsState: false)
    }

    /// Rolls the current segment over (close + reopen, gapless) so audio
    /// recorded up to this moment becomes fully readable on disk. No-op
    /// (completion fires immediately) when not recording.
    func forceRollover(completion: @escaping () -> Void) {
        switch state {
        case .recording:
            session.forceRollover(completion: completion)
        case .idle, .paused, .warningDeviceUnavailable, .warningMicPermissionDenied:
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// Closes out the current segment cleanly when the process is going away
    /// on purpose - a manual stop (no notification), so the session is not
    /// left with an unclosed `.m4a`. On iOS the system rarely gives an app
    /// this courtesy, which is why `StartupReconciliation` repairs open rows
    /// on the next launch regardless.
    func stopForQuit() {
        guard state != .idle else { return }
        session.stop()
    }

    /// A normal fresh launch (including at login) starts idle and does not
    /// auto-record. The sole exception: the persisted state confidently
    /// says we were recording when last seen (crash/force-quit/reboot),
    /// in which case we auto-resume and fire a high-priority notification.
    /// Ambiguous/undeterminable state stays idle - never falsely "resumed."
    private func attemptCrashRecovery() {
        guard let persisted = RecordingStateStore.load() else { return }
        guard persisted.isRecording, let uid = persisted.pinnedDeviceUID else { return }

        pinnedDeviceUID = uid
        session.start(pinnedDeviceUID: uid)
        WorklogNotifier.crashRecoveryResumed()
    }

    private static func mapPhase(_ phase: RecordingSession.Phase) -> RecordingState {
        switch phase {
        case .stopped: return .idle
        case .active: return .recording
        case .pausedForInterruption: return .paused
        case .warningDeviceUnavailable: return .warningDeviceUnavailable
        case .warningMicPermissionDenied: return .warningMicPermissionDenied
        }
    }
}
