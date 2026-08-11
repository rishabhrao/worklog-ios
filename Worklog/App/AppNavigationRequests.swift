import Combine
import Foundation

enum AppShellRoute: String, Hashable {
    case clip
    case library
    case dictations
    case settings
}

/// Navigation asked for from outside the view tree - a tapped notification,
/// a file shared into the app. Both can arrive before the shell exists on a
/// cold start, so the request is held until something is listening rather
/// than published into the void.
///
/// Mirrors the Android build's object of the same name.
enum AppNavigationRequests {
    private static let subject = CurrentValueSubject<AppShellRoute?, Never>(nil)

    static var publisher: AnyPublisher<AppShellRoute, Never> {
        subject.compactMap { $0 }.eraseToAnyPublisher()
    }

    static func request(_ route: AppShellRoute) {
        subject.send(route)
    }

    static func consume() {
        subject.send(nil)
    }
}
