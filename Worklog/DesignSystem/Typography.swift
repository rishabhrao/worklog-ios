import SwiftUI

/// Spacing rhythm - the only spacing values used anywhere in the app.
/// No view should hardcode a magic-number padding/spacing constant;
/// compose from this small set (per design-system spec).
enum WorklogSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32

    /// The screen's side margin. 16pt is the iOS standard and what every
    /// system control aligns to; content that sets its own inset immediately
    /// looks off next to a navigation title.
    static let screenMargin: CGFloat = 16

    /// Kept so views shared with the macOS build still compile. iOS has no
    /// overlay scrollbar sitting on top of content, so it is zero here rather
    /// than reserving a gutter nothing needs.
    static let scrollbarGutter: CGFloat = 0
}

/// Corner radii, kept alongside spacing since both drive the app's
/// "precise, tactile" surfaces and should stay consistent across
/// buttons/cards/rows rather than being picked ad hoc per view.
///
/// Larger than the macOS build's, deliberately: iOS's own surfaces are much
/// rounder than the desktop's, and a 6pt card reads as a web page next to a
/// system sheet.
enum WorklogRadius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 18
}

/// Type scale - sizes/weights for headers, body, captions, and the
/// monospace style reserved for transcript/technical text (SF Mono).
///
/// The sizes are iOS's, not the macOS build's. Those are a desktop scale
/// (13pt body) read at arm's length on a large display; on a phone held a
/// foot from your face the same numbers are simply too small, and an app that
/// ships them looks like a port. The token *names* are identical to the macOS
/// build so every shared view compiles unchanged - only the values move.
///
/// Everything is built on `Font.system(_:design:weight:)` with a semantic text
/// style rather than a fixed point size, so the whole app follows Dynamic
/// Type. That is not a nicety on iOS: text size is the single most-used
/// accessibility setting there is.
enum WorklogFont {
    static let largeTitle = Font.system(.largeTitle, design: .default, weight: .bold)
    static let title = Font.system(.title2, design: .default, weight: .semibold)

    /// Size-specific tracking (WWDC "Details of UI Typography"): large
    /// text reads too loose at default spacing, so display sizes tighten;
    /// body stays at 0. Apply via `.kerning(...)` on title Texts - SwiftUI
    /// fonts can't carry tracking themselves.
    static let largeTitleTracking: CGFloat = -0.4
    static let titleTracking: CGFloat = -0.2

    static let headline = Font.system(.headline, design: .default, weight: .semibold)
    static let body = Font.system(.body, design: .default, weight: .regular)
    static let bodyEmphasized = Font.system(.body, design: .default, weight: .medium)
    static let caption = Font.system(.caption, design: .default, weight: .regular)
    static let footnote = Font.system(.footnote, design: .default, weight: .medium)

    /// Row titles and other places that need a touch more presence than body
    /// without becoming a heading.
    static let labelStrong = Font.system(.subheadline, design: .default, weight: .semibold)
    static let label = Font.system(.subheadline, design: .default, weight: .regular)

    /// Transcript/technical text - SF Mono. A notch below body, because a
    /// monospace face at the same point size reads noticeably larger.
    static let transcript = Font.system(.callout, design: .monospaced, weight: .regular)
    static let transcriptCaption = Font.system(.caption, design: .monospaced, weight: .regular)

    /// SF Pro Rounded for select numerals/headers (e.g. selection-length
    /// readout, clip duration) - used sparingly, not as the body face.
    static let numeralRounded = Font.system(.headline, design: .rounded, weight: .semibold)
    static let headerRounded = Font.system(.title2, design: .rounded, weight: .bold)
}
