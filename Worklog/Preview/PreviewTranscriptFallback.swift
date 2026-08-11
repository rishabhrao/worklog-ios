import SwiftUI

/// Which saved snapshot a preview belongs to, if any.
///
/// A clip or dictation keeps its own copy of the words the on-device engine
/// heard, taken when it was cut (`clip_preview_words` /
/// `dictation_preview_words`). That copy outlives the raw audio, so reading
/// through the owner is what makes an old clip still show its preview. The
/// free-floating time range is the fallback for anything created before the
/// snapshot existed - and for windows that aren't a clip at all.
enum PreviewTranscriptOwner {
    case clip(String)
    case dictation(String)
    case timeRangeOnly
}

/// The rough on-device preview of a time window.
///
/// Appears in two roles, and the difference between them is a hierarchy
/// decision, not a styling one:
///
/// - `.primary` - Scribe isn't going to answer: it's switched off, has no
///   key, failed, or hasn't finished yet. Then these words *are* the
///   transcript, and they are rendered as one - full weight, no apology,
///   provenance stated once by the section's own subtitle. This is what
///   makes Worklog usable without ever linking a Scribe account: a complete
///   transcription path where nothing leaves the machine. It is also the
///   resilience story - a dictation made offline, or a clip stuck behind a
///   dead network, is readable the moment it exists rather than a spinner
///   with audio behind it.
///
/// - `.companion` - Scribe's transcript is present, and this one stays
///   permanently beside it. Collapsed by default, because two full
///   transcripts stacked would make the reader scroll past the *less*
///   accurate one to reach anything else, and the page would read as "two
///   transcripts" rather than "the transcript, plus what the device heard".
///   Collapsed still means present: the row names it, counts it, and opens
///   in one click. It is never discarded when Scribe lands - it is the only
///   record of what this device itself heard, it is what the clip's own
///   preview timeline was built from, and it stays readable long after the
///   raw audio has aged out of retention.
///
/// Always attributed, so it can never be silently mistaken for Scribe's
/// work - as a companion by its own row, as the primary transcript by the
/// provenance line under the section header.
struct PreviewTranscriptFallback: View {
    enum Role {
        /// The on-device words *are* the transcript for this item - because
        /// Scribe is switched off, has no key, failed, or hasn't finished.
        /// Rendered at full weight, with provenance stated by the section
        /// around it, because for someone who never links a Scribe account
        /// this is the only transcript there will ever be.
        case primary
        /// Scribe's transcript is present; these stay beside it, collapsed.
        case companion
    }

    let start: Date
    let end: Date
    var owner: PreviewTranscriptOwner = .timeRangeOnly
    var role: Role = .primary

    @State private var text = ""
    @State private var wordCount = 0
    @State private var isExpanded = false
    @State private var hasLoaded = false
    @State private var isPreviewsEnabled = false
    @ObservedObject private var engine = SpeechPreviewEngine.shared

    var body: some View {
        // The conditional content lives *inside* an always-present VStack:
        // `.onAppear` on a view that renders nothing never fires, which
        // left this permanently empty the first time around.
        VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
            if text.isEmpty {
                // Only the primary role speaks up when empty: as a companion
                // there is simply nothing to add, but as *the* transcript,
                // silence needs explaining.
                if role == .primary, hasLoaded { emptyBody }
            } else {
                switch role {
                case .primary: primaryBody
                case .companion: companionBody
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: load)
        // A dictation sitting on "Transcribing…" gets its preview the
        // moment those words finalize, not on the next open.
        .onChange(of: engine.wordsStoredTick) { _ in load() }
    }

    // MARK: - Roles

    /// No card, no badge: at full weight this reads as the transcript,
    /// which is what it is. Where it came from is said once, by the
    /// provenance line directly under the section's header, rather than
    /// repeated as a decoration around the text.
    private var primaryBody: some View {
        transcriptText
    }

    private var emptyBody: some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
            badge(caption: isPreviewsEnabled
                ? "Nothing transcribed here."
                : "No transcription. Turn on Scribe or on-device speech in Settings.")
        }
        .padding(WorklogSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: WorklogRadius.sm, style: .continuous)
                .fill(Color.worklogSurface)
        }
    }

    /// Deliberately the same chevron, rotation and timing as the detail
    /// view's own transcript sections - a second disclosure idiom on the
    /// same screen would read as a different kind of thing.
    private var companionBody: some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
            HStack(spacing: WorklogSpacing.xs) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.worklogTextTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(MotionPrimitives.aware(MotionPrimitives.interactive), value: isExpanded)
                Image(systemName: "captions.bubble")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.worklogTextTertiary)
                Text("On-device preview")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextSecondary)
                // The count is what makes the collapsed row worth having:
                // it says there is something here, and how much, without
                // asking anyone to open it.
                Text("\(wordCount) word\(wordCount == 1 ? "" : "s")")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(MotionPrimitives.aware(MotionPrimitives.standard)) {
                    isExpanded.toggle()
                }
            }

            if isExpanded {
                transcriptText
            }
        }
    }

    // MARK: - Pieces

    private func badge(caption: String) -> some View {
        HStack(spacing: WorklogSpacing.xs) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 9, weight: .medium))
            Text(caption)
                .font(WorklogFont.caption)
        }
        .foregroundStyle(Color.worklogTextTertiary)
    }

    private var transcriptText: some View {
        Text(text)
            .font(WorklogFont.transcript)
            .foregroundStyle(Color.worklogTextSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func load() {
        let start = self.start
        let end = self.end
        let owner = self.owner
        Task.detached(priority: .userInitiated) {
            let database = WorklogDatabase.shared
            // The owner's own snapshot first - it is the durable copy, and
            // for anything older than retention it is the only one left.
            var words: [PreviewWord]
            switch owner {
            case .clip(let id): words = database.clipPreviewWords(clipID: id)
            case .dictation(let id): words = database.dictationPreviewWords(dictationID: id)
            case .timeRangeOnly: words = []
            }
            if words.isEmpty {
                words = database.previewWords(from: start, to: end, limit: 4_000)
            }
            let joined = words.map(\.text).joined(separator: " ")
            let count = words.count
            let enabled = WorklogSettingsStore.load().isSpeechPreviewsEnabled
            await MainActor.run {
                text = joined
                wordCount = count
                isPreviewsEnabled = enabled
                hasLoaded = true
            }
        }
    }
}
