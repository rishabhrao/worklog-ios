import SwiftUI

extension View {
    /// The app's rename prompt. A plain iOS text-field alert, which is the
    /// native shape for "give this one thing a new name" - the macOS build
    /// renamed in place in the detail header, but a phone has nowhere to put
    /// an inline editor without shifting everything under it.
    func worklogRenameDialog(
        isPresented: Binding<Bool>,
        title: String,
        text: Binding<String>,
        onCommit: @escaping () -> Void
    ) -> some View {
        alert(title, isPresented: isPresented) {
            TextField("Name", text: text)
                .textInputAutocapitalization(.sentences)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                WorklogHaptics.play(.success)
                onCommit()
            }
        } message: {
            Text("This only changes what it's called here.")
        }
    }
}
