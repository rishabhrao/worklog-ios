import SwiftUI

/// The tail of a list that's been capped: says how much more there is, and
/// opens it.
///
/// Settings is one long scroll, and a section that grows without limit
/// pushes everything after it out of reach - a vocabulary of forty tags
/// would bury the sections below it under a wall of rows nobody was looking
/// for. Capping keeps every section roughly the size of what it's *about*
/// rather than the size of its contents.
///
/// The count is on the button rather than in a generic "Show more", because
/// the useful question is never "is there more" - it's "is there enough more
/// to be worth the scroll".
///
/// Renders nothing when there's nothing to hide, so call sites can place it
/// unconditionally after their rows.
struct ShowMoreButton: View {
    let total: Int
    @Binding var isExpanded: Bool
    var limit: Int = ShowMoreButton.collapsedLimit

    /// How many rows a collapsed list shows. Five is enough to see what kind
    /// of list it is and to cover the usual case outright, while still
    /// leaving the section shorter than the screen.
    static let collapsedLimit = 5

    @State private var isHovering = false
    @State private var isPressing = false

    var body: some View {
        if total > limit {
            Button {
                withAnimation(MotionPrimitives.aware(MotionPrimitives.standard)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: WorklogSpacing.xs) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    Text(isExpanded ? "Show fewer" : "Show \(total - limit) more")
                        .font(WorklogFont.caption)
                        // Only the number changes, so it crossfades rather
                        // than the whole label hard-swapping.
                        .contentTransition(.opacity)
                    Spacer()
                }
                .foregroundStyle(isHovering ? Color.worklogTextSecondary : Color.worklogTextTertiary)
                .padding(.horizontal, WorklogSpacing.sm)
                .padding(.vertical, WorklogSpacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .scaleEffect(isPressing ? 0.99 : 1)
            .onHover { hovering in
                withAnimation(MotionPrimitives.aware(MotionPrimitives.hover)) { isHovering = hovering }
            }
            // `.select` rather than `.tap`: what this does is reveal content,
            // which is the same kind of event as moving a selection, not the
            // same kind as pressing a button that acts.
            .worklogPressFeedback(isPressing: $isPressing, haptic: .select)
            .focusable(true)
            .focusEffectDisabled()
            .animation(MotionPrimitives.aware(MotionPrimitives.standard), value: isExpanded)
        }
    }
}

extension Collection {
    /// The first `limit` elements, or all of them once expanded. Keeps the
    /// call site reading as what it means rather than as index arithmetic.
    func capped(to limit: Int, expanded: Bool) -> [Element] {
        expanded ? Array(self) : Array(prefix(limit))
    }
}
