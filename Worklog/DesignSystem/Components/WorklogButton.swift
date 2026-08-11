import SwiftUI

/// Button visual weight. Screens choose the semantic style; this view
/// owns press/disabled rendering so no screen redefines button styling
/// locally (per design-system spec).
enum WorklogButtonStyleKind {
    case primary
    case secondary
    case destructive
}

struct WorklogButton: View {
    let title: String
    let kind: WorklogButtonStyleKind
    /// A full-width call to action, the way iOS ends a screen. Off by default
    /// so the inline buttons scattered through the detail views keep hugging
    /// their labels.
    let fillsWidth: Bool
    let action: () -> Void

    @State private var isPressing = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, kind: WorklogButtonStyleKind = .primary, fillsWidth: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.kind = kind
        self.fillsWidth = fillsWidth
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(fillsWidth ? WorklogFont.headline : WorklogFont.bodyEmphasized)
                .foregroundStyle(foregroundColor)
                // Label morphs ("Create" → "Exporting…") crossfade instead of
                // hard-swapping - state changes should read as the same object
                // changing, not two objects trading places.
                .contentTransition(.opacity)
                .animation(MotionPrimitives.aware(MotionPrimitives.standard), value: title)
                .lineLimit(1)
                .padding(.horizontal, WorklogSpacing.lg)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                // 44pt is the smallest target a thumb hits reliably and the
                // figure iOS itself is built around; a full-width CTA gets the
                // 50pt the system uses for the same job. The macOS build's
                // 8pt vertical padding was fine for a pointer and is not fine
                // here.
                .frame(minHeight: fillsWidth ? 50 : 44)
                .background(
                    RoundedRectangle(cornerRadius: fillsWidth ? WorklogRadius.lg : WorklogRadius.md, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: fillsWidth ? WorklogRadius.lg : WorklogRadius.md, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: kind == .secondary ? 1 : 0)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressing ? 0.97 : 1.0)
        .opacity(isEnabled ? 1.0 : 0.4)
        // Asymmetric press: the down-stroke is near-instant (feedback the
        // moment the finger lands), the release settles on a soft spring.
        // The haptic rides the same instant as the scale, so the button is
        // felt and seen to go down together.
        .worklogPressFeedback(isPressing: $isPressing, haptic: kind == .destructive ? .warning : .tap)
    }

    private var backgroundColor: Color {
        switch kind {
        case .primary:
            return isPressing ? Color.worklogAccent.opacity(0.85) : Color.worklogAccent
        case .secondary:
            return isPressing ? Color.worklogElevatedSurface : Color.worklogSurface
        case .destructive:
            return isPressing ? Color.worklogError.opacity(0.85) : Color.worklogError
        }
    }

    private var foregroundColor: Color {
        switch kind {
        case .primary, .destructive: return .worklogOnAccent
        case .secondary: return .worklogTextPrimary
        }
    }

    private var borderColor: Color {
        kind == .secondary ? Color.worklogHairline : .clear
    }
}
