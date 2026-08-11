import AVFoundation
import Foundation

/// Broadcast point for the canonical-format audio buffers coming off
/// `SegmentWriter`'s capture delegate, so live consumers can read the
/// microphone while it is being recorded. Today: the realtime dictation
/// streamer, and the on-device speech-preview engine.
///
/// This is a process-wide singleton rather than a callback property on
/// `SegmentWriter` on purpose. The writer instance is *replaced* on several
/// paths - engine-wedge recovery, capture-error restart, device change,
/// sleep/wake resume - and each replacement builds a fresh object. A sink
/// wired onto one writer instance would be silently dropped by any of those,
/// producing a dictation that records audio to disk but streams nothing,
/// with no error anywhere. Feeding one shared point means every writer, old
/// or new, lands in the same place.
///
/// Same reasoning (and the same lifetime) as `LivePeakStore`, which sits
/// beside this in the delegate path.
final class LiveAudioTap {
    static let shared = LiveAudioTap()

    /// Who is consuming. One slot per consumer: a dictation replacing the
    /// previous dictation's sink is correct (only one dictation streams at
    /// a time), and it must never be able to displace the preview engine -
    /// which runs for the whole recording - or vice versa.
    enum Consumer: Hashable {
        case dictation
        case preview
    }

    private let lock = NSLock()
    private var sinks: [Consumer: (AVAudioPCMBuffer) -> Void] = [:]

    /// True while something is listening. Checked on the capture path to
    /// skip the (small) broadcast cost entirely when nothing is consuming.
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !sinks.isEmpty
    }

    /// Installs (or replaces) the sink for one consumer slot.
    ///
    /// Sinks are invoked on `SegmentWriter`'s serial write queue, which
    /// also has to keep up with disk writes for the always-on recording.
    /// **They must not block**: convert/copy what they need and return.
    func setSink(for consumer: Consumer, _ sink: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.lock()
        sinks[consumer] = sink
        lock.unlock()
    }

    func removeSink(for consumer: Consumer) {
        lock.lock()
        sinks[consumer] = nil
        lock.unlock()
    }

    /// Called from the capture delegate for every buffer written, in the
    /// writer's canonical format (48kHz mono float32).
    func broadcast(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let sinks = self.sinks
        lock.unlock()
        for sink in sinks.values {
            sink(buffer)
        }
    }
}
