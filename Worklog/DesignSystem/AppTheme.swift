import SwiftUI
import Combine

/// User-facing theme override. `.system` (the default) tracks macOS
/// appearance; `.light`/`.dark` pin the app regardless of system setting.
/// Persisted so the override survives relaunch - Priority 7's Settings
/// screen is the only writer besides the default.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Single source of truth for the theme override, read by the app shell to
/// apply `.preferredColorScheme` and animated so switches crossfade rather
/// than snap (per spec §5.2 / design-system spec's "Theming").
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published private(set) var theme: AppTheme

    private static let defaultsKey = "worklog.appTheme"

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey)
        theme = raw.flatMap(AppTheme.init(rawValue:)) ?? .system
    }

    func setTheme(_ theme: AppTheme) {
        UserDefaults.standard.set(theme.rawValue, forKey: Self.defaultsKey)
        withAnimation(MotionPrimitives.aware(MotionPrimitives.themeTransition)) {
            self.theme = theme
        }
    }
}
