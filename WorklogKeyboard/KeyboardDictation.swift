import AVFoundation
import Speech
import SwiftUI
import UIKit

/// How a dictation spoken into the keyboard reaches the app.
///
/// The extension deliberately does not open `worklog.db`. Two processes
/// writing one SQLite file is a real hazard, and an extension can be killed
/// mid-write at any moment; a half-written row in the user's only database
/// would be a bad trade for a convenience. Instead the keyboard drops a small
/// JSON file into the shared container and the app drains that folder on
/// launch, inside its own normal write path.
enum KeyboardBridge {
    static let appGroup = "group.com.rishabhrao.worklog"

    /// Where handoff files live. Nil when the app group is not provisioned,
    /// in which case the dictation is still inserted - it just is not saved.
    static var inboxURL: URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let inbox = container.appendingPathComponent("keyboard-inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    /// One dictation, as written by the keyboard and read by the app.
    struct Handoff: Codable {
        let id: String
        let text: String
        let startedAt: Date
        let endedAt: Date
    }

    static func write(text: String, startedAt: Date, endedAt: Date) {
        guard let inbox = inboxURL else { return }
        let handoff = Handoff(id: UUID().uuidString, text: text, startedAt: startedAt, endedAt: endedAt)
        guard let data = try? JSONEncoder().encode(handoff) else { return }
        try? data.write(to: inbox.appendingPathComponent("\(handoff.id).json"), options: .atomic)
    }
}

/// Dictation inside the keyboard extension.
///
/// On-device only, always. A keyboard sees everything the user types; sending
/// its audio anywhere would be indefensible, so the app's cloud models stay in
/// the app and this checks `supportsOnDeviceRecognition` before it will run -
/// without an installed offline model `SFSpeechRecognizer` silently falls back
/// to Apple's servers, which is exactly what must not happen here.
@MainActor
final class KeyboardDictationModel: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var status = ""
    @Published private(set) var isError = false

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var heard = ""
    private var startedAt: Date?

    func begin() {
        guard !isListening else { return }
        isError = false
        heard = ""

        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            Task { @MainActor in
                guard let self else { return }
                guard auth == .authorized else {
                    self.fail("Speech recognition is off. Turn it on in Settings › Worklog.")
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        guard granted else {
                            self.fail("Microphone access is off. Turn it on in Settings › Worklog.")
                            return
                        }
                        self.start()
                    }
                }
            }
        }
    }

    private func start() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else {
            fail("No recognizer for \(Locale.current.identifier).")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            fail("No offline model for \(Locale.current.identifier). Add it under Settings › General › Keyboard › Dictation Languages.")
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            fail("Couldn't start the microphone.")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        if #available(iOS 16.0, *) { request.addsPunctuation = true }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            fail("The microphone isn't available right now.")
            return
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            fail("Couldn't start the microphone.")
            return
        }

        startedAt = Date()
        isListening = true
        status = "Listening…"

        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            Task { @MainActor in
                guard let self, self.isListening else { return }
                guard let result else { return }
                self.heard = result.bestTranscription.formattedString
                self.status = self.heard.isEmpty ? "Listening…" : self.heard
            }
        }
    }

    /// Ends the dictation and inserts what was heard.
    func end(proxy: UITextDocumentProxy?) {
        guard isListening else { return }
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let began = startedAt ?? Date()
        stopAudio()

        guard !text.isEmpty else {
            status = "Nothing heard"
            clearSoon()
            return
        }

        // A separating space when the caret is right behind a word, or two
        // dictations run into each other.
        if let before = proxy?.documentContextBeforeInput, let last = before.last, !last.isWhitespace {
            proxy?.insertText(" ")
        }
        proxy?.insertText(text)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        status = "Inserted"
        clearSoon()

        KeyboardBridge.write(text: text, startedAt: began, endedAt: Date())
    }

    private func stopAudio() {
        isListening = false
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func fail(_ message: String) {
        isError = true
        status = message
        isListening = false
    }

    private func clearSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if !isError { status = "" }
        }
    }
}

/// The keyboard's dictation button - the same press-and-hold shape as the app's,
/// without the hands-free latch. The keyboard is only on screen while you are
/// there anyway.
struct KeyboardDictationButton: View {
    @ObservedObject var model: KeyboardDictationModel
    let proxyProvider: () -> UITextDocumentProxy?

    @State private var isHolding = false

    var body: some View {
        Circle()
            .fill(model.isListening ? KeyboardPalette.recording : KeyboardPalette.accent)
            .frame(width: 72, height: 72)
            .overlay(
                Image(systemName: "mic.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(KeyboardPalette.onAccent)
            )
            .overlay(
                Circle()
                    .strokeBorder(KeyboardPalette.recording.opacity(0.35), lineWidth: 6)
                    .scaleEffect(model.isListening ? 1.2 : 1)
                    .opacity(model.isListening ? 1 : 0)
            )
            .scaleEffect(isHolding ? 0.94 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.8), value: isHolding)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.isListening)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isHolding else { return }
                        isHolding = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        model.begin()
                    }
                    .onEnded { _ in
                        isHolding = false
                        model.end(proxy: proxyProvider())
                    }
            )
            .accessibilityLabel("Hold to dictate")
    }
}
