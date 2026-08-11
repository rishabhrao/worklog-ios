import SwiftUI

/// A compact, real player control row: a circular Play/Pause icon button on
/// the left, current-position / total-duration timestamp next to it. Shared
/// between the Clip screen and Library detail view so both present the same
/// player affordance rather than each screen inventing its own (previously
/// a plain "Play"-labeled `WorklogButton` with a separate timestamp - this
/// replaces that per explicit user request for "a nice player-like
/// interface").
struct PlayerBar: View {
    let isPlaying: Bool
    let position: TimeInterval
    let duration: TimeInterval
    let onToggle: () -> Void
    /// What a range's preview export looks like from here. Playing a
    /// Clip-screen range is not instant - the segments it spans have to be
    /// assembled into one file first - and a transport that gave no sign of
    /// that was indistinguishable from a button that didn't work.
    var isPreparing: Bool = false

    @State private var isHovering = false
    @State private var isPressing = false

    var body: some View {
        HStack(spacing: WorklogSpacing.sm) {
            Button(action: onToggle) {
                Group {
                    if isPreparing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.worklogOnAccent)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.worklogOnAccent)
                            // Play ⇄ pause morphs as one glyph instead of two
                            // different images hard-swapping.
                            .contentTransition(.symbolEffect(.replace))
                            .animation(MotionPrimitives.aware(MotionPrimitives.standard), value: isPlaying)
                    }
                }
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.worklogAccent.opacity(isHovering ? 0.92 : 1)))
            }
            .buttonStyle(.plain)
            .scaleEffect(isPressing ? 0.92 : 1.0)
            .onHover { hovering in
                withAnimation(MotionPrimitives.aware(MotionPrimitives.hover)) {
                    isHovering = hovering
                }
            }
            .worklogPressFeedback(isPressing: $isPressing)
            .focusable(true)
            .focusEffectDisabled()
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            Text(isPreparing ? "Preparing…" : "\(formatTime(position)) / \(formatTime(duration))")
                .font(WorklogFont.caption.monospacedDigit())
                .foregroundStyle(Color.worklogTextTertiary)
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
