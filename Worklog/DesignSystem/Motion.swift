import SwiftUI
import UIKit

/// Shared animation curves so every screen (Clip's waveform, screen
/// transitions, micro-interactions) draws from the same handful of feels
/// instead of one-off animations per view. Read `MotionPrimitives.reduceMotionEnabled`
/// before applying any of these - every call site must offer an instant
/// fallback when reduce-motion is on, per design-system spec.
enum MotionPrimitives {
    /// Standard UI transitions: navigation, hover/press state, toggles.
    static let standard = Animation.spring(response: 0.32, dampingFraction: 0.86)

    /// Slightly slower, softer spring for larger surfaces (screen/sidebar
    /// transitions, window content swaps).
    static let screenTransition = Animation.spring(response: 0.42, dampingFraction: 0.88)

    /// Snappy spring for direct-manipulation feedback (drag-release on
    /// waveform handles, button press settle).
    static let interactive = Animation.spring(response: 0.24, dampingFraction: 0.8)

    /// Press-down feedback - near-instant and critically damped. Response
    /// must be felt the moment the pointer goes down; any spring softness
    /// belongs on the release, never the press ("slow where the user is
    /// deciding, fast where the system is responding" - inverted here:
    /// the press is the system hearing you, so it's the fast side).
    static let pressDown = Animation.spring(response: 0.14, dampingFraction: 1.0)

    /// Hover color/opacity changes - a quick ease, not a spring; hover is
    /// seen dozens of times a day and should read as instant shading, not
    /// as an object moving.
    static let hover = Animation.easeOut(duration: 0.15)

    /// A single, slightly under-damped spring for moments that carry
    /// momentum or celebrate (the row's "just completed" pop, a toggle
    /// thumb landing). Bounce is reserved for these; standard UI stays
    /// critically damped.
    static let pop = Animation.spring(response: 0.38, dampingFraction: 0.68)

    /// Crossfade used specifically for theme-token changes so a
    /// System/Light/Dark switch never hard-snaps.
    static let themeTransition = Animation.easeInOut(duration: 0.25)

    /// Gentle, continuous pulse for the recording-live indicator.
    static let livePulse = Animation.easeInOut(duration: 1.1).repeatForever(autoreverses: true)

    /// True when the user has "Reduce Motion" enabled in system
    /// Accessibility settings. Every animated call site must branch on this
    /// and substitute an instant change (or a much-reduced, non-repeating
    /// variant for persistent effects like `livePulse`) rather than ignore it.
    static var reduceMotionEnabled: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    /// Returns `animation` normally, or `nil` (instant/no animation) when
    /// reduce-motion is on. Use this at call sites instead of referencing
    /// the raw curves directly: `withAnimation(MotionPrimitives.aware(.standard)) { ... }`.
    static func aware(_ animation: Animation) -> Animation? {
        reduceMotionEnabled ? nil : animation
    }
}

/// View modifier that applies a gentle continuous pulse (opacity breathing)
/// for "live" state indicators, honoring reduce-motion by freezing at full
/// opacity instead of animating.
struct LivePulseModifier: ViewModifier {
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(MotionPrimitives.reduceMotionEnabled ? 1.0 : (pulsing ? 0.45 : 1.0))
            .onAppear {
                guard !MotionPrimitives.reduceMotionEnabled else { return }
                withAnimation(MotionPrimitives.livePulse) {
                    pulsing = true
                }
            }
    }
}

extension View {
    /// Applies the shared live-pulse breathing effect, respecting reduce-motion.
    func livePulse() -> some View {
        modifier(LivePulseModifier())
    }

    /// Gentle one-shot entrance (fade + small rise) for content that just
    /// arrived on screen - empty states, freshly loaded panes. Purely
    /// decorative and short; reduce-motion drops the movement and keeps a
    /// quick fade (comprehension-aiding opacity is fine, motion is not).
    func gentleEntrance(delay: Double = 0) -> some View {
        modifier(GentleEntranceModifier(delay: delay))
    }
}

struct GentleEntranceModifier: ViewModifier {
    let delay: Double
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || MotionPrimitives.reduceMotionEnabled ? 0 : 6)
            .onAppear {
                let animation = MotionPrimitives.reduceMotionEnabled
                    ? Animation.easeOut(duration: 0.15)
                    : MotionPrimitives.standard.delay(delay)
                withAnimation(animation) {
                    appeared = true
                }
            }
    }
}
