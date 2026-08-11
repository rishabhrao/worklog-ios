import AVFoundation
import Foundation

/// The three sounds dictation makes: one for starting, one for finishing,
/// one for throwing it away.
///
/// Dictation is the one part of this app used with the window nowhere in
/// sight - you hold a key inside some other app and talk. The bubble says
/// what is happening, but you are looking at the text field, not at it, so
/// the only feedback that reliably arrives is the kind you don't have to
/// look at. That is what these are for, and it is why the *ending* sounds
/// matter more than the starting one: by then you have already looked away.
///
/// They are synthesised rather than shipped as files so there is exactly one
/// place that defines how they sound, and it reads as notes and intervals
/// instead of as a binary nobody can edit.
///
/// ## Why these three
///
/// All three are the same two-note gesture at different pitches and
/// directions, so they are told apart by *shape* rather than by having to be
/// learnt individually:
///
/// - **Start** rises a perfect fifth (E5 → B5) - opening, unresolved, "go".
/// - **Stop** is its exact mirror, falling the same fifth (B5 → E5) -
///   the same object closing. Enter and exit along the same path.
/// - **Cancel** falls the same interval an octave lower and duller
///   (E4 → A3) - recognisably the closing gesture, but sunk and gone.
///
/// Kept short (under a quarter second) and soft. The microphone is recording
/// the whole time this app runs, so anything longer or louder would be
/// audible in the clip you were making when you dictated.
@MainActor
enum DictationSounds {

    enum Cue {
        /// The hotkey went down; capture has begun.
        case start
        /// Latched hands-free - the key can be released now.
        case latch
        /// Ended and on its way to transcription.
        case stop
        /// Thrown away; nothing was saved and nothing will be inserted.
        case cancel
    }

    // MARK: - Playing

    static func play(_ cue: Cue) {
        guard isEnabled else { return }
        guard let player = player(for: cue) else { return }
        // Restarting an already-playing cue is the common case when someone
        // taps the hotkey twice quickly, and `play()` alone would be a no-op
        // on a player that hasn't finished.
        player.currentTime = 0
        player.play()
    }

    /// Renders and warms every cue. Called at launch so the first dictation
    /// of a session isn't the one that pays for synthesis and for
    /// `AVAudioPlayer` opening the output device.
    static func prepare() {
        guard isEnabled else { return }
        for cue in [Cue.start, .latch, .stop, .cancel] {
            _ = player(for: cue)
        }
    }

    private static var players: [String: AVAudioPlayer] = [:]

    private static func player(for cue: Cue) -> AVAudioPlayer? {
        let key = String(describing: cue)
        if let existing = players[key] { return existing }
        guard let player = try? AVAudioPlayer(data: render(cue)) else {
            dictationLog.error("dictation cue \(key, privacy: .public) could not be prepared")
            return nil
        }
        // Well under the level of a system alert. These play next to a live
        // microphone; they are meant to be noticed, not to announce.
        player.volume = 0.5
        player.prepareToPlay()
        players[key] = player
        return player
    }

    // MARK: - The score

    private static func notes(for cue: Cue) -> [Note] {
        switch cue {
        case .start:
            return [
                Note(frequency: .e5, start: 0, duration: 0.14, gain: 0.85, timbre: .bell),
                Note(frequency: .b5, start: 0.06, duration: 0.20, gain: 1.0, timbre: .bell),
            ]
        case .latch:
            // One tick, not a gesture: latching is a modifier on a dictation
            // already running, so it must not sound like one starting.
            return [Note(frequency: .b5, start: 0, duration: 0.09, gain: 0.7, timbre: .bell)]
        case .stop:
            return [
                Note(frequency: .b5, start: 0, duration: 0.14, gain: 0.9, timbre: .bell),
                Note(frequency: .e5, start: 0.06, duration: 0.22, gain: 1.0, timbre: .bell),
            ]
        case .cancel:
            return [
                Note(frequency: .e4, start: 0, duration: 0.13, gain: 0.8, timbre: .soft),
                Note(frequency: .a3, start: 0.065, duration: 0.26, gain: 0.9, timbre: .soft),
            ]
        }
    }

    private struct Note {
        let frequency: Double
        /// Seconds from the top of the cue.
        let start: TimeInterval
        let duration: TimeInterval
        let gain: Double
        let timbre: Timbre
    }

    /// Two voices, and the difference between them carries most of the
    /// meaning: `bell` cuts through a room, `soft` sits behind it.
    private enum Timbre {
        /// A little second and third harmonic - enough sheen to be heard
        /// over a keyboard without being shrill.
        case bell
        /// Very nearly a pure sine. Reads as dull, distant, finished.
        case soft

