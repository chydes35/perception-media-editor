import SwiftUI

/// The Masks section of the Develop panel: choose a tool, pick a mask, and adjust it.
struct MaskPanel: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            tools

            if store.maskTool == .brush || store.selectedMask?.shape.isGradient == false {
                brushControls
            }

            if !store.masks.isEmpty {
                maskList
            } else if store.maskTool == .none {
                Text("Pick a tool, then drag on the photo. Gradients darken a sky or lift a face; the brush paints exactly where you want a change.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let mask = store.selectedMask {
                Divider()
                selectedControls(mask)
            }
        }
        .disabled(store.selectedAsset?.kind != .photo)
    }

    // MARK: Tools

    private var tools: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                toolButton(.linear, "Linear", "rectangle.tophalf.inset.filled", "Drag from where the effect is strongest toward where it fades out")
                toolButton(.radial, "Radial", "circle.dashed", "Drag from the center outward")
                toolButton(.brush, "Brush", "paintbrush.pointed", "Paint the area to adjust. Hold ⌥ to erase, and use [ and ] to resize.")
            }
            HStack(spacing: 6) {
                Button {
                    store.startSubjectSelection()
                } label: {
                    Label("Select Subject", systemImage: "person.crop.rectangle.stack")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isAnalyzingSubjects || store.isAnalyzingSky || store.isEditingCrop)
                .help("Detect foreground subjects and select one for local adjustments")
                if store.isAnalyzingSubjects { ProgressView().controlSize(.small) }
                if store.isPickingSubject {
                    Button("Cancel") { store.cancelSubjectSelection() }
                        .buttonStyle(.bordered)
                }
            }
            HStack(spacing: 6) {
                Button {
                    store.startClickSelection()
                } label: {
                    Label("Click to Select", systemImage: "cursorarrow.click.2")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(store.isClickSelecting || store.isAnalyzingSubjects || store.isAnalyzingSky || store.isEditingCrop)
                .help("Click any object in the photo to select it. Option-click removes a part.")
                if store.isPreparingClickSelection { ProgressView().controlSize(.small) }
            }
            if store.isClickSelecting { clickSelectionControls }
            HStack(spacing: 6) {
                Button { store.startSkySelection() } label: {
                    Label("Select Sky", systemImage: "cloud.sun")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(store.isAnalyzingSubjects || store.isAnalyzingSky || store.isEditingCrop)
                .help("Detect the sky for separate exposure and color adjustments")
                if store.isAnalyzingSky {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { store.cancelSkySelection() }
                        .buttonStyle(.bordered)
                }
            }
            if let analysis = store.subjectAnalysis, analysis.candidates.count > 1 {
                HStack {
                    Text("\(analysis.candidates.count) subjects found")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Done selecting") { store.cancelSubjectSelection() }
                        .buttonStyle(.borderless).font(.caption2)
                }
                if store.isPickingSubject {
                    Text("Hover over the photo or a name to preview. Click to select.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Button("Add all subjects") { store.selectAllSubjects() }
                        .onHover { if $0 { store.previewSubjectCandidate(nil) } }
                    ForEach(analysis.candidates) { candidate in
                        Button("Add \(candidate.name)") { store.selectSubjectCandidate(candidate.id) }
                            .tint(store.highlightedSubjectID == candidate.id ? .orange : .accentColor)
                            .onHover { store.previewSubjectCandidate($0 ? candidate.id : nil) }
                            .help("Preview \(candidate.name) in the photo before selecting it")
                    }
                }
                .buttonStyle(.bordered)
            }
            if store.maskTool != .none || store.selectedMask != nil {
                HStack {
                    Toggle("Show mask", isOn: Binding(
                        get: { store.showMaskOverlay },
                        set: { _ in store.toggleMaskOverlay() }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("Tint the masked area red (O)")
                    Spacer()
                    Button("Done") { store.cancelMaskEditing() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Close the mask tools (Esc)")
                }
            }
        }
    }

    private func toolButton(_ tool: MaskTool, _ title: String, _ symbol: String, _ help: String) -> some View {
        let isActive = store.maskTool == tool
        return Button {
            store.chooseMaskTool(tool)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(title).font(.system(size: 10, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(isActive ? Color.orange.opacity(0.22) : Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7).stroke(isActive ? Color.orange : Color.gray.opacity(0.25), lineWidth: isActive ? 1.5 : 0.5)
            }
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("\(title) mask tool")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var brushControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            slider("Size", value: Binding(get: { store.brushSize * 100 }, set: { store.brushSize = $0 / 100 }), range: 0.5 ... 30, format: "%.1f")
            slider("Feather", value: Binding(get: { store.brushFeather * 100 }, set: { store.brushFeather = $0 / 100 }), range: 0 ... 100, format: "%.0f")
            Toggle("Erase", isOn: $store.brushErasing)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Paint away parts of this mask (or hold ⌥)")
        }
    }

    // MARK: List

    private var maskList: some View {
        VStack(spacing: 3) {
            ForEach(store.masks) { mask in
                row(mask)
            }
        }
    }

    private func row(_ mask: LocalMask) -> some View {
        let isSelected = mask.id == store.selectedMaskID
        return HStack(spacing: 6) {
            Button {
                store.updateMask(mask.id) { $0.isEnabled.toggle() }
            } label: {
                Image(systemName: mask.isEnabled ? "eye" : "eye.slash")
                    .frame(width: 16)
                    .foregroundStyle(mask.isEnabled ? Color.primary : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(mask.isEnabled ? "Hide this mask's effect" : "Show this mask's effect")

            Button {
                store.selectMask(isSelected ? nil : mask.id)
            } label: {
                HStack {
                    Image(systemName: icon(for: mask)).frame(width: 16).foregroundStyle(.secondary)
                    Text(store.displayName(for: mask)).font(.caption).lineLimit(1)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                store.deleteMask(mask.id)
            } label: {
                Image(systemName: "trash").font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("Delete this mask")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(isSelected ? Color.orange.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func icon(for mask: LocalMask) -> String {
        switch mask.shape {
        case .linear: "rectangle.tophalf.inset.filled"
        case .radial: "circle.dashed"
        case .brush: "paintbrush.pointed"
        case .subject: "person.crop.rectangle"
        case .sky: "cloud.sun"
        }
    }

    // MARK: Selected mask

    private func selectedControls(_ mask: LocalMask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Invert", isOn: Binding(
                    get: { mask.invert },
                    set: { value in store.updateMask(mask.id) { $0.invert = value } }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                Spacer()
                Button("Duplicate") { store.duplicateMask(mask.id) }
                    .buttonStyle(.borderless).font(.caption)
                Button("Reset") { store.resetMaskAdjustments(mask.id) }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(mask.adjustments.isNeutral)
            }

            maskSlider("Amount", mask, range: 0 ... 100, format: "%.0f") { $0.amount * 100 } set: { $0.amount = $1 / 100 }

            if let subject = mask.shape.rasterSelection {
                let kind = mask.shape.kindName
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("REFINE \(kind.uppercased())")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset edges") {
                            store.nextHistoryLabel = "Reset \(kind.lowercased()) edges"
                            store.updateMask(mask.id) {
                                guard var value = $0.shape.rasterSelection else { return }
                                value.edgeShift = 0
                                value.edgeFeather = 0
                                value.edgeContrast = 0
                                $0.shape.rasterSelection = value
                            }
                        }
                        .buttonStyle(.borderless).font(.caption2)
                        .disabled(subject.edgeShift == 0 && subject.edgeFeather == 0 && subject.edgeContrast == 0)
                    }
                    subjectEdgeSlider("Edge shift", mask, -0.5 ... 0.5, \.edgeShift, format: "%.2f%%")
                        .help("Negative values pull the edge inward; positive values expand it. Percentage of the photo's longer side.")
                    subjectEdgeSlider("Edge feather", mask, 0 ... 0.5, \.edgeFeather, format: "%.2f%%")
                        .help("Soften the selection boundary. Keep low to preserve fine hair and translucent fabric.")
                    subjectEdgeSlider("Edge contrast", mask, 0 ... 100, \.edgeContrast, format: "%.0f")
                        .help("Make soft selection edges firmer. Higher values may remove translucent detail.")
                    HStack(spacing: 6) {
                        Button {
                            store.beginSubjectRefinement(erasing: false)
                        } label: {
                            Label("Add to \(kind.lowercased())", systemImage: "plus.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .tint(store.maskTool == .brush && !store.brushErasing ? .orange : .accentColor)
                        Button {
                            store.beginSubjectRefinement(erasing: true)
                        } label: {
                            Label("Remove spill", systemImage: "minus.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .tint(store.maskTool == .brush && store.brushErasing ? .orange : .accentColor)
                    }
                    .buttonStyle(.bordered)
                    Text("Paint over areas to add or remove them. Adjust Size and Feather above; press Esc when done.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if case .radial(let center, let rx, let ry, let rotation, let feather) = mask.shape {
                slider("Feather", value: Binding(
                    get: { feather * 100 },
                    set: { value in
                        store.updateMask(mask.id) { $0.shape = .radial(center: center, radiusX: rx, radiusY: ry, rotation: rotation, feather: value / 100) }
                    }
                ), range: 0 ... 100, format: "%.0f")
                slider("Rotation", value: Binding(
                    get: { rotation },
                    set: { value in
                        store.updateMask(mask.id) { $0.shape = .radial(center: center, radiusX: rx, radiusY: ry, rotation: value, feather: feather) }
                    }
                ), range: -180 ... 180, format: "%.0f°")
            }

            Text("ADJUST INSIDE THE MASK")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)

            adjustment("Exposure", mask, -3 ... 3, \.exposure)
            adjustment("Contrast", mask, -1 ... 1, \.contrast)
            adjustment("Highlights", mask, -1 ... 1, \.highlights)
            adjustment("Shadows", mask, -1 ... 1, \.shadows)
            adjustment("Warmth", mask, -1 ... 1, \.temperature)
            adjustment("Tint", mask, -1 ... 1, \.tint)
            adjustment("Saturation", mask, -1 ... 1, \.saturation)
            adjustment("Sharpness", mask, 0 ... 1, \.sharpness)
        }
    }

    private func adjustment(
        _ label: String, _ mask: LocalMask, _ range: ClosedRange<Double>, _ keyPath: WritableKeyPath<MaskAdjustments, Double>
    ) -> some View {
        maskSlider(label, mask, range: range, format: "%.2f") { $0.adjustments[keyPath: keyPath] } set: { $0.adjustments[keyPath: keyPath] = $1 }
    }

    private var clickSelectionControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.isPreparingClickSelection
                 ? "Getting the photo ready. The first selection can take a few seconds."
                 : "Click what you want. Click more to add, ⌥-click to remove a part.")
                .font(.caption2).foregroundStyle(.secondary)
            if store.clickMaskPNGs.count > 1 {
                Picker("Size", selection: Binding(get: { store.clickGranularity }, set: { store.setClickGranularity($0) })) {
                    Text("Part").tag(0)
                    Text("Object").tag(1)
                    if store.clickMaskPNGs.count > 2 { Text("Whole").tag(2) }
                }
                .pickerStyle(.segmented)
                .help("The same click can mean a part, the object, or everything it belongs to")
            }
            HStack {
                Button("Accept") { store.acceptClickSelection() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.clickMaskPNGs.isEmpty)
                Button("Undo click") { store.undoClickPoint() }
                    .disabled(store.clickPoints.isEmpty)
                Button("Cancel") { store.cancelClickSelection() }
                if store.isDecodingClickSelection { ProgressView().controlSize(.small) }
            }
            .buttonStyle(.bordered)
        }
    }

    private func subjectEdgeSlider(
        _ label: String, _ mask: LocalMask, _ range: ClosedRange<Double>,
        _ keyPath: WritableKeyPath<SubjectMask, Double>, format: String
    ) -> some View {
        maskSlider(label, mask, range: range, format: format) {
            guard let subject = $0.shape.rasterSelection else { return 0 }
            return subject[keyPath: keyPath] * 100
        } set: {
            guard var subject = $0.shape.rasterSelection else { return }
            subject[keyPath: keyPath] = $1 / 100
            $0.shape.rasterSelection = subject
        }
    }

    /// A slider that reads and writes one value of a mask, as one undo step per drag.
    private func maskSlider(
        _ label: String, _ mask: LocalMask, range: ClosedRange<Double>, format: String,
        get: @escaping (LocalMask) -> Double, set: @escaping (inout LocalMask, Double) -> Void
    ) -> some View {
        slider(label, value: Binding(
            get: { get(store.masks.first { $0.id == mask.id } ?? mask) },
            set: { value in store.updateMask(mask.id) { set(&$0, value) } }
        ), range: range, format: format)
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, onEditingChanged: { editing in
                if editing { store.beginAdjustmentEdit() } else { store.endAdjustmentEdit() }
            })
            .tint(.orange)
            .accessibilityLabel(label)
        }
    }
}
