import SwiftUI

/// Quick presets, a free-form "load last N minutes", and a historical
/// date/time range. All three funnel into
/// `ClipScreenViewModel.loadLastMinutes`/`loadRange`.
///
/// A scrolling row of chips rather than the macOS build's single wide row of
/// buttons and fields: five controls laid side by side need about 700pt, and
/// a phone has 402. Chips also make the primary action - grab the last few
/// minutes - the biggest thing on the row, which is right, because it is what
/// this screen is for.
struct RangeLoaderView: View {
    @ObservedObject var viewModel: ClipScreenViewModel

    @State private var showingHistoricalPicker = false
    @State private var showingCustomMinutes = false
    @State private var freeformMinutesText = ""
    @State private var historicalStart = Date().addingTimeInterval(-3600)
    @State private var historicalEnd = Date()

    private let presets = [5, 15, 30]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: WorklogSpacing.sm) {
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
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .padding(.horizontal, WorklogSpacing.screenMargin)
            .padding(.vertical, WorklogSpacing.xs)
        }
        // The row bleeds to the screen edges so chips scroll out from under
        // the margin rather than stopping short of it.
        .padding(.horizontal, -WorklogSpacing.screenMargin)
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

/// One chip on the range row. Capsule, 44pt tall, presses like every other
/// control in the app.
private struct RangeChip: View {
    enum Role { case normal, destructive }

    let title: String
    var systemImage: String?
    var role: Role = .normal
    let action: () -> Void

    @State private var isPressing = false

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
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressing ? 0.96 : 1)
        .worklogPressFeedback(isPressing: $isPressing, haptic: nil)
    }
}
