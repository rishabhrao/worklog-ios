import AVFoundation
import Foundation

/// Reads how much of an `.m4a` is currently decodable, without doing a full
/// peak computation - used for a still-open (actively recording) segment,
/// where `AVAudioFile.length` reflects whatever's been flushed to disk so
/// far. Opening the file for reading while another writer still has it open
/// for writing is safe; AVFoundation only reads back already-written,
/// complete frames.
enum AudioFileDuration {
    static func current(for url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
