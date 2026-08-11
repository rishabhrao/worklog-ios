import SwiftUI

/// Small icon-only button with the app's shared interaction physics:
/// instant press-down scale, quick hover shading, and a smooth symbol
/// crossfade when `systemName` changes (e.g. copy → checkmark). Two
/// visual styles cover every icon-button in the app - `bare` (section
/// action icons) and `filledCircle` (the range-loader's calendar/clear).
struct WorklogIconButton: View {
    enum Style {
        case bare
        case filledCircle
    }

    let systemName: String
    let label: String
    var tint: Color? = nil
    var style: Style = .bare
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressing = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: style == .bare ? 12 : 13, weight: style == .bare ? .regular : .medium))
                .foregroundStyle(tint ?? Color.worklogTextSecondary)
                .contentTransition(.symbolEffect(.replace))
                .animation(MotionPrimitives.aware(MotionPrimitives.standard), value: systemName)
                .frame(width: style == .bare ? 22 : nil, height: style == .bare ? 22 : nil)
                .padding(style == .filledCircle ? WorklogSpacing.sm : 0)
                .background(backgroundShape)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressing ? 0.92 : 1.0)
        .opacity(isEnabled ? 1.0 : 0.4)
        .onHover { hovering in
            withAnimation(MotionPrimitives.aware(MotionPrimitives.hover)) {
                isHovering = hovering
            }
        }
        .worklogPressFeedback(isPressing: $isPressing)
        .focusable(true)
        .focusEffectDisabled()
        .accessibilityLabel(label)
        .help(label)
    }

    @ViewBuilder
    private var backgroundShape: some View {
        switch style {
        case .bare:
            // Hover reveals a soft chip behind the glyph so the target
            // reads as pressable the moment the pointer arrives.
            RoundedRectangle(cornerRadius: WorklogRadius.sm, style: .continuous)
                .fill(Color.worklogSurface.opacity(isHovering ? 1 : 0))
        case .filledCircle:
            Circle().fill(isHovering ? Color.worklogElevatedSurface : Color.worklogSurface)
        }
    }
}
