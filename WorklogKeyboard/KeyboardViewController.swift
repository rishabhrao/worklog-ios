import AVFoundation
import Speech
import SwiftUI
import UIKit

/// The Worklog keyboard.
///
/// A custom keyboard is the only sanctioned way to put text into another
/// app's field on iOS - exactly the constraint the Android build works under,
/// which is why that one ships an input method too and neither has the Mac's
/// global hotkey.
///
/// Deliberately not a general-purpose keyboard: one button that dictates, a
/// globe to get back to the keyboard you actually type with, and a delete.
/// Reimplementing QWERTY would be a worse keyboard than the system one and is
/// not what anybody installs this for.
///
/// **This target compiles nothing from the app.** An extension runs under a
/// hard memory ceiling and can be killed the moment the keyboard is
/// dismissed, so it carries its own small copies of the few things it needs
/// rather than pulling in the database layer, the capture engine and the
/// design system. The duplication is a handful of colours and a date format.
final class KeyboardViewController: UIInputViewController {
    private var host: UIHostingController<KeyboardRootView>?

    override func viewDidLoad() {
        super.viewDidLoad()

        // The app reads these back to tell the user accurately what is set
        // up - there is no API to ask either question from the app's side.
        let defaults = UserDefaults(suiteName: KeyboardBridge.appGroup)
        defaults?.set(true, forKey: "keyboard.hasEverLoaded")
        defaults?.set(hasFullAccess, forKey: "keyboard.hasFullAccess")

        let root = KeyboardRootView(
            hasFullAccess: hasFullAccess,
            onAdvance: { [weak self] in self?.advanceToNextInputMode() },
            onDelete: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            proxyProvider: { [weak self] in self?.textDocumentProxy }
        )
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            // A keyboard has no intrinsic height; without this it collapses.
            view.heightAnchor.constraint(equalToConstant: 232),
        ])
        host.didMove(toParent: self)
        self.host = host
    }
}

struct KeyboardRootView: View {
    let hasFullAccess: Bool
    let onAdvance: () -> Void
    let onDelete: () -> Void
    let proxyProvider: () -> UITextDocumentProxy?

    @StateObject private var model = KeyboardDictationModel()

    var body: some View {
        VStack(spacing: 10) {
            Text(model.status.isEmpty ? defaultStatus : model.status)
                .font(.footnote)
                .foregroundStyle(model.isError ? KeyboardPalette.error : KeyboardPalette.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .animation(.easeOut(duration: 0.2), value: model.status)

            KeyboardDictationButton(model: model, proxyProvider: proxyProvider)

            HStack {
                keyButton("globe", label: "Next keyboard", action: onAdvance)
                Spacer()
                keyButton("delete.left", label: "Delete", action: onDelete)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KeyboardPalette.background)
    }

    private func keyButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(KeyboardPalette.secondaryText)
                .frame(width: 48, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    private var defaultStatus: String {
        hasFullAccess
            ? "Hold to talk. Release to insert."
            : "Hold to talk. Turn on Allow Full Access to save dictations to Worklog."
    }
}

/// The extension's own tokens. The app's design system is not imported here -
/// see the note on `KeyboardViewController`.
enum KeyboardPalette {
    static let background = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(hue: 0.08, saturation: 0.018, brightness: 0.13, alpha: 1)
        : UIColor(hue: 0.08, saturation: 0.010, brightness: 0.965, alpha: 1) })
    static let accent = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.361, green: 0.541, blue: 0.639, alpha: 1)
        : UIColor(red: 0.145, green: 0.365, blue: 0.478, alpha: 1) })
    static let recording = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(hue: 0.0, saturation: 0.72, brightness: 0.94, alpha: 1)
        : UIColor(hue: 0.0, saturation: 0.78, brightness: 0.86, alpha: 1) })
    static let secondaryText = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.72, alpha: 1) : UIColor(white: 0.38, alpha: 1) })
    static let error = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(hue: 0.0, saturation: 0.65, brightness: 0.90, alpha: 1)
        : UIColor(hue: 0.0, saturation: 0.72, brightness: 0.80, alpha: 1) })
    static let onAccent = Color.white
}
