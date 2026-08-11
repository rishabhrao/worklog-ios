import SwiftUI

/// Naming and shaping one place. Deliberately one view for both entry
/// points - the popover on a clip's location and the Places tab's detail
/// pane - so a place behaves identically whichever door you came in
/// through, and there is only one place for the rules to live.
struct PlaceEditorView: View {
    /// The coordinate being named. For an existing place this is its center,
    /// not wherever the clip that opened the editor happened to be.
    let latitude: Double
    let longitude: Double
    /// The place that already covers this coordinate, if any - its name and
    /// radius seed the fields, and its presence is what turns "Name this
    /// place" into an edit (with a Remove action).
    let existing: PlaceRecord?
    /// What the OS calls this coordinate, shown so the custom name is
    /// clearly an override of something rather than the only thing known.
    let detectedName: String?
    /// Dismisses the surrounding popover/sheet. The Places tab passes an
    /// empty closure - its editor is always on screen.
    var onClose: () -> Void = {}
    /// Popovers need an explicit width to size themselves; the Places tab's
    /// pane fills whatever it is given.
    var width: CGFloat? = 340
    /// Reports the draft radius as the slider moves, so a surrounding view
    /// can preview the same circle. Without it the Places tab would show a
    /// count for the radius you're choosing next to a list for the radius
    /// you saved last - two answers to one question.
    var onRadiusChange: (Double) -> Void = { _ in }

    @State private var name: String = ""
    @State private var radiusMeters: Double = PlaceRadius.standard
    @State private var coordinates: [(latitude: Double, longitude: Double)] = []
    @State private var justSaved = false
    @FocusState private var isNameFocused: Bool

    @ObservedObject private var store = PlaceStore.shared

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Live as the radius changes: how many recordings this circle claims.
    private var affectedCount: Int {
        store.recordingCount(
            in: coordinates,
            latitude: latitude,
            longitude: longitude,
            radiusMeters: radiusMeters,
            excluding: existing?.id
        )
    }

