import SwiftUI

/// Renders a long block of text without laying all of it out at once.
///
/// A single SwiftUI `Text` holding a whole transcript has to lay the entire
/// string out synchronously, on the main thread, before it can report its
/// height - and `.textSelection(.enabled)` builds selection infrastructure
/// across the whole run on top of that. A real clip transcript here is ~52KB
/// over ~1000 lines, which froze the app for seconds the moment its section
/// was expanded, and made scrolling afterwards unusable.
///
/// Splitting on newlines and handing the pieces to a `LazyVStack` means only
/// the lines near the viewport are ever built. The split is free of visual
/// cost because the source text is already line-structured - one line per
/// speaker turn for transcripts, per markdown line otherwise. Measured on
/// this app's own data the median line is ~32 characters and the p90 is
/// ~130, so no individual line is expensive to lay out.
///
/// The one thing this gives up is selection *across* lines: each line is
/// independently selectable, but a drag can't span several. Every section
/// that uses this already has a Copy button for the whole artifact, which is
/// how you get all of it.
struct LazyLongText: View {
    private struct Line: Identifiable {
        let id: Int
        let text: String
    }

    private let lines: [Line]
    private let font: Font

    init(_ text: String, font: Font = WorklogFont.transcript) {
        self.font = font
        self.lines = text
            .components(separatedBy: .newlines)
            .enumerated()
            .map { Line(id: $0.offset, text: $0.element) }
    }

    var body: some View {
        // spacing: 0 because the source newlines already provide the
        // separation - adding more would space paragraphs differently than
        // the single-Text rendering this replaces.
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                // An empty Text collapses to zero height, which would eat
                // the blank lines that separate markdown paragraphs; a
                // space keeps the line's full height.
                Text(line.text.isEmpty ? " " : line.text)
                    .font(font)
                    .foregroundStyle(Color.worklogTextPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
