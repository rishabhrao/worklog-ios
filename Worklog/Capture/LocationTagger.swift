import CoreLocation
import Foundation

/// A single location tag for a raw audio segment, captured at segment close
/// and written straight into the segment's `worklog.db` row - no sidecar
/// file (per explicit user request: everything in the database).
struct SegmentLocationTag: Codable {
    let latitude: Double
    let longitude: Double
    let capturedAt: Date
}

/// Location tagging for raw segments. Never blocks or degrades recording:
/// if permission is missing or no fix is available, callers just get `nil`
/// back and proceed without a tag.
///
/// Reliability model (this went wrong twice before - see guardrails): a
/// fix must survive app relaunches. CoreLocation's delegate callback can
/// take minutes to fire after a launch (and macOS visibly stops delivering
/// updates at all after rapid repeated relaunches), so waiting on
/// `didUpdateLocations` alone left every segment after a relaunch untagged.
/// Three layers make a tag available immediately:
///  1. the freshest in-process delegate fix,
///  2. `CLLocationManager.location` - the system's own cached last fix,
///     available synchronously right after launch,
///  3. the last good fix persisted in `app_state`, seeded at init.
/// Whichever candidate is newest (and within `maxFixAge`) wins.
final class LocationTagger: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var lastLocation: CLLocation?

    /// Fired on every fresh CoreLocation fix - used to stamp the
    /// currently-open segment row the moment a fix finally arrives, so a
    /// slow first fix still tags the segment being written right now.
    var onFix: ((SegmentLocationTag) -> Void)?

    /// A cached/persisted fix older than this is treated as unknown -
    /// better no tag than somewhere the Mac hasn't been since yesterday.
    private static let maxFixAge: TimeInterval = 24 * 60 * 60
    private static let persistedFixKey = "last-location"

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        lastLocation = Self.loadPersistedFix()
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    func requestPermissionIfNeeded() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    func startUpdatingIfAuthorized() {
        guard isAuthorized else { return }
        manager.startUpdatingLocation()
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
    }

    /// Best-effort current tag for a segment being written. Returns `nil`
    /// silently (never throws, never blocks) when permission is missing or
    /// no acceptable fix exists in any layer.
    func currentTag() -> SegmentLocationTag? {
        guard isAuthorized else { return nil }
        let candidates = [lastLocation, manager.location].compactMap { $0 }
        guard let best = candidates.max(by: { $0.timestamp < $1.timestamp }),
              Date().timeIntervalSince(best.timestamp) <= Self.maxFixAge else { return nil }
        return SegmentLocationTag(
            latitude: best.coordinate.latitude,
            longitude: best.coordinate.longitude,
            capturedAt: best.timestamp
        )
    }

    private var isAuthorized: Bool {
        manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorized
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        lastLocation = latest
        let tag = SegmentLocationTag(
            latitude: latest.coordinate.latitude,
            longitude: latest.coordinate.longitude,
            capturedAt: latest.timestamp
        )
        Self.persistFix(tag)
        onFix?(tag)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Location is best-effort only - a failure here must never affect
        // recording, so there is nothing to surface, just drop it.
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if isAuthorized {
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
        }
    }

    // MARK: - Persisted last fix (survives relaunches)

    private static func loadPersistedFix() -> CLLocation? {
        guard let json = WorklogDatabase.shared.appStateValue(forKey: persistedFixKey),
              let data = json.data(using: .utf8),
              let tag = try? JSONDecoder().decode(SegmentLocationTag.self, from: data),
              Date().timeIntervalSince(tag.capturedAt) <= maxFixAge else { return nil }
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: tag.latitude, longitude: tag.longitude),
            altitude: 0,
            horizontalAccuracy: kCLLocationAccuracyHundredMeters,
            verticalAccuracy: -1,
            timestamp: tag.capturedAt
        )
    }

    private static func persistFix(_ tag: SegmentLocationTag) {
        guard let data = try? JSONEncoder().encode(tag),
              let json = String(data: data, encoding: .utf8) else { return }
        WorklogDatabase.shared.setAppStateValue(json, forKey: persistedFixKey)
    }
}
