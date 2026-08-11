import SwiftUI
import UIKit

/// The Worklog keyboard.
///
/// A custom keyboard is the only sanctioned way to put text into another
/// app's field on iOS - exactly the constraint the Android build works under,
/// which is why that one ships an input method too and neither has the Mac's
/// global hotkey.
///
/// It is deliberately not a general-purpose keyboard. There is one button, it
/// dictates, and a "next keyboard" globe to get back to the one you actually
/// type with. Reimplementing QWERTY would be a worse keyboard than the system
/// one and is not what anybody installs this for.
final class KeyboardViewController: UIInputViewController {
    private var host: UIHostingController<KeyboardRootView>?

    override func viewDidLoad() {
        super.viewDidLoad()

        // The app reads these back to tell the user, accurately, what is set
        // up - there is no API for either question from the app's side.
        let defaults = AppGroup.defaults
        defaults?.set(true, forKey: "keyboard.hasEverLoaded")
        defaults?.set(hasFullAccess, forKey: "keyboard.hasFullAccess")

        let root = KeyboardRootView(
            hasFullAccess: hasFullAccess,
            onAdvance: { [weak self] in self?.advanceToNextInputMode() },
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
            view.heightAnchor.constraint(equalToConstant: 216),
        ])
        host.didMove(toParent: self)
        self.host = host
    }
}

/// The keyboard's one screen.
struct KeyboardRootView: View {
    let hasFullAccess: Bool
    let onAdvance: () -> Void
    let proxyProvider: () -> UITextDocumentProxy?

    @StateObject private var model = KeyboardDictationModel()

    var body: some View {
        VStack(spacing: WorklogSpacing.sm) {
            statusLine

            Button {} label: { EmptyView() }.frame(height: 0).hidden()

            KeyboardDictationButton(model: model, proxyProvider: proxyProvider)

            HStack {
                Button(action: onAdvance) {
                    Image(systemName: "globe")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Next keyboard")

                Spacer()

                Button {
                    proxyProvider()?.deleteBackward()
                } label: {
                    Image(systemName: "delete.left")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Delete")
            }
            .foregroundStyle(Color.worklogTextSecondary)
            .padding(.horizontal, WorklogSpacing.md)
        }
        .padding(.vertical, WorklogSpacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.worklogBackground)
    }

    private var statusLine: some View {
        Text(model.status.isEmpty ? defaultStatus : model.status)
            .font(WorklogFont.caption)
            .foregroundStyle(model.isError ? Color.worklogError : Color.worklogTextTertiary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, WorklogSpacing.lg)
            .animation(MotionPrimitives.aware(MotionPrimitives.standard), value: model.status)
    }

    private var defaultStatus: String {
        hasFullAccess
            ? "Hold to talk. Release to insert."
            : "Hold to talk. Turn on Allow Full Access in Settings to save dictations to Worklog."
    }
}
