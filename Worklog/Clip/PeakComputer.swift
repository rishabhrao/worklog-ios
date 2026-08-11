import AVFoundation
import Foundation

/// Computes downsampled amplitude peaks for a finalized `.m4a` segment, for
/// the waveform peak-cache (spec `05-clip-screen-and-waveform.md`): "cache a
/// peaks file alongside each segment... computed once when the segment is
/// finalized." Decoding happens once per segment, off the main queue; the
/// result is a small `Float` array (`~10` peaks/second) stored in
/// `worklog.db`'s `segment_peaks` table so the Clip screen never re-decodes
/// raw PCM to draw or re-draw a waveform.
enum PeakComputer {
    /// Peaks-per-second resolution: enough for retina-sharp rendering at
    /// realistic on-screen widths for even a multi-hour range, without
    /// storing more samples than any zoom level could use.
    static let peaksPerSecond: Double = 10

    /// Decodes `url` fully (a single ~5-minute mono segment, small enough
    /// this is cheap) and reduces it to one peak (max absolute sample
    /// magnitude) per `1 / peaksPerSecond` window.
    static func computePeaks(for url: URL) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return [] }

        do {
            try file.read(into: buffer)
        } catch {
            return []
        }

        guard let channelData = buffer.floatChannelData else { return [] }
        let sampleRate = format.sampleRate
        let samplesPerWindow = max(1, Int(sampleRate / peaksPerSecond))
        let totalSamples = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)

        var peaks: [Float] = []
        peaks.reserveCapacity(totalSamples / samplesPerWindow + 1)

        var windowStart = 0
        while windowStart < totalSamples {
            let windowEnd = min(windowStart + samplesPerWindow, totalSamples)
            var peak: Float = 0
            for channel in 0..<channelCount {
                let samples = channelData[channel]
                for i in windowStart..<windowEnd {
                    peak = max(peak, abs(samples[i]))
                }
            }
            peaks.append(peak)
            windowStart = windowEnd
        }

        return peaks
    }
}
