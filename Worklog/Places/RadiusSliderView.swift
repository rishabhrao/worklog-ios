import SwiftUI

/// The radius control: a track with a detent for every stop in
/// `PlaceRadius.stops`, from 10 m to 1 km.
///
/// Why a detented slider rather than a set of preset buttons: the useful
/// range spans two orders of magnitude, and which end of it a place needs
/// depends entirely on the place - a desk, a floor, a building, a campus. A
/// slider shows the whole range at once and lets you feel along it; discrete
/// stops keep every position a number worth having.
///
/// The thumb snaps stop to stop rather than sliding freely, so the control
/// has bumps: each one lands with a short spring, which is what makes a drag
/// read as passing over notches instead of smearing across a continuum. The
/// readouts deliberately never animate - they are watched during a drag, and
/// anything that lags the pointer reads as the app lagging.
///
/// Hand-built rather than a `Slider(value:in:step:)`: the stops are unevenly
/// spaced (so `step:` can't express them), and the named detents need to be
/// drawn larger than the rest.
struct RadiusSliderView: View {
    @Binding var meters: Double

    @State private var isDragging = false
    @State private var isHovering = false

    private let thumbRadius: CGFloat = 8
    private let trackHeight: CGFloat = 4

    private var index: Int { PlaceRadius.index(of: meters) }
    private var stops: [Double] { PlaceRadius.stops }

    var body: some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: WorklogSpacing.xs) {
                Text("How far it reaches")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextSecondary)
                Spacer()
                // Only some stops have a name; the distance is always the
                // truth, so it takes the emphasis and the name trails it.
                if let name = PlaceRadius.name(meters) {
                    Text(name)
                        .font(WorklogFont.footnote)
                        .foregroundStyle(Color.worklogTextTertiary)
                }
                Text(PlaceRadius.label(meters))
                    .font(WorklogFont.bodyEmphasized)
                    .foregroundStyle(Color.worklogAccent)
                    .monospacedDigit()
            }

            GeometryReader { geometry in
                let span = max(geometry.size.width - thumbRadius * 2, 1)
                let thumbX = thumbRadius + span * CGFloat(index) / CGFloat(stops.count - 1)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.worklogHairline)
                        .frame(height: trackHeight)
                    Capsule()
                        .fill(Color.worklogAccent)
                        .frame(width: thumbX, height: trackHeight)

                    // Detents. Named stops are drawn a touch larger - they're
                    // the ones worth aiming for, and the size difference
                    // reads at a glance where a label would only add clutter.
                    ForEach(Array(stops.enumerated()), id: \.offset) { offset, stop in
                        let x = thumbRadius + span * CGFloat(offset) / CGFloat(stops.count - 1)
                        Circle()
                            .fill(x <= thumbX ? Color.worklogOnAccent.opacity(0.5) : Color.worklogHairline)
                            .frame(width: PlaceRadius.name(stop) != nil ? 5 : 3)
                            .offset(x: x - (PlaceRadius.name(stop) != nil ? 2.5 : 1.5))
                    }

                    Circle()
                        .fill(Color.worklogAccent)
                        .frame(width: thumbRadius * 2, height: thumbRadius * 2)
                        .scaleEffect(isDragging ? 1.25 : (isHovering ? 1.1 : 1))
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                        .offset(x: thumbX - thumbRadius)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                // Pressing anywhere on the track jumps there. The alternative
                // - only the thumb is draggable - turns a ten-stop control
                // into a game of hitting a 16 pt target.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            select(at: value.location.x, span: span)
                        }
                        .onEnded { _ in isDragging = false }
                )
            }
            .frame(height: 24)
            .onHover { hovering in
                withAnimation(MotionPrimitives.aware(MotionPrimitives.hover)) { isHovering = hovering }
            }
        }
        // Only the thumb's travel animates. Snapping with no animation
        // teleports it; a slow spring lags the pointer.
        .animation(MotionPrimitives.aware(MotionPrimitives.interactive), value: index)
        .animation(MotionPrimitives.aware(MotionPrimitives.interactive), value: isDragging)
    }

    private func select(at x: CGFloat, span: CGFloat) {
        let fraction = min(max((x - thumbRadius) / span, 0), 1)
        let next = Int((fraction * CGFloat(stops.count - 1)).rounded())
        let clamped = min(max(next, 0), stops.count - 1)
        guard stops[clamped] != meters else { return }
        meters = stops[clamped]
        // The bumps, made literal. Dragging the length of the track ticks
        // ten times - which is the whole reason the stops are discrete, and
        // the only way the control communicates its resolution without
        // making you read the number.
        WorklogHaptics.play(clamped == 0 || clamped == stops.count - 1 ? .boundary : .detent)
    }
}
