import CoreLocation
import Foundation

/// How wide a named place reaches. A place is a building or a block, never
/// a point: two fixes taken at the same desk an hour apart routinely differ
/// by tens of meters, and a GPS-denied indoor fix can be off by more.
///
/// The stops are the detents of the radius slider. They are spaced roughly
/// logarithmically rather than evenly, because the useful resolution is not
/// uniform across the range - the difference between 10 m and 25 m decides
/// whether a desk and a lift lobby are the same place, while the difference
/// between 600 m and 1 km barely changes anything. Every stop is a number
/// people actually think in. Identical to the Android app's, so a radius set
/// on one lands on a real detent on the other.
enum PlaceRadius {
    static let stops: [Double] = [10, 25, 50, 75, 100, 150, 250, 400, 600, 1000]

    /// A building's worth of slop - right for a home or an office, which is
    /// what almost every named place turns out to be.
    static let standard: Double = 150

    /// Names for the stops that mean something in plain language. The rest
    /// are just distances, and saying so is more honest than inventing a
    /// word for every one of them.
    private static let names: [Double: String] = [
        10: "Exact",
        50: "Precise",
        150: "Building",
        400: "Area",
        1000: "Neighbourhood",
    ]

    static func name(_ meters: Double) -> String? { names[snap(meters)] }

    static func label(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.1f km", meters / 1000) : "\(Int(meters)) m"
    }

    /// The nearest stop. A radius stored by the phone (or by an older build
    /// with different stops) still lands on a real detent.
    static func snap(_ meters: Double) -> Double {
        stops.min { abs($0 - meters) < abs($1 - meters) } ?? standard
    }

    static func index(of meters: Double) -> Int {
        stops.firstIndex(of: snap(meters)) ?? 0
    }

    /// The smallest stop that still covers `meters`, or nil when nothing
    /// does. Merging needs a radius that definitely reaches both halves, so
    /// it rounds up where everything else rounds to nearest.
    static func snapUp(_ meters: Double) -> Double? {
        stops.first { $0 >= meters - 0.5 }
    }
}

/// What a coordinate is called, in priority order: the user's own name for
/// the place if it falls inside one, otherwise whatever the OS reverse-
/// geocoded, otherwise the bare coordinates.
struct LocationLabel {
    let latitude: Double
    let longitude: Double
    /// The user-named place this coordinate falls inside, if any.
    let place: PlaceRecord?
    /// The OS-provided name, once resolved - `nil` while a lookup is still
    /// pending or if it failed.
    let detectedName: String?
    /// Locality/area/country behind the detected name, kept for search.
    let detectedContext: String?

    var coordinateText: String { String(format: "%.4f, %.4f", latitude, longitude) }

    /// What the UI shows. Never empty, and never a spinner: the coordinates
    /// are a real answer, so a slow geocode degrades to something useful
    /// rather than to a placeholder.
    var displayName: String { place?.name ?? detectedName ?? coordinateText }

    /// True when the name on screen is one the user chose.
    var isCustom: Bool { place != nil }

    /// The OS name shown as a subtitle beneath a custom name - omitted when
    /// it is the custom name, or when there's nothing to add.
    var detectedSubtitle: String? {
        guard place != nil, let detectedName, detectedName != place?.name else { return nil }
        return detectedName
    }

