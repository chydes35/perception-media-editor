import SwiftUI

/// A creative LUT and its intensity, for a photo or a timeline clip.
struct LUTControls: View {
    @EnvironmentObject private var store: EditorStore
    let application: LUTApplication?
    let setLUT: (LUTReference?) -> Void
    let setIntensity: (Double) -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }
    var tint: Color = .orange

    /// The library plus the current LUT, which may be missing from it.
    private var choices: [LUTReference] {
        var all = store.availableLUTs
        if let current = application?.reference, !all.contains(current) { all.append(current) }
        return all
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("LUT", selection: Binding(get: { application?.reference }, set: { setLUT($0) })) {
                    Text("None").tag(LUTReference?.none)
                    ForEach(choices) { reference in
                        Text(reference.displayName).tag(Optional(reference))
                    }
                }
                .labelsHidden()
                Button("Import…") {
                    Task {
                        if let reference = await store.chooseAndImportLUT() { setLUT(reference) }
                    }
                }
                .help("Import a .cube LUT. The file is copied; the original is never changed.")
            }
            .controlSize(.small)

            if let application {
                if store.missingLUTs.contains(application.reference) {
                    Label("This LUT's file is missing, so it is not applied.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Text("Intensity").font(.caption)
                    Spacer()
                    Text(application.intensity, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(get: { application.intensity }, set: { setIntensity(min(1, max(0, $0))) }),
                    in: 0 ... 1,
                    onEditingChanged: onEditingChanged
                )
                .tint(tint)
            }
        }
    }
}

/// How a video's code values become picture color: as recorded, through OpenColorIO's V-Log to
/// ACES 2.0 Rec. 709, or through a LUT such as Panasonic's V-Log to V-709.
struct SourceColorPicker: View {
    @EnvironmentObject private var store: EditorStore
    let asset: MediaAsset

    private var current: ColorInputTransform { store.project.colorInput(for: asset.id) }

    private var choices: [LUTReference] {
        var all = store.availableLUTs
        if case .lut(let reference) = current, !all.contains(reference) { all.append(reference) }
        return all
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Source color", selection: Binding(get: { current }, set: { store.setColorInput($0, forAssets: [asset.id]) })) {
                    Text("Automatic").tag(ColorInputTransform.automatic)
                    Text("As recorded").tag(ColorInputTransform.none)
                    // Only the V-Log transform exists so far; Apple Log's comes with plan Task 13.3.
                    if asset.sourceColor?.transfer != .appleLog || current == .aces {
                        Text("V-Log → Rec. 709 (ACES 2.0)").tag(ColorInputTransform.aces)
                    }
                    ForEach(choices) { reference in
                        Text("LUT: \(reference.displayName)").tag(ColorInputTransform.lut(reference))
                    }
                }
                .font(.caption)
                Button("Import LUT…") {
                    Task {
                        if let reference = await store.chooseAndImportLUT() {
                            store.setColorInput(.lut(reference), forAssets: [asset.id])
                        }
                    }
                }
            }
            .controlSize(.small)
            if case .lut(let reference) = current, store.missingLUTs.contains(reference) {
                Label("This LUT's file is missing, so the clip shows as recorded.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if current == .automatic, asset.sourceColor?.transfer == .vLog {
                Text("V-Log is shown through ACES 2.0 (OpenColorIO). Choose As recorded for the flat log image.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if current == .automatic, asset.sourceColor?.transfer == .appleLog {
                Text("Apple Log shows as recorded (flat) for now. Import Apple's Apple Log to Rec. 709 LUT to view it normally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if asset.sourceColor?.isHDR == true {
                Text("HDR source — shown without tone mapping.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if asset.sourceColor?.isUnsupportedLog == true {
                Text("This log format (such as Apple Log 2) is not supported yet; it shows as recorded.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if current == .automatic, asset.sourceColor?.detectedFrom == .formatDescription || asset.sourceColor == nil {
                // Only the camera's own metadata rules out log; container tags do not (Lumix V-Log is tagged BT.709).
                Text("Set source color if this is log footage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