        /// Harmonic number to its level, relative to the fundamental.
        var partials: [(multiple: Double, level: Double)] {
            switch self {
            case .bell: return [(1, 1.0), (2, 0.17), (3, 0.05)]
            case .soft: return [(1, 1.0), (2, 0.05)]
            }
        }
    }

    // MARK: - Synthesis

    private static let sampleRate: Double = 44_100

    /// Internal rather than private so the cues can be rendered out and
    /// listened to on their own - the alternative is tuning a sound design
    /// by rebuilding the app and holding a hotkey.
    static func render(_ cue: Cue) -> Data {
        let notes = notes(for: cue)
        let span = notes.map { $0.start + $0.duration }.max() ?? 0
        let frames = Int((span + 0.01) * sampleRate)
        var samples = [Float](repeating: 0, count: max(frames, 1))

        for note in notes {
            let firstFrame = Int(note.start * sampleRate)
            let noteFrames = Int(note.duration * sampleRate)
            for frame in 0..<noteFrames {
                let index = firstFrame + frame
                guard index < samples.count else { break }
                let t = Double(frame) / sampleRate
                var value = 0.0
                for partial in note.timbre.partials {
                    value += partial.level * sin(2 * .pi * note.frequency * partial.multiple * t)
                }
                samples[index] += Float(value * note.gain * envelope(t: t, duration: note.duration))
            }
        }

        normalise(&samples, to: 0.85)
        return wav(samples)
    }

    /// Fast in, exponential out, and forced to exactly zero at the end.
    ///
    /// The attack is a raised cosine rather than a straight ramp: a linear
    /// one still starts with a corner, and a corner at this scale is an
    /// audible click. The release is the same idea at the other end - a tone
    /// cut mid-cycle pops, however quiet it had already become.
    private static func envelope(t: Double, duration: Double) -> Double {
        let attack = 0.005
        let release = 0.010
        guard t >= 0, t <= duration else { return 0 }
        let rise = t < attack ? 0.5 - 0.5 * cos(.pi * t / attack) : 1
        let decay = exp(-4.5 * t / duration)
        let fall = min(1, (duration - t) / release)
        return rise * decay * fall
    }

    private static func normalise(_ samples: inout [Float], to peak: Float) {
        guard let loudest = samples.map({ abs($0) }).max(), loudest > 0 else { return }
        let scale = peak / loudest
        for index in samples.indices { samples[index] *= scale }
    }

    /// A 16-bit mono WAV in memory. `AVAudioPlayer(data:)` takes a container,
    /// not raw frames, and a WAV header is fourteen lines - cheaper than
    /// standing up an `AVAudioEngine` and a player node just to emit a beep
    /// beside an app that is already using the audio hardware to record.
    private static func wav(_ samples: [Float]) -> Data {
        let channels = 1, bitsPerSample = 16
        let rate = Int(sampleRate)
        let blockAlign = channels * bitsPerSample / 8
        let payloadBytes = samples.count * blockAlign

        var data = Data(capacity: 44 + payloadBytes)
        func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }

        ascii("RIFF"); u32(36 + payloadBytes); ascii("WAVE")
        ascii("fmt "); u32(16)
        u16(1)                       // linear PCM
        u16(channels)
        u32(rate)
        u32(rate * blockAlign)       // byte rate
        u16(blockAlign)
        u16(bitsPerSample)
        ascii("data"); u32(payloadBytes)

        for sample in samples {
            let clamped = max(-1, min(1, sample))
            withUnsafeBytes(of: Int16(clamped * 32_767).littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    // MARK: - Settings

    /// Cached for the same reason the haptics flag is: this is checked on
    /// every hotkey press and loading settings is a database read.
    private static var cachedEnabled: Bool?

    static var isEnabled: Bool {
        if let cachedEnabled { return cachedEnabled }
        let value = WorklogSettingsStore.load().areDictationSoundsEnabled
        cachedEnabled = value
        return value
    }

    static func settingsDidChange() {
        cachedEnabled = nil
        // Re-warm rather than merely invalidating: switching the setting on
        // in Settings and immediately dictating should not be the call that
        // renders four cues.
        if isEnabled { prepare() }
    }
}

/// The pitches the cues are built from, so the score above reads as notes.
private extension Double {
    static let a3 = 220.00
    static let e4 = 329.63
    static let e5 = 659.25
    static let b5 = 987.77
}
