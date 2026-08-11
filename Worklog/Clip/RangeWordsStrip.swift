import SwiftUI

/// The words at the selection's edges, under the waveform: what a clip cut
/// at these handles would open and close with.
///
/// This answers the question the waveform can't - "what am I actually
/// selecting?" - at exactly the moment it's asked, live while a handle is
/// dragged. The side being dragged brightens, because that's the edge whose
/// words are changing under the finger.
///
/// Hidden entirely while speech previews are off; while they're on the row
/// keeps a stable height (placeholder text when the selection holds no
/// speech) so dragging never makes the layout jump.
struct RangeWordsStrip: View {
    let range: LoadedRange
    let selectionStart: TimeInterval
    let selectionEnd: TimeInterval
    let isDraggingStart: Bool
    let isDraggingEnd: Bool

    @ObservedObject private var engine = SpeechPreviewEngine.shared

    private enum EdgeWords: Equatable {
        case none
        /// The whole selection is short enough to just say.
        case whole(String)
        case edges(String, String)
    }

    @State private var words: EdgeWords = .none

    /// How many words each edge shows, and the threshold under which the
    /// selection is shown whole instead of as two edges with a hole.
    private static let edgeWordCount = 5

    var body: some View {
        if isEnabled {
            content
                .frame(height: 16)
                .onAppear(perform: reload)
                .onChange(of: quantizedSelection) { _ in reload() }
                .onChange(of: engine.wordsStoredTick) { _ in reload() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch words {
        case .none:
            Text("No speech in this selection")
                .font(WorklogFont.caption)
                .foregroundStyle(Color.worklogTextTertiary)
                .frame(maxWidth: .infinity)
        case .whole(let text):
            Text("\u{201C}\(text)\u{201D}")
                .font(WorklogFont.caption)
                .foregroundStyle(Color.worklogTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
        case .edges(let start, let end):
            HStack(spacing: WorklogSpacing.md) {
                Text("\u{201C}\(start) …")
                    .font(WorklogFont.caption)
                    .foregroundStyle(isDraggingStart ? Color.worklogTextPrimary : Color.worklogTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: WorklogSpacing.md)
                Text("… \(end)\u{201D}")
                    .font(WorklogFont.caption)
                    .foregroundStyle(isDraggingEnd ? Color.worklogTextPrimary : Color.worklogTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    /// The strip exists whenever the feature is on - including mid-download,
    /// when it's about to start being useful - and never when it's off.
    private var isEnabled: Bool {
        switch engine.status {
        case .off, .unavailable: return false
        case .downloadingModel, .idle, .listening: return true
        }
    }

    /// Selection quantized to quarter-seconds: fine enough that words change
    /// the moment a handle crosses one, coarse enough that a drag doesn't
    /// re-query per pixel.
    private var quantizedSelection: [Int] {
        [
            Int(selectionStart * 4),
            Int(selectionEnd * 4),
            Int(range.requestedStart.timeIntervalSince1970),
        ]
    }

    private func reload() {
        let start = range.requestedStart.addingTimeInterval(selectionStart)
        let end = range.requestedStart.addingTimeInterval(selectionEnd)
        guard end > start else {
            words = .none
            return
        }

        // One capped probe decides the shape: a short selection is shown
        // whole; a long one as its two edges.
        let probe = WorklogDatabase.shared.previewWords(from: start, to: end, limit: Self.edgeWordCount * 2 + 2)
        if probe.isEmpty {
            words = .none
        } else if probe.count <= Self.edgeWordCount * 2 + 1 {
            words = .whole(probe.map(\.text).joined(separator: " "))
        } else {
            let first = probe.prefix(Self.edgeWordCount).map(\.text).joined(separator: " ")
            let last = WorklogDatabase.shared
                .lastPreviewWords(from: start, to: end, limit: Self.edgeWordCount)
                .map(\.text)
                .joined(separator: " ")
            words = .edges(first, last)
        }
    }
}
