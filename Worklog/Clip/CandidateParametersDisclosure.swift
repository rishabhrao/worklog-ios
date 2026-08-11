import SwiftUI

/// Advanced/disclosure section exposing candidate-detection tuning:
/// sensitivity, minimum quiet, marker count. Per spec, this doesn't
/// need to live in Settings - it's session-local tuning for the current
/// range, not persistent app config.
struct CandidateParametersDisclosure: View {
    @Binding var parameters: CandidateDetectionParameters
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: WorklogSpacing.sm) {
                labeledSlider(
                    "Sensitivity",
                    value: Binding(
                        get: { Double(parameters.sensitivity) },
                        set: { parameters.sensitivity = Float($0) }
                    ),
                    range: 0...1,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                labeledSlider(
                    "Minimum quiet before a start",
                    value: $parameters.minimumSilenceDuration,
                    range: 0.5...10,
                    format: { "\(Int($0))s" }
                )
                labeledSlider(
                    "Marker count",
                    value: Binding(
                        get: { Double(parameters.maxCandidates) },
                        set: { parameters.maxCandidates = Int($0) }
                    ),
                    range: 1...15,
                    format: { "\(Int($0))" }
                )
            }
            .padding(.top, WorklogSpacing.sm)
        } label: {
            Text("Candidate detection")
                .font(WorklogFont.bodyEmphasized)
                .foregroundStyle(Color.worklogTextSecondary)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(MotionPrimitives.aware(MotionPrimitives.standard)) {
                        expanded.toggle()
                    }
                }
        }
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: @escaping (Double) -> String) -> some View {
        HStack {
            Text(title)
                .font(WorklogFont.caption)
                .foregroundStyle(Color.worklogTextSecondary)
                .frame(width: 160, alignment: .leading)
            Slider(value: value, in: range)
            Text(format(value.wrappedValue))
                .font(WorklogFont.transcriptCaption)
                .foregroundStyle(Color.worklogTextTertiary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}
