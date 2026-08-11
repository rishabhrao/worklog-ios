import Foundation
import os

/// Takes in dictations spoken into the Worklog keyboard.
///
/// The keyboard deliberately does not write to `worklog.db`. Two processes
/// writing one SQLite file is a real hazard, and an extension can be killed
/// mid-write at any moment - a half-written row in someone's only database is
/// a bad trade for a convenience. So the keyboard drops a small JSON file into
/// the shared container and this drains that folder, on the app's own normal
/// write path, whenever the app becomes active.
///
/// Dictations from the keyboard have no audio: an extension has neither the
/// capture session nor the memory budget to record and export one, and it does
/// not need to - the text was inserted into the field the moment it was
/// spoken, and this is the record of it.
@MainActor
enum KeyboardInbox {
    private static let log = Logger(subsystem: "com.rishabhrao.worklog", category: "dictation")

    /// Mirrors `KeyboardBridge.Handoff` in the extension. The two are
    /// deliberately separate declarations - the extension shares no code with
    /// the app - so this is the contract between them.
    private struct Handoff: Codable {
        let id: String
        let text: String
        let startedAt: Date
        let endedAt: Date
    }

    static func drain() {
        guard let inbox = AppGroup.containerURL?.appendingPathComponent("keyboard-inbox", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil),
              !files.isEmpty else { return }

        var imported = 0
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let handoff = try? JSONDecoder().decode(Handoff.self, from: data) else {
                // Unreadable: remove it rather than retrying forever.
                try? FileManager.default.removeItem(at: file)
                continue
            }

            let folder = WorklogPaths.dictationFolder(dictationID: handoff.id)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let textURL = WorklogPaths.dictationTextURL(dictationID: handoff.id)
            try? handoff.text.data(using: .utf8)?.write(to: textURL, options: .atomic)

            WorklogDatabase.shared.insertKeyboardDictation(
                id: handoff.id,
                name: DictationController.defaultDictationName(for: handoff.startedAt),
                startedAt: handoff.startedAt,
                endedAt: handoff.endedAt,
                textPath: textURL.path
            )
            try? FileManager.default.removeItem(at: file)
            imported += 1
        }

        if imported > 0 {
            log.info("imported \(imported, privacy: .public) dictation(s) from the keyboard")
            NotificationCenter.default.post(name: DictationController.didChangeNotification, object: nil)
        }
    }
}
