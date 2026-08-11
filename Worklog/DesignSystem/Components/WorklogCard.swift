import SwiftUI

/// Elevated-surface container for grouped content (Settings sections,
/// Library empty states, showcase panels). Purely presentational - no
/// interaction states of its own beyond an optional hover lift when a
/// tap action is supplied.
struct WorklogCard<Content: View>: View {
    let action: (() -> Void)?
    @ViewBuilder let content: () -> Content

    @State private var isHovering = false

    init(action: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.action = action
        self.content = content
    }

    var body: some View {
        let card = content()
            .padding(WorklogSpacing.lg)
            .background(
                RoundedRectangle(cornerRadius: WorklogRadius.lg, style: .continuous)
                    .fill(Color.worklogElevatedSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: WorklogRadius.lg, style: .continuous)
                    .strokeBorder(Color.worklogHairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(isHovering && action != nil ? 0.10 : 0.05), radius: isHovering && action != nil ? 8 : 4, y: 2)

        if let action {
            Button(action: action) { card }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(MotionPrimitives.aware(MotionPrimitives.standard)) {
                        isHovering = hovering
                    }
                }
        } else {
            card
        }
    }
}
