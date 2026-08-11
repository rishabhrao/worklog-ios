import SwiftUI
import UIKit

/// Semantic color tokens - the *only* way color is expressed in any view.
/// No view should ever construct `Color(red:green:blue:)` or a raw hex
/// literal; every surface, text style, and status indicator reads from
/// `Color.worklog*` below. Both light and dark variants are hand-tuned
/// (never a naive inversion) with a warm hue bias that ties the neutral
/// ramp to the accent, per design-system spec.
///
/// The accent itself honors the system accent color (`Color.accentColor`)
/// rather than a fixed brand color - per ticket §5.1, "system accent color
/// honored."
enum WorklogPalette {
    // Warm-biased neutral ramp (a faint warm cast, not default template
    // grey) - hue ~30° (warm paper/graphite), very low saturation.
    static func neutral(_ white: Double, saturationBoost: Double = 0.012) -> Color {
        Color(hue: 0.08, saturation: saturationBoost, brightness: white)
    }

    // MARK: Light theme

    enum Light {
        static let background = neutral(0.965, saturationBoost: 0.010)
        static let surface = neutral(0.985, saturationBoost: 0.008)
        static let elevatedSurface = Color.white
        static let hairline = neutral(0.82, saturationBoost: 0.012)

        static let textPrimary = neutral(0.14, saturationBoost: 0.010)
        static let textSecondary = neutral(0.38, saturationBoost: 0.010)
        static let textTertiary = neutral(0.58, saturationBoost: 0.010)

        static let recording = Color(hue: 0.0, saturation: 0.78, brightness: 0.86)
        static let success = Color(hue: 0.36, saturation: 0.55, brightness: 0.68)
        static let warning = Color(hue: 0.11, saturation: 0.75, brightness: 0.92)
        static let error = Color(hue: 0.0, saturation: 0.72, brightness: 0.80)
    }

    // MARK: Dark theme

    enum Dark {
        static let background = neutral(0.09, saturationBoost: 0.018)
        static let surface = neutral(0.13, saturationBoost: 0.016)
        static let elevatedSurface = neutral(0.17, saturationBoost: 0.014)
        static let hairline = neutral(0.26, saturationBoost: 0.014)

        static let textPrimary = neutral(0.95, saturationBoost: 0.006)
        static let textSecondary = neutral(0.72, saturationBoost: 0.008)
        static let textTertiary = neutral(0.52, saturationBoost: 0.010)

        static let recording = Color(hue: 0.0, saturation: 0.72, brightness: 0.94)
        static let success = Color(hue: 0.37, saturation: 0.50, brightness: 0.78)
        static let warning = Color(hue: 0.11, saturation: 0.70, brightness: 0.95)
        static let error = Color(hue: 0.0, saturation: 0.65, brightness: 0.90)
    }
}

/// Resolves the correct token for the *current* SwiftUI color scheme.
/// Views read these via `@Environment(\.colorScheme)` implicitly by using
/// `Color.worklogBackground` etc., which pick the right branch dynamically
/// (SwiftUI re-evaluates `Color` computed properties on scheme change, so
/// this participates correctly in the theme-transition animation).
extension Color {
    private static func token(light: Color, dark: Color) -> Color {
        Color(UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    static var worklogBackground: Color { token(light: WorklogPalette.Light.background, dark: WorklogPalette.Dark.background) }
    static var worklogSurface: Color { token(light: WorklogPalette.Light.surface, dark: WorklogPalette.Dark.surface) }
    static var worklogElevatedSurface: Color { token(light: WorklogPalette.Light.elevatedSurface, dark: WorklogPalette.Dark.elevatedSurface) }
    static var worklogHairline: Color { token(light: WorklogPalette.Light.hairline, dark: WorklogPalette.Dark.hairline) }

    static var worklogTextPrimary: Color { token(light: WorklogPalette.Light.textPrimary, dark: WorklogPalette.Dark.textPrimary) }
    static var worklogTextSecondary: Color { token(light: WorklogPalette.Light.textSecondary, dark: WorklogPalette.Dark.textSecondary) }
    static var worklogTextTertiary: Color { token(light: WorklogPalette.Light.textTertiary, dark: WorklogPalette.Dark.textTertiary) }

    /// System accent color, honored per ticket §5.1 rather than a fixed brand hue.
    static var worklogAccent: Color { Color.accentColor }

    static var worklogRecording: Color { token(light: WorklogPalette.Light.recording, dark: WorklogPalette.Dark.recording) }
    static var worklogSuccess: Color { token(light: WorklogPalette.Light.success, dark: WorklogPalette.Dark.success) }
    static var worklogWarning: Color { token(light: WorklogPalette.Light.warning, dark: WorklogPalette.Dark.warning) }
    static var worklogError: Color { token(light: WorklogPalette.Light.error, dark: WorklogPalette.Dark.error) }

    /// Foreground color for content drawn on top of a filled accent surface
    /// (primary/destructive button labels, the selected candidate marker,
    /// a toggle's thumb) - always white regardless of appearance, since the
    /// surface underneath is itself a saturated fill, not a themed
    /// background. Exists so call sites never reach for a raw `.white`.
    static var worklogOnAccent: Color { .white }
}