    /// Other places' names, offered as one-click fills. Naming a second
    /// building "Work" is legitimate - two places can share a name, they're
    /// still separate circles.
    private var suggestions: [String] {
        var seen = Set<String>()
        return store.places
            .filter { $0.id != existing?.id }
            .map(\.name)
            .filter { seen.insert($0).inserted }
            .prefix(4)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.md) {
            header
            nameField
            if !suggestions.isEmpty && trimmedName.isEmpty {
                suggestionRow
            }
            // Directly above the control that changes it, so a drag and its
            // effect are in the same glance.
            PlaceMapPreviewView(
                latitude: latitude,
                longitude: longitude,
                radiusMeters: radiusMeters,
                excludingPlaceID: existing?.id
            )
            RadiusSliderView(meters: $radiusMeters)
                .onChange(of: radiusMeters) {
                    onRadiusChange(radiusMeters)
                    if justSaved { justSaved = false }
                }
            reachSummary
            Divider().overlay(Color.worklogHairline)
            actions
        }
        .padding(WorklogSpacing.lg)
        .frame(width: width, alignment: .leading)
        .onAppear {
            name = existing?.name ?? ""
            radiusMeters = existing?.radiusMeters ?? PlaceRadius.standard
            onRadiusChange(radiusMeters)
            coordinates = WorklogDatabase.shared.taggedCoordinates()
            isNameFocused = true
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.xs) {
            Text(existing == nil ? "Name this place" : "Edit place")
                .font(WorklogFont.bodyEmphasized)
                .foregroundStyle(Color.worklogTextPrimary)
            Text(subtitle)
                .font(WorklogFont.caption)
                .foregroundStyle(Color.worklogTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Always says what the OS calls this spot, so removing a custom name is
    /// a visible trade rather than a leap - you can see what you'd get back.
    private var subtitle: String {
        if let detectedName {
            return "\(detectedName) · \(String(format: "%.4f, %.4f", latitude, longitude))"
        }
        return String(format: "%.4f, %.4f", latitude, longitude)
    }

    private var nameField: some View {
        TextField("Home, Office, Studio…", text: $name)
            .textFieldStyle(.plain)
            .font(WorklogFont.body)
            .foregroundStyle(Color.worklogTextPrimary)
            .focused($isNameFocused)
            .padding(.horizontal, WorklogSpacing.sm)
            .padding(.vertical, WorklogSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: WorklogRadius.sm, style: .continuous)
                    .fill(Color.worklogSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: WorklogRadius.sm, style: .continuous)
                    .strokeBorder(Color.worklogHairline, lineWidth: 1)
            )
            .onSubmit(save)
            .onChange(of: name) { if justSaved { justSaved = false } }
    }

    private var suggestionRow: some View {
        HStack(spacing: WorklogSpacing.xs) {
            ForEach(suggestions, id: \.self) { suggestion in
                Button { name = suggestion } label: {
                    Text(suggestion)
                        .font(WorklogFont.footnote)
                        .foregroundStyle(Color.worklogTextSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, WorklogSpacing.sm)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.worklogSurface)
                        )
                        .overlay(Capsule().strokeBorder(Color.worklogHairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Use “\(suggestion)” for this place too")
            }
        }
    }

    /// The whole point of the radius control, in one line: what this circle
    /// currently covers. Renaming a place is retroactive, so seeing the
    /// count before saving is the difference between a confident edit and a
    /// guess.
    private var reachSummary: some View {
        HStack(spacing: WorklogSpacing.xs) {
            Image(systemName: "square.stack.3d.up")
            Text(affectedCount == 1 ? "Covers 1 recording here" : "Covers \(affectedCount) recordings here")
        }
        .font(WorklogFont.caption)
        .foregroundStyle(Color.worklogTextTertiary)
    }

    private var actions: some View {
        HStack(spacing: WorklogSpacing.sm) {
            WorklogIconButton(systemName: "map", label: "Open in Maps") {
                PlaceEditorView.openInMaps(latitude: latitude, longitude: longitude, label: trimmedName)
            }
            if existing != nil {
                WorklogIconButton(systemName: "trash", label: "Remove this name", tint: Color.worklogError, action: confirmRemove)
            }
            Spacer()
            WorklogButton("Cancel", kind: .secondary, action: onClose)
                .fixedSize()
            // The button reports its own outcome. In the Places tab the pane
            // stays put after a save, so without this the press has no answer
            // at all; in the popover it holds the confirmation just long
            // enough to be read before dismissing.
            WorklogButton(justSaved ? "Saved" : "Save", action: save)
                .fixedSize()
                // Live only when there is something to save - pressing a lit
                // button that does nothing is what makes an editor feel
                // broken. It stays lit through the confirmation, since a
                // greyed-out "Saved" would read as a failure.
                .disabled(!hasChanges && !justSaved)
        }
    }

    /// True when the fields differ from what's stored - a new place with a
    /// name, or an edit that actually changes something.
    private var hasChanges: Bool {
        guard !trimmedName.isEmpty else { return false }
        guard let existing else { return true }
        return trimmedName != existing.name || radiusMeters != existing.radiusMeters
    }

    /// Says exactly what removal does - including that it reaches backwards,
    /// which is the one thing about this feature a user could be surprised
    /// by.
    private var removeMessage: String {
        let count = existing.map {
            store.recordingCount(
                in: coordinates,
                latitude: $0.latitude,
                longitude: $0.longitude,
                radiusMeters: $0.radiusMeters,
                excluding: $0.id
            )
        } ?? 0
        let subject = count == 1 ? "1 recording" : "\(count) recordings"
        let fallback = detectedName.map { "“\($0)”" } ?? "its coordinates"
        return "\(subject) here will go back to \(fallback) - the name your Mac detects."
    }

    // MARK: - Actions

    private func save() {
        guard !trimmedName.isEmpty, !justSaved else { return }
        if let existing {
            store.update(existing, name: trimmedName, radiusMeters: radiusMeters)
        } else {
            store.save(name: trimmedName, latitude: latitude, longitude: longitude, radiusMeters: radiusMeters)
        }
        // The "Saved" morph is the visual half of this confirmation; the
        // haptic is the half that lands even when your eyes are still on
        // the map above the button.
        WorklogHaptics.play(.success)
        withAnimation(MotionPrimitives.aware(MotionPrimitives.standard)) { justSaved = true }
        // Hold the confirmation long enough to be read, then hand control
        // back: a popover closes (its job is done), a pane stays and the
        // button relaxes.
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            onClose()
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation(MotionPrimitives.aware(MotionPrimitives.standard)) { justSaved = false }
        }
    }

    /// This confirmation guards a retroactive change, so it asks even though
    /// the button that opens it is already explicit.
    private func confirmRemove() {
        guard let existing else { return }
        Platform.confirm(
            title: "Remove the name “\(existing.name)”?",
            message: removeMessage,
            confirmTitle: "Remove",
            isDestructive: true
        ) {
            store.remove(existing)
            // Removing a name is retroactive - every past recording here goes
            // back to what the OS called it - so it gets the two-knock pattern
            // rather than the one a save gets.
            WorklogHaptics.play(.warning)
            onClose()
        }
    }

    static func openInMaps(latitude: Double, longitude: Double, label: String = "") {
        let query = label.isEmpty ? "Recording location" : label
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Recording+location"
        guard let url = URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)&q=\(encoded)") else { return }
        Platform.open(url)
    }
}
