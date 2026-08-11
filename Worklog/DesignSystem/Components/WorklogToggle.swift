import SwiftUI

/// Styled toggle (Settings' switches) with an animated thumb and
/// hover/press feedback, reading only from tokens.
struct WorklogToggle: View {
    let label: String
    @Binding var isOn: Bool

    @State private var isHovering = false

    var body: some View {
        Button {
            // Felt as the thumb lands, not as the pointer goes down: on a
            // switch the click *is* the state change, and a tick that
            // arrived before the flip would be describing the wrong thing.
            WorklogHaptics.play(.toggle)
            // The thumb lands with a hint of bounce - a flip carries
            // momentum, and this is one of the few places overshoot is
            // earned rather than decorative.
            withAnimation(MotionPrimitives.aware(MotionPrimitives.interactive)) {
                isOn.toggle()
            }
        } label: {
            HStack {
                Text(label)
                    .font(WorklogFont.body)
                    .foregroundStyle(Color.worklogTextPrimary)
                Spacer()
                capsule
            }
            .padding(.vertical, WorklogSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(MotionPrimitives.aware(MotionPrimitives.interactive)) {
                isHovering = hovering
            }
        }
        .focusable(true)
        .focusEffectDisabled()
    }

    private var capsule: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.worklogAccent : Color.worklogHairline)
                .frame(width: 36, height: 20)
                .opacity(isHovering ? 0.88 : 1.0)

            Circle()
                .fill(Color.worklogOnAccent)
                .frame(width: 16, height: 16)
                .padding(2)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
        }
    }
}
