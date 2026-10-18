import SwiftUI

extension AdjustmentEditing {
    func setGrade(_ change: @escaping (inout ColorGradeAdjustments) -> Void) {
        update { adjustments in
            var grade = adjustments.grading ?? ColorGradeAdjustments()
            change(&grade)
            adjustments.grading = grade.isNeutral ? nil : grade
        }
    }

    func resetGrade() {
        update { $0.grading = nil }
    }

    func setGrain(_ change: @escaping (inout GrainAdjustments) -> Void) {
        update { adjustments in
            var grain = adjustments.grain ?? GrainAdjustments()
            change(&grain)
            adjustments.grain = grain.isNeutral ? nil : grain
        }
    }

    func resetGrain() {
        update { $0.grain = nil }
    }
}

/// A labelled slider with a numeric field, shown in a display scale (for example 0…100).
private struct EffectSlider: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let scale: Double
    let editing: AdjustmentEditing
    let onChange: (Double) -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                TextField(
                    label,
                    value: Binding(
                        get: { (value * scale).rounded() },
                        set: { onChange(min(range.upperBound, max(range.lowerBound, $0 / scale))) }
                    ),
                    format: .number.precision(.fractionLength(0))
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
            }
            Slider(
                value: Binding(get: { value }, set: onChange),
                in: range,
                onEditingChanged: { dragging in
                    if dragging { editing.beginEdit() } else { editing.endEdit() }
                }
            )
            .disabled(!editing.isAvailable)
            .accessibilityLabel(label)
        }
    }
}

struct ThreeWayGradePanel: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.adjustmentEditing) private var environmentEditing
    @State private var zone: ColorGradeAdjustments.Zone = .shadows

    private var editing: AdjustmentEditing { environmentEditing ?? store.photoAdjustmentEditing }
    private var grade: ColorGradeAdjustments { editing.current.grading ?? ColorGradeAdjustments() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Zone", selection: $zone) {
                    ForEach(ColorGradeAdjustments.Zone.allCases) { zone in
                        Text(zone.title).tag(zone)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                if editing.current.grading != nil {
                    Button { editing.resetGrade() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless)
                        .help("Reset color grading")
                }
            }

            // The swatch shows the tint this zone adds, at full saturation.
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hue: grade[zone].hue / 360, saturation: max(0.15, grade[zone].saturation), brightness: 0.95))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color.primary.opacity(0.4), lineWidth: 1))
                Text(zone.title).font(.caption.weight(.semibold))
            }

            EffectSlider(label: "Hue", value: grade[zone].hue, range: 0 ... 360, scale: 1, editing: editing) { v in
                editing.setGrade { $0[zone].hue = v }
            }
            EffectSlider(label: "Saturation", value: grade[zone].saturation, range: 0 ... 1, scale: 100, editing: editing) { v in
                editing.setGrade { $0[zone].saturation = v }
            }
            EffectSlider(label: "Luminance", value: grade[zone].luminance, range: -1 ... 1, scale: 100, editing: editing) { v in
                editing.setGrade { $0[zone].luminance = v }
            }
            EffectSlider(label: "Blending", value: grade.blending, range: 0 ... 1, scale: 100, editing: editing) { v in
                editing.setGrade { $0.blending = v }
            }
            EffectSlider(label: "Balance", value: grade.balance, range: -1 ... 1, scale: 100, editing: editing) { v in
                editing.setGrade { $0.balance = v }
            }
        }
    }
}

struct GrainPanel: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.adjustmentEditing) private var environmentEditing

    private var editing: AdjustmentEditing { environmentEditing ?? store.photoAdjustmentEditing }
    private var grain: GrainAdjustments { editing.current.grain ?? GrainAdjustments() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if editing.current.grain != nil {
                HStack {
                    Spacer()
                    Button { editing.resetGrain() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless)
                        .help("Remove grain")
                }
            }
            EffectSlider(label: "Amount", value: grain.amount, range: 0 ... 1, scale: 100, editing: editing) { v in
                editing.setGrain { $0.amount = v }
            }
            EffectSlider(label: "Size", value: grain.size, range: 0 ... 1, scale: 100, editing: editing) { v in
                editing.setGrain { $0.size = v }
            }
            EffectSlider(label: "Roughness", value: grain.roughness, range: 0 ... 1, scale: 100, editing: editing) { v in
                editing.setGrain { $0.roughness = v }
            }
            Text("Grain applies to photos, not video clips.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
