import SwiftUI

/// A generic styled list row (used by Library's clip list, Settings device
/// picker, etc.) with hover/press feedback. Content is supplied via a
/// ViewBuilder so callers keep row-specific layout while inheriting the
/// shared hover/press/selection chrome.
struct WorklogListRow<Content: View>: View {
    let isSelected: Bool
    let action: (() -> Void)?
    @ViewBuilder let content: () -> Content

    @State private var isHovering = false
    @State private var isPressing = false

    init(isSelected: Bool = false, action: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.isSelected = isSelected
        self.action = action
        self.content = content
    }

    var body: some View {
        let row = content()
            .padding(.horizontal, WorklogSpacing.md)
            .padding(.vertical, WorklogSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: WorklogRadius.sm, style: .continuous)
                    .fill(backgroundColor)
            )
            .contentShape(Rectangle())
            .scaleEffect(isPressing ? 0.99 : 1.0)
            .onHover { hovering in
                withAnimation(MotionPrimitives.aware(MotionPrimitives.hover)) {
                    isHovering = hovering
                }
            }

        if let action {
            Button(action: action) { row }
                .buttonStyle(.plain)
                .focusable(true)
                .focusEffectDisabled()
                .worklogPressFeedback(isPressing: $isPressing, haptic: isSelected ? .tap : .select)
        } else {
            row
        }
    }

    private var backgroundColor: Color {
        if isSelected { return Color.worklogAccent.opacity(0.16) }
        if isPressing { return Color.worklogSurface }
        if isHovering { return Color.worklogSurface.opacity(0.7) }
        return .clear
    }
}
