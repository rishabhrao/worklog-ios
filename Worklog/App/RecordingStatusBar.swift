import SwiftUI

extension View {
    /// Pins the recording status bar directly above the tab bar.
    ///
    /// Applied to each tab's content rather than around the `TabView`,
    /// because a `TabView` draws its own bar at its bottom edge - wrapping it
    /// in a `VStack` puts the status bar *below* the tabs, which reads as a
    /// stray toolbar rather than as part of the app's chrome. Insetting the
    /// content is also what keeps scroll views from running underneath it.
    func withRecordingStatusBar() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { RecordingStatusBar() }
    }
}

/// The always-visible recording status and Start/Stop control - the iOS
/// counterpart of the macOS menu-bar icon and the Android build's bar of the
/// same name. It sits directly above the tab bar so "is it recording?" is
/// answerable at a glance from anywhere in the app, which for an always-on
/// recorder is the single most important thing on screen.
struct RecordingStatusBar: View {
    @EnvironmentObject private var controller: RecordingController

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.worklogHairline)
            HStack(spacing: 12) {
                StatusDot(state: controller.state)

                VStack(alignment: .leading, spacing: 1) {
                    Text(headline)
                        .font(WorklogFont.labelStrong)
                        .foregroundStyle(headlineColor)
                    Group {
                        if controller.state == .recording, let startedAt = controller.sessionStartedAt {
                            ElapsedReadout(startedAt: startedAt)
                        } else {
                            Text(subhead)
                        }
                    }
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)
                }

                Spacer(minLength: 8)

                Button(controller.state == .idle ? "Start" : "Stop") {
                    WorklogHaptics.play(controller.state == .idle ? .success : .toggle)
                    controller.toggle(source: .manual)
                }
                .buttonStyle(.borderedProminent)
                .tint(controller.state == .idle ? Color.accentColor : Color.worklogRecording)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.worklogSurface)
        }
        .animation(MotionPrimitives.aware(MotionPrimitives.standard), value: controller.state)
    }

    private var headline: String {
        switch controller.state {
        case .idle: return "Not recording"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .warningDeviceUnavailable, .warningMicPermissionDenied: return "NOT recording"
        }
    }

    private var headlineColor: Color {
        switch controller.state {
        case .warningDeviceUnavailable, .warningMicPermissionDenied: return .worklogWarning
        default: return .worklogTextPrimary
        }
    }

    private var subhead: String {
        switch controller.state {
        case .idle: return "Your work day isn't being captured"
        case .recording: return ""
        case .paused: return "Something else is using the microphone"
        case .warningDeviceUnavailable: return "Pinned mic unavailable - resumes when it returns"
        case .warningMicPermissionDenied: return "Microphone permission needed"
        }
    }
}

/// The living indicator: a gentle pulse while recording, steady otherwise.
private struct StatusDot: View {
    let state: RecordingState
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .opacity(state == .recording && isPulsing ? 0.45 : 1)
            .animation(
                state == .recording ? MotionPrimitives.aware(MotionPrimitives.livePulse) : nil,
                value: isPulsing
            )
            .onAppear { isPulsing = true }
            .animation(MotionPrimitives.aware(MotionPrimitives.standard), value: color)
    }

    private var color: Color {
        switch state {
        case .recording: return .worklogRecording
        case .paused: return .worklogWarning
        case .warningDeviceUnavailable, .warningMicPermissionDenied: return .worklogWarning
        case .idle: return .worklogTextTertiary
        }
    }
}

/// Live `H:MM:SS` elapsed readout, ticking once a second.
private struct ElapsedReadout: View {
    let startedAt: Date
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(formatted)
            .monospacedDigit()
            .onReceive(tick) { now = $0 }
    }

    private var formatted: String {
        let total = max(0, Int(now.timeIntervalSince(startedAt)))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
