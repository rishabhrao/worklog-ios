import Foundation
import UIKit

/// Where a finished dictation's text goes.
///
/// On macOS this synthesised keystrokes into whatever app had focus, which
/// needed an Accessibility grant and a lot of care about focus moving
/// mid-dictation. iOS forbids that outright: no app can put text into another
/// app's field. The only sanctioned route is a keyboard extension, which owns
/// a `UITextDocumentProxy` pointing at the field being edited - so that is the
/// route, exactly as the Android build uses an input method for the same
/// reason.
///
/// The consequence is two insertion targets rather than one:
///
/// - **Keyboard extension.** A proxy is attached, text is inserted directly,
///   and the dictation reads as typing.
/// - **In the app itself.** There is no field to type into, so the text goes
///   to the clipboard and the dictation is saved to the Dictations tab. That
///   is reported honestly as `.copiedOnly` rather than pretending it landed
///   somewhere.
@MainActor
final class DictationInserter {

    enum PasteOutcome {
        /// Went into the field the user was editing.
        case pasted
        /// Only reached the clipboard - no field was available.
        case copiedOnly
        /// There was nothing to insert.
        case nothingToInsert
    }

    /// Set by the keyboard extension while it is on screen; nil everywhere
    /// else. Weak-ish by construction: the extension clears it in
    /// `viewWillDisappear`, because a proxy outliving its input session
    /// inserts text into nothing.
    var proxy: UITextDocumentProxy?

    /// Text inserted so far this session, so a dictation that loses its
    /// field partway can put the remainder somewhere useful.
    private(set) var bufferedText: String = ""

    /// True when there is no field to insert into - which in this app means
    /// "we are not running inside the keyboard". The macOS build used this to
    /// mean "focus moved since the dictation started"; the consequence is the
    /// same either way, so the callers are unchanged.
    var didLoseTarget: Bool { proxy == nil }

    private var streamedText: String = ""

    func beginSession(guardsFocus: Bool) {
        bufferedText = ""
        streamedText = ""
    }

    /// Types a committed phrase as it arrives, for realtime dictation in
    /// type-as-you-speak mode.
    func insertStreaming(segment: String) {
        guard !segment.isEmpty else { return }
        bufferedText += bufferedText.isEmpty ? segment : " " + segment
        guard let proxy else { return }
        proxy.insertText(streamedText.isEmpty ? segment : " " + segment)
        streamedText = bufferedText
    }

    /// Removes text this session already typed - a discarded dictation must
    /// not leave half a sentence behind in someone's message.
    func undoStreamingInsertion() {
        guard let proxy, !streamedText.isEmpty else {
            bufferedText = ""
            streamedText = ""
            return
        }
        for _ in 0..<streamedText.count { proxy.deleteBackward() }
        bufferedText = ""
        streamedText = ""
    }

    /// Puts the whole text in, in one go.
    func pasteAll(_ text: String) -> PasteOutcome {
        guard !text.isEmpty else { return .nothingToInsert }
        guard let proxy else {
            copyToPasteboard(text)
            return .copiedOnly
        }
        proxy.insertText(text)
        return .pasted
    }

    func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }
}
