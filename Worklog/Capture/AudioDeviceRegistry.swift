import AVFoundation
import Foundation

/// One available audio input. `uid` is a stable identity the app pins to and
/// stores; it must survive app relaunches and the device disconnecting and
/// coming back, so it is built from the port's own UID plus the data-source
/// id rather than from any transient handle.
struct AudioInputDevice: Equatable, Identifiable {
    var id: String { uid }
    let uid: String
    let name: String
    /// The session port this input lives on.
    let portUID: String
    /// Set when the input is one data source of a multi-element port - the
    /// built-in microphone array, which iOS exposes as Bottom / Front / Back
    /// on the same port.
    let dataSourceID: NSNumber?
}

/// Enumerates input ports and resolves a pinned UID back to a live one - the
/// iOS counterpart of the macOS CoreAudio registry and the Android
/// `AudioManager` one. Capture always binds to the resolved pinned input and
/// never follows whatever the system would route to on its own, which is the
/// exact failure this app exists to avoid: a headset connecting mid-meeting
/// must not silently become the source.
///
/// On iOS the pin is expressed through `AVAudioSession.setPreferredInput`,
/// which the session honours for the whole app - `AVAudioEngine`'s input node
/// then follows it. That is the reverse of macOS, where the engine's input
/// node chases the system default and the app had to drop to
/// `AVCaptureSession` to hold a pin at all.
enum AudioDeviceRegistry {

    /// A phone always has a microphone, but `availableInputs` is only
    /// populated once the session has been activated at least once in a
    /// recording-capable category. Settings and onboarding both enumerate
    /// devices before any recording has started, so the category is set up
    /// front rather than at first capture.
    static func prepareSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
            )
            try session.setActive(true, options: [])
        } catch {
            captureLog.error("audio session preparation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stable UID for a port + optional data source.
    static func uid(portUID: String, dataSourceID: NSNumber?) -> String {
        guard let dataSourceID else { return portUID }
        return "\(portUID)|\(dataSourceID.intValue)"
    }

    static func displayName(for port: AVAudioSessionPortDescription, dataSource: AVAudioSessionDataSourceDescription?) -> String {
        switch port.portType {
        case .builtInMic:
            // iPhones expose the built-in array as several data sources
            // (Bottom, Front, Back); name them the way the Android build
            // names its equivalents rather than repeating "iPhone Microphone"
            // three times.
            guard let dataSource else { return "Built-in microphone" }
            return "Built-in microphone (\(dataSource.dataSourceName.lowercased()))"
        case .headsetMic:
            return "Wired headset microphone"
        case .bluetoothHFP:
            return "\(port.portName) (Bluetooth)"
        case .usbAudio:
            return "\(port.portName) (USB)"
        case .carAudio:
            return "\(port.portName) (CarPlay)"
        case .lineIn:
            return "\(port.portName) (line in)"
        default:
            return port.portName.isEmpty ? "Input device" : port.portName
        }
    }

    /// All currently-connected inputs, built-in first. A multi-element
    /// built-in array is expanded into one entry per data source so the user
    /// can pin "the bottom mic" specifically, matching the Android build.
    static func inputDevices() -> [AudioInputDevice] {
        let session = AVAudioSession.sharedInstance()
        if session.availableInputs?.isEmpty ?? true { prepareSession() }
        guard let ports = session.availableInputs else { return [] }

        var devices: [AudioInputDevice] = []
        for port in ports {
            if let sources = port.dataSources, !sources.isEmpty {
                for source in sources {
                    devices.append(
                        AudioInputDevice(
                            uid: uid(portUID: port.uid, dataSourceID: source.dataSourceID),
                            name: displayName(for: port, dataSource: source),
                            portUID: port.uid,
                            dataSourceID: source.dataSourceID
                        )
                    )
                }
            } else {
                devices.append(
                    AudioInputDevice(
                        uid: uid(portUID: port.uid, dataSourceID: nil),
                        name: displayName(for: port, dataSource: nil),
                        portUID: port.uid,
                        dataSourceID: nil
                    )
                )
            }
        }

        var seen = Set<String>()
        return devices
            .filter { seen.insert($0.uid).inserted }
            .sorted { lhs, rhs in
                let lhsBuiltIn = lhs.name.hasPrefix("Built-in")
                let rhsBuiltIn = rhs.name.hasPrefix("Built-in")
                if lhsBuiltIn != rhsBuiltIn { return lhsBuiltIn }
                return false
            }
    }

    /// Resolves a pinned UID to a live input, or nil if it is disconnected.
    static func resolve(uid: String) -> AudioInputDevice? {
        inputDevices().first { $0.uid == uid }
    }

    static func isConnected(uid: String) -> Bool { resolve(uid: uid) != nil }

    /// Points the shared session at the given input and, for the built-in
    /// array, at the specific element. Throws so a failed pin surfaces as a
    /// capture error rather than silently recording from somewhere else.
    static func applyPreferredInput(_ device: AudioInputDevice) throws {
        let session = AVAudioSession.sharedInstance()
        guard let port = session.availableInputs?.first(where: { $0.uid == device.portUID }) else {
            throw SegmentWriterError.deviceNotFound
        }
        if let dataSourceID = device.dataSourceID,
           let source = port.dataSources?.first(where: { $0.dataSourceID == dataSourceID }) {
            try port.setPreferredDataSource(source)
        }
        try session.setPreferredInput(port)
    }
}

/// Fires whenever the set of connected inputs might have changed, so the
/// session can notice its pinned device leaving or coming back. iOS folds
/// both into one route-change notification rather than the separate
/// added/removed callbacks Android has.
final class AudioDeviceListWatcher {
    private var observers: [NSObjectProtocol] = []

    func start(onChanged: @escaping () -> Void) {
        stop()
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
                onChanged()
            }
        )
        // A media-services reset tears down every audio object the app owns;
        // the route is unchanged but everything holding it is dead, so the
        // session has to rebuild exactly as it would after a device swap.
        observers.append(
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
                AudioDeviceRegistry.prepareSession()
                onChanged()
            }
        )
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    deinit { stop() }
}
