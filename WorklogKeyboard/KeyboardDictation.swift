import AVFoundation
import Speech
import SwiftUI
import UIKit

/// Dictation inside the keyboard extension.
///
/// The app's `DictationController` is not reused here, and that is deliberate.
/// It borrows the *recording session* - it asks `RecordingController` to power
/// the mic on, reads out of the rolling segments, and exports a window of
/// them. An extension has none of that: no capture running, no segment writer,
/// a hard memory ceiling, and it may be killed the moment the keyboard is
/// dismissed. So this is the small version: open the mic, recognise
/// on-device, insert, and - when Full Access allows reaching the shared
/// container - write the dictation into the same database the app reads.
///
/// On-device only. A keyboard sees everything the user types; sending its
/// audio anywhere would be indefensible, and the app's cloud models stay in
/// the app.
@MainActor
final class KeyboardDictationModel: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var status = ""
    @Published private(set) var isError = false
    /// The provisional tail, shown while speaking so the user can see it is
    /// hearing them. Never inserted - only the final text is.
    @Published private(set) var partial = ""

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var startedAt: Date?

    func begin(proxy: UITextDocumentProxy?) {
        guard !isListening else { return }
        isError = false
        partial = ""

        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            Task { @MainActor in
                guard let self else { return }
                guard auth == .authorized else {
                    self.fail("Speech recognition permission is off. Turn it on in Settings › Worklog.")
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        guard granted else {
                            self.fail("Microphone access is off. Turn it on in Settings › Worklog.")
                            return
                        }
                        self.start(proxy: proxy)
                    }
                }
            }
        }
    }

    private func start(proxy: UITextDocumentProxy?) {
        let locale = Locale(identifier: WorklogSettingsStore.load().preferredPreviewLocales.first ?? Locale.current.identifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            fail("No on-device recognizer for \(locale.identifier).")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            fail("No offline model for \(locale.identifier). Add it under Settings › General › Keyboard › Dictation Languages.")
            return
        }
        self.recognizer = recognizer

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
        // Never off-device, for the reason in the type comment.
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

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.partial = result.bestTranscription.formattedString
                    self.status = self.partial.isEmpty ? "Listening…" : self.partial
                }
                if error != nil, self.isListening {
                    // A task ending mid-hold is routine (its own length
                    // limit); what was heard so far still stands.
                    self.finishAudio()
                }
            }
        }
    }

    /// Ends the dictation and inserts what was heard.
    func end(proxy: UITextDocumentProxy?) {
        guard isListening else { return }
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        let began = startedAt
        finishAudio()

        guard !text.isEmpty else {
            status = "Nothing heard"
            clearStatusSoon()
            return
        }

        // A space before, when the field already has a word right behind the
        // caret - otherwise dictating twice runs the sentences together.
        if let before = proxy?.documentContextBeforeInput,
           let last = before.last, !last.isWhitespace {
            proxy?.insertText(" ")
        }
        proxy?.insertText(text)
        WorklogHaptics.play(.dictationStop)
        status = "Inserted"
        clearStatusSoon()

        record(text: text, startedAt: began ?? Date())
    }

    /// Throws the dictation away without inserting anything.
    func cancel() {
        guard isListening else { return }
        finishAudio()
        status = "Discarded"
        clearStatusSoon()
    }

    private func finishAudio() {
        isListening = false
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Saves the dictation into the same database the app reads, so it shows
    /// up in the Dictations tab with no syncing step. Needs Full Access to
    /// reach the shared container; without it the text was still inserted,
    /// which is the part that mattered.
    private func record(text: String, startedAt: Date) {
        guard AppGroup.containerURL != nil else { return }
        let id = UUID().uuidString
        let folder = WorklogPaths.dictationFolder(dictationID: id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let textURL = WorklogPaths.dictationTextURL(dictationID: id)
        try? text.data(using: .utf8)?.write(to: textURL)

        WorklogDatabase.shared.insertKeyboardDictation(
            id: id,
            name: DictationController.defaultDictationName(for: startedAt),
            startedAt: startedAt,
            endedAt: Date(),
            text: text,
            textPath: textURL.path
        )
    }

    private func fail(_ message: String) {
        isError = true
        status = message
        isListening = false
    }

    private func clearStatusSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            partial = ""
            if !isError { status = "" }
        }
    }
}

/// The keyboard's dictation button - the same press-and-hold shape as the
/// one in the app, without the hands-free latch. A keyboard is on screen
/// only while you are holding it anyway.
struct KeyboardDictationButton: View {
    @ObservedObject var model: KeyboardDictationModel
    let proxyProvider: () -> UITextDocumentProxy?

    @State private var isHolding = false

    var body: some View {
        Circle()
            .fill(model.isListening ? Color.worklogRecording : Color.worklogAccent)
            .frame(width: 72, height: 72)
            .overlay(
                Image(systemName: "mic.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.worklogOnAccent)
            )
            .overlay(
                Circle()
                    .strokeBorder(Color.worklogRecording.opacity(0.35), lineWidth: 6)
                    .scaleEffect(model.isListening ? 1.2 : 1)
                    .opacity(model.isListening ? 1 : 0)
            )
            .scaleEffect(isHolding ? 0.94 : 1)
            .animation(MotionPrimitives.aware(MotionPrimitives.interactive), value: isHolding)
            .animation(MotionPrimitives.aware(MotionPrimitives.standard), value: model.isListening)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isHolding else { return }
                        isHolding = true
                        WorklogHaptics.play(.dictationStart)
                        model.begin(proxy: proxyProvider())
                    }
                    .onEnded { _ in
                        isHolding = false
                        model.end(proxy: proxyProvider())
                    }
            )
            .accessibilityLabel("Hold to dictate")
    }
}
