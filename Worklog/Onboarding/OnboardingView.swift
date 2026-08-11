import AVFoundation
import SwiftUI
import UIKit

/// First run: a short, calm, two-step flow - choose the pinned mic, grant
/// microphone permission - then straight into a recording-ready idle state.
/// Not a long wizard; location and API keys are deliberately absent, deferred
/// to Settings.
///
/// Laid out the way iOS lays out a first-run screen, which is not how the
/// macOS build does it: content flows from the top under the safe area, the
/// primary action is a full-width button pinned above the home indicator, and
/// nothing has a fixed size. The macOS version is a 520x460 panel centred in
/// its own window - rendered as-is on a phone it clipped its own title.
struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    let onFinished: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: WorklogSpacing.xl) {
                    header
                    Group {
                        switch viewModel.step {
                        case .chooseDevice: deviceStep
                        case .microphonePermission: micPermissionStep
                        case .done: EmptyView()
                        }
                    }
                    // Slide sideways between steps - the two steps are a
                    // sequence, and the motion should say so.
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 24)),
                        removal: .opacity.combined(with: .offset(x: -24))
                    ))
                    .id(viewModel.step)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, WorklogSpacing.screenMargin)
                .padding(.top, WorklogSpacing.xl)
                .padding(.bottom, WorklogSpacing.xl)
            }
            .scrollBounceBehavior(.basedOnSize)

            footer
        }
        .background(Color.worklogBackground.ignoresSafeArea())
        .animation(MotionPrimitives.aware(MotionPrimitives.screenTransition), value: viewModel.step)
        .onChange(of: viewModel.step) { _, newValue in
            if newValue == .done { onFinished() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.lg) {
            WorklogWordmark()
            StepDots(current: viewModel.step == .chooseDevice ? 0 : 1, total: 2)
        }
    }

    // MARK: - Step 1

    private var deviceStep: some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.lg) {
            titleBlock(
                "Welcome to Worklog",
                "Pick the microphone Worklog should always record from. It stays pinned to that one, whatever else connects."
            )

            if viewModel.availableDevices.isEmpty {
                WorklogCard {
                    VStack(spacing: WorklogSpacing.sm) {
                        Image(systemName: "mic.slash")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(Color.worklogTextTertiary)
                        Text("No microphone detected")
                            .font(WorklogFont.bodyEmphasized)
                            .foregroundStyle(Color.worklogTextPrimary)
                        Text("Connect one and reopen Worklog.")
                            .font(WorklogFont.caption)
                            .foregroundStyle(Color.worklogTextTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, WorklogSpacing.sm)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.availableDevices.enumerated()), id: \.element.uid) { index, device in
                        if index > 0 {
                            Divider()
                                .overlay(Color.worklogHairline)
                                .padding(.leading, WorklogSpacing.lg)
                        }
                        deviceRow(device)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: WorklogRadius.lg, style: .continuous)
                        .fill(Color.worklogElevatedSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: WorklogRadius.lg, style: .continuous)
                        .strokeBorder(Color.worklogHairline, lineWidth: 1)
                )
            }
        }
    }

    private func deviceRow(_ device: AudioInputDevice) -> some View {
        let isSelected = viewModel.selectedDeviceUID == device.uid
        return Button {
            WorklogHaptics.play(.select)
            viewModel.selectedDeviceUID = device.uid
        } label: {
            HStack(spacing: WorklogSpacing.md) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.worklogAccent : Color.worklogTextTertiary)
                    .contentTransition(.symbolEffect(.replace))
                Text(device.name)
                    .font(WorklogFont.body)
                    .foregroundStyle(Color.worklogTextPrimary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, WorklogSpacing.lg)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(MotionPrimitives.aware(MotionPrimitives.interactive), value: isSelected)
    }

    // MARK: - Step 2

    private var micPermissionStep: some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.lg) {
            titleBlock(
                "Allow the microphone",
                "Worklog needs it to record. Location and API keys are optional and live in Settings."
            )
            micStatusCard
        }
    }

    private var micStatusCard: some View {
        HStack(alignment: .top, spacing: WorklogSpacing.md) {
            Image(systemName: micStatusIcon)
                .font(.system(size: 22))
                .foregroundStyle(micStatusColor)
            Text(micStatusText)
                .font(WorklogFont.body)
                .foregroundStyle(Color.worklogTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(WorklogSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: WorklogRadius.lg, style: .continuous)
                .fill(Color.worklogElevatedSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WorklogRadius.lg, style: .continuous)
                .strokeBorder(Color.worklogHairline, lineWidth: 1)
        )
    }

    // MARK: - Footer

    /// The primary action, pinned. On a phone the thing you are meant to do
    /// next belongs under your thumb, not floating after the content.
    private var footer: some View {
        VStack(spacing: WorklogSpacing.sm) {
            Divider().overlay(Color.worklogHairline)
            Group {
                switch viewModel.step {
                case .chooseDevice:
                    WorklogButton("Continue", kind: .primary, fillsWidth: true) {
                        viewModel.confirmDeviceChoice()
                    }
                    .disabled(!viewModel.canContinueFromDeviceStep)
                case .microphonePermission:
                    WorklogButton(micButtonTitle, kind: .primary, fillsWidth: true) {
                        micButtonAction()
                    }
                case .done:
                    EmptyView()
                }
            }
            .padding(.horizontal, WorklogSpacing.screenMargin)
            .padding(.top, WorklogSpacing.sm)
        }
        .background(Color.worklogBackground)
    }

    private func titleBlock(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: WorklogSpacing.sm) {
            Text(title)
                .font(WorklogFont.largeTitle)
                .kerning(WorklogFont.largeTitleTracking)
                .foregroundStyle(Color.worklogTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(WorklogFont.body)
                .foregroundStyle(Color.worklogTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var micStatusIcon: String {
        switch viewModel.micAuthorizationStatus {
        case .authorized: return "checkmark.circle.fill"
        case .denied, .restricted: return "exclamationmark.triangle.fill"
        default: return "mic"
        }
    }

    private var micStatusColor: Color {
        switch viewModel.micAuthorizationStatus {
        case .authorized: return Color.worklogSuccess
        case .denied, .restricted: return Color.worklogWarning
        default: return Color.worklogAccent
        }
    }

    private var micStatusText: String {
        switch viewModel.micAuthorizationStatus {
        case .authorized:
            return "Microphone access granted. You're ready to record."
        case .denied, .restricted:
            return "Microphone access is off, so Worklog can't record. Turn it on in Settings › Worklog › Microphone."
        case .notDetermined:
            return "Worklog will ask for microphone access next."
        @unknown default:
            return ""
        }
    }

    private var micButtonTitle: String {
        switch viewModel.micAuthorizationStatus {
        case .authorized, .denied, .restricted: return "Start using Worklog"
        default: return "Allow microphone"
        }
    }

    private func micButtonAction() {
        switch viewModel.micAuthorizationStatus {
        case .authorized, .denied, .restricted:
            WorklogHaptics.play(.success)
            viewModel.finish()
        default:
            viewModel.requestMicrophonePermission()
        }
    }
}

/// Two dots. Enough to say "this is short" without a progress bar implying
/// there is a lot of it.
private struct StepDots: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: WorklogSpacing.xs) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.worklogAccent : Color.worklogHairline)
                    .frame(width: index == current ? 20 : 6, height: 6)
            }
        }
        .animation(MotionPrimitives.aware(MotionPrimitives.standard), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(total)")
    }
}

/// The single canonical mark. The macOS build loads `Logo.svg` straight out
/// of its bundle and tints it as a template; UIKit cannot decode SVG into a
/// `UIImage`, so iOS uses the app icon artwork from the asset catalog and
/// falls back to a system glyph if it is somehow missing. Same mark either
/// way - never a substitute or a reinvented one.
private struct WorklogWordmark: View {
    var body: some View {
        Group {
            if let image = UIImage(named: "AppIcon") ?? UIImage(named: "appicon_1024") {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.worklogHairline, lineWidth: 0.5)
                    )
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Color.worklogAccent)
                    .frame(width: 64, height: 64)
            }
        }
    }
}
