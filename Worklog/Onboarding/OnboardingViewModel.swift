import AVFoundation
import Combine
import Foundation

/// Whether first-run onboarding has ever completed. Persisted in
/// `UserDefaults` (not `settings.json` - this is app-launch bookkeeping, not
/// user-facing data) so onboarding appears exactly once, per spec.
enum OnboardingState {
    private static let defaultsKey = "worklog.onboardingCompleted"

    static var hasCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}

/// Drives the two-step first-run flow (spec `08-settings-and-onboarding.md`,
/// ticket §5.7): choose an input device, then grant microphone permission.
/// Location permission and API keys are deliberately not asked here - both
/// are optional and deferred to Settings. Handles permission denial
/// gracefully: the flow still completes, with a plain explanation of what's
/// limited and how to fix it later.
@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step {
        case chooseDevice
        case microphonePermission
        case done
    }

    @Published private(set) var step: Step = .chooseDevice
    @Published private(set) var availableDevices: [AudioInputDevice] = []
    @Published var selectedDeviceUID: String?
    @Published private(set) var micAuthorizationStatus: AVAuthorizationStatus

    private let recordingController: RecordingController

    init(recordingController: RecordingController) {
        self.recordingController = recordingController
        micAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        refreshDevices()
        selectedDeviceUID = availableDevices.first?.uid
    }

    func refreshDevices() {
        availableDevices = AudioDeviceRegistry.inputDevices()
        if selectedDeviceUID == nil {
            selectedDeviceUID = availableDevices.first?.uid
        }
    }

    var canContinueFromDeviceStep: Bool {
        selectedDeviceUID != nil
    }

    func confirmDeviceChoice() {
        guard let uid = selectedDeviceUID else { return }
        recordingController.selectDevice(uid: uid)
        step = .microphonePermission
    }

    /// Requests mic permission if undetermined; if already decided
    /// (granted or denied), just reflects the real status so the UI never
    /// dead-ends waiting on a prompt that will never show.
    func requestMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.micAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                }
            }
        default:
            micAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    func finish() {
        OnboardingState.hasCompleted = true
        step = .done
    }
}
