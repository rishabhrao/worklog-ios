import SwiftUI

/// Places, as a Settings section: every named place, plus the spots you
/// record at most that aren't named yet.
///
/// A plain list, with the editor opening over it - the same shape as the tag
/// manager beside it, and the same editor a clip's location chip opens.
/// Places stopped being a tab, then stopped being a page: naming a place is
/// setup, a place is a name and a radius, and neither warranted a screen.
struct PlacesSettingsView: View {
    @ObservedObject private var store = PlaceStore.shared

    @State private var editingKey: String?
    @State private var suggestions: [PlaceStore.Suggestion] = []
    @State private var entries: [WorklogDatabase.TaggedEntry] = []
    /// One per group: the two lists grow for different reasons, so opening
    /// the one you care about shouldn't drag the other open with it.
    @State private var placesExpanded = false
    @State private var suggestionsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.sm) {
            if store.places.isEmpty && suggestions.isEmpty {
                Text("No places yet. Once recordings carry a location, the spots you record at most show up here to name.")
                    .font(WorklogFont.caption)
                    .foregroundStyle(Color.worklogTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !store.places.isEmpty {
                sectionLabel("Your places")
                ForEach(store.places.capped(to: ShowMoreButton.collapsedLimit, expanded: placesExpanded)) { place in
                    row(
                        key: "p:\(place.id)",
                        title: place.name,
                        caption: "\(PlaceRadius.label(place.radiusMeters)) · \(countLabel(store.recordingCount(in: coordinates, latitude: place.latitude, longitude: place.longitude, radiusMeters: place.radiusMeters, excluding: place.id)))",
                        isNamed: true,
                        latitude: place.latitude,
                        longitude: place.longitude,
                        existing: place
                    )
                }
                ShowMoreButton(total: store.places.count, isExpanded: $placesExpanded)
            }

            if !suggestions.isEmpty {
                sectionLabel("Suggested")
                    .padding(.top, store.places.isEmpty ? 0 : WorklogSpacing.xs)
                ForEach(suggestions.capped(to: ShowMoreButton.collapsedLimit, expanded: suggestionsExpanded)) { suggestion in
                    row(
                        key: suggestion.id,
                        title: suggestion.displayName,
                        caption: countLabel(suggestion.count),
                        isNamed: false,
                        latitude: suggestion.latitude,
                        longitude: suggestion.longitude,
                        existing: nil
                    )
                }
                ShowMoreButton(total: suggestions.count, isExpanded: $suggestionsExpanded)
            }
        }
        .onAppear(perform: refresh)
        // A place saved or removed changes both lists - a named cluster
        // leaves Suggested and joins Your places - and a shrunk circle pushes
        // recordings back into Suggested on its own.
        .onChange(of: store.places) { refresh() }
        .onChange(of: store.geocodes.count) { refresh() }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(WorklogFont.footnote)
            .kerning(0.6)
            .foregroundStyle(Color.worklogTextTertiary)
    }

    @ViewBuilder
    private func row(
        key: String,
        title: String,
        caption: String,
        isNamed: Bool,
        latitude: Double,
        longitude: Double,
        existing: PlaceRecord?
    ) -> some View {
        WorklogListRow(action: { editingKey = key }) {
            HStack(spacing: WorklogSpacing.sm) {
                Image(systemName: isNamed ? "mappin.circle.fill" : "mappin.and.ellipse")
                    .foregroundStyle(isNamed ? Color.worklogAccent : Color.worklogTextTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(isNamed ? WorklogFont.bodyEmphasized : WorklogFont.body)
                        .foregroundStyle(isNamed ? Color.worklogTextPrimary : Color.worklogTextSecondary)
                        .lineLimit(1)
                    Text(caption)
                        .font(WorklogFont.caption)
                        .foregroundStyle(Color.worklogTextTertiary)
                }
                Spacer()
            }
        }
        // The same editor the location chip on a clip opens, over the list
        // rather than in a page of its own - a place is a name and a radius.
        .popover(
            isPresented: Binding(
                get: { editingKey == key },
                set: { if !$0 { editingKey = nil } }
            ),
            arrowEdge: .trailing
        ) {
            PlaceEditorView(
                latitude: latitude,
                longitude: longitude,
                existing: existing,
                detectedName: store.label(latitude: latitude, longitude: longitude)?.detectedName,
                onClose: { editingKey = nil }
            )
        }
    }

    private var coordinates: [(latitude: Double, longitude: Double)] {
        entries.map { (latitude: $0.latitude, longitude: $0.longitude) }
    }

    private func refresh() {
        entries = WorklogDatabase.shared.taggedEntries()
        suggestions = store.suggestions()
    }

    private func countLabel(_ count: Int) -> String {
        count == 1 ? "1 recording" : "\(count) recordings"
    }
}
