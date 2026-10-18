import SwiftUI

/// One labeled slider for a value of the selected timeline clip's color adjustments.
/// Shared by the Cut inspector and the Color screen.
struct VideoAdjustmentSlider: View {
    @EnvironmentObject private var store: EditorStore
    let label: String
    let keyPath: WritableKeyPath<PhotoAdjustments, Double>
    let range: ClosedRange<Double>

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                Spacer()
                Text(
                    store.selectedVideoAdjustments[keyPath: keyPath],
                    format: .number.precision(.fractionLength(2))
                )
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
            }
            Slider(
                value: Binding(
                    get: { store.selectedVideoAdjustments[keyPath: keyPath] },
                    set: { value in
                        store.updateSelectedVideoAdjustments { $0[keyPath: keyPath] = value }
                    }
                ),
                in: range
            )
            .tint(.orange)
            .accessibilityLabel(label)
        }
    }
}