    /// Everything a search should match: the custom name, the OS name, its
    /// locality context, and the raw coordinates.
    var searchText: String {
        [place?.name, detectedName, detectedContext, coordinateText]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

/// Owns user-named places and the reverse-geocode cache, and resolves any
/// coordinate to a name.
///
/// The central decision here: a recording's place name is **never written
/// onto the recording**. It is derived, every time, from the places table by
/// distance. That is what makes naming a place retroactive - one row insert
/// renames every recording ever made there, past and future - and what makes
/// removing a name fall back to the OS name everywhere, with nothing to
/// migrate and nothing that can drift out of sync.
@MainActor
final class PlaceStore: ObservableObject {
    static let shared = PlaceStore()

    @Published private(set) var places: [PlaceRecord] = []
    /// Resolved OS names by coordinate cell. Published so a name arriving
    /// from a background lookup re-renders whatever is already on screen.
    @Published private(set) var geocodes: [String: GeocodeRecord] = [:]

    /// Cells queued for reverse geocoding, oldest first. Drained by one
    /// serial task - `CLGeocoder` is a rate-limited network service that
    /// starts returning errors (and stops answering for a while) if hit in
    /// parallel or in a tight loop.
    private var pendingCells: [String: CLLocationCoordinate2D] = [:]
    private var resolverTask: Task<Void, Never>?
    /// Cells a lookup has already failed or come back empty for. Without
    /// this the backfill would retry the same unnameable coordinate forever.
    private var unresolvableCells: Set<String> = []

    /// Bumped whenever the rules that pick a name out of a placemark change.
    /// A cached name is never revisited, so without this a row written under
    /// worse rules would keep its worse name forever.
    private static let namingRulesVersion = "2"
    private static let namingRulesKey = "geocode-naming-rules"

    private init() {
        places = WorklogDatabase.shared.allPlaces()
        // Drop the cache once per rule change so old rows re-resolve. The
        // backfill refills it in the background, and nothing user-authored
        // lives here - it is all re-derivable from coordinates.
        if WorklogDatabase.shared.appStateValue(forKey: Self.namingRulesKey) != Self.namingRulesVersion {
            WorklogDatabase.shared.clearGeocodes()
            WorklogDatabase.shared.setAppStateValue(Self.namingRulesVersion, forKey: Self.namingRulesKey)
        }
        geocodes = WorklogDatabase.shared.allGeocodes()
        // Same-named places written before merging existed are folded now.
        consolidate()
    }

    // MARK: - Resolution

    /// The label for a coordinate pair, or `nil` when the recording has no
    /// location at all. Kicks off a background geocode the first time an
    /// unresolved coordinate is asked about, so simply showing a row is what
    /// schedules its lookup.
    func label(latitude: Double?, longitude: Double?) -> LocationLabel? {
        guard let latitude, let longitude else { return nil }
        let cell = Self.cellKey(latitude: latitude, longitude: longitude)
        let geocode = geocodes[cell]
        if geocode == nil {
            enqueue(cell: cell, latitude: latitude, longitude: longitude)
        }
        return LocationLabel(
            latitude: latitude,
            longitude: longitude,
            place: place(containing: latitude, longitude),
            detectedName: geocode?.name,
            detectedContext: geocode?.context
        )
    }

    /// The place a coordinate belongs to: the one whose circle contains it,
    /// nearest center first when several overlap.
    func place(containing latitude: Double, _ longitude: Double) -> PlaceRecord? {
        places
            .map { (place: $0, distance: Self.distance(latitude, longitude, $0.latitude, $0.longitude)) }
            .filter { $0.distance <= $0.place.radiusMeters }
            .min { $0.distance < $1.distance }?
            .place
    }

    /// How many clips and dictations a circle would claim - shown live in the
    /// editor so the blast radius of a rename is never a surprise.
    func recordingCount(latitude: Double, longitude: Double, radiusMeters: Double) -> Int {
        recordingCount(
            in: WorklogDatabase.shared.taggedCoordinates(),
            latitude: latitude,
            longitude: longitude,
            radiusMeters: radiusMeters
        )
    }

    /// The same count against a caller-held snapshot of the coordinates -
    /// the editor recomputes this as the radius slider moves, and re-reading
    /// every tagged coordinate from SQLite on each frame would be waste.
    ///
    /// Recordings a *different* place holds more tightly don't count. Places
    /// that sit next to each other (a home and an office across the road)
    /// overlap constantly, and every recording still belongs to exactly one
    /// of them - the nearest centre. Counting raw circle area instead would
    /// promise a number the labels never deliver.
    func recordingCount(
        in coordinates: [(latitude: Double, longitude: Double)],
        latitude: Double,
        longitude: Double,
        radiusMeters: Double,
        excluding placeID: String? = nil
    ) -> Int {
        coordinates.filter { coordinate in
            let own = Self.distance(latitude, longitude, coordinate.latitude, coordinate.longitude)
            guard own <= radiusMeters else { return false }
            return !places.contains { other in
                guard other.id != placeID else { return false }
                let d = Self.distance(other.latitude, other.longitude, coordinate.latitude, coordinate.longitude)
                return d <= other.radiusMeters && d < own
            }
        }.count
    }

    /// Other named places near enough to matter while sizing this one -
    /// drawn on the map preview so a radius is never chosen blind to what it
    /// is about to sit on top of.
    func neighbours(latitude: Double, longitude: Double, within meters: Double, excluding placeID: String?) -> [PlaceRecord] {
        places.filter {
            $0.id != placeID && Self.distance(latitude, longitude, $0.latitude, $0.longitude) <= meters
        }
    }

    /// A spot the user records at often but hasn't named. Surfaced in the
    /// Places tab so naming somewhere doesn't require first finding a clip
    /// that happens to be there.
    struct Suggestion: Identifiable {
        let id: String
        let latitude: Double
        let longitude: Double
        let count: Int
        let detectedName: String?

        var displayName: String {
            detectedName ?? String(format: "%.4f, %.4f", latitude, longitude)
        }
    }

    /// Unnamed clusters, busiest first. Greedy single-pass clustering at the
    /// default place radius: exact cluster boundaries don't matter here -
    /// this only has to point at somewhere worth naming, and the moment the
    /// user names it, the real circle they chose takes over.
    /// Raised from six once the Settings list learned to collapse: the cap
    /// used to *be* the UI's limit, so it had to be small enough to sit in a
    /// section. Now the section shows five and offers the rest, so this only
    /// has to bound the clustering work.
    func suggestions(limit: Int = 12) -> [Suggestion] {
        var unnamed = WorklogDatabase.shared.taggedCoordinates()
            .filter { place(containing: $0.latitude, $0.longitude) == nil }
        var clusters: [Suggestion] = []

        while let seed = unnamed.first {
            let members = unnamed.filter {
                Self.distance(seed.latitude, seed.longitude, $0.latitude, $0.longitude) <= PlaceRadius.standard
            }
            unnamed.removeAll { member in
                Self.distance(seed.latitude, seed.longitude, member.latitude, member.longitude) <= PlaceRadius.standard
            }
            // The centroid, not the seed: a cluster's center should sit in
            // the middle of its recordings, so the radius the user picks
            // reaches evenly rather than being anchored to whichever fix
            // happened to be read first.
            let latitude = members.reduce(0.0) { $0 + $1.latitude } / Double(members.count)
            let longitude = members.reduce(0.0) { $0 + $1.longitude } / Double(members.count)
            let cell = Self.cellKey(latitude: latitude, longitude: longitude)
            if geocodes[cell] == nil {
                enqueue(cell: cell, latitude: latitude, longitude: longitude)
            }
            clusters.append(Suggestion(
                id: cell,
                latitude: latitude,
                longitude: longitude,
                count: members.count,
                detectedName: geocodes[cell]?.name
            ))
        }

        return Array(clusters.sorted { $0.count > $1.count }.prefix(limit))
    }

    // MARK: - Editing

    /// Names a place, or renames/reshapes the one that already covers this
    /// coordinate. Returns the saved record.
    ///
    /// Editing keeps the existing row's ID and center: moving the center to
    /// wherever the user happened to be standing when they renamed it would
    /// silently drag the circle across the map, dropping recordings out of a
    /// place that hasn't moved.
    @discardableResult
    func save(name: String, latitude: Double, longitude: Double, radiusMeters: Double) -> PlaceRecord? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let now = Date()
        let existing = place(containing: latitude, longitude)
        let record = PlaceRecord(
            id: existing?.id ?? UUID().uuidString,
            name: trimmed,
            latitude: existing?.latitude ?? latitude,
            longitude: existing?.longitude ?? longitude,
            radiusMeters: PlaceRadius.snap(radiusMeters),
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        WorklogDatabase.shared.upsertPlace(record)
        places = WorklogDatabase.shared.allPlaces()
        consolidate()
        return record
    }

    /// Updates an already-identified place - used by the Settings list,
    /// where the row being edited is known and no coordinate lookup applies.
    func update(_ place: PlaceRecord, name: String, radiusMeters: Double) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = place
        updated.name = trimmed
        updated.radiusMeters = PlaceRadius.snap(radiusMeters)
        updated.updatedAt = Date()
        WorklogDatabase.shared.upsertPlace(updated)
        places = WorklogDatabase.shared.allPlaces()
        consolidate()
    }

    func remove(_ place: PlaceRecord) {
        WorklogDatabase.shared.deletePlace(id: place.id)
        places = WorklogDatabase.shared.allPlaces()
    }

    // MARK: - Merging

    /// Folds places that share a name into one, wherever a single circle can
    /// still cover them.
    ///
    /// Two spots a few metres apart get separate rows the moment their
    /// circles don't quite touch - easy to do by naming the same office from
    /// two clips recorded at opposite ends of it. Giving them the same name
    /// is the user saying they are one place, so this makes them one: the
    /// survivor keeps the oldest row's identity and grows just enough to
    /// reach both.
    func consolidate() {
        var changed = false
        let coordinates = WorklogDatabase.shared.taggedCoordinates()
        let groups = Dictionary(grouping: places) { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
        for (_, group) in groups {
            guard group.count > 1, canMerge(group, coordinates: coordinates),
                  let union = Self.union(of: group),
                  let keep = group.min(by: { $0.createdAt < $1.createdAt }) else { continue }
            var merged = keep
            merged.latitude = union.latitude
            merged.longitude = union.longitude
            merged.radiusMeters = union.radiusMeters
            merged.updatedAt = Date()
            WorklogDatabase.shared.upsertPlace(merged)
            for place in group where place.id != keep.id {
                WorklogDatabase.shared.deletePlace(id: place.id)
            }
            changed = true
        }
        if changed { places = WorklogDatabase.shared.allPlaces() }
    }

    /// True when these places may combine.
    ///
    /// The bar is behavioural, not geometric: a merge is allowed as long as
    /// no recording that currently belongs to some *other* place would change
    /// hands. Overlapping a neighbour is fine and normal - a home and an
    /// office next door to each other always will, and the nearest centre
    /// still decides. Taking a neighbour's recordings is not, and that is the
    /// "don't grow over my home" case exactly.
    func canMerge(_ group: [PlaceRecord], coordinates: [(latitude: Double, longitude: Double)]) -> Bool {
        guard group.count > 1, let union = Self.union(of: group) else { return false }
        let groupIDs = Set(group.map(\.id))
        let outsiders = places.filter { !groupIDs.contains($0.id) }
        return !coordinates.contains { coordinate in
            let owner = outsiders
                .map { (place: $0, distance: Self.distance($0.latitude, $0.longitude, coordinate.latitude, coordinate.longitude)) }
                .filter { $0.distance <= $0.place.radiusMeters }
                .min { $0.distance < $1.distance }
            guard let owner else { return false }
            let toUnion = Self.distance(union.latitude, union.longitude, coordinate.latitude, coordinate.longitude)
            return toUnion <= union.radiusMeters && toUnion < owner.distance
        }
    }

    private struct Circle {
        var latitude: Double
        var longitude: Double
        var radiusMeters: Double
    }

    /// The smallest allowed circle covering every place in `group`, or nil
    /// when no allowed radius reaches. Folded pairwise: not strictly minimal
    /// for three or more, but always covering, which is the property that
    /// matters.
    private static func union(of group: [PlaceRecord]) -> Circle? {
        guard let first = group.first else { return nil }
        var current = Circle(latitude: first.latitude, longitude: first.longitude, radiusMeters: first.radiusMeters)
        for place in group.dropFirst() {
            current = union(
                current,
                Circle(latitude: place.latitude, longitude: place.longitude, radiusMeters: place.radiusMeters)
            )
        }
        guard let radius = PlaceRadius.snapUp(current.radiusMeters) else { return nil }
        current.radiusMeters = radius
        return current
    }

    private static func union(_ a: Circle, _ b: Circle) -> Circle {
        let d = distance(a.latitude, a.longitude, b.latitude, b.longitude)
        if d + b.radiusMeters <= a.radiusMeters { return a }
        if d + a.radiusMeters <= b.radiusMeters { return b }
        // The circle through both far edges: its centre sits on the line
        // between them, offset so each original circle just fits inside.
        let radius = (d + a.radiusMeters + b.radiusMeters) / 2
        let t = (radius - a.radiusMeters) / d
        return Circle(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t,
            radiusMeters: radius
        )
    }

    // MARK: - Reverse geocoding

    /// Queues every tagged coordinate that has no cached name yet. Called at
    /// launch: search has to match the OS name of recordings the user has
    /// never opened, which means those names must be resolved without anyone
    /// looking at them.
    func backfillDetectedNames() {
        for coordinate in WorklogDatabase.shared.taggedCoordinates() {
            let cell = Self.cellKey(latitude: coordinate.latitude, longitude: coordinate.longitude)
            guard geocodes[cell] == nil else { continue }
            enqueue(cell: cell, latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
    }

    private func enqueue(cell: String, latitude: Double, longitude: Double) {
        guard geocodes[cell] == nil,
              pendingCells[cell] == nil,
              !unresolvableCells.contains(cell) else { return }
        pendingCells[cell] = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        startResolverIfNeeded()
    }

    private func startResolverIfNeeded() {
        guard resolverTask == nil else { return }
        resolverTask = Task { [weak self] in
            while let self, let next = await self.nextPendingCell() {
                await self.resolve(cell: next.key, coordinate: next.value)
                // Paced deliberately. Apple documents CLGeocoder as
                // rate-limited and starts failing every request for a while
                // once a burst trips it - which would poison the cache with
                // "unresolvable" entries for coordinates that are perfectly
                // nameable.
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
            await self?.clearResolverTask()
        }
    }

    private func nextPendingCell() -> (key: String, value: CLLocationCoordinate2D)? {
        guard let first = pendingCells.first else { return nil }
        pendingCells.removeValue(forKey: first.key)
        return first
    }

    private func clearResolverTask() {
        resolverTask = nil
    }

    private func resolve(cell: String, coordinate: CLLocationCoordinate2D) async {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location)
        guard let placemark = placemarks?.first,
              let name = Self.displayName(from: placemark) else {
            unresolvableCells.insert(cell)
            return
        }
        let record = GeocodeRecord(cell: cell, name: name, context: Self.context(from: placemark))
        WorklogDatabase.shared.storeGeocode(record)
        geocodes[cell] = record
    }

    /// The most specific human name the placemark offers: a POI or street
    /// address first (`name`), then the street, then the neighbourhood.
    private static func displayName(from placemark: CLPlacemark) -> String? {
        let name = placemark.name.flatMap { isHouseNumber($0) ? nil : $0 }
        return [name, placemark.thoroughfare, placemark.subLocality, placemark.locality, placemark.administrativeArea]
            .compactMap { $0 }
            .first { !$0.isEmpty }
    }

    /// A bare house or plot number ("4a", "129") names a doorway, not a
    /// place - and two desks in one building routinely land on different
    /// ones, so it makes the same place look like several. The street is
    /// both more stable and more recognisable.
    private static func isHouseNumber(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return trimmed.range(of: "^\\d+\\s*[A-Za-z]?$", options: .regularExpression) != nil
    }

    /// Everything broader than the name, so searching a neighbourhood or a
    /// city finds recordings labelled only with a street.
    private static func context(from placemark: CLPlacemark) -> String? {
        let parts = [placemark.subLocality, placemark.locality, placemark.administrativeArea, placemark.country]
            .compactMap { $0 }
            .filter { !$0.isEmpty && $0 != displayName(from: placemark) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: - Geometry

    /// ~11 m grid. Coarser than a raw coordinate (so nearby fixes share one
    /// lookup) and exactly the precision the UI already prints coordinates
    /// at, so a displayed coordinate and its cache key never disagree.
    static func cellKey(latitude: Double, longitude: Double) -> String {
        String(format: "%.4f,%.4f", latitude, longitude)
    }

    /// Great-circle distance in meters.
    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let earthRadius = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
