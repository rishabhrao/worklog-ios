import MapKit
import SwiftUI

/// A live preview of what a place covers: the map around it with the radius
/// drawn on top, re-framed as the radius changes.
///
/// This is the answer to "how far is 400 m from here", which no number can
/// give you. The circle is the thing being edited, so it stays the brightest
/// element; the map underneath is context.
///
/// Deliberately not interactive. Panning or zooming would let the view drift
/// away from the circle it exists to explain, and there is nothing to find on
/// it - the place's center is fixed by where the recordings actually are.
struct PlaceMapPreviewView: View {
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double
    /// The place being edited, so it isn't drawn twice.
    var excludingPlaceID: String? = nil

    @State private var camera: MapCameraPosition = .automatic
    @ObservedObject private var store = PlaceStore.shared

    /// Everything else you've named that's close enough to matter. Drawn so a
    /// radius is never chosen blind to what it's about to sit on top of -
    /// which is the whole risk when your home is across the road from your
    /// office.
    private var neighbours: [PlaceRecord] {
        store.neighbours(latitude: latitude, longitude: longitude, within: radiusMeters * 4, excluding: excludingPlaceID)
    }

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// A little over twice the diameter, so the circle sits comfortably
    /// inside the frame with its surroundings readable rather than filling
    /// the view edge to edge.
    private var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: radiusMeters * 4.5,
            longitudinalMeters: radiusMeters * 4.5
        )
    }

    var body: some View {
        Map(position: $camera, interactionModes: []) {
            // Neighbours first, so the circle being edited reads on top of
            // them. Named, because "that dashed circle is my home" is the
            // entire point of drawing them.
            ForEach(neighbours) { neighbour in
                let center = CLLocationCoordinate2D(latitude: neighbour.latitude, longitude: neighbour.longitude)
                MapCircle(center: center, radius: neighbour.radiusMeters)
                    .foregroundStyle(.clear)
                    .stroke(Color.worklogWarning.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                Annotation(neighbour.name, coordinate: center) {
                    Circle()
                        .fill(Color.worklogWarning)
                        .frame(width: 5, height: 5)
                }
                .annotationTitles(.visible)
            }
            MapCircle(center: coordinate, radius: radiusMeters)
                .foregroundStyle(Color.worklogAccent.opacity(0.18))
                .stroke(Color.worklogAccent, lineWidth: 1.5)
            Annotation("", coordinate: coordinate) {
                Circle()
                    .fill(Color.worklogAccent)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(Color.worklogOnAccent, lineWidth: 1.5))
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .including([.publicTransport])))
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: WorklogRadius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorklogRadius.sm, style: .continuous)
                .strokeBorder(Color.worklogHairline, lineWidth: 1)
        )
        .onAppear { camera = .region(region) }
        // The zoom follows the radius so the circle keeps the same share of
        // the frame at 10 m and at 1 km - without this, the two extremes are
        // a dot and a shape with no visible edge.
        .onChange(of: radiusMeters) {
            withAnimation(MotionPrimitives.aware(MotionPrimitives.standard)) {
                camera = .region(region)
            }
        }
        .onChange(of: latitude) { camera = .region(region) }
        .onChange(of: longitude) { camera = .region(region) }
    }
}
