import SwiftUI

/// The loaded range as *text*: preview words grouped into utterances, with
/// the current selection painted across them - an alternative projection of
/// exactly the same range state the waveform edits.
///
/// An all-day recording is mostly silence, and silence is where a waveform
/// spends its pixels. Words spend them on speech: hours compress into a few
/// screenfuls of readable text, and "clip that conversation" becomes
/// text-selection instead of peak-reading.
///
/// Interactions:
/// - **Click a word** - the nearer selection edge moves to it. Click before
///   the selection to grow it backward, after to grow it forward, inside to
///   shrink to the side you clicked.
/// - **Drag across words** - the selection becomes exactly the dragged span,
///   like selecting text.
/// - The waveform's handles remain the fine-trim tool; switching back and
///   forth never loses the selection, because both views edit the same one.
struct TranscriptRangePicker: View {
    let range: LoadedRange
    let selectionStart: TimeInterval
    let selectionEnd: TimeInterval
    let onStartDragged: (TimeInterval) -> Void
    let onEndDragged: (TimeInterval) -> Void

    @ObservedObject private var engine = SpeechPreviewEngine.shared

    /// One word, positioned in seconds from range start.
    struct WordToken: Equatable, Identifiable {
        let id: Int
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// A run of words with no long silence inside it.
    struct UtteranceBlock: Equatable, Identifiable {
        let id: Int
        let words: [WordToken]
        let start: TimeInterval
        let end: TimeInterval
        /// Wall-clock label shown above the block (the first block, and any
        /// block after a real gap in time).
        let timeLabel: String?
        /// "12 min silence" row shown before this block, for gaps long
        /// enough to matter.
        let gapLabel: String?
    }

    @State private var blocks: [UtteranceBlock] = []
    @State private var hasLoadedOnce = false
    @State private var loadGeneration = 0
    /// Scroll-to-selection happens once per appearance, after the first
    /// load lands - not on every refresh, which would fight the user's own
    /// scrolling while new words arrive.
    @State private var wantsInitialScroll = true

    /// Silence longer than this splits utterances.
    private static let utteranceGap: TimeInterval = 2.5
    /// Silence longer than this earns a visible gap row and a fresh time
    /// label - five minutes is where "same conversation" stops being true.
    private static let visibleGap: TimeInterval = 5 * 60

