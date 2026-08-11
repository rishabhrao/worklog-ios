import SwiftUI

/// Sidebar recording control: status pill (same state/label/color logic as
/// the toolbar's `RecordingStatusIndicator`) plus a Start/Stop button
/// directly beneath it, so recording can be controlled from inside the app
/// without needing the menu-bar item - per explicit user request to move
/// the status badge into the sidebar and let it double as a control.
struct RecordingControlCard: View {
    @ObservedObject var recordingController: RecordingController

    @State private var isHovering = false
    @State private var isPressing = false

    var body: some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.sm) {
            HStack(spacing: WorklogSpacing.xs) {
                indicatorDot
                Text(label)
                    .font(WorklogFont.footnote)
                    .foregroundStyle(Color.worklogTextSecondary)
                    // State labels morph in place rather than hard-swap.
                    .contentTransition(.opacity)
            }

            Button {
                recordingController.toggle(source: .manual)
            } label: {
                Text(isActive ? "Stop Recording" : "Start Recording")
                    .font(WorklogFont.bodyEmphasized)
                    .foregroundStyle(isActive ? Color.worklogError : Color.worklogOnAccent)
                    .contentTransition(.opacity)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, WorklogSpacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: WorklogRadius.sm, style: .continuous)
                            .fill(buttonBackground)
                    )
            }
            .buttonStyle(.plain)
            .scaleEffect(isPressing ? 0.97 : 1.0)
            .onHover { hovering in
                withAnimation(MotionPrimitives.aware(MotionPrimitives.hover)) {
                    isHovering = hovering
                }
            }
            // Starting or stopping the day's recording is the heaviest
            // switch in the app, so it gets the heavier pattern - the same
            // one a toggle gets, because that is what this is.
            .worklogPressFeedback(isPressing: $isPressing, haptic: .toggle)
            .focusable(true)
            .focusEffectDisabled()
        }
        .padding(WorklogSpacing.sm)
        .background(
            // The card itself breathes state: a whisper of the recording
            // red while live, warning amber in the device-trouble states -
            // legible from the corner of the eye without reading a word.
            RoundedRectangle(cornerRadius: WorklogRadius.md, style: .continuous)
                .fill(cardBackground)
        )
        .animation(MotionPrimitives.aware(MotionPrimitives.standard), value: recordingController.state)
    }

    private var buttonBackground: Color {
        if isActive {
            return Color.worklogError.opacity(isHovering ? 0.22 : 0.16)
        }
        return isHovering ? Color.worklogAccent.opacity(0.92) : Color.worklogAccent
    }

    private var cardBackground: Color {
        switch recordingController.state {
        case .recording: return Color.worklogRecording.opacity(0.08)
        case .warningDeviceUnavailable, .warningMicPermissionDenied: return Color.worklogWarning.opacity(0.08)
        case .idle, .paused: return Color.worklogSurface
        }
    }

    private var isActive: Bool {
        switch recordingController.state {
        case .recording, .paused, .warningDeviceUnavailable, .warningMicPermissionDenied: return true
        case .idle: return false
        }
    }

    @ViewBuilder
    private var indicatorDot: some View {
        let dot = Circle().fill(dotColor).frame(width: 7, height: 7)
        if recordingController.state == .recording {
            dot.modifier(LivePulseModifier())
        } else {
            dot
        }
    }

    private var dotColor: Color {
        switch recordingController.state {
        case .idle: return .worklogTextTertiary
        case .recording: return .worklogRecording
        case .paused: return .worklogTextTertiary
        case .warningDeviceUnavailable, .warningMicPermissionDenied: return .worklogWarning
        }
    }

    private var label: String {
        switch recordingController.state {
        case .idle: return "Not Recording"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .warningDeviceUnavailable: return "Device Unavailable"
        case .warningMicPermissionDenied: return "Mic Access Denied"
        }
    }
}
