import SwiftUI

/// The location line under a clip or dictation title: what this spot is
/// called, and the way in to renaming it.
///
/// One tap target, not two. The old row opened Maps on click, which left
/// naming with nowhere to live; putting *every* location action inside one
/// popover keeps the header uncluttered and makes the naming affordance
/// discoverable, which a hover-only pencil icon would not be.
struct LocationChipView: View {
    let label: LocationLabel

    @State private var isEditing = false
    @State private var isHovering = false

    var body: some View {
        Button { isEditing = true } label: {
            HStack(spacing: WorklogSpacing.xs) {
                Image(systemName: label.isCustom ? "mappin.circle.fill" : "mappin.and.ellipse")
                    .foregroundStyle(label.isCustom ? Color.worklogAccent : Color.worklogTextTertiary)
                Text(label.displayName)
                    .foregroundStyle(label.isCustom ? Color.worklogTextSecondary : Color.worklogTextTertiary)
                    .lineLimit(1)
                // The OS name stays visible behind a custom one, so a
                // renamed place never hides where it actually is.
                if let detected = label.detectedSubtitle {
                    Text("· \(detected)")
                        .foregroundStyle(Color.worklogTextTertiary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.worklogTextTertiary)
                    .opacity(isHovering ? 1 : 0)
            }
            .font(WorklogFont.caption)
            .padding(.horizontal, WorklogSpacing.xs)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: WorklogRadius.sm, style: .continuous)
                    .fill(isHovering ? Color.worklogSurface : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(true)
        .focusEffectDisabled()
        .onHover { hovering in
            withAnimation(MotionPrimitives.aware(MotionPrimitives.hover)) { isHovering = hovering }
        }
        .help(label.isCustom ? "Edit “\(label.displayName)”" : "Name this place")
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            PlaceEditorView(
                latitude: label.place?.latitude ?? label.latitude,
                longitude: label.place?.longitude ?? label.longitude,
                existing: label.place,
                detectedName: label.detectedName,
                onClose: { isEditing = false }
            )
        }
    }
}

/// The same information with no interaction, for list rows - small, muted,
/// and only present when there is actually a name to show.
struct LocationTagView: View {
    let label: LocationLabel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 11, weight: .medium))
            Text(label.displayName)
                .lineLimit(1)
        }
        .foregroundStyle(label.isCustom ? Color.worklogAccent.opacity(0.85) : Color.worklogTextTertiary)
    }
}