    var body: some View {
        Group {
            if !isEnabled {
                promptState(
                    icon: "captions.bubble",
                    title: "Speech previews are off",
                    detail: "Turn them on in Settings to see this range as text and clip by words."
                )
            } else if blocks.isEmpty {
                promptState(
                    icon: "text.word.spacing",
                    title: hasLoadedOnce ? "No speech previews in this range" : "Loading previews…",
                    detail: engine.status == .listening
                        ? "Words appear here as they're recognized. Previews only cover audio recorded while they were switched on."
                        : "Previews only cover audio recorded while they were switched on."
                )
            } else {
                transcript
            }
        }
        .onAppear {
            wantsInitialScroll = true
            reload()
        }
        .onChange(of: engine.wordsStoredTick) { _ in reload() }
        .onChange(of: range.requestedEnd) { _ in reload() }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: WorklogSpacing.md) {
                    ForEach(blocks) { block in
                        if let gapLabel = block.gapLabel {
                            gapRow(gapLabel)
                        }
                        TranscriptBlockView(
                            block: block,
                            selectionStart: selectionStart,
                            selectionEnd: selectionEnd,
                            onTapWord: handleTap,
                            onDragSpan: handleDragSpan
                        )
                        .id(block.id)
                    }
                }
                .padding(WorklogSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: blocks.isEmpty) { empty in
                guard !empty, wantsInitialScroll else { return }
                wantsInitialScroll = false
                proxy.scrollTo(initialScrollTarget, anchor: .center)
            }
            .onAppear {
                guard !blocks.isEmpty, wantsInitialScroll else { return }
                wantsInitialScroll = false
                proxy.scrollTo(initialScrollTarget, anchor: .center)
            }
        }
    }

    /// The block holding the selection start - or the newest speech, which
    /// is what "clip the last few minutes" wants on a fresh full-range
    /// selection.
    private var initialScrollTarget: Int {
        let containing = blocks.first { $0.end >= selectionStart }
        // A fresh load selects the whole range (start = 0): the *end* of
        // the transcript is where the action is.
        if selectionStart <= 0.5 { return blocks.last?.id ?? 0 }
        return containing?.id ?? blocks.last?.id ?? 0
    }

    private func gapRow(_ label: String) -> some View {
        HStack(spacing: WorklogSpacing.sm) {
            Rectangle().fill(Color.worklogHairline).frame(height: 1)
            Text(label)
                .font(WorklogFont.caption)
                .foregroundStyle(Color.worklogTextTertiary)
                .fixedSize()
            Rectangle().fill(Color.worklogHairline).frame(height: 1)
        }
        .padding(.vertical, WorklogSpacing.xs)
    }

    private func promptState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: WorklogSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Color.worklogTextTertiary)
            Text(title)
                .font(WorklogFont.bodyEmphasized)
                .foregroundStyle(Color.worklogTextPrimary)
            Text(detail)
                .font(WorklogFont.caption)
                .foregroundStyle(Color.worklogTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isEnabled: Bool {
        switch engine.status {
        case .off, .unavailable: return false
        case .downloadingModel, .idle, .listening: return true
        }
    }

    // MARK: - Selection edits

    /// Click: the nearer edge comes to the word. Predictable and modeless -
    /// the same rule the handles themselves obey, just addressed by word.
    private func handleTap(_ word: WordToken) {
        let mid = (word.start + word.end) / 2
        if mid <= selectionStart {
            onStartDragged(word.start)
        } else if mid >= selectionEnd {
            onEndDragged(word.end)
        } else if (mid - selectionStart) < (selectionEnd - mid) {
            onStartDragged(word.start)
        } else {
            onEndDragged(word.end)
        }
        WorklogHaptics.play(.select)
    }

    /// Drag: the selection is the dragged span, ends snapped to word
    /// boundaries.
    private func handleDragSpan(_ a: WordToken, _ b: WordToken) {
        let start = min(a.start, b.start)
        let end = max(a.end, b.end)
        // Order matters: moving the start above the current end clamps to
        // it, so the end is pushed out first when growing.
        if end > selectionEnd {
            onEndDragged(end)
            onStartDragged(start)
        } else {
            onStartDragged(start)
            onEndDragged(end)
        }
    }

    // MARK: - Data

    private func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        let start = range.requestedStart
        let end = range.requestedEnd
        Task.detached(priority: .userInitiated) {
            let words = WorklogDatabase.shared.previewWords(from: start, to: end)
            let blocks = Self.group(words, rangeStart: start)
            await MainActor.run {
                guard generation == loadGeneration else { return }
                self.blocks = blocks
                self.hasLoadedOnce = true
            }
        }
    }

    private static func group(_ words: [PreviewWord], rangeStart: Date) -> [UtteranceBlock] {
        guard !words.isEmpty else { return [] }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        var blocks: [UtteranceBlock] = []
        var current: [WordToken] = []
        var blockID = 0
        var previousBlockEnd: TimeInterval?
        var tokenID = 0

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let gap = previousBlockEnd.map { first.start - $0 }
            let needsLabel = blocks.isEmpty || (gap ?? 0) > visibleGap
            blocks.append(UtteranceBlock(
                id: blockID,
                words: current,
                start: first.start,
                end: last.end,
                timeLabel: needsLabel
                    ? formatter.string(from: rangeStart.addingTimeInterval(first.start))
                    : nil,
                gapLabel: (gap ?? 0) > visibleGap ? gapLabel(gap!) : nil
            ))
            blockID += 1
            previousBlockEnd = last.end
            current = []
        }

        for word in words {
            let token = WordToken(
                id: tokenID,
                text: word.text,
                start: word.start.timeIntervalSince(rangeStart),
                end: word.end.timeIntervalSince(rangeStart)
            )
            tokenID += 1
            if let last = current.last, token.start - last.end > utteranceGap {
                flush()
            }
            current.append(token)
        }
        flush()
        return blocks
    }

    private static func gapLabel(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min silence" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) hr silence" : "\(hours) hr \(rest) min silence"
    }
}

