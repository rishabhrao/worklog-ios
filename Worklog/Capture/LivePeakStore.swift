import AVFoundation
import Foundation

/// In-memory waveform peaks for the segment currently being recorded, fed
/// directly from `SegmentWriter`'s audio tap as buffers arrive.
///
/// This exists because the on-disk `.m4a` cannot be used for a live
/// waveform: the writer only updates the file's header occasionally, so a
/// fresh `AVAudioFile(forReading:)` sees a frozen length no matter how much
/// audio has actually been written since (verified empirically - three
/// reads 6s apart all reported the identical frame count while the file
/// itself kept growing). Peaks computed tap-side are always current to the
/// last buffer, with zero file I/O.
///
/// Single-writer (SegmentWriter's serial write queue), multi-reader
/// (RangeLoader on arbitrary background queues) - guarded by a lock.
final class LivePeakStore {
    static let shared = LivePeakStore()

    private let lock = NSLock()
    private var activePath: String?
    private var peaks: [Float] = []
    private var windowPeak: Float = 0
    private var framesInWindow: Int = 0
    private var framesPerWindow: Int = 4800

    struct Snapshot {
        let peaksPerSecond: Double
        let peaks: [Float]
        /// Seconds of audio represented, including the in-progress window.
        let duration: TimeInterval
    }

    /// Called when a new segment file opens - resets accumulation for it.
    func beginSegment(path: String, sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        activePath = path
        peaks = []
        windowPeak = 0
        framesInWindow = 0
        framesPerWindow = max(1, Int(sampleRate / PeakComputer.peaksPerSecond))
    }

    /// Called per tap buffer from the writer's serial queue.
    func append(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)

        lock.lock()
        defer { lock.unlock() }
        guard activePath != nil else { return }

        for frame in 0..<frames {
            var sample: Float = 0
            for channel in 0..<channels {
                sample = max(sample, abs(channelData[channel][frame]))
            }
            windowPeak = max(windowPeak, sample)
            framesInWindow += 1
            if framesInWindow >= framesPerWindow {
                peaks.append(windowPeak)
                windowPeak = 0
                framesInWindow = 0
            }
        }
    }

    /// Called when the segment closes - its real peaks now come from the
    /// finalized file via the normal peak cache, so the live copy is done.
    func endSegment(path: String) {
        lock.lock()
        defer { lock.unlock() }
        guard activePath == path else { return }
        activePath = nil
        peaks = []
        windowPeak = 0
        framesInWindow = 0
    }

    /// Path of the segment genuinely being written right now, if any -
    /// used by `StartupReconciliation.closeOrphanedOpenRows` to distinguish
    /// "actively recording" from "orphaned-open row left by a quit/crash
    /// that lost its close-write."
    var currentActivePath: String? {
        lock.lock()
        defer { lock.unlock() }
        return activePath
    }

    /// Live peaks for the given segment path, if it's the one currently
    /// recording. `nil` for anything else.
    func snapshot(forPath path: String) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard activePath == path else { return nil }
        var current = peaks
        // Include the partial window so the waveform's tail reaches "now"
        // rather than lagging up to one window behind.
        if framesInWindow > 0 {
            current.append(windowPeak)
        }
        let duration = (Double(peaks.count) * Double(framesPerWindow) + Double(framesInWindow))
            / (Double(framesPerWindow) * PeakComputer.peaksPerSecond)
        return Snapshot(peaksPerSecond: PeakComputer.peaksPerSecond, peaks: current, duration: duration)
    }
}
