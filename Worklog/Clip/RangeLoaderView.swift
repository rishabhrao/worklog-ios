import SwiftUI

/// Quick presets, a free-form "load last N minutes", and a historical
/// date/time range. All three funnel into
/// `ClipScreenViewModel.loadLastMinutes`/`loadRange`.
///
/// A wrapped grid of chips rather than the macOS build's single wide row of
/// buttons and fields: five controls laid side by side need about 700pt, and
/// a phone has 402. Chips also make the primary action - grab the last few
/// minutes - the biggest thing on the screen, which is right, because it is
/// what this screen is for.
struct RangeLoaderView: View {
    @ObservedObject var viewModel: ClipScreenViewModel

    @State private var showingHistoricalPicker = false
    @State private var showingCustomMinutes = false
    @State private var freeformMinutesText = ""
    @State private var historicalStart = Date().addingTimeInterval(-3600)
    @State private var historicalEnd = Date()

    private let presets = [5, 15, 30]

    var body: some View {
        // Wrapped, not scrolled. A horizontal scroll view here was the wrong
        // control twice over: it hid the last two options off-screen with no
        // affordance saying so, and inside a safe-area inset it never got a
        // bounded width, so it sized to its content and refused to scroll at
        // all. Five short chips fit in two lines. Everything is reachable and
        // nothing is hidden.
        FlowLayout(spacing: WorklogSpacing.sm) {
            ForEach(presets, id: \.self) { minutes in
                RangeChip(title: "Last \(minutes) min", systemImage: nil) {
                    WorklogHaptics.play(.select)
                    viewModel.loadLastMinutes(Double(minutes))
                }
            }

            RangeChip(title: "Custom", systemImage: "slider.horizontal.3") {
                freeformMinutesText = ""
                showingCustomMinutes = true
            }

            RangeChip(title: "Date range", systemImage: "calendar") {
                showingHistoricalPicker = true
            }

            if viewModel.loadState != .empty {
                RangeChip(title: "Clear", systemImage: "xmark", role: .destructive) {
                    WorklogHaptics.play(.toggle)
                    viewModel.clearLoadedRange()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(MotionPrimitives.aware(MotionPrimitives.standard), value: viewModel.loadState == .empty)
        .alert("Load last N minutes", isPresented: $showingCustomMinutes) {
            TextField("Minutes", text: $freeformMinutesText)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {}
            Button("Load") { submitFreeformMinutes() }
        } message: {
            Text("How far back should the waveform reach?")
        }
        .sheet(isPresented: $showingHistoricalPicker) {
            historicalPickerContent
        }
    }

    private func submitFreeformMinutes() {
        guard let minutes = Double(freeformMinutesText), minutes > 0 else { return }
        viewModel.loadLastMinutes(minutes)
    }

    /// A sheet rather than the macOS build's popover, and iOS's own compact
    /// date pickers rather than `.field`, which does not exist here. Tapping
    /// either one opens the wheel/calendar the platform already knows.
    private var historicalPickerContent: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Start", selection: $historicalStart)
                    DatePicker("End", selection: $historicalEnd)
                } footer: {
                    Text("Segments recorded in this window stitch into one continuous waveform.")
                }
            }
            .navigationTitle("Historical range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingHistoricalPicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Load") {
                        viewModel.loadRange(start: historicalStart, end: historicalEnd)
                        showingHistoricalPicker = false
                    }
                    .disabled(historicalEnd <= historicalStart)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// One chip on the range row. Capsule, 44pt tall.
///
/// The press feel comes from a `ButtonStyle` rather than the app's shared
/// `worklogPressFeedback`, and that is the whole reason the row scrolls: that
/// modifier attaches a `DragGesture(minimumDistance: 0)` to every control,
/// which inside a horizontal scroll view wins the pan and leaves the row
/// stuck. A `ButtonStyle` reads `configuration.isPressed` from the button's
/// own recogniser and competes with nothing.
private struct RangeChip: View {
    enum Role { case normal, destructive }

    let title: String
    var systemImage: String?
    var role: Role = .normal
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: WorklogSpacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(WorklogFont.labelStrong)
                    .lineLimit(1)
            }
            .foregroundStyle(role == .destructive ? Color.worklogError : Color.worklogTextPrimary)
            .padding(.horizontal, WorklogSpacing.lg)
            .frame(minHeight: 44)
            .background(Capsule().fill(Color.worklogElevatedSurface))
            .overlay(
                Capsule().strokeBorder(
                    role == .destructive ? Color.worklogError.opacity(0.35) : Color.worklogHairline,
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(ChipButtonStyle())
    }
}

private struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(MotionPrimitives.aware(MotionPrimitives.interactive), value: configuration.isPressed)
    }
}