// MARK: - Block

/// One utterance: an optional time label, then the words as a wrapping flow
/// with the selection painted over them. Owns the click/drag gesture, using
/// per-word frames collected through an anchor preference - one geometry
/// resolution per block, not one per word.
private struct TranscriptBlockView: View {
    let block: TranscriptRangePicker.UtteranceBlock
    let selectionStart: TimeInterval
    let selectionEnd: TimeInterval
    let onTapWord: (TranscriptRangePicker.WordToken) -> Void
    let onDragSpan: (TranscriptRangePicker.WordToken, TranscriptRangePicker.WordToken) -> Void

    /// Index of the word the drag started on, and the last one it touched -
    /// `nil` between gestures.
    @State private var dragAnchorIndex: Int?
    @State private var dragLastIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
            if let label = block.timeLabel {
                Text(label)
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)
            }
            FlowLayout(spacing: 0, lineSpacing: 3) {
                ForEach(Array(block.words.enumerated()), id: \.element.id) { index, word in
                    Text(word.text)
                        .font(WorklogFont.body)
                        .foregroundStyle(isSelected(word) ? Color.worklogTextPrimary : Color.worklogTextSecondary)
                        .padding(.horizontal, 2.5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(isSelected(word) ? Color.worklogAccent.opacity(0.16) : Color.clear)
                        )
                        .anchorPreference(key: WordFramesKey.self, value: .bounds) { [index: $0] }
                }
            }
            .overlayPreferenceValue(WordFramesKey.self) { anchors in
                GeometryReader { proxy in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(selectionGesture(anchors: anchors, proxy: proxy))
                }
            }
        }
    }

    private func isSelected(_ word: TranscriptRangePicker.WordToken) -> Bool {
        let mid = (word.start + word.end) / 2
        return mid >= selectionStart && mid <= selectionEnd
    }

    private func selectionGesture(anchors: [Int: Anchor<CGRect>], proxy: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let index = wordIndex(at: value.location, anchors: anchors, proxy: proxy) else { return }
                if dragAnchorIndex == nil {
                    dragAnchorIndex = index
                    dragLastIndex = index
                    return
                }
                guard index != dragLastIndex else { return }
                dragLastIndex = index
                // Painting across words: each word crossed ticks, and the
                // selection follows live so the paint is the feedback.
                WorklogHaptics.play(.detent)
                if let anchor = dragAnchorIndex {
                    onDragSpan(block.words[anchor], block.words[index])
                }
            }
            .onEnded { _ in
                defer {
                    dragAnchorIndex = nil
                    dragLastIndex = nil
                }
                guard let anchor = dragAnchorIndex, let last = dragLastIndex else { return }
                if anchor == last {
                    onTapWord(block.words[anchor])
                }
            }
    }

    /// The word under the point - or, in the leading between lines, the
    /// nearest one, so a drag doesn't stutter as it crosses line breaks.
    private func wordIndex(at point: CGPoint, anchors: [Int: Anchor<CGRect>], proxy: GeometryProxy) -> Int? {
        var nearest: (index: Int, distance: CGFloat)?
        for (index, anchor) in anchors {
            let rect = proxy[anchor]
            if rect.contains(point) { return index }
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            let distance = dx * dx + dy * dy
            if nearest == nil || distance < nearest!.distance {
                nearest = (index, distance)
            }
        }
        // Only snap to a neighbor when actually close - a click into empty
        // space past a short last line shouldn't grab a distant word.
        guard let nearest, nearest.distance < 900 else { return nil }
        return nearest.index
    }
}

private struct WordFramesKey: PreferenceKey {
    static var defaultValue: [Int: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue()) { current, _ in current }
    }
}
