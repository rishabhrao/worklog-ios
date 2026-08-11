import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The handful of places the app has to talk to the system rather than to
/// itself. Kept in one file so the iOS-specific calls are countable, and so
/// the view models that use them read the same as their macOS counterparts
/// instead of sprouting `#if os(...)` throughout.
/// A message a view model needs to put in front of the user. The macOS build
/// ran a modal `NSAlert` from wherever it happened to be; on iOS presentation
/// belongs to the view, so the model publishes one of these and the screen
/// binds an `.alert` to it.
struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}

enum Platform {

    /// Copy text. The macOS build's `NSPasteboard.general.setString`.
    static func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
    }

    /// Open a URL in whatever app handles it - a map, Safari, Settings.
    static func open(_ url: URL) {
        UIApplication.shared.open(url)
    }

    /// Jump to this app's page in Settings, where microphone, location and
    /// notification permissions live once the user has denied one. On macOS
    /// this was a deep link into System Settings' privacy pane; on iOS every
    /// per-app permission is on one screen, so there is a single destination.
    static func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        open(url)
    }

    /// Ask before doing something expensive or destructive, then do it.
    ///
    /// The macOS build ran an `NSAlert` modally and branched on the return
    /// value, which iOS has no equivalent of - nothing blocks the main thread
    /// here. The call sites keep their shape (ask, then act in a closure)
    /// rather than being restructured into published state and a bound
    /// `.alert`, because there are only a handful of them and they are all
    /// "confirm this one action", never a state a screen needs to render.
    static func confirm(
        title: String,
        message: String,
        confirmTitle: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) {
        guard let presenter = topMostViewController() else {
            // Nothing on screen to present from. Refusing is the safe branch:
            // silently performing an action the user was about to be asked
            // about is the one outcome that must never happen.
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: confirmTitle, style: isDestructive ? .destructive : .default) { _ in
            action()
        })
        presenter.present(alert, animated: true)
    }

    /// Tell the user something they cannot act on.
    static func notify(title: String, message: String) {
        guard let presenter = topMostViewController() else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
    }

    private static func topMostViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.keyWindow?.rootViewController else { return nil }
        return topMost(from: root)
    }

    /// Present the system share sheet for a set of files.
    ///
    /// This replaces the macOS build's "reveal in Finder", which has no iOS
    /// equivalent worth faking: the files *are* browsable, in the Files app
    /// under On My iPhone › Worklog, but no API opens Files at a path. Sharing
    /// is what someone actually wants from that button on a phone anyway -
    /// send the clip to a chat, save it to Files, drop it in a note.
    static func share(_ urls: [URL], from source: UIView? = nil) {
        guard !urls.isEmpty else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.keyWindow?.rootViewController else { return }

        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        // iPad presents this as a popover and hard-crashes without an anchor.
        if let popover = controller.popoverPresentationController {
            let anchor = source ?? root.view
            popover.sourceView = anchor
            popover.sourceRect = CGRect(x: anchor?.bounds.midX ?? 0, y: anchor?.bounds.midY ?? 0, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        topMost(from: root).present(controller, animated: true)
    }

    private static func topMost(from controller: UIViewController) -> UIViewController {
        var top = controller
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}

extension UIWindowScene {
    var keyWindow: UIWindow? {
        windows.first(where: \.isKeyWindow) ?? windows.first
    }
}
