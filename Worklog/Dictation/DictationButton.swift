import SwiftUI

/// The in-app dictation trigger: press and hold to talk, release to save,
/// slide up while holding to go hands-free.
///
/// The macOS build's trigger is a global hotkey; iOS has no such thing, so
/// dictation needs a surface. There are two, and this is the one inside the
/// app - it saves to the Dictations tab and puts the text on the clipboard.
/// The other is the Worklog keyboard, which can insert straight into whatever
/// field you are editing in any app.
///
/// Press-and-hold rather than tap-to-start-tap-to-stop because that is what
/// the feature is: the audio is padded on both ends and the hold length is
/// what decides whether it was a dictation or a brush against the button.
/// A hold is also self-cancelling - let go and it ends - which matters for
/// something that is recording you.
struct DictationButton: View {
    @ObservedObject var controller: DictationController

    /// How far up you have to slide, mid-hold, to latch hands-free. Far
    /// enough not to trigger on the wobble of holding a phone, close enough
    /// to reach without shifting grip.
    private static let latchDistance: CGFloat = 64

    @State private var isHolding = false
    @State private var didLatchThisGesture = false
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            latchHint
            button
        }
        .animation(MotionPrimitives.aware(MotionPrimitives.standard), value: isHolding)
        .animation(MotionPrimitives.aware(MotionPrimitives.standard), value: controller.isHandsFree)
    }

    private var button: some View {
        Circle()
            .fill(fill)
            .frame(width: 68, height: 68)
            .overlay(
                Image(systemName: controller.isHandsFree ? "lock.fill" : "mic.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.worklogOnAccent)
                    .contentTransition(.symbolEffect(.replace))
            )
            .overlay(
                // A ring that only exists while listening, so "it is on" is
                // legible from the corner of your eye.
                Circle()
                    .strokeBorder(Color.worklogRecording.opacity(0.35), lineWidth: 6)
                    .scaleEffect(controller.isDictating ? 1.22 : 1)
                    .opacity(controller.isDictating ? 1 : 0)
            )
            .scaleEffect(isHolding ? 0.94 : 1)
            .shadow(color: .black.opacity(0.18), radius: isHolding ? 4 : 10, y: isHolding ? 2 : 5)
            .gesture(holdGesture)
            .accessibilityLabel(controller.isDictating ? "Stop dictating" : "Hold to dictate")
            .accessibilityHint("Double tap and hold. Slide up to keep recording hands-free.")
            .accessibilityAddTraits(.isButton)
    }

    /// Appears above the button mid-hold to say the latch is there. Nobody
    /// discovers a hidden slide-up gesture on their own.
    @ViewBuilder
    private var latchHint: some View {
        if isHolding && !controller.isHandsFree {
            VStack(spacing: WorklogSpacing.xs) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .bold))
                Text("Slide up to lock")
                    .font(WorklogFont.caption)
            }
            .foregroundStyle(dragOffset <= -Self.latchDistance ? Color.worklogAccent : Color.worklogTextTertiary)
            .padding(.horizontal, WorklogSpacing.md)
            .padding(.vertical, WorklogSpacing.sm)
            .background(Capsule().fill(Color.worklogElevatedSurface))
            .overlay(Capsule().strokeBorder(Color.worklogHairline, lineWidth: 1))
            .offset(y: -78)
            .transition(.opacity.combined(with: .offset(y: 8)))
            .allowsHitTesting(false)
        }
    }

    private var fill: Color {
        if controller.isHandsFree { return .worklogRecording }
        if controller.isDictating { return .worklogRecording }
        return .worklogAccent
    }

    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isHolding {
                    isHolding = true
                    didLatchThisGesture = false
                    // Warm the Taptic Engine: a dictation is about to fire
                    // several haptics in quick succession.
                    WorklogHaptics.prepare()
                    controller.press()
                }
                dragOffset = value.translation.height
                if !didLatchThisGesture, dragOffset <= -Self.latchDistance {
                    didLatchThisGesture = true
                    controller.latch()
                }
            }
            .onEnded { _ in
                isHolding = false
                dragOffset = 0
                // A latched dictation keeps running after the finger lifts;
                // that is the whole point of latching.
                if !controller.isHandsFree {
                    controller.release()
                }
            }
    }
}

/// The dictation bubble, floated over whatever screen is showing.
struct DictationOverlay: ViewModifier {
    @ObservedObject var overlay: DictationOverlayController

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if overlay.isVisible {
                DictationBubbleView(state: overlay.state)
                    .padding(.bottom, WorklogSpacing.xxl)
                    .transition(.opacity.combined(with: .offset(y: 16)))
                    .allowsHitTesting(false)
            }
        }
        .animation(MotionPrimitives.aware(MotionPrimitives.standard), value: overlay.isVisible)
    }
}

extension View {
    func dictationBubble(_ overlay: DictationOverlayController) -> some View {
        modifier(DictationOverlay(overlay: overlay))
    }
}
